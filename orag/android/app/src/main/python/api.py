import threading
import json
import os
import time
import hashlib

# Deferred imports to prevent module-level hangs
pipeline = None
downloader = None
runtime = None
bootstrap = None

_initialized = False
_init_lock = threading.Lock()
_is_generating = False
_stop_flag = False
_conversation_history = []
_conversation_summary = ""   # compressed summary of turns older than MAX_TURNS
MAX_TURNS = 5
_server_confirmed_ready = False  # cached after first successful health check

# ---- Response cache (Improvement #3) ----
_response_cache: dict = {}          # key -> JSON result string
_CACHE_MAX_SIZE = 20                # keep last 20 unique responses (FIFO)
_cache_lock = threading.Lock()


def _cache_key(query: str, history_len: int) -> str:
    """Fast 16-char hash key — includes history length so follow-ups don't collide."""
    raw = f"{query.strip().lower()}|histlen={history_len}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _try_cache(query: str, history: list):
    """Return cached result string, or None on miss."""
    with _cache_lock:
        return _response_cache.get(_cache_key(query, len(history)))


def _store_cache(query: str, history: list, result: str) -> None:
    """Store result in FIFO cache, evicting oldest entry when full."""
    with _cache_lock:
        key = _cache_key(query, len(history))
        if len(_response_cache) >= _CACHE_MAX_SIZE:
            _response_cache.pop(next(iter(_response_cache)))
        _response_cache[key] = result

# ---- Progress callback holder (set from Kotlin) ----
_progress_callback = None
_progress_lock = threading.Lock()

def _set_progress_callback(cb):
    global _progress_callback
    with _progress_lock:
        _progress_callback = cb


def _emit_progress(state, progress, message):
    """Send a progress event to Flutter via the Kotlin callback."""
    with _progress_lock:
        cb = _progress_callback
    if cb is not None:
        try:
            data = json.dumps({
                "state": state,
                "progress": max(0.0, min(1.0, progress)),
                "message": str(message),
            })
            cb.invoke(data)
        except Exception as e:
            print(f"[API] progress callback error: {e}")


def _make_simple_summary(turns: list) -> str:
    """
    Improvement #5: Zero-latency summary — extracts first sentence from each
    dropped turn instead of making an LLM call. Keeps the model aware of older
    context without any extra latency.
    """
    parts = []
    for q, a in turns:
        q_short = (q.split(".")[0] + ".").strip()[:120]
        a_short = (a.split(".")[0] + ".").strip()[:180]
        parts.append(f"User: {q_short} Assistant: {a_short}")
    return " | ".join(parts)


def trim_history():
    """Trim history to MAX_TURNS, compressing dropped turns into a rolling summary."""
    global _conversation_history, _conversation_summary
    if len(_conversation_history) > MAX_TURNS:
        to_drop = _conversation_history[:-MAX_TURNS]
        dropped_summary = _make_simple_summary(to_drop)
        # Rolling append to existing summary, capped at 400 chars
        if _conversation_summary:
            _conversation_summary = f"{_conversation_summary} | {dropped_summary}"
        else:
            _conversation_summary = dropped_summary
        _conversation_summary = _conversation_summary[-400:]
        _conversation_history = _conversation_history[-MAX_TURNS:]
    # Enforce character budget to prevent context window overflow
    # Uses 256-token system overhead estimate to match build_rag_prompt.
    try:
        from memory_management import get_profile
        profile = get_profile()
        n_ctx = profile.get("n_ctx", 2048)
        max_tokens = profile.get("max_tokens", 512)
        budget_chars = max(300, (n_ctx - max_tokens - 256) * 4)
        total = sum(len(q) + len(a) for q, a in _conversation_history)
        while total > budget_chars and _conversation_history:
            removed = _conversation_history.pop(0)
            total -= len(removed[0]) + len(removed[1])
    except Exception:
        pass


def clear_memory():
    global _conversation_history, _conversation_summary
    _conversation_history = []
    _conversation_summary = ""


def stop_generation():
    global _stop_flag
    _stop_flag = True


def wait_for_server():
    """Wait for the llama-server health endpoint.
    Short-circuits after first confirmed healthy response to avoid
    redundant polling on every subsequent chat call (BE-1).
    Fires a background KV-cache pre-warm after the server is first confirmed
    healthy so the very first user query is as fast as all subsequent ones.
    """
    global _server_confirmed_ready
    if _server_confirmed_ready:
        return True
    import urllib.request
    import time
    from config import QWEN_SERVER_PORT
    for _ in range(10):
        try:
            r = urllib.request.urlopen(f"http://127.0.0.1:{QWEN_SERVER_PORT}/health", timeout=2)
            if r.getcode() == 200:
                _server_confirmed_ready = True
                # Fire-and-forget KV cache pre-warm (Improvement #5)
                threading.Thread(target=_prewarm_kv_cache, daemon=True).start()
                return True
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Server not ready")


def _prewarm_kv_cache() -> None:
    """
    Improvement #5: Send a silent 1-token generation immediately after the
    server becomes healthy.  This loads model weights into CPU caches and
    pre-computes the system-prompt KV cache so the FIRST real user query
    feels as fast as all subsequent ones.

    Runs in a daemon thread — never blocks startup or the chat flow.
    """
    import urllib.request
    from config import QWEN_SERVER_PORT
    from llm import build_direct_prompt

    time.sleep(1.5)   # small grace period after health confirms ready

    # Pre-warm Direct Chat prompt
    prewarm_prompt_direct = build_direct_prompt("Hello", history=[], summary="")
    payload_direct = json.dumps({
        "prompt": prewarm_prompt_direct,
        "n_predict": 1,
        "temperature": 0.0,
        "cache_prompt": True,   # keep KV in server cache after this call
    }).encode()
    
    # Pre-warm RAG system prompt prefix (up to the user block)
    from llm import build_rag_prompt
    # Passing empty context and question "Hello" generates the base RAG prompt shape
    prewarm_prompt_rag = build_rag_prompt([], "Hello")
    # Only evaluate up to the Context: part to pre-cache the static system message
    split_idx = prewarm_prompt_rag.find("Context:\n")
    if split_idx != -1:
        prewarm_prompt_rag = prewarm_prompt_rag[:split_idx]
        
    payload_rag = json.dumps({
        "prompt": prewarm_prompt_rag,
        "n_predict": 1,
        "temperature": 0.0,
        "cache_prompt": True,
    }).encode()

    url = f"http://127.0.0.1:{QWEN_SERVER_PORT}/completion"
    
    for payload in [payload_direct, payload_rag]:
        req = urllib.request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=30):
                pass
        except Exception as e:
            print(f"[API] Pre-warm skipped (non-fatal): {e}")
            
    print("[API] KV cache pre-warmed — first queries will be fast.")


def ensure_ready(model_path=None):
    global _initialized
    if _initialized:
        return
    with _init_lock:
        if not _initialized:
            # Need imports here too if calling ensure_ready directly
            global pipeline
            if pipeline is None:
                import pipeline as pipe_mod
                pipeline = pipe_mod
            pipeline.init(model_path)   # this will now BLOCK until models are ready
            _initialized = True


def init_with_path(model_path):
    ensure_ready(model_path)


def init_with_progress(model_path, progress_callback):
    """Initialize with real-time progress events pushed to Flutter.

    progress_callback is a Kotlin method reference called via .invoke(jsonString).
    Events have the shape: {"state": "downloading|loading|ready|error", "progress": 0.0-1.0, "message": "..."}
    """
    global _initialized, pipeline, downloader, runtime, bootstrap

    if _initialized:
        _emit_progress("ready", 1.0, "Ready.")
        return

    _set_progress_callback(progress_callback)

    with _init_lock:
        if _initialized:
            _emit_progress("ready", 1.0, "Ready.")
            return

        try:
            import gc
            _emit_progress("downloading", 0.01, "[BOOTSTRAP] Initializing Python runtime…")
            
            # Step 0: Imports (Deferred)
            import pipeline as pipe_mod
            import downloader as dl_mod
            from runtime import bootstrap as bs_mod
            pipeline = pipe_mod
            downloader = dl_mod
            bootstrap = bs_mod

            _emit_progress("downloading", 0.05, "[SYS] Configuring storage layer…")

            if model_path:
                downloader.set_model_dir(model_path)

            from storage import init_db
            init_db()
            pipeline.retriever.reload()

            # Step 1: Download models (with progress)
            download_done = threading.Event()
            download_error = [None]

            def on_download_progress(frac, text):
                _emit_progress("downloading", frac, f"[DL] {text}")

            def on_download_done(success, message):
                if not success:
                    download_error[0] = message
                download_done.set()

            downloader.auto_download_default(
                on_progress=on_download_progress,
                on_done=on_download_done,
            )

            # Wait for download to complete (up to 10 minutes)
            gc.collect()
            download_done.wait(timeout=600)

            if download_error[0]:
                _emit_progress("error", 1.0, f"[ERR-DL] {download_error[0]}")
                return

            # Step 2: Load model (with progress)
            qwen_path = downloader.model_dest_path(downloader.QWEN_MODEL["filename"])

            if not pipeline.runtime.is_loaded():
                _emit_progress("loading", 0.05, "[LOAD] Preparing the AI engine…")

                def on_load_progress(frac, text):
                    msg = f"[LOAD] {text}" if text else "[LOAD] Preparing the AI engine…"
                    _emit_progress("loading", frac, msg)

                pipeline.runtime.load(qwen_path, on_progress=on_load_progress)

            # Step 3: Start embedding engine (lazy or eager based on RAM profile)
            from downloader import NOMIC_MODEL
            nomic_path = downloader.model_dest_path(NOMIC_MODEL["filename"])
            from memory_management import get_profile, ensure_nomic_server
            mem_profile = get_profile()
            if os.path.isfile(nomic_path):
                if mem_profile.get("nomic_lazy", False):
                    _emit_progress("loading", 0.95,
                                   f"[LOAD] Semantic index deferred (profile={mem_profile['profile']})")
                else:
                    _emit_progress("loading", 0.95, "[LOAD] Starting semantic index…")
                    ensure_nomic_server(nomic_path)

            _initialized = True
            _emit_progress("ready", 1.0, "Ready to chat!")

        except BaseException as e:
            msg = f"Fatal Error: {type(e).__name__}: {e}"
            _emit_progress("error", 1.0, f"[CRITICAL] {msg}")
            # Do NOT re-raise, let the UI handle the error state


def get_status():
    """Return current bootstrap state as a dict for one-shot polling."""
    if _initialized:
        return {"state": "ready", "progress": 1.0, "message": "AI engine ready."}

    try:
        from runtime import bootstrap as bs_mod
        evt = bs_mod.get_bootstrap_event() # Or use global bootstrap if set
        state_map = {
            bs_mod.BootstrapState.IDLE: "idle",
            bs_mod.BootstrapState.DOWNLOADING: "downloading",
            bs_mod.BootstrapState.READY: "ready",
            bs_mod.BootstrapState.ERROR: "error",
        }
        return {
            "state": state_map.get(evt.state, "idle"),
            "progress": evt.progress,
            "message": evt.message,
        }
    except Exception:
        return {"state": "idle", "progress": 0.0, "message": ""}


def get_init_logs():
    return "Diagnostic logs are no longer available in production mode."


def chat(query):
    global _is_generating, _stop_flag

    if _is_generating:
        return "Please wait, processing previous request..."

    _is_generating = True
    _stop_flag = False
    print("[CHAT] Request started")
    
    try:
        ensure_ready()
        wait_for_server()
        trim_history()

        global pipeline
        ok, response = pipeline.chat_direct(
            question=query,
            history=_conversation_history,
            summary=_conversation_summary
        )

        if ok:
            # Idempotency guard: skip duplicate turns from double-submit (BE-2)
            if not _conversation_history or _conversation_history[-1] != (query, response):
                _conversation_history.append((query, response))

        print("[CHAT] Response received")
        return response if ok else f"ERROR: {response}"

    except Exception as e:
        return f"ERROR: {str(e)}"
    finally:
        _is_generating = False


def chat_stream(query, token_callback, response_style="concise"):
    """Streaming chat — calls token_callback for each generated token."""
    global _is_generating, _stop_flag

    if _is_generating:
        return "Please wait, processing previous request..."

    _is_generating = True
    _stop_flag = False
    print("[CHAT-STREAM] Request started")
    
    try:
        ensure_ready()
        wait_for_server()

        def _on_token(token):
            try:
                token_callback.invoke(token)
            except Exception as e:
                print(f"[CHAT-STREAM] callback error: {e}")

        trim_history()
        global pipeline
        ok, response, thinking = pipeline.chat_direct(
            question=query,
            history=_conversation_history,
            summary=_conversation_summary,
            stream_cb=_on_token,
            response_style=str(response_style),
        )

        if ok:
            # Idempotency guard: skip duplicate turns from double-submit (BE-2)
            if not _conversation_history or _conversation_history[-1] != (query, response):
                _conversation_history.append((query, response))

        print("[CHAT-STREAM] Response received")
        result_str = response if ok else f"ERROR: {response}"
        return json.dumps({"answer": result_str, "thinking": thinking})

    except Exception as e:
        return json.dumps({"answer": f"ERROR: {str(e)}", "thinking": ""})
    finally:
        _is_generating = False


# ------------------------------------------------------------------ #
#  Document management                                                 #
# ------------------------------------------------------------------ #

def upload_document(file_path):
    try:
        global pipeline
        if pipeline is None:
            import pipeline as pipe_mod
            pipeline = pipe_mod
        ok, msg = pipeline.ingest_document(file_path)
        return json.dumps({"success": ok, "message": msg})
    except Exception as e:
        return json.dumps({"success": False, "message": f"Error: {e}"})


def list_docs():
    try:
        global pipeline
        if pipeline is None:
            import pipeline as pipe_mod
            pipeline = pipe_mod
        docs = pipeline.list_documents()
        return json.dumps(docs)
    except Exception as e:
        return json.dumps([])


def delete_doc(doc_id):
    try:
        global pipeline
        if pipeline is None:
            import pipeline as pipe_mod
            pipeline = pipe_mod
        pipeline.delete_document_by_id(int(doc_id))
        return json.dumps({"success": True, "message": "Document deleted."})
    except Exception as e:
        return json.dumps({"success": False, "message": f"Error: {e}"})


def clear_docs():
    try:
        global pipeline
        if pipeline is None:
            import pipeline as pipe_mod
            pipeline = pipe_mod
        pipeline.clear_all_documents()
        return json.dumps({"success": True, "message": "All documents cleared."})
    except Exception as e:
        return json.dumps({"success": False, "message": f"Error: {e}"})


# ------------------------------------------------------------------ #
#  RAG streaming query                                                 #
# ------------------------------------------------------------------ #

def ask_rag(query, token_callback, response_style="concise"):
    """RAG streaming query with source attribution, response caching,
    and conversation history so follow-up questions carry prior context."""
    global _is_generating, _stop_flag

    if _is_generating:
        return json.dumps({"answer": "Please wait, processing previous request...", "sources": [], "thinking": "", "parent_chunks": []})

    # --- Cache hit: skip retrieval + LLM entirely (Improvement #3) ---
    cached = _try_cache(query, _conversation_history)
    if cached:
        print("[RAG-STREAM] Cache hit — returning instantly")
        try:
            data = json.loads(cached)
            # Re-stream tokens so the UI animation still plays
            for word in data.get("answer", "").split():
                try:
                    token_callback.invoke(word + " ")
                except Exception:
                    pass
        except Exception:
            pass
        return cached

    _is_generating = True
    _stop_flag = False
    print("[RAG-STREAM] Request started")

    try:
        ensure_ready()
        wait_for_server()
        # Trim history BEFORE query so retrieval_query augmentation uses
        # the most recent clean turns (same as chat_stream does)
        trim_history()

        def _on_token(token):
            try:
                token_callback.invoke(token)
            except Exception as e:
                print(f"[RAG-STREAM] callback error: {e}")

        global pipeline
        ok, response, sources, thinking, parent_chunks = pipeline.ask(
            question=query,
            history=_conversation_history,
            summary=_conversation_summary,
            stream_cb=_on_token,
            response_style=str(response_style),
        )

        print("[RAG-STREAM] Response received")

        # Append this turn to conversation history so follow-up questions
        # can reference what was just said (mirrors chat_stream behaviour).
        if ok:
            if not _conversation_history or _conversation_history[-1] != (query, response):
                _conversation_history.append((query, response))

        result_json = json.dumps({
            "answer": response if ok else f"ERROR: {response}",
            "sources": sources,
            "thinking": thinking,
            "parent_chunks": parent_chunks,
        })

        # Store in cache only on success
        if ok:
            _store_cache(query, _conversation_history, result_json)

        return result_json

    except Exception as e:
        return json.dumps({"answer": f"ERROR: {str(e)}", "sources": [], "thinking": "", "parent_chunks": []})
    finally:
        _is_generating = False


# ------------------------------------------------------------------ #
#  Engine health                                                       #
# ------------------------------------------------------------------ #

def get_engine_health():
    """Return JSON with model/server health info for the settings screen."""
    try:
        global pipeline
        if pipeline is None:
            import pipeline as pipe_mod
            pipeline = pipe_mod
            
        from runtime.model_runtime import LlamaModelRuntime

        health = {
            "model_loaded": pipeline.runtime.is_loaded(),
            "backend": "On-device",
            "qwen_ready": False,
            "nomic_ready": False,
            "doc_count": 0,
            "chunk_count": 0,
        }

        if isinstance(pipeline.runtime, LlamaModelRuntime):
            h = pipeline.runtime.health()
            health["qwen_ready"] = h.qwen_ready
            health["nomic_ready"] = h.nomic_ready
            health["backend"] = "On-device"

        try:
            docs = pipeline.list_documents()
            health["doc_count"] = len(docs)
            health["chunk_count"] = sum(d.get("num_chunks", 0) for d in docs)
        except Exception:
            pass

        return json.dumps(health)
    except Exception as e:
        return json.dumps({"error": str(e)})


# ------------------------------------------------------------------ #
#  Resource usage (memory + battery for Settings UI)                    #
# ------------------------------------------------------------------ #

def get_resource_usage():
    """Return JSON with live memory, battery, and profile info."""
    try:
        from memory_management import get_resource_report_json
        return get_resource_report_json()
    except Exception as e:
        return json.dumps({"error": str(e)})