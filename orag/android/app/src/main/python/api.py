import threading
import json
import os
import time

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
MAX_TURNS = 5

# ---- Progress callback holder (set from Kotlin) ----
_progress_callback = None
_progress_lock = threading.Lock()

def _log_init(msg):
    """Write diagnostic info to a log file in the app private directory."""
    try:
        from llm import _android_private_dir
        priv = _android_private_dir()
        if not priv:
            return
        log_path = os.path.join(priv, "api_init.log")
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"[{timestamp}] {msg}\n")
    except Exception:
        pass


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


def trim_history():
    global _conversation_history
    if len(_conversation_history) > MAX_TURNS:
        _conversation_history = _conversation_history[-MAX_TURNS:]


def clear_memory():
    global _conversation_history
    _conversation_history = []


def stop_generation():
    global _stop_flag
    _stop_flag = True


def wait_for_server():
    import urllib.request
    import time
    from config import QWEN_SERVER_PORT
    for _ in range(10):
        try:
            r = urllib.request.urlopen(f"http://127.0.0.1:{QWEN_SERVER_PORT}/health", timeout=2)
            if r.getcode() == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Server not ready")


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
            # IMMEDIATE progress before any heavy imports
            _emit_progress("downloading", 0.01, "[BOOTSTRAP] Initializing Python runtime…")
            _log_init("Starting init_with_progress Stage 0 (v3)")
            
            # Step 0: Imports (Deferred)
            _log_init("Importing modules...")
            import pipeline as pipe_mod
            import downloader as dl_mod
            from runtime import bootstrap as bs_mod
            pipeline = pipe_mod
            downloader = dl_mod
            bootstrap = bs_mod
            _log_init("Imports successful.")

            _emit_progress("downloading", 0.05, "[SYS] Configuring storage layer…")

            if model_path:
                downloader.set_model_dir(model_path)
                _log_init(f"Model dir set: {model_path}")

            from storage import init_db
            _log_init("Initializing database...")
            init_db()
            _log_init("Reloading retriever...")
            pipeline.retriever.reload()
            _log_init("Stage 0/1 done")

            # Step 1: Download models (with progress)
            _log_init("Stage 2: Sequential downloads starting")
            download_done = threading.Event()
            download_error = [None]

            def on_download_progress(frac, text):
                _emit_progress("downloading", frac, f"[DL] {text}")

            def on_download_done(success, message):
                _log_init(f"Download callback: success={success}, msg={message}")
                if not success:
                    download_error[0] = message
                download_done.set()

            downloader.auto_download_default(
                on_progress=on_download_progress,
                on_done=on_download_done,
            )

            # Wait for download to complete (sequential)
            _log_init("auto_download_default finished.")
            gc.collect() 

            if download_error[0]:
                _emit_progress("error", 1.0, f"[ERR-DL] {download_error[0]}")
                return

            # Step 2: Load model (with progress)
            _log_init("Stage 3: Model loading starting")
            qwen_path = downloader.model_dest_path(downloader.QWEN_MODEL["filename"])

            if not pipeline.runtime.is_loaded():
                _log_init(f"Loading Qwen model from: {qwen_path}")
                _emit_progress("loading", 0.05, "[LOAD] Initializing inference engine…")

                def on_load_progress(frac, text):
                    msg = f"[LOAD] {text}" if text else "[LOAD] Warming up…"
                    _emit_progress("loading", frac, msg)

                pipeline.runtime.load(qwen_path, on_progress=on_load_progress)
                _log_init("Qwen model loaded successfully.")

            # Step 3: Start embedding engine for RAG semantic search
            from downloader import NOMIC_MODEL
            nomic_path = downloader.model_dest_path(NOMIC_MODEL["filename"])
            from runtime.model_runtime import LlamaModelRuntime
            if os.path.isfile(nomic_path) and isinstance(pipeline.runtime, LlamaModelRuntime):
                _log_init(f"Starting Nomic server from: {nomic_path}")
                _emit_progress("loading", 0.95, "[LOAD] Starting semantic index…")
                pipeline.runtime.start_nomic_server_if_needed(nomic_path)
                _log_init("Nomic server ready.")

            _initialized = True
            _log_init("Initialization complete.")
            _emit_progress("ready", 1.0, "[READY] System online.")

        except Exception as e:
            _emit_progress("error", 1.0, f"Init failed: {e}")
            _log_init(f"Init failed: {e}")
            raise


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
            summary=""
        )

        if ok:
            _conversation_history.append((query, response))

        print("[CHAT] Response received")
        return response if ok else f"ERROR: {response}"

    except Exception as e:
        return f"ERROR: {str(e)}"
    finally:
        _is_generating = False


def chat_stream(query, token_callback):
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
        ok, response = pipeline.chat_direct(
            question=query,
            history=_conversation_history,
            summary="",
            stream_cb=_on_token,
        )

        if ok:
            _conversation_history.append((query, response))

        print("[CHAT-STREAM] Response received")
        return response if ok else f"ERROR: {response}"

    except Exception as e:
        return f"ERROR: {str(e)}"
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

def ask_rag(query, token_callback):
    """RAG streaming query with source attribution."""
    global _is_generating, _stop_flag

    if _is_generating:
        return json.dumps({"answer": "Please wait, processing previous request...", "sources": []})

    _is_generating = True
    _stop_flag = False
    print("[RAG-STREAM] Request started")

    try:
        ensure_ready()
        wait_for_server()

        def _on_token(token):
            try:
                token_callback.invoke(token)
            except Exception as e:
                print(f"[RAG-STREAM] callback error: {e}")

        global pipeline
        ok, response, sources = pipeline.ask(
            question=query,
            stream_cb=_on_token,
        )

        print("[RAG-STREAM] Response received")
        return json.dumps({
            "answer": response if ok else f"ERROR: {response}",
            "sources": sources,
        })

    except Exception as e:
        return json.dumps({"answer": f"ERROR: {str(e)}", "sources": []})
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