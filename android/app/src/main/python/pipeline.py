"""
pipeline.py — Orchestrates document ingest, retrieval, and generation.

This module is the single source of truth for all pipeline operations.
It owns the module-level retriever, runtime, and bootstrap coordinator
and is the only place that calls into storage, retriever, and llm.

Phase 1 changes:
  Step 2  — ingest_document uses storage.ingest_document_atomic()
  Step 4  — retriever mutations: add_chunks / remove_doc / clear
  Step 7  — Bootstrap state consolidated through pipeline.bootstrap
  Step 8  — stdout _debug_stream wrappers removed
  Step 9  — _generate_with_timeout() added
  Step 10 — doc name cache added

Phase 3 changes:
  Step 16 — auto_download_default dead import removed
  Step 16 — ingest_document now calls chunker.process_document()
             instead of duplicating extract/chunk/tokenise/tfidf inline
"""
from __future__ import annotations

import os
import threading
import time
import traceback
from pathlib import Path
from typing import Callable, List, Optional

from config import QWEN_SERVER_PORT
from runtime.bootstrap import BootstrapCoordinator
from runtime.model_runtime import LlamaModelRuntime, ModelRuntime
from downloader import (
    NOMIC_MODEL,
    QWEN_MODEL,
    auto_download_default_sync,
    model_dest_path,
    set_model_dir,
)
from prompt import build_direct_prompt, build_rag_prompt
from retriever import HybridRetriever
from storage import (
    delete_document as storage_delete_document,
    get_conn,
    init_db,
    ingest_document_atomic,
    list_documents as storage_list_documents,
)

# ------------------------------------------------------------------ #
#  Module-level singletons                                             #
# ------------------------------------------------------------------ #

retriever  = HybridRetriever(alpha=0.5)
runtime: ModelRuntime = LlamaModelRuntime()
bootstrap  = BootstrapCoordinator()

# ------------------------------------------------------------------ #
#  Tunables                                                            #
# ------------------------------------------------------------------ #

GENERATION_TIMEOUT_S = 60   # seconds before LLM call is declared hung


# ------------------------------------------------------------------ #
#  Document metadata cache  (Step 10)                                  #
# ------------------------------------------------------------------ #

_doc_cache:      dict            = {}
_doc_cache_lock: threading.Lock = threading.Lock()


def _get_doc_name_cache() -> dict:
    """
    Return a {doc_id: doc_name} snapshot, loading from DB on first call
    or after any corpus mutation.  Never hits the DB on a warm path.
    """
    with _doc_cache_lock:
        if not _doc_cache:
            try:
                for d in storage_list_documents():
                    _doc_cache[d["id"]] = d["name"]
            except Exception:
                pass
        return dict(_doc_cache)


def _invalidate_doc_cache() -> None:
    """Call after any ingest, delete, or clear operation."""
    with _doc_cache_lock:
        _doc_cache.clear()


# ------------------------------------------------------------------ #
#  Generation timeout helper  (Step 9)                                 #
# ------------------------------------------------------------------ #

def _generate_with_timeout(
    prompt:    str,
    stream_cb: Optional[Callable[[str], None]] = None,
    timeout:   int = GENERATION_TIMEOUT_S,
    cancel_event = None,
) -> str:
    """
    Run runtime.generate() in a worker thread and join with a timeout.
    Raises RuntimeError if generation does not complete within *timeout*
    seconds so the caller can surface a clean error instead of hanging.
    """
    result:    list = [None]
    exc_holder:list = [None]

    def _run() -> None:
        try:
            result[0] = runtime.generate(prompt, stream_cb=stream_cb,
                                         cancel_event=cancel_event).strip()
        except Exception as e:
            exc_holder[0] = e

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(timeout)

    if t.is_alive():
        raise RuntimeError(
            f"LLM generation timed out after {timeout}s"
        )
    if exc_holder[0]:
        raise exc_holder[0]
    return result[0]


# ------------------------------------------------------------------ #
#  Internal helpers                                                    #
# ------------------------------------------------------------------ #

def _service_qwen_ready(
    wait_seconds: float = 0.0,
    per_try_timeout: float = 0.35,
) -> bool:
    """Probe the Qwen llama-server health endpoint."""
    import urllib.request

    attempts = max(1, int(wait_seconds / 0.5))
    for i in range(attempts):
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{QWEN_SERVER_PORT}/health",
                timeout=per_try_timeout,
            ) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        if i < attempts - 1:
            time.sleep(0.5)
    return False


# ------------------------------------------------------------------ #
#  Initialisation  (Step 7 — single bootstrap source of truth)        #
# ------------------------------------------------------------------ #

def init(model_path: Optional[str] = None) -> None:
    """
    Full synchronous initialisation.  Drives all state transitions
    through the module-level bootstrap coordinator so every observer
    (api.get_status, api.init_with_progress callbacks) sees a
    consistent view.

    Sequence
    --------
    1. DB init + retriever full-load (fast, local)
    2. Model download if needed      (potentially slow, network)
    3. Qwen model load               (slow, CPU/GPU)
    4. Nomic embedding server start  (fast if already running)
    """
    print("[INIT] Starting initialisation…")

    try:
        # --- 1. DB + retriever ---
        bootstrap.emit_downloading(0.0, "Preparing database…")

        if model_path:
            set_model_dir(model_path)

        init_db()
        retriever.reload()

        # --- 2. Download models ---
        bootstrap.emit_downloading(0.05, "Checking models…")
        auto_download_default_sync()

        # --- 3. Load Qwen ---
        qwen_path = model_dest_path(QWEN_MODEL["filename"])
        bootstrap.emit_downloading(0.50, "Loading AI model…")
        print("[INIT] Loading Qwen via runtime…")

        try:
            runtime.load(qwen_path)
            print("[INIT] Qwen loaded.")
        except Exception as e:
            print(f"[INIT] Qwen load failed: {e}")
            bootstrap.emit_error(f"Model load failed: {e}")
            raise

        # --- 4. Nomic embedding server ---
        if isinstance(runtime, LlamaModelRuntime):
            nomic_path = model_dest_path(NOMIC_MODEL["filename"])
            if os.path.isfile(nomic_path):
                bootstrap.emit_downloading(0.90, "Starting embedding engine…")
                print("[INIT] Starting Nomic server…")
                runtime.start_nomic_server_if_needed(nomic_path)

        bootstrap.emit_ready("AI engine ready.")
        print("[INIT] Initialisation complete.")

    except Exception as exc:
        bootstrap.emit_error(f"Init failed: {exc}")
        raise


# ------------------------------------------------------------------ #
#  Document ingestion  (Steps 2 + 4)                                   #
# ------------------------------------------------------------------ #

def ingest_document(
    file_path: str,
    on_done: Optional[Callable[[bool, str], None]] = None,
) -> tuple[bool, str]:
    """
    Ingest a .txt or .pdf file synchronously.

    Uses storage.ingest_document_atomic() so the document row, chunk
    rows, and chunk count are written in a single DB transaction.
    Uses retriever.add_chunks() so the full corpus is not rebuilt.
    Invalidates the doc name cache so ask() sees the new document.
    """
    try:
        from chunker import process_document, resolve_uri

        # Resolve URI first so we can extract a display name.
        # process_document also calls resolve_uri internally, but that
        # second call is a no-op on a real path (content:// already resolved).
        resolved = resolve_uri(file_path)
        name     = Path(resolved).name
        print(f"[INGEST] Starting: {name}")

        # --- ensure Nomic server is up for background embedding ---
        nomic_path = model_dest_path(NOMIC_MODEL["filename"])
        if os.path.isfile(nomic_path) and isinstance(runtime, LlamaModelRuntime):
            runtime.start_nomic_server_if_needed(nomic_path)

        # --- extract, chunk, tokenise, TF-IDF in one canonical call ---
        # process_document is the single source of truth for the full
        # text → chunk pipeline. No duplication with chunker internals.
        chunks = process_document(resolved)
        if not chunks:
            result = (False, f"No content could be extracted from '{name}'")
            if on_done:
                on_done(*result)
            return result
        print(f"[INGEST] {len(chunks)} chunks ready")

        # --- atomic DB write (Step 2) ---
        doc_id = ingest_document_atomic(name, resolved, chunks)
        print(f"[INGEST] Saved to DB: doc_id={doc_id}, chunks={len(chunks)}")

        # --- incremental retriever update (Step 4) ---
        # Attach doc_id to each chunk so the retriever can index them
        for c in chunks:
            c["id"]     = None   # DB id unknown here; reload will assign real ids
            c["doc_id"] = doc_id
            c["embedding"] = None

        # Reload only the new doc's chunks from DB to get real chunk ids
        from storage import load_all_chunks
        all_chunks   = load_all_chunks()
        new_chunks   = [c for c in all_chunks if c["doc_id"] == doc_id]
        retriever.add_chunks(new_chunks)
        print(f"[INGEST] Retriever updated ({len(new_chunks)} new chunks)")

        # --- invalidate doc name cache ---
        _invalidate_doc_cache()

        result = (True, f"Ingested '{name}' — {len(chunks)} chunks")

    except Exception as exc:
        traceback.print_exc()
        result = (False, f"Error: {exc}")

    if on_done:
        on_done(*result)
    return result


# ------------------------------------------------------------------ #
#  Document management                                                 #
# ------------------------------------------------------------------ #

def list_documents() -> List[dict]:
    """List ingested documents sorted by most recent first."""
    try:
        init_db()
        return storage_list_documents()
    except Exception:
        return []


def delete_document_by_id(doc_id: int) -> None:
    """Delete a document from DB and remove its chunks from the retriever."""
    try:
        init_db()
        storage_delete_document(doc_id)
        retriever.remove_doc(doc_id)       # incremental — no reload()
        _invalidate_doc_cache()
    except Exception as exc:
        traceback.print_exc()
        raise exc


def clear_all_documents() -> None:
    """Delete all documents and chunks, reset the retriever in memory."""
    with get_conn() as conn:
        conn.execute("DELETE FROM chunks")
        conn.execute("DELETE FROM documents")
    retriever.clear()                      # in-memory reset — no reload()
    _invalidate_doc_cache()


# ------------------------------------------------------------------ #
#  Model helpers                                                       #
# ------------------------------------------------------------------ #

def load_model(
    model_path: str,
    on_progress: Optional[Callable[[float, str], None]] = None,
    on_done:     Optional[Callable[[bool, str], None]]  = None,
) -> tuple[bool, str]:
    """Load a GGUF model synchronously."""
    try:
        runtime.load(model_path, on_progress=on_progress)
        result = (True, f"Model loaded: {Path(model_path).name}")
    except Exception as exc:
        result = (False, f"Failed to load model: {exc}")

    if on_done:
        on_done(*result)
    return result


def get_available_models() -> List[str]:
    if isinstance(runtime, LlamaModelRuntime):
        return runtime.available_models()
    return []


def is_model_loaded() -> bool:
    return runtime.is_loaded()


def get_bootstrap_event():
    """Return the latest bootstrap state snapshot for UI polling."""
    return bootstrap.event()


# ------------------------------------------------------------------ #
#  Chat — direct (no retrieval)  (Step 8 + 9)                         #
# ------------------------------------------------------------------ #

def chat_direct(
    question:  str,
    history:   Optional[list] = None,
    summary:   str            = "",
    stream_cb: Optional[Callable[[str], None]] = None,
    on_done:   Optional[Callable[[bool, str], None]] = None,
    cancel_event = None,
) -> tuple[bool, str]:
    """
    Chat directly with the LLM — no retrieval.

    history : last N verbatim (user, assistant) turn pairs.
    summary : compressed plain-text summary of older turns.
    stream_cb: called with each token as it is generated.
    cancel_event: threading.Event — set to cancel generation.
    """
    try:
        if not runtime.is_loaded():
            result = (False, "No LLM model loaded.")
        else:
            prompt = build_direct_prompt(question, history, summary)
            print("[CHAT] Generation started…")
            answer = _generate_with_timeout(prompt, stream_cb=stream_cb,
                                             cancel_event=cancel_event)
            print("[CHAT] Generation finished.")
            result = (True, answer)

    except Exception as exc:
        traceback.print_exc()
        result = (False, f"Error during inference: {exc}")

    if on_done:
        on_done(*result)
    return result


# ------------------------------------------------------------------ #
#  RAG query  (Steps 8 + 9 + 10)                                       #
# ------------------------------------------------------------------ #

def ask(
    question:  str,
    stream_cb: Optional[Callable[[str], None]] = None,
    on_done:   Optional[Callable[[bool, str], None]] = None,
    cancel_event = None,
) -> tuple[bool, str, list]:
    """
    Run a RAG query synchronously.

    Retrieval returns [] when no chunk clears the relevance threshold,
    so the pipeline never injects irrelevant context into the prompt.

    Returns (success, answer, sources) where sources is:
        [{"doc_name": str, "chunk_text": str, "score": float}, ...]
    """
    sources: list = []

    try:
        if retriever.is_empty():
            return (False, "No documents ingested yet.", [])

        if not runtime.is_loaded():
            return (False, "No LLM model loaded.", [])

        # --- retrieval ---
        print(f"[RAG] Query: {question[:100]}")
        results = retriever.query(question, top_k=2)

        if not results:
            print("[RAG] No relevant context found (below threshold)")
            return (False, "No relevant context found.", [])

        for i, (text, score, doc_id) in enumerate(results):
            print(f"[RAG] Chunk {i}: score={score:.3f} doc_id={doc_id} "
                  f"preview={text[:60]}…")

        # --- build prompt ---
        context_chunks = [text for text, _, _ in results]
        prompt         = build_rag_prompt(context_chunks, question)
        print(f"[RAG] Prompt length: {len(prompt)} chars")

        # --- source attribution (Step 10 — cached, no per-query DB hit) ---
        doc_name_cache  = _get_doc_name_cache()
        seen_doc_names: set = set()

        for text, score, doc_id in results:
            doc_name = doc_name_cache.get(doc_id, f"Document #{doc_id}")
            if doc_name in seen_doc_names:
                continue
            seen_doc_names.add(doc_name)
            sources.append({
                "doc_name":   doc_name,
                "chunk_text": text[:200],
                "score":      round(score, 3),
            })

        # --- generation (Step 8: no stdout wrapper / Step 9: timeout) ---
        print("[RAG] Generation started…")
        answer = _generate_with_timeout(prompt, stream_cb=stream_cb,
                                         cancel_event=cancel_event)
        print(f"[RAG] Generation finished. Answer length: {len(answer)}")

        result = (True, answer, sources)

    except Exception as exc:
        traceback.print_exc()
        result = (False, f"Error during inference: {exc}", [])

    if on_done:
        on_done(result[0], result[1])
    return result