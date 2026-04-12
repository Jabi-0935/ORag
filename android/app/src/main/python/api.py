"""
api.py — Public Python surface called from Kotlin via Chaquopy.

Every method in this file is a direct Kotlin MethodChannel entry point.
All blocking work (LLM generation, ingestion) is dispatched to the
single worker thread via worker.submit() so the Kotlin thread returns
immediately and the UI stays responsive.

Changes from previous version
------------------------------
Step 6  — _is_generating boolean and _stop_flag removed entirely.
          Replaced by worker.submit() which enforces single-task
          execution through a bounded Queue(maxsize=1).
          Non-streaming chat() removed — confirmed unused by Flutter.
          stop_generation() removed — was checking a dead flag.

Step 7  — init_with_progress no longer contains its own download/load
          orchestration.  It registers a progress-forwarding callback
          on pipeline.bootstrap and then dispatches pipeline.init()
          to the worker.  pipeline.bootstrap is now the single source
          of truth for all init state; get_status() was already reading
          from it and continues to work unchanged.

Busy sentinel
-------------
When submit() returns False (worker occupied) the streaming entry points
send the string "__BUSY__" as a token via token_callback so Flutter can
display a "please wait" message without polling.
"""
from __future__ import annotations

import json
import threading

from pipeline import (
    ask          as pipeline_ask,
    chat_direct,
    clear_all_documents as pipeline_clear_docs,
    delete_document_by_id as pipeline_delete_doc,
    get_bootstrap_event,
    init,
    ingest_document as pipeline_ingest,
    is_model_loaded,
    list_documents as pipeline_list_docs,
)
from runtime.bootstrap import BootstrapState
from worker import start_worker, submit

# ------------------------------------------------------------------ #
#  Module initialisation                                               #
# ------------------------------------------------------------------ #

# Start the single background worker thread immediately on import.
# safe to call here — it's idempotent and lightweight.
start_worker()

# ------------------------------------------------------------------ #
#  Initialisation state                                                #
# ------------------------------------------------------------------ #

_initialized     = False
_init_lock       = threading.Lock()

# Conversation history for direct chat (non-RAG)
_conversation_history: list = []
MAX_TURNS = 5

# ------------------------------------------------------------------ #
#  Progress callback bridge (Kotlin → Python → Flutter)               #
# ------------------------------------------------------------------ #

_progress_callback       = None
_progress_lock           = threading.Lock()


def _set_progress_callback(cb) -> None:
    global _progress_callback
    with _progress_lock:
        _progress_callback = cb


def _emit_progress(state: str, progress: float, message: str) -> None:
    """
    Forward a bootstrap event to Flutter via the Kotlin method reference.
    cb.invoke(jsonString) is Chaquopy's mechanism for calling JVM lambdas.
    """
    with _progress_lock:
        cb = _progress_callback
    if cb is None:
        return
    try:
        data = json.dumps({
            "state":    state,
            "progress": max(0.0, min(1.0, float(progress))),
            "message":  str(message),
        })
        cb.invoke(data)
    except Exception as exc:
        print(f"[API] progress callback error: {exc}")


# ------------------------------------------------------------------ #
#  Bootstrap coordinator forwarding                                    #
# ------------------------------------------------------------------ #

def _forward_bootstrap_events() -> None:
    """
    Register callbacks on pipeline.bootstrap so every state transition
    emitted by pipeline.init() is forwarded to Flutter in real time.

    State mapping
    -------------
    bootstrap emits:  emit_downloading(frac, text)  → state="downloading"
                      emit_ready(text)               → state="ready"
                      emit_error(text)               → state="error"

    We map these to the progress JSON shape Flutter already expects.
    """
    from pipeline import bootstrap

    def _on_progress(frac: float, text: str) -> None:
        _emit_progress("downloading", frac, text)

    def _on_done(success: bool, message: str) -> None:
        if success:
            _emit_progress("ready", 1.0, message)
        else:
            _emit_progress("error", 1.0, message)

    bootstrap.register_callbacks(
        on_progress=_on_progress,
        on_done=_on_done,
    )


# ------------------------------------------------------------------ #
#  Internal init task (runs on worker thread)                          #
# ------------------------------------------------------------------ #

def _do_init(model_path) -> None:
    """
    Runs on the worker thread.  Calls pipeline.init() which drives all
    state transitions through pipeline.bootstrap.  The callbacks
    registered in _forward_bootstrap_events() forward those events to
    Flutter via _emit_progress().
    """
    global _initialized
    try:
        init(model_path)
        with _init_lock:
            _initialized = True
    except Exception as exc:
        # pipeline.init() already called bootstrap.emit_error() —
        # no need to emit again, just log.
        print(f"[API] init failed: {exc}")


# ------------------------------------------------------------------ #
#  Public init API                                                     #
# ------------------------------------------------------------------ #

def init_with_path(model_path: str) -> None:
    """Initialise without progress callbacks (headless / test use)."""
    global _initialized
    if _initialized:
        return
    with _init_lock:
        if not _initialized:
            init(model_path)
            _initialized = True


def init_with_progress(model_path, progress_callback) -> None:
    """
    Initialise with real-time progress events pushed to Flutter.

    progress_callback is a Kotlin method reference invoked via
    .invoke(jsonString).  Events have the shape:
        {"state": "downloading|loading|ready|error",
         "progress": 0.0–1.0,
         "message": "..."}

    This method returns immediately — all blocking work runs on the
    worker thread.  Progress events are forwarded via _emit_progress().
    """
    global _initialized

    # Fast path: already done.
    if _initialized:
        _emit_progress("ready", 1.0, "AI engine ready.")
        return

    _set_progress_callback(progress_callback)

    with _init_lock:
        if _initialized:
            _emit_progress("ready", 1.0, "AI engine ready.")
            return

        # Wire pipeline.bootstrap → _emit_progress before submitting
        # so no events are missed.
        _forward_bootstrap_events()

        accepted = submit(_do_init, model_path)
        if not accepted:
            # Worker is already running init from a previous call —
            # callbacks are already registered, nothing to do.
            print("[API] init already in progress")


def get_status() -> dict:
    """
    Return current bootstrap state as a dict for one-shot polling.
    Reads exclusively from pipeline.bootstrap — the single source of
    truth for all init state.
    """
    if _initialized:
        return {"state": "ready", "progress": 1.0, "message": "AI engine ready."}

    try:
        evt = get_bootstrap_event()
        state_map = {
            BootstrapState.IDLE:        "idle",
            BootstrapState.DOWNLOADING: "downloading",
            BootstrapState.READY:       "ready",
            BootstrapState.ERROR:       "error",
        }
        return {
            "state":    state_map.get(evt.state, "idle"),
            "progress": evt.progress,
            "message":  evt.message,
        }
    except Exception:
        return {"state": "idle", "progress": 0.0, "message": ""}


# ------------------------------------------------------------------ #
#  Conversation helpers                                                #
# ------------------------------------------------------------------ #

def _trim_history() -> None:
    global _conversation_history
    if len(_conversation_history) > MAX_TURNS:
        _conversation_history = _conversation_history[-MAX_TURNS:]


def clear_memory() -> None:
    """Clear the in-memory conversation history."""
    global _conversation_history
    _conversation_history = []


# ------------------------------------------------------------------ #
#  Streaming chat (direct — no retrieval)                              #
# ------------------------------------------------------------------ #

def _do_chat_stream(query: str, token_callback) -> None:
    """Worker-thread body for chat_stream."""
    def _on_token(token: str) -> None:
        try:
            token_callback.invoke(token)
        except Exception as exc:
            print(f"[CHAT-STREAM] token callback error: {exc}")

    _trim_history()
    ok, response = chat_direct(
        question=query,
        history=_conversation_history,
        summary="",
        stream_cb=_on_token,
    )

    if ok:
        _conversation_history.append((query, response))

    # Send the end-of-stream sentinel so Flutter knows generation is done.
    try:
        token_callback.invoke("__DONE__")
    except Exception:
        pass

    print(f"[CHAT-STREAM] finished ok={ok}")


def chat_stream(query: str, token_callback) -> str:
    """
    Streaming chat via direct LLM (no retrieval).

    Tokens are delivered to Flutter via token_callback.invoke(token).
    Returns a status string synchronously (the token stream is async).

    token_callback is a Kotlin method reference (Chaquopy PyObject).
    """
    accepted = submit(_do_chat_stream, query, token_callback)
    if not accepted:
        try:
            token_callback.invoke("__BUSY__")
        except Exception:
            pass
        return "BUSY"
    return "OK"


# ------------------------------------------------------------------ #
#  RAG streaming query                                                 #
# ------------------------------------------------------------------ #

def _do_ask_rag(query: str, token_callback) -> None:
    """Worker-thread body for ask_rag."""
    def _on_token(token: str) -> None:
        try:
            token_callback.invoke(token)
        except Exception as exc:
            print(f"[RAG-STREAM] token callback error: {exc}")

    print(f"[RAG-STREAM] query: {query[:80]}")

    ok, response, sources = pipeline_ask(
        question=query,
        stream_cb=_on_token,
    )

    # Send end-of-stream sentinel
    try:
        token_callback.invoke("__DONE__")
    except Exception:
        pass

    print(f"[RAG-STREAM] finished ok={ok} sources={len(sources)}")


def ask_rag(query: str, token_callback) -> str:
    """
    RAG streaming query with source attribution.

    Tokens stream to Flutter via token_callback.invoke(token).
    Source metadata is sent as a final "__SOURCES__:{json}" token
    after "__DONE__" so Flutter can display attribution without
    a second round trip.

    Returns "OK" or "BUSY" synchronously.
    """
    def _do_ask_rag_with_sources(query: str, token_callback) -> None:
        def _on_token(token: str) -> None:
            try:
                token_callback.invoke(token)
            except Exception as exc:
                print(f"[RAG-STREAM] token callback error: {exc}")

        print(f"[RAG-STREAM] query: {query[:80]}")

        ok, response, sources = pipeline_ask(
            question=query,
            stream_cb=_on_token,
        )

        # End-of-stream sentinel
        try:
            token_callback.invoke("__DONE__")
        except Exception:
            pass

        # Source metadata as a structured sentinel token
        try:
            token_callback.invoke(
                "__SOURCES__:" + json.dumps(sources)
            )
        except Exception:
            pass

        print(f"[RAG-STREAM] finished ok={ok} sources={len(sources)}")

    accepted = submit(_do_ask_rag_with_sources, query, token_callback)
    if not accepted:
        try:
            token_callback.invoke("__BUSY__")
        except Exception:
            pass
        return "BUSY"
    return "OK"


# ------------------------------------------------------------------ #
#  Document management                                                 #
# ------------------------------------------------------------------ #

def upload_document(file_path: str) -> str:
    """
    Ingest a PDF/TXT document into the RAG pipeline.
    Runs synchronously — ingestion is fast enough that it does not need
    to be dispatched to the worker (no generation involved).
    Returns JSON: {"success": bool, "message": str}
    """
    try:
        ok, msg = pipeline_ingest(file_path)
        return json.dumps({"success": ok, "message": msg})
    except Exception as exc:
        return json.dumps({"success": False, "message": f"Error: {exc}"})


def list_docs() -> str:
    """
    Return JSON array of ingested documents.
    Each entry: {"id": int, "name": str, "num_chunks": int, "added_at": str}
    """
    try:
        return json.dumps(pipeline_list_docs())
    except Exception:
        return json.dumps([])


def delete_doc(doc_id) -> str:
    """Delete a document by ID. Returns JSON status."""
    try:
        pipeline_delete_doc(int(doc_id))
        return json.dumps({"success": True, "message": "Document deleted."})
    except Exception as exc:
        return json.dumps({"success": False, "message": f"Error: {exc}"})


def clear_docs() -> str:
    """Clear all documents. Returns JSON status."""
    try:
        pipeline_clear_docs()
        return json.dumps({"success": True, "message": "All documents cleared."})
    except Exception as exc:
        return json.dumps({"success": False, "message": f"Error: {exc}"})


# ------------------------------------------------------------------ #
#  Engine health                                                       #
# ------------------------------------------------------------------ #

def get_engine_health() -> str:
    """Return JSON with model/server health info for the settings screen."""
    try:
        from pipeline import retriever, runtime
        from runtime.model_runtime import LlamaModelRuntime

        health = {
            "model_loaded": runtime.is_loaded(),
            "model_name":   "",
            "backend":      "",
            "qwen_ready":   False,
            "nomic_ready":  False,
            "doc_count":    0,
            "chunk_count":  0,
        }

        if isinstance(runtime, LlamaModelRuntime):
            h = runtime.health()
            health["qwen_ready"]  = h.qwen_ready
            health["nomic_ready"] = h.nomic_ready
            health["backend"]     = h.backend
            health["model_name"]  = (
                h.model_path.split("/")[-1] if h.model_path else ""
            )

        try:
            docs = pipeline_list_docs()
            health["doc_count"]  = len(docs)
            health["chunk_count"] = sum(d.get("num_chunks", 0) for d in docs)
        except Exception:
            pass

        return json.dumps(health)

    except Exception as exc:
        return json.dumps({"error": str(exc)})