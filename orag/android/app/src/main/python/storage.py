"""
storage.py — SQLite-backed document and chunk store.

Stores document metadata, text chunks with TF-IDF vectors, and an FTS5
full-text index for native BM25 ranking.  Supports "Small-to-Big"
hierarchical retrieval via parent_chunk_idx.

Optimizations:
  - Thread-local connection pooling (avoids per-call connect overhead)
  - Embedding persistence (BLOB column) — survives app restarts
  - FTS5 query preprocessing with stopword removal

No external vector DB needed; everything lives in a single SQLite file.
"""
import atexit
import sqlite3
import json
import os
import pickle
import struct
import threading
from pathlib import Path
from typing import List, Tuple, Optional


DB_PATH = os.path.join(
    os.environ.get("ANDROID_PRIVATE", os.path.expanduser("~")),
    "ragapp.db",
)


# ------------------------------------------------------------------ #
#  Thread-local connection pool                                        #
# ------------------------------------------------------------------ #

_local = threading.local()
_db_initialized = False


def get_conn() -> sqlite3.Connection:
    """Return a thread-local SQLite connection (reused across calls)."""
    conn = getattr(_local, 'conn', None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL;")      # faster concurrent writes
        conn.execute("PRAGMA synchronous=NORMAL;")
        conn.execute("PRAGMA foreign_keys=ON;")        # enable CASCADE deletes
        conn.execute("PRAGMA cache_size=-4000;")       # 4 MB page cache
        conn.execute("PRAGMA mmap_size=8388608;")      # 8 MB mmap for reads
        _local.conn = conn
    return conn


def close_conn() -> None:
    """Explicitly close the thread-local connection (call on shutdown)."""
    conn = getattr(_local, 'conn', None)
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
        _local.conn = None


def init_db() -> None:
    """Create tables if they don't exist.

    Includes:
    - FTS5 virtual table for native BM25 sparse retrieval
    - parent_chunk_idx column for Small-to-Big hierarchical expansion
    - embedding BLOB column for persisted dense vectors
    - Triggers to keep FTS5 index in sync with chunks table
    """
    global _db_initialized
    if _db_initialized:
        return
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                name      TEXT NOT NULL,
                path      TEXT NOT NULL UNIQUE,
                added_at  TEXT DEFAULT (datetime('now')),
                num_chunks INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS chunks (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id           INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                chunk_idx        INTEGER NOT NULL,
                text             TEXT NOT NULL,
                tokens           TEXT,          -- JSON list of lowercase tokens
                tfidf_vec        BLOB,          -- pickled dict {term: tf_idf_score}
                parent_chunk_idx INTEGER DEFAULT -1,  -- index into parent chunk array (-1 = none)
                embedding        BLOB DEFAULT NULL     -- persisted dense vector (packed floats)
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);

            CREATE TABLE IF NOT EXISTS chunk_images (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                chunk_id   INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                doc_id     INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                image_path TEXT NOT NULL,
                page_num   INTEGER DEFAULT 0,
                width      INTEGER DEFAULT 0,
                height     INTEGER DEFAULT 0
            );

            CREATE INDEX IF NOT EXISTS idx_chunk_images_chunk ON chunk_images(chunk_id);

            -- Parent chunks table for Small-to-Big expansion
            CREATE TABLE IF NOT EXISTS parent_chunks (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id           INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                parent_chunk_idx INTEGER NOT NULL,
                text             TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_parent_chunks_doc ON parent_chunks(doc_id);
            """
        )

        # --- FTS5 virtual table for native BM25 ---
        # content-linked to the chunks table so we don't duplicate text.
        # Use try/except because CREATE VIRTUAL TABLE IF NOT EXISTS
        # is supported in newer SQLite but we guard for older versions.
        try:
            conn.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts
                USING fts5(text, content='chunks', content_rowid='id')
                """
            )
        except Exception as e:
            print(f"[storage] FTS5 table creation skipped: {e}")

        # --- Triggers to keep FTS5 in sync ---
        for trigger_sql in [
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
        ]:
            try:
                conn.execute(trigger_sql)
            except Exception:
                pass  # Trigger already exists

        # --- Migrations for existing databases ---
        try:
            cols = [
                row[1]
                for row in conn.execute("PRAGMA table_info(chunks)").fetchall()
            ]
            if "parent_chunk_idx" not in cols:
                conn.execute(
                    "ALTER TABLE chunks ADD COLUMN parent_chunk_idx INTEGER DEFAULT -1"
                )
                print("[storage] Migrated: added parent_chunk_idx to chunks")
            if "embedding" not in cols:
                conn.execute(
                    "ALTER TABLE chunks ADD COLUMN embedding BLOB DEFAULT NULL"
                )
                print("[storage] Migrated: added embedding column to chunks")
        except Exception as e:
            print(f"[storage] Migration check failed (non-fatal): {e}")

        # --- Rebuild FTS index from existing data (idempotent) ---
        try:
            conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
        except Exception:
            pass
    _db_initialized = True


# ------------------------------------------------------------------ #
#  Embedding serialization helpers                                     #
# ------------------------------------------------------------------ #

def _pack_embedding(emb: list) -> bytes:
    """Pack a list of floats into a compact binary BLOB."""
    return struct.pack(f'{len(emb)}f', *emb)


def _unpack_embedding(blob: bytes) -> list:
    """Unpack a binary BLOB back to a list of floats."""
    n = len(blob) // 4  # 4 bytes per float
    return list(struct.unpack(f'{n}f', blob))


# ---------- document helpers ----------

def insert_document(name: str, path: str) -> int:
    with get_conn() as conn:
        # Check if this path already exists — if so, delete its old chunks
        # so re-uploading the same file doesn't accumulate duplicates.
        existing = conn.execute(
            "SELECT id FROM documents WHERE path=?", (path,)
        ).fetchone()
        if existing:
            doc_id = existing[0]
            conn.execute("DELETE FROM chunks WHERE doc_id=?", (doc_id,))
            conn.execute("DELETE FROM parent_chunks WHERE doc_id=?", (doc_id,))
            return doc_id
        cur = conn.execute(
            "INSERT INTO documents(name, path) VALUES (?, ?)", (name, path)
        )
        return cur.lastrowid


def update_doc_chunk_count(doc_id: int, count: int) -> None:
    with get_conn() as conn:
        conn.execute(
            "UPDATE documents SET num_chunks=? WHERE id=?", (count, doc_id)
        )


def list_documents() -> List[dict]:
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, name, path, added_at, num_chunks FROM documents ORDER BY added_at DESC"
        ).fetchall()
    return [
        {"id": r[0], "name": r[1], "path": r[2], "added_at": r[3], "num_chunks": r[4]}
        for r in rows
    ]


def delete_document(doc_id: int) -> None:
    with get_conn() as conn:
        conn.execute("DELETE FROM parent_chunks WHERE doc_id=?", (doc_id,))
        conn.execute("DELETE FROM documents WHERE id=?", (doc_id,))


# ---------- chunk helpers ----------

def insert_chunks(doc_id: int, chunks: List[dict]) -> List[int]:
    """
    chunks: list of dicts with keys:
        chunk_idx, text, tokens (list[str]), tfidf_vec (dict),
        parent_chunk_idx (int, optional)
    Returns list of inserted chunk IDs (for image association).
    """
    rows = [
        (
            doc_id,
            c["chunk_idx"],
            c["text"],
            json.dumps(c["tokens"]),
            pickle.dumps(c["tfidf_vec"]),
            c.get("parent_chunk_idx", -1),
        )
        for c in chunks
    ]
    chunk_ids = []
    with get_conn() as conn:
        for row in rows:
            cur = conn.execute(
                "INSERT INTO chunks(doc_id, chunk_idx, text, tokens, tfidf_vec, parent_chunk_idx) "
                "VALUES (?,?,?,?,?,?)",
                row,
            )
            chunk_ids.append(cur.lastrowid)
    return chunk_ids


def insert_parent_chunks(doc_id: int, parent_chunks: List[dict]) -> None:
    """
    Store parent (big) chunks for Small-to-Big expansion.
    parent_chunks: list of dicts with keys: parent_chunk_idx, text
    """
    with get_conn() as conn:
        conn.executemany(
            "INSERT INTO parent_chunks(doc_id, parent_chunk_idx, text) VALUES (?,?,?)",
            [(doc_id, pc["parent_chunk_idx"], pc["text"]) for pc in parent_chunks],
        )


def get_parent_chunk_text(doc_id: int, parent_chunk_idx: int) -> Optional[str]:
    """Retrieve the parent (big) chunk text for Small-to-Big expansion."""
    if parent_chunk_idx < 0:
        return None
    with get_conn() as conn:
        row = conn.execute(
            "SELECT text FROM parent_chunks WHERE doc_id=? AND parent_chunk_idx=?",
            (doc_id, parent_chunk_idx),
        ).fetchone()
    return row[0] if row else None


def load_all_chunks() -> List[dict]:
    """Load chunks for the retriever (text + metadata, skips heavy TF-IDF blobs)."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, doc_id, chunk_idx, text, tokens, parent_chunk_idx FROM chunks"
        ).fetchall()
    result = []
    for r in rows:
        result.append(
            {
                "id": r[0],
                "doc_id": r[1],
                "chunk_idx": r[2],
                "text": r[3],
                "tokens": json.loads(r[4]) if r[4] else [],
                "parent_chunk_idx": r[5] if r[5] is not None else -1,
            }
        )
    return result


# Auto-close DB connections on interpreter shutdown
atexit.register(close_conn)


def load_chunk_metadata() -> List[dict]:
    """Load lightweight chunk metadata only (no text/tokens/tfidf).
    Used by the optimized retriever for O(1) lookups without full RAM load.
    """
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, doc_id, parent_chunk_idx FROM chunks"
        ).fetchall()
    return [
        {"id": r[0], "doc_id": r[1], "parent_chunk_idx": r[2] if r[2] is not None else -1}
        for r in rows
    ]


def get_chunk_text(chunk_id: int) -> Optional[str]:
    """Fetch a single chunk's text by ID (on-demand, not preloaded)."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT text FROM chunks WHERE id=?", (chunk_id,)
        ).fetchone()
    return row[0] if row else None


def get_chunk_texts_by_ids(ids: List[int]) -> List[str]:
    if not ids:
        return []
    placeholders = ",".join("?" * len(ids))
    with get_conn() as conn:
        rows = conn.execute(
            f"SELECT id, text FROM chunks WHERE id IN ({placeholders})", ids
        ).fetchall()
    id_to_text = {r[0]: r[1] for r in rows}
    return [id_to_text[i] for i in ids if i in id_to_text]


# ------------------------------------------------------------------ #
#  Embedding persistence                                               #
# ------------------------------------------------------------------ #

def save_embeddings_batch(embeddings: dict) -> None:
    """Persist chunk embeddings to SQLite.
    embeddings: {chunk_id: [float, ...]}
    """
    if not embeddings:
        return
    with get_conn() as conn:
        conn.executemany(
            "UPDATE chunks SET embedding=? WHERE id=?",
            [(
                _pack_embedding(emb),
                chunk_id,
            ) for chunk_id, emb in embeddings.items()],
        )
    print(f"[storage] Persisted {len(embeddings)} embeddings")


def load_cached_embeddings() -> dict:
    """Load all persisted embeddings from SQLite.
    Returns {chunk_id: [float, ...]}.
    """
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL"
        ).fetchall()
    result = {}
    for chunk_id, blob in rows:
        if blob:
            try:
                result[chunk_id] = _unpack_embedding(blob)
            except Exception:
                pass
    if result:
        print(f"[storage] Loaded {len(result)} cached embeddings")
    return result


# ---------- FTS5 BM25 search ----------

# Minimal stopwords for query preprocessing (matches chunker._STOP)
_QUERY_STOP = frozenset(
    "a an the is are was were be been being have has had do does did "
    "will would could should may might shall can of in on at to for "
    "from by with about as into through during including before after "
    "above below between each other than and or but not this that "
    "these those i me my we our you your he she it its they them their "
    "what which who whom when where why how all both each few more most "
    "other some such no nor only same so than too very just".split()
)


def fts5_bm25_search(query: str, top_k: int = 10) -> List[Tuple[int, float]]:
    """
    Run a BM25 search via SQLite FTS5.

    Returns list of (chunk_rowid, bm25_score) sorted by relevance.
    FTS5's rank column returns negative BM25 scores (lower = better),
    so we negate for a conventional "higher is better" interface.

    Query preprocessing: removes stopwords and quotes terms for safety.
    """
    if not query or not query.strip():
        return []
    try:
        with get_conn() as conn:
            # Preprocess: split, remove stopwords, filter short tokens
            terms = query.strip().split()
            terms = [t for t in terms if t.lower() not in _QUERY_STOP and len(t) > 1]
            if not terms:
                # Fallback: use original query if all terms are stopwords
                terms = query.strip().split()[:5]
            if not terms:
                return []
            # Quote each term for FTS5 safety, join with OR for broad matching
            fts_query = " OR ".join(f'"{t}"' for t in terms)
            rows = conn.execute(
                "SELECT rowid, rank FROM chunks_fts WHERE chunks_fts MATCH ? "
                "ORDER BY rank LIMIT ?",
                (fts_query, top_k),
            ).fetchall()
        # rank is negative (lower = better), negate for "higher is better"
        return [(r[0], -r[1]) for r in rows]
    except Exception as e:
        print(f"[storage] FTS5 search failed: {e}")
        return []


# ---------- chunk image helpers ----------

def insert_chunk_images(chunk_id: int, doc_id: int, images: List[dict]) -> None:
    """
    Store image metadata for a chunk.
    images: list of dicts with keys: path, page, width, height
    """
    rows = [
        (
            chunk_id,
            doc_id,
            img["path"],
            img.get("page", 0),
            img.get("width", 0),
            img.get("height", 0),
        )
        for img in images
    ]
    with get_conn() as conn:
        conn.executemany(
            "INSERT INTO chunk_images(chunk_id, doc_id, image_path, page_num, width, height) "
            "VALUES (?,?,?,?,?,?)",
            rows,
        )


def get_images_for_chunks(chunk_ids: List[int]) -> List[dict]:
    """Return all images associated with the given chunk IDs."""
    if not chunk_ids:
        return []
    placeholders = ",".join("?" * len(chunk_ids))
    with get_conn() as conn:
        rows = conn.execute(
            f"SELECT chunk_id, image_path, page_num, width, height "
            f"FROM chunk_images WHERE chunk_id IN ({placeholders})",
            chunk_ids,
        ).fetchall()
    return [
        {
            "chunk_id": r[0],
            "image_path": r[1],
            "page_num": r[2],
            "width": r[3],
            "height": r[4],
        }
        for r in rows
    ]
