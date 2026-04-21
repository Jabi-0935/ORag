"""
llm.py — Unified LLM backend facade.

Phase 3 refactor: this file is now a thin orchestration layer that delegates to:
  - llm_runtime.py  — process lifecycle, Android detection, binary management
  - llm_client.py   — HTTP /completion calls to the Qwen llama-server
  - embedding.py    — Nomic embedding server + /embedding API + query cache
  - prompt.py       — ChatML prompt builders

This file retains:
  - LlamaCppModel class (the unified backend facade with fallback chain)
  - Thinking-token stream filter
  - Module-level singleton: llm = LlamaCppModel()
"""
from __future__ import annotations

import re
import threading
from typing import Callable, Optional

# ------------------------------------------------------------------ #
#  Re-exports for backward compatibility                               #
# ------------------------------------------------------------------ #
# Modules that historically imported from llm.py can continue to do so.
# New code should import from the specific module directly.

from llm_runtime import (
    set_android_paths,
    is_android as _is_android,
    android_private_dir as _android_private_dir,
    server_exe as _server_exe,
    extract_zip_if_needed as _extract_zip_if_needed,
    start_llama_server as _start_llama_server,
    stop_llama_server as _stop_llama_server,
    get_android_binary_error,
    probe_port,
    qwen_port,
    list_available_models,
    _optimal_threads,
)

from llm_client import (
    gen_via_server as _gen_via_server,
)

from embedding import (
    get_embedding,
    start_nomic_server,
    stop_nomic_server,
    nomic_port,
)

from prompt import (
    build_rag_prompt,
    build_direct_prompt,
)


# ------------------------------------------------------------------ #
#  Backend helpers                                                     #
# ------------------------------------------------------------------ #

_llama_mod = None

def _get_llama():
    """Return llama_cpp.Llama class, or raise RuntimeError if not installed."""
    global _llama_mod
    if _llama_mod is None:
        try:
            from llama_cpp import Llama
            _llama_mod = Llama
        except ImportError:
            raise RuntimeError("llama-cpp-python is not installed.")
    return _llama_mod


def _ollama_reachable() -> bool:
    """Return True if the Ollama server is reachable on localhost:11434."""
    try:
        import ollama as _ol
        _ol.list()
        return True
    except Exception:
        return False


# ------------------------------------------------------------------ #
#  LLM singleton                                                       #
# ------------------------------------------------------------------ #

class LlamaCppModel:
    """
    Unified LLM backend — tries each backend in priority order:
      1. llama-cpp-python  (in-process, best performance)
      2. Ollama            (if the server is running on localhost:11434)
      3. llama-server      (auto-extracted from llamacpp_bin.zip)
    """

    DEFAULT_CTX      = 768
    DEFAULT_MAX_TOK  = 320
    DEFAULT_TEMP     = 0.7
    DEFAULT_TOP_P    = 0.9
    DEFAULT_THREADS  = 0   # 0 = auto-detect via _optimal_threads()

    def __init__(self) -> None:
        self._model      = None
        self._model_path: Optional[str] = None
        self._lock       = threading.Lock()
        self._backend    = "none"   # "llama_cpp"|"ollama"|"llama_server"|"none"
        self._ollama_name = ""

    # ---------------------------------------------------------------- #
    #  Loading                                                           #
    # ---------------------------------------------------------------- #

    def load(self, model_path: str, n_ctx: int = DEFAULT_CTX,
             n_threads: int = DEFAULT_THREADS, n_gpu_layers: int = 0,
             on_progress: Optional[Callable[[float, str], None]] = None) -> None:
        if n_threads == 0:
            n_threads = _optimal_threads()
        with self._lock:
            self._unload_internal()

            # 1. llama-cpp-python
            try:
                Llama = _get_llama()
                self._model = Llama(
                    model_path   = model_path,
                    n_ctx        = n_ctx,
                    n_threads    = n_threads,
                    n_gpu_layers = n_gpu_layers,
                    verbose      = False,
                )
                self._model_path = model_path
                self._backend    = "llama_cpp"
                print("[LLM] Backend: llama-cpp-python")
                return
            except RuntimeError:
                pass

            # 2. Ollama
            if _ollama_reachable():
                try:
                    self._load_via_ollama(model_path)
                    return
                except RuntimeError as e:
                    print(f"[LLM] Ollama failed: {e}")

            # 3. llama-server (bundled binary)
            _extract_zip_if_needed()
            if _start_llama_server(model_path, n_ctx, n_threads,
                                   on_progress=on_progress):
                self._model_path = model_path
                self._backend    = "llama_server"
                print("[LLM] Backend: llama-server (built-in)")
                return

            if _is_android():
                detail = get_android_binary_error() or "unknown error"
                raise RuntimeError(
                    f"No LLM backend available.\n\n"
                    f"Binary extraction failed: {detail}\n\n"
                    f"Debug log: {_android_private_dir()}/llama_debug.txt"
                )
            raise RuntimeError(
                "No LLM backend available.\n\n"
                "Options:\n"
                "  A) Install Ollama: https://ollama.com/download/windows\n"
                "  B) Place llamacpp_bin.zip in the app folder\n"
                "     (Windows CPU build from https://github.com/ggml-org/llama.cpp/releases)\n"
                "  C) Install llama-cpp-python (requires a C++ compiler)"
            )

    def _load_via_ollama(self, model_path: str) -> None:
        try:
            import ollama as _ol
        except ImportError:
            raise RuntimeError("ollama package not installed.")
        from pathlib import Path
        stem  = Path(model_path).stem.lower()
        clean = "".join(c if (c.isalnum() or c == "-") else "-" for c in stem)
        ollama_name = clean[:50].strip("-") or "local-gguf"
        abs_path = str(Path(model_path).resolve())
        print(f"[LLM] Registering '{ollama_name}' with Ollama ...")
        try:
            _ol.create(model=ollama_name, from_=abs_path, stream=False)
        except Exception as exc:
            raise RuntimeError(f"Ollama registration failed: {exc}") from exc
        self._ollama_name = ollama_name
        self._model_path  = model_path
        self._backend     = "ollama"
        print(f"[LLM] Backend: Ollama (model '{ollama_name}')")

    def _unload_internal(self) -> None:
        if self._model is not None:
            del self._model
            self._model = None
        if self._backend == "llama_server":
            _stop_llama_server()
        self._backend     = "none"
        self._model_path  = None
        self._ollama_name = ""

    def unload(self) -> None:
        with self._lock:
            self._unload_internal()

    def is_loaded(self) -> bool:
        return self._backend != "none"

    @property
    def model_path(self) -> Optional[str]:
        return self._model_path

    @property
    def backend_name(self) -> str:
        return self._backend

    def connect_external_server(self, model_path: str) -> None:
        """Attach to an already-running llama-server process (service-owned)."""
        from llm_client import probe_qwen_port
        if not probe_qwen_port():
            raise RuntimeError("llama-server is not healthy on localhost")
        with self._lock:
            self._unload_internal()
            self._model_path = model_path
            self._backend = "llama_server"

    # ---------------------------------------------------------------- #
    #  Inference                                                         #
    # ---------------------------------------------------------------- #

    def generate(
        self,
        prompt: str,
        max_tokens:  int   = DEFAULT_MAX_TOK,
        temperature: float = DEFAULT_TEMP,
        top_p:       float = DEFAULT_TOP_P,
        stream_cb:   Optional[Callable[[str], None]] = None,
        cancel_event: Optional["threading.Event"] = None,
    ) -> str:
        """
        Generate a response.  stream_cb (if given) is called with each
        new token fragment as it arrives.  Returns the full response text.
        Thinking-model reasoning blocks are automatically stripped.
        cancel_event: if set, the streaming loop breaks early (user stop).
        """
        if self._backend == "none":
            raise RuntimeError("No model loaded. Call load() first.")

        # Wrap stream_cb with the thinking-token filter
        filtered_cb = None
        think_filter: Optional[_ThinkingStreamFilter] = None
        if stream_cb is not None:
            think_filter = _ThinkingStreamFilter(stream_cb)
            filtered_cb  = think_filter

        if self._backend == "llama_cpp":
            raw = self._gen_llama_cpp(prompt, max_tokens, temperature, top_p, filtered_cb, cancel_event)
        elif self._backend == "ollama":
            raw = self._gen_ollama(prompt, max_tokens, temperature, top_p, filtered_cb, cancel_event)
        else:
            raw = _gen_via_server(prompt, max_tokens, temperature, top_p, filtered_cb, cancel_event)

        if think_filter is not None:
            think_filter.flush()

        # Strip thinking blocks from the full returned string too
        return _strip_thinking(raw)

    def _gen_llama_cpp(self, prompt, max_tokens, temp, top_p, stream_cb, cancel_event=None):
        with self._lock:
            if stream_cb:
                full = ""
                for chunk in self._model(
                    prompt,
                    max_tokens  = max_tokens,
                    temperature = temp,
                    top_p       = top_p,
                    stream      = True,
                ):
                    if cancel_event is not None and cancel_event.is_set():
                        break
                    token = chunk["choices"][0]["text"]
                    full += token
                    stream_cb(token)
                return full
            else:
                out = self._model(
                    prompt,
                    max_tokens  = max_tokens,
                    temperature = temp,
                    top_p       = top_p,
                    stream      = False,
                )
                return out["choices"][0]["text"]

    def _gen_ollama(self, prompt, max_tokens, temp, top_p, stream_cb, cancel_event=None):
        import ollama as _ol
        options = {
            "temperature": temp,
            "top_p":       top_p,
            "num_predict": max_tokens,
        }
        if stream_cb:
            full = ""
            for chunk in _ol.generate(
                model   = self._ollama_name,
                prompt  = prompt,
                options = options,
                stream  = True,
            ):
                if cancel_event is not None and cancel_event.is_set():
                    break
                token = chunk.response
                full += token
                stream_cb(token)
            return full
        else:
            resp = _ol.generate(
                model   = self._ollama_name,
                prompt  = prompt,
                options = options,
                stream  = False,
            )
            return resp.response


# ------------------------------------------------------------------ #
#  Thinking-token filter                                               #
# ------------------------------------------------------------------ #

def _strip_thinking(text: str) -> str:
    """
    Remove internal reasoning blocks that thinking models emit before
    the real answer.  Handles several common tag styles.
    """
    # Standard <think>...</think> (Qwen, DeepSeek, GLM thinking variants)
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
    # Pipe-delimited variants  <|think|>...</|think|>
    text = re.sub(r'<\|think\|>.*?</\|think\|>', '', text, flags=re.DOTALL)
    # Some models wrap reasoning in triple-backtick reasoning blocks
    text = re.sub(r'```reasoning.*?```', '', text, flags=re.DOTALL)
    return text.strip()


class _ThinkingStreamFilter:
    """
    Wraps a stream_cb so that tokens inside <think>…</think> blocks are
    suppressed; only the real answer tokens are forwarded to the UI.
    """
    def __init__(self, cb):
        self._cb     = cb
        self._buf    = ""    # accumulates tokens we haven't decided about yet
        self._depth  = 0     # nesting level inside <think> block
        self._past   = False # True once we've seen </think>

    def __call__(self, token: str):
        self._buf += token
        while True:
            if self._depth == 0:
                # Not inside a think block — look for opening tag
                idx = self._buf.find("<think>")
                if idx == -1:
                    # No think tag anywhere — flush all buffered tokens
                    if self._buf:
                        self._cb(self._buf)
                        self._buf = ""
                    break
                else:
                    # Flush everything before the tag, then swallow from tag onward
                    if idx > 0:
                        self._cb(self._buf[:idx])
                    self._buf  = self._buf[idx + len("<think>"):]
                    self._depth = 1
            else:
                # Inside a think block — look for closing tag
                idx = self._buf.find("</think>")
                if idx == -1:
                    # Haven't seen closing tag yet — keep buffering
                    break
                else:
                    self._buf   = self._buf[idx + len("</think>"):]
                    self._depth = 0
                    self._past  = True

    def flush(self):
        """Call after generation ends to emit any remaining buffered tokens."""
        if self._buf and self._depth == 0:
            self._cb(self._buf)
            self._buf = ""


# Module-level singleton
llm = LlamaCppModel()