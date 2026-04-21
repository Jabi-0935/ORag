"""
storage.py — SQLite-backed document and chunk store.

Stores document metadata and text chunks with their TF-IDF vectors
and dense embedding vectors.

Phase 1 changes:
  - tfidf_vec: pickle BLOB → JSON TEXT (security + portability)
  - embedding: new TEXT column (JSON float array, NULL until computed)
  - ingest_document_atomic: single-connection transaction replaces the
    old three-step sequence that could leave the DB inconsistent
  - _migrate_pickle_to_json: one-time migration run at init_db()

Phase 3 changes:
  - Removed deprecated insert_document, insert_chunks,
    update_doc_chunk_count — all call sites now use ingest_document_atomic
  - pickle import kept (needed by _migrate_pickle_to_json for legacy rows)
"""
import sqlite3
import json
import os
import pickle   # used only by _migrate_pickle_to_json for legacy row conversion
from typing import List


DB_PATH = os.path.join(
    os.environ.get("ANDROID_PRIVATE", os.path.expanduser("~")),
    "ragapp.db",
)


# ------------------------------------------------------------------ #
#  Connection                                                          #
# ------------------------------------------------------------------ #

def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL;")   # faster concurrent writes
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA foreign_keys=ON;")    # enable CASCADE deletes
    return conn


# ------------------------------------------------------------------ #
#  Schema + migration                                                  #
# ------------------------------------------------------------------ #

def init_db() -> None:
    """
    Create tables if they don't exist, then run any pending migrations.
    Safe to call multiple times — all operations are idempotent.
    """
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT    NOT NULL,
                path       TEXT    NOT NULL UNIQUE,
                added_at   TEXT    DEFAULT (datetime('now')),
                num_chunks INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS chunks (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id    INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                text      TEXT    NOT NULL,
                tokens    TEXT,        -- JSON list of lowercase tokens for BM25
                tfidf_vec TEXT,        -- JSON dict {term: tf_idf_score}
                embedding TEXT         -- JSON float array, NULL until computed
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);
            """
        )

        # Add embedding column if upgrading from a schema that predates it.
        # "duplicate column" error means it already exists — safe to ignore.
        try:
            conn.execute("ALTER TABLE chunks ADD COLUMN embedding TEXT")
        except sqlite3.OperationalError:
            pass

        # One-time migration: convert any legacy pickle BLOBs to JSON.
        _migrate_pickle_to_json(conn)


def _migrate_pickle_to_json(conn: sqlite3.Connection) -> None:
    """
    Convert tfidf_vec rows that are still stored as pickle BLOBs to JSON.
    Runs inside the caller's connection/transaction.
    Skips rows that are already JSON strings or NULL.
    Safe to run repeatedly — already-migrated rows are left untouched.
    """
    rows = conn.execute(
        "SELECT id, tfidf_vec FROM chunks WHERE tfidf_vec IS NOT NULL"
    ).fetchall()

    migrated = 0
    for row_id, raw in rows:
        # JSON strings start with '{' — already migrated, skip.
        if isinstance(raw, str):
            continue
        # raw is bytes (legacy pickle BLOB) — convert.
        if isinstance(raw, bytes):
            try:
                vec = pickle.loads(raw)                 # noqa: S301
                conn.execute(
                    "UPDATE chunks SET tfidf_vec=? WHERE id=?",
                    (json.dumps(vec), row_id),
                )
                migrated += 1
            except Exception as exc:
                # Corrupted row — zero it out rather than crashing.
                print(f"[storage] migration: corrupt tfidf_vec on chunk {row_id}: {exc}")
                conn.execute(
                    "UPDATE chunks SET tfidf_vec=? WHERE id=?",
                    (json.dumps({}), row_id),
                )
                migrated += 1

    if migrated:
        print(f"[storage] migrated {migrated} chunk(s) from pickle → JSON")


# ------------------------------------------------------------------ #
#  Atomic ingest  (replaces insert_document + insert_chunks +         #
#                  update_doc_chunk_count)                            #
# ------------------------------------------------------------------ #

def ingest_document_atomic(name: str, path: str, chunks: List[dict]) -> int:
    """
    Insert or replace a document and all its chunks in a single
    BEGIN IMMEDIATE transaction.

    If a document with the same path already exists its old chunks are
    deleted and replaced atomically — a crash at any point leaves the
    DB in its previous consistent state rather than half-updated.

    chunks: list of dicts with keys:
        chunk_idx   int
        text        str
        tokens      list[str]
        tfidf_vec   dict {term: float}

    Returns doc_id.
    """
    conn = get_conn()
    try:
        conn.execute("BEGIN IMMEDIATE")

        # --- upsert document row ---
        existing = conn.execute(
            "SELECT id FROM documents WHERE path=?", (path,)
        ).fetchone()

        if existing:
            doc_id = existing[0]
            # Delete old chunks first so re-upload is always clean.
            conn.execute("DELETE FROM chunks WHERE doc_id=?", (doc_id,))
            # Refresh name in case the file was renamed.
            conn.execute(
                "UPDATE documents SET name=?, added_at=datetime('now') WHERE id=?",
                (name, doc_id),
            )
        else:
            cur = conn.execute(
                "INSERT INTO documents(name, path) VALUES (?, ?)", (name, path)
            )
            doc_id = cur.lastrowid

        # --- insert chunks ---
        rows = [
            (
                doc_id,
                c["chunk_idx"],
                c["text"],
                json.dumps(c["tokens"]),
                json.dumps(c["tfidf_vec"]),   # JSON, never pickle
                None,                          # embedding — computed later
            )
            for c in chunks
        ]
        conn.executemany(
            "INSERT INTO chunks(doc_id, chunk_idx, text, tokens, tfidf_vec, embedding) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            rows,
        )

        # --- update chunk count ---
        conn.execute(
            "UPDATE documents SET num_chunks=? WHERE id=?",
            (len(chunks), doc_id),
        )

        conn.execute("COMMIT")
        return doc_id

    except Exception:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


# ------------------------------------------------------------------ #
#  Document helpers                                                    #
# ------------------------------------------------------------------ #

def list_documents() -> List[dict]:
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, name, path, added_at, num_chunks "
            "FROM documents ORDER BY added_at DESC"
        ).fetchall()
    return [
        {
            "id":         r[0],
            "name":       r[1],
            "path":       r[2],
            "added_at":   r[3],
            "num_chunks": r[4],
        }
        for r in rows
    ]


def delete_document(doc_id: int) -> None:
    """Delete a document row; chunks are removed via ON DELETE CASCADE."""
    with get_conn() as conn:
        conn.execute("DELETE FROM documents WHERE id=?", (doc_id,))


# ------------------------------------------------------------------ #
#  Chunk helpers                                                       #
# ------------------------------------------------------------------ #

def load_all_chunks() -> List[dict]:
    """
    Load every chunk for the retriever.
    Returns embedding as list[float] if persisted, else None.
    """
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, doc_id, chunk_idx, text, tokens, tfidf_vec, embedding "
            "FROM chunks"
        ).fetchall()

    result = []
    for r in rows:
        result.append(
            {
                "id":        r[0],
                "doc_id":    r[1],
                "chunk_idx": r[2],
                "text":      r[3],
                "tokens":    json.loads(r[4]) if r[4] else [],
                "tfidf_vec": json.loads(r[5]) if r[5] else {},
                "embedding": json.loads(r[6]) if r[6] else None,
            }
        )
    return result


def save_chunk_embedding(chunk_id: int, embedding: List[float]) -> None:
    """Persist a computed embedding vector for a single chunk."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE chunks SET embedding=? WHERE id=?",
            (json.dumps(embedding), chunk_id),
        )