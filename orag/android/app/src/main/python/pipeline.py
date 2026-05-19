"""
pipeline.py - Orchestrates document ingest, retrieval and generation.
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Callable, Optional


from config import QWEN_SERVER_PORT
from runtime.bootstrap import BootstrapCoordinator
from runtime.model_runtime import LlamaModelRuntime, ModelRuntime
from chunker import process_document, process_document_hierarchical
from downloader import NOMIC_MODEL, QWEN_MODEL, auto_download_default, model_dest_path, auto_download_default_sync, set_model_dir
from llm import build_direct_prompt, build_rag_prompt
from retriever import HybridRetriever
from storage import (
    delete_document as storage_delete_document,
    get_conn,
    init_db,
    insert_chunks,
    insert_document,
    insert_parent_chunks,
    list_documents as storage_list_documents,
    update_doc_chunk_count,
)


# Module-level retriever/runtime (shared across the whole app)
retriever = HybridRetriever(alpha=0.5)
runtime: ModelRuntime = LlamaModelRuntime()
bootstrap = BootstrapCoordinator()


def _service_qwen_ready(wait_seconds: float = 0.0, per_try_timeout: float = 0.35) -> bool:
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


def register_auto_download_callbacks(
    on_progress: Optional[Callable[[float, str], None]],
    on_done: Optional[Callable[[bool, str], None]],
) -> None:
    """
    Register UI callbacks for model bootstrap lifecycle.
    """
    bootstrap.register_callbacks(on_progress=on_progress, on_done=on_done)

    # Fast-path: if model already loaded or service already healthy, mark ready.
    if runtime.is_loaded():
        bootstrap.emit_ready("Models ready: Qwen + Nomic")
        return

    if _service_qwen_ready(wait_seconds=0.0):
        qwen_path = model_dest_path(QWEN_MODEL["filename"])
        try:
            runtime.connect_external_server(qwen_path)
            bootstrap.emit_ready("Models ready: Qwen + Nomic (service)")
        except Exception:
            pass


def init(model_path: Optional[str] = None) -> None:
    print("[INIT] Starting initialization...")

    if model_path:
        set_model_dir(model_path)

    init_db()
    retriever.reload()

    # Step 1: Ensure models are downloaded
    auto_download_default_sync()

    # Step 2: Load Qwen model into runtime
    qwen_path = model_dest_path(QWEN_MODEL["filename"])

    print("[INIT] Loading model via runtime...")

    try:
        runtime.load(qwen_path)
        print("[INIT] Model loaded successfully.")
    except Exception as e:
        print(f"[INIT] Model loading failed: {e}")
        raise
        
    # Step 3: Start Nomic embedding server (lazy or eager based on RAM profile)
    # On low-RAM devices, Nomic is deferred to first RAG query to avoid OOM.
    if isinstance(runtime, LlamaModelRuntime):
        from memory_management import get_profile, ensure_nomic_server
        mem_profile = get_profile()
        nomic_path = model_dest_path(NOMIC_MODEL["filename"])
        if mem_profile.get("nomic_lazy", False):
            print(f"[INIT] Nomic deferred to first RAG query "
                  f"(profile={mem_profile['profile']}, lazy mode)")
        else:
            if os.path.isfile(nomic_path):
                print("[INIT] Starting Nomic embedding server (eager)...")
                ensure_nomic_server(nomic_path)


def _start_auto_download() -> None:
    """Ensure Qwen + Nomic are on disk, then load/connect Qwen."""

    def _progress(frac: float, text: str) -> None:
        bootstrap.emit_downloading(frac, text)

    def _done(success: bool, message: str) -> None:
        qwen_path = model_dest_path(QWEN_MODEL["filename"])

        if not success:
            bootstrap.emit_error(message)
            return

        if runtime.is_loaded():
            bootstrap.emit_ready("Models ready: Qwen + Nomic")
            return

        # Prefer the service-owned Qwen server if it is up.
        if _service_qwen_ready(wait_seconds=12.0):
            try:
                runtime.connect_external_server(qwen_path)
                bootstrap.emit_ready("Models ready: Qwen + Nomic")
                return
            except Exception:
                pass

        # Fallback: load/connect from app process.
        ok, msg = load_model(qwen_path, on_progress=_progress)
        if ok:
            bootstrap.emit_ready(msg)
        else:
            bootstrap.emit_error(msg)

    auto_download_default(on_progress=_progress, on_done=_done)


def ingest_document(
    file_path: str,
    on_done: Optional[Callable[[bool, str], None]] = None,
) -> tuple[bool, str]:
    """
    Ingest a .txt or .pdf file synchronously.
    Starts Nomic server lazily on first call.

    The document row is only updated with the chunk count AFTER all
    chunks are fully processed and inserted, so the UI never shows
    a document with 0 chunks while processing is in-flight.
    """
    try:
        # Resolve content:// URI to a real file path (Android)
        from chunker import resolve_uri, extract_text, chunk_text, tokenise, compute_tfidf_vecs
        resolved = resolve_uri(file_path)
        name = Path(resolved).name
        print(f"[INGEST] Starting: {name} ({resolved})")

        # Start Nomic server lazily (needed for embeddings)
        nomic_path = model_dest_path(NOMIC_MODEL["filename"])
        if os.path.isfile(nomic_path) and isinstance(runtime, LlamaModelRuntime):
            runtime.start_nomic_server_if_needed(nomic_path)

        # Step 1: Extract text ONCE and reuse for both small and parent chunking
        raw_text = extract_text(resolved)
        if not raw_text or not raw_text.strip():
            result = (False, f"No text could be extracted from '{name}'")
            if on_done:
                on_done(*result)
            return result
        print(f"[INGEST] Extracted {len(raw_text)} chars")

        # Step 2: Chunk with Small-to-Big hierarchy + compute TF-IDF vectors
        # Pass raw_text directly to avoid re-reading the file a second time.
        try:
            from chunker import process_document_hierarchical_from_text
            small_chunks, parent_chunks = process_document_hierarchical_from_text(raw_text)
        except Exception:
            # Fallback to flat chunking if hierarchical fails
            from chunker import chunk_text, tokenise, compute_tfidf_vecs
            raw_chunks = chunk_text(raw_text)
            small_chunks = []
            if raw_chunks:
                token_lists = [tokenise(c) for c in raw_chunks]
                tfidf_vecs, _ = compute_tfidf_vecs(token_lists)
                for idx, (text, tokens, vec) in enumerate(
                    zip(raw_chunks, token_lists, tfidf_vecs)
                ):
                    small_chunks.append({
                        "chunk_idx": idx, "text": text,
                        "tokens": tokens, "tfidf_vec": vec,
                    })
            parent_chunks = []

        # Release raw_text and working lists immediately to free RAM
        del raw_text
        import gc; gc.collect()

        chunks = small_chunks
        if not chunks:
            result = (False, f"Document '{name}' produced 0 chunks")
            if on_done:
                on_done(*result)
            return result
        print(f"[INGEST] {len(chunks)} small chunks + {len(parent_chunks)} parent chunks ready")

        # Step 3: Insert document + chunks + parent chunks atomically
        doc_id = insert_document(name, resolved)
        chunk_ids = insert_chunks(doc_id, chunks)
        if parent_chunks:
            insert_parent_chunks(doc_id, parent_chunks)
        update_doc_chunk_count(doc_id, len(chunks))

        # Free chunk working memory before reloading retriever
        del small_chunks, parent_chunks, chunks
        gc.collect()
        print(f"[INGEST] Saved {len(chunk_ids)} chunks for doc_id={doc_id}")

        # Step 5: Reload retriever so new chunks are queryable
        retriever.reload()
        print(f"[INGEST] Retriever reloaded")

        result = (True, f"Ingested '{name}' — {len(chunk_ids)} chunks")
    except Exception as exc:
        import traceback
        traceback.print_exc()
        result = (False, f"Error: {exc}")

    if on_done:
        on_done(*result)
    return result





def load_model(
    model_path: str,
    on_progress: Optional[Callable[[float, str], None]] = None,
    on_done: Optional[Callable[[bool, str], None]] = None,
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


def get_available_models() -> list[str]:
    if isinstance(runtime, LlamaModelRuntime):
        return runtime.available_models()
    return []


def clear_all_documents() -> None:
    """Delete all ingested documents + chunks and reset the in-memory retriever."""
    with get_conn() as conn:
        conn.execute("DELETE FROM chunks")
        conn.execute("DELETE FROM documents")
    retriever.reload()


def is_model_loaded() -> bool:
    return runtime.is_loaded()


def get_bootstrap_event():
    """Return the latest bootstrap state snapshot for UI surfaces."""
    return bootstrap.event()


def list_documents() -> list[dict]:
    """List ingested documents sorted by most recent first.

    Safe during very early startup before init() has run.
    """
    try:
        return storage_list_documents()
    except Exception:
        return []


def delete_document_by_id(doc_id: int) -> None:
    """Delete a document and update the in-memory retriever index.

    BE-4: Uses incremental remove_doc() instead of a full reload()
    to avoid a DB round-trip and full index rebuild on single-doc deletes.
    """
    try:
        storage_delete_document(doc_id)
    finally:
        # Incremental update: faster than full reload for single deletes
        try:
            retriever.remove_doc(doc_id)
        except Exception:
            # Fallback to full reload if incremental path fails
            retriever.reload()


def chat_direct(
    question: str,
    history: list | None = None,
    summary: str = "",
    stream_cb: Optional[Callable[[str], None]] = None,
    on_done: Optional[Callable[[bool, str], None]] = None,
    response_style: str = "concise",
) -> tuple[bool, str, str]:
    """
    Chat directly with the LLM (no retrieval).
    history: last 3 verbatim (user, assistant) turns.
    summary: compressed plain-text summary of older turns.
    response_style: 'concise' or 'detailed'
    Returns (success, answer, thinking_text).
    """
    try:
        if not runtime.is_loaded():
            result = (False, "No LLM model loaded. Please load a GGUF model first.", "")
        else:
            prompt = build_direct_prompt(question, history, summary, response_style=response_style)
            from memory_management import check_memory_pressure
            pressure = check_memory_pressure()
            max_tok = _get_safe_max_tokens(pressure, response_style)
            answer = runtime.generate(prompt, stream_cb=stream_cb, max_tokens=max_tok).strip()
            thinking = getattr(runtime, 'last_thinking', '')
            result = (True, answer, thinking)
    except Exception as exc:
        result = (False, f"Error during inference: {exc}", "")

    if on_done:
        on_done(result[0], result[1])
    return result


def _estimate_top_k(question: str) -> int:
    """
    Estimate chunk count needed based on question complexity AND device profile.
    Since parent chunks are large (400 words), keep chunk count low to avoid TTFT delays.
    Zero latency — pure string heuristics, no model call.
    """
    from memory_management import get_profile
    profile_name = get_profile().get("profile", "LOW")

    # Base chunk count per profile — scales with available context window
    base_k = {"ULTRA_LOW": 2, "LOW": 2, "MEDIUM": 3, "HIGH": 4}.get(profile_name, 2)

    q_lower = question.lower()
    broad_signals = [
        "summarize", "summary", "overview", "all ", "everything",
        "compare", "list ", "what are", "describe", "explain",
        "main points", "key findings", "tell me about", "how does",
    ]
    if any(sig in q_lower for sig in broad_signals):
        return min(base_k + 1, 5)   # broad questions get extra chunk (max 5)
    if len(question.split()) > 20:
        return min(base_k + 1, 5)   # long questions get extra chunk (max 5)
    return base_k


def _get_safe_max_tokens(profile: dict, response_style: str = "concise") -> int:
    """
    Return the max_tokens for generation, capped to prevent the
    llama-server 'reduce the prompts' error.

    Concise mode: profile's base max_tokens, capped at 40% of n_ctx.
    Detailed mode: uses the full 40% of n_ctx ceiling to allow
        longer, well-structured answers.
    """
    from memory_management import get_profile as _get_profile
    n_ctx     = _get_profile().get("n_ctx", 2048)
    abs_max   = max(64, int(n_ctx * 0.40))   # 40% of n_ctx hard ceiling
    base = profile.get("max_tokens", 512)

    if response_style == "detailed":
        # Use the full 40% ceiling (not limited by profile base)
        return abs_max

    return min(base, abs_max)


def _build_retrieval_query(question: str, history: list) -> str:
    """
    Improvement #2: Augment retrieval query with the last user turn.
    Fixes follow-up questions like 'Who wrote it?' that lack context alone.
    Zero latency — simple string concatenation.
    """
    if not history:
        return question
    last_q = history[-1][0] if history else ""
    if last_q and last_q.lower().strip() != question.lower().strip():
        return f"{last_q} {question}"
    return question


def ask(
    question: str,
    history: list | None = None,
    summary: str = "",
    stream_cb: Optional[Callable[[str], None]] = None,
    on_done: Optional[Callable[[bool, str], None]] = None,
    response_style: str = "concise",
) -> tuple[bool, str, list, str, list]:
    """
    Run a RAG query synchronously.
    Retrieves top-4 chunks for better context coverage.
    response_style: 'concise' or 'detailed'
    Returns (success, answer, sources, thinking_text, parent_chunks_info) where:
      sources          = [{"doc_name": ..., "chunk_text": ..., "score": ...}, ...]
      thinking_text    = raw <think> block from Qwen3 (empty string if none)
      parent_chunks_info = [{"doc_name": ..., "text": ..., "score": ...}, ...]
    """
    sources: list = []
    parent_chunks_info: list = []
    try:
        if retriever.is_empty():
            result = (False, "No documents ingested yet.", [], "", [])
        elif not runtime.is_loaded():
            result = (False, "No LLM model loaded. Please load a GGUF model first.", [], "", [])
        else:
            print(f"[RAG] Query: {question[:100]}")
            # Ensure Nomic is running for dense retrieval (may have been
            # stopped after ingest on low-RAM profiles)
            try:
                from memory_management import ensure_nomic_server, is_nomic_running
                if not is_nomic_running():
                    nomic_path = model_dest_path(NOMIC_MODEL["filename"])
                    if os.path.isfile(nomic_path):
                        ensure_nomic_server(nomic_path)
            except Exception:
                pass
            # Improvement #9: adaptive top_k based on question complexity
            top_k = _estimate_top_k(question)
            # Improvement #2: augment retrieval query with conversation context
            retrieval_query = _build_retrieval_query(question, history or [])
            print(f"[RAG] top_k={top_k}, retrieval_query={retrieval_query[:80]}")

            # Use Small-to-Big expansion: retrieve small chunks, expand to parent context
            results = retriever.query_with_expansion(retrieval_query, top_k=top_k)
            if not results:
                # Fallback to regular query without expansion
                results = retriever.query(retrieval_query, top_k=top_k)
            if not results:
                print("[RAG] No relevant context found")
                result = (
                    False,
                    "I couldn't find relevant information in your documents for this question. "
                    "Try rephrasing, or verify the relevant document has been uploaded.",
                    [], "", []
                )
            else:
                # Build source metadata early so we can inject it into the prompt
                doc_name_cache = {}
                try:
                    docs = storage_list_documents()
                    for d in docs:
                        doc_name_cache[d["id"]] = d["name"]
                except Exception:
                    pass

                context_chunks = []
                for i, (text, score, doc_id) in enumerate(results):
                    print(f"[RAG] Chunk {i}: score={score:.3f}, doc_id={doc_id}, text={text[:80]}...")
                    doc_name = doc_name_cache.get(doc_id, f"Document #{doc_id}")
                    context_chunks.append(f"[Source: {doc_name}]\n{text}")
                    # Build parent_chunks_info for UI display (full text, not truncated)
                    parent_chunks_info.append({
                        "doc_name": doc_name,
                        "text": text,
                        "score": round(score, 4),
                    })

                prompt = build_rag_prompt(context_chunks, question, history, summary, response_style=response_style)
                print(f"[RAG] Prompt length: {len(prompt)} chars")

                # Use memory profile default max_tokens with 40% n_ctx safety cap
                from memory_management import check_memory_pressure
                pressure = check_memory_pressure()
                max_tok = _get_safe_max_tokens(pressure, response_style)
                print(f"[RAG] max_tokens={max_tok} (base={pressure.get('max_tokens', 512)})")
                seen_doc_names = set()
                for text, score, doc_id in results:
                    doc_name = doc_name_cache.get(doc_id, f"Document #{doc_id}")
                    if doc_name in seen_doc_names:
                        continue
                    seen_doc_names.add(doc_name)
                    sources.append({
                        "doc_name": doc_name,
                        "chunk_text": text[:200],  # Preview only
                        "score": round(score, 3),
                    })

                print("[RAG] Generation started...")
                answer = runtime.generate(prompt, stream_cb=stream_cb, max_tokens=max_tok).strip()
                thinking = getattr(runtime, 'last_thinking', '')
                print(f"[RAG] Generation finished. Answer length: {len(answer)}")
                result = (True, answer, sources, thinking, parent_chunks_info)
    except Exception as exc:
        import traceback
        traceback.print_exc()
        result = (False, f"Error during inference: {exc}", [], "", [])

    if on_done:
        on_done(result[0], result[1])
    return result
