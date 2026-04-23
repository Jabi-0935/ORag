"""
storage.py — SQLite-backed document and chunk store.

Stores document metadata, text chunks with TF-IDF vectors, and an FTS5
full-text index for native BM25 ranking.  Supports "Small-to-Big"
hierarchical retrieval via parent_chunk_idx.

No external vector DB needed; everything lives in a single SQLite file.
"""
import sqlite3
import json
import os
import pickle
from pathlib import Path
from typing import List, Tuple, Optional


DB_PATH = os.path.join(
    os.environ.get("ANDROID_PRIVATE", os.path.expanduser("~")),
    "ragapp.db",
)


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL;")   # faster concurrent writes
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA foreign_keys=ON;")    # enable CASCADE deletes
    return conn


def init_db() -> None:
    """Create tables if they don't exist.

    Includes:
    - FTS5 virtual table for native BM25 sparse retrieval
    - parent_chunk_idx column for Small-to-Big hierarchical expansion
    - Triggers to keep FTS5 index in sync with chunks table
    """
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
                parent_chunk_idx INTEGER DEFAULT -1  -- index into parent chunk array (-1 = none)
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

        # --- Migration: add parent_chunk_idx if missing ---
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
        except Exception as e:
            print(f"[storage] Migration check failed (non-fatal): {e}")

        # --- Rebuild FTS index from existing data (idempotent) ---
        try:
            conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
        except Exception:
            pass


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
    """Load every chunk (text + tokens + tfidf_vec) for the retriever."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, doc_id, chunk_idx, text, tokens, tfidf_vec, parent_chunk_idx FROM chunks"
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
                "tfidf_vec": pickle.loads(r[5]) if r[5] else {},
                "parent_chunk_idx": r[6] if r[6] is not None else -1,
            }
        )
    return result


def get_chunk_texts_by_ids(ids: List[int]) -> List[str]:
    placeholders = ",".join("?" * len(ids))
    with get_conn() as conn:
        rows = conn.execute(
            f"SELECT id, text FROM chunks WHERE id IN ({placeholders})", ids
        ).fetchall()
    id_to_text = {r[0]: r[1] for r in rows}
    return [id_to_text[i] for i in ids if i in id_to_text]


# ---------- FTS5 BM25 search ----------

def fts5_bm25_search(query: str, top_k: int = 10) -> List[Tuple[int, float]]:
    """
    Run a BM25 search via SQLite FTS5.

    Returns list of (chunk_rowid, bm25_score) sorted by relevance.
    FTS5's rank column returns negative BM25 scores (lower = better),
    so we negate for a conventional "higher is better" interface.
    """
    if not query or not query.strip():
        return []
    try:
        with get_conn() as conn:
            # FTS5 MATCH query — simple terms joined by OR for broad matching
            terms = query.strip().split()
            if not terms:
                return []
            # Use OR to match any term (more recall), FTS5 handles ranking
            fts_query = " OR ".join(t for t in terms if t.strip())
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
