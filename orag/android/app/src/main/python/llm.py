"""
llm.py â€” LLM backend with automatic three-step fallback.

Priority order:
  1. llama-cpp-python (Android / Linux, or Windows with a C++ compiler)
  2. Ollama            (if installed: https://ollama.com)
  3. llama-server      (bundled pre-built Windows CPU binary â€” zero install)

External interface is identical for all backends:
    load(model_path, ...)  â†’ None
    generate(prompt, ...)  â†’ str
    is_loaded()            â†’ bool
    unload()               â†’ None

Prompts are built for Qwen ChatML in this app runtime.
"""
from __future__ import annotations

import os
import glob
import json
import re
import subprocess
import threading
import time
import zipfile
from pathlib import Path
from typing import Callable, Optional


from config import NOMIC_SERVER_PORT, QWEN_SERVER_PORT

# App root: rag/llm.py â†’ ../..
_APP_ROOT = Path(__file__).resolve().parent.parent.parent

# ------------------------------------------------------------------ #
#  Android detection                                                   #
# ------------------------------------------------------------------ #

# Paths injected from Kotlin (MainActivity) before Python init runs.
# mActivity is not accessible from Chaquopy in Flutter's threading model,
# so these are the single source of truth on Android.
_ANDROID_NATIVE_LIB_DIR: Optional[str] = None
_ANDROID_FILES_DIR: Optional[str] = None


def set_android_paths(native_lib_dir: str, files_dir: str) -> None:
    """Called from Kotlin to inject Android-specific paths before init."""
    global _ANDROID_NATIVE_LIB_DIR, _ANDROID_FILES_DIR
    _ANDROID_NATIVE_LIB_DIR = native_lib_dir
    _ANDROID_FILES_DIR = files_dir
    os.environ["ANDROID_PRIVATE"] = files_dir
    print(f"[llm] Android paths injected: native_lib={native_lib_dir}, files={files_dir}")


def _is_android() -> bool:
    """Reliably detect Android runtime via multiple indicators."""
    if _ANDROID_NATIVE_LIB_DIR is not None:
        return True
    if os.environ.get("ANDROID_PRIVATE"):
        return True
    try:
        if os.path.isfile("/system/build.prop"):
            return True
    except Exception:
        pass
    return False


def _android_private_dir() -> str:
    """Return the best available private directory for the app on Android."""
    if _ANDROID_FILES_DIR:
        return _ANDROID_FILES_DIR
    priv = os.environ.get("ANDROID_PRIVATE", "")
    if priv:
        return priv
    return ""



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
#  llama-server subprocess backend                                     #
# ------------------------------------------------------------------ #

_LLAMASERVER_PORT  = QWEN_SERVER_PORT   # Qwen generation server


def _optimal_threads() -> int:
    """Pick a sensible thread count for the device.
    Use half the logical CPUs (targets performance cores on big.LITTLE),
    clamped to [2, 8].  Falls back to 4 if cpu_count is unavailable.
    """
    try:
        import os as _os
        count = _os.cpu_count() or 4
        return max(2, min(8, count // 2))
    except Exception:
        return 4


# ------------------------------------------------------------------ #
#  Adaptive memory profiling (delegated to memory_management.py)       #
# ------------------------------------------------------------------ #

def get_memory_profile() -> dict:
    """Return the adaptive memory profile from memory_management module.
    This is kept as a thin wrapper for backward compatibility.
    """
    from memory_management import get_profile
    return get_profile()


_LLAMASERVER_PROC  = None
_LLAMASERVER_LOCK  = threading.Lock()
_ANDROID_EXE_PATH: Optional[str] = None   # set once by _ensure_android_binary
_ANDROID_BINARY_ERROR: str = ""            # stores last extraction failure reason

_NOMIC_PORT  = NOMIC_SERVER_PORT         # Nomic embedding server
_NOMIC_PROC  = None
_NOMIC_LOCK  = threading.Lock()


def _bin_dir() -> Path:
    return _APP_ROOT / "llamacpp_bin"


def _ensure_android_binary() -> Optional[str]:
    """
    Android-specific: locate the bundled ARM64 llama-server binary.
    """
    global _ANDROID_EXE_PATH, _ANDROID_BINARY_ERROR
    if _ANDROID_EXE_PATH is not None:
        return _ANDROID_EXE_PATH

    if not _is_android():
        return None

    # Primary: use path injected from Kotlin (most reliable)
    native_lib_dir: Optional[str] = _ANDROID_NATIVE_LIB_DIR
    if not native_lib_dir:
        try:
            from android import mActivity  # type: ignore
            native_lib_dir = str(mActivity.getApplicationInfo().nativeLibraryDir)
        except Exception:
            pass

    if native_lib_dir:
        candidates = ["llama-server.so", "libllama_server.so"]
        for name in candidates:
            exe = os.path.join(native_lib_dir, name)
            if os.path.isfile(exe):
                _ANDROID_EXE_PATH = exe
                return exe

        _ANDROID_BINARY_ERROR = f"No llama server binary found in {native_lib_dir}."
    else:
        _ANDROID_BINARY_ERROR = "Could not determine nativeLibraryDir"

    return None


def _server_exe():
    # 1. Android: use bundled ARM64 binary from nativeLibraryDir
    if _is_android():
        return _ensure_android_binary()  # returns str path or None

    # 2. Desktop: look in llamacpp_bin/ dir
    for p in [_bin_dir() / "llama-server.exe", _bin_dir() / "llama-server"]:
        if p.exists():
            return p
    return None


def _extract_zip_if_needed() -> bool:
    if _is_android():
        return _server_exe() is not None   # on Android, skip ZIP handling
    if _server_exe() is not None:
        return True
    zip_path = _APP_ROOT / "llamacpp_bin.zip"
    if not zip_path.exists():
        return False
    dest = _bin_dir()
    dest.mkdir(parents=True, exist_ok=True)
    print(f"[llama-server] Extracting {zip_path.name} ...")
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest)
    print("[llama-server] Extraction complete.")
    return _server_exe() is not None



def _wait_for_server(port: int, timeout: int = 120,
                     on_tick: Optional[Callable[[float, str], None]] = None) -> bool:
    import urllib.request
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.time() + timeout
    started  = time.time()
    last_tick = 0.0
    while time.time() < deadline:
        proc = _LLAMASERVER_PROC if port == _LLAMASERVER_PORT else _NOMIC_PROC
        if proc is not None and proc.poll() is not None:
            # Process died. Read tail of log if available.
            tail = ""
            priv = _android_private_dir()
            if priv:
                try:
                    log_fn = "llama_server.log" if port == _LLAMASERVER_PORT else "nomic_server.log"
                    log_path = os.path.join(priv, log_fn)
                    if os.path.isfile(log_path):
                        with open(log_path, "rb") as lf:
                            lf.seek(max(0, os.path.getsize(log_path) - 500))
                            tail = lf.read().decode("utf-8", errors="replace")
                except Exception:
                    pass
            print(f"[llama-server port={port}] process exited early (code={proc.returncode}). Tail: {tail}")
            return False

        try:
            with urllib.request.urlopen(url, timeout=1.5) as r:
                if r.status == 200:
                    if on_tick:
                        on_tick(1.0, "AI engine ready!")
                    return True
        except Exception:
            pass

        elapsed = time.time() - started
        if on_tick and elapsed - last_tick >= 1.0:
            last_tick = elapsed
            pct = min(elapsed / timeout, 0.95)
            on_tick(pct, "Preparing the AI engine\u2026")
        time.sleep(1.0)
    return False


def _probe_port(port: int) -> bool:
    """Return True if a llama-server is already responding on *port*."""
    import urllib.request
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health", timeout=1
        ) as r:
            return r.status == 200
    except Exception:
        return False

def probe_port(port: int) -> bool:
    """Public health probe helper for runtime components."""
    return _probe_port(port)


def qwen_port() -> int:
    return _LLAMASERVER_PORT


def nomic_port() -> int:
    return _NOMIC_PORT


def _prepare_android_env() -> dict:
    """Build an environment dict suitable for launching native binaries on Android.

    Sets LD_LIBRARY_PATH to include the nativeLibraryDir so the dynamic linker
    can resolve libllama_server.so's dependencies (libc, libdl, libm are system
    libs but the linker still needs the search path for the binary itself).
    """
    env = os.environ.copy()
    if _is_android() and _ANDROID_NATIVE_LIB_DIR:
        ld = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = f"{_ANDROID_NATIVE_LIB_DIR}:{ld}" if ld else _ANDROID_NATIVE_LIB_DIR
    return env


def _launch_binary(cmd: list, env: dict | None = None) -> subprocess.Popen:
    """Launch a native binary in a cross-platform way.

    On Android: ensures executable permissions, sets LD_LIBRARY_PATH, and tries
    multiple execution strategies if direct exec fails (ENOEXEC).

    Strategy order:
      1. Direct exec (works on most Android versions)
      2. Copy binary to app's private filesDir and exec from there
         (some Android versions require binaries in writable private dirs)
      3. Invoke via /system/bin/linker64 (bypasses kernel exec check)
    """
    exe_path = cmd[0]

    # Ensure the binary has execute permissions (Android may strip them)
    if _is_android():
        try:
            import stat
            st = os.stat(exe_path)
            if not (st.st_mode & stat.S_IXUSR):
                os.chmod(exe_path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                print(f"[launch] Set +x on {exe_path}")
        except Exception as e:
            print(f"[launch] chmod failed (non-fatal): {e}")

    if env is None:
        env = _prepare_android_env()

    kwargs = dict(
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )

    # creationflags is Windows-only; using it on Android causes issues
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        return subprocess.Popen(cmd, **kwargs)

    # On Android, try multiple execution strategies
    strategies = [cmd]  # Strategy 1: direct exec

    if _is_android():
        # Strategy 2: copy to filesDir and exec from there
        priv = _android_private_dir()
        if priv:
            import shutil
            bin_name = os.path.basename(exe_path)
            copied_path = os.path.join(priv, bin_name)
            try:
                if not os.path.isfile(copied_path) or os.path.getsize(copied_path) != os.path.getsize(exe_path):
                    shutil.copy2(exe_path, copied_path)
                    print(f"[launch] Copied binary to {copied_path}")
                import stat as stat_mod
                os.chmod(copied_path, 0o755)
                copied_cmd = [copied_path] + cmd[1:]
                strategies.append(copied_cmd)
            except Exception as e:
                print(f"[launch] Copy-to-filesDir failed (non-fatal): {e}")

        # Strategy 3: invoke via linker64
        linker = "/system/bin/linker64"
        if os.path.isfile(linker):
            linker_cmd = [linker, exe_path] + cmd[1:]
            strategies.append(linker_cmd)

    last_error = None
    for i, try_cmd in enumerate(strategies):
        try:
            print(f"[launch] Strategy {i+1}: {try_cmd[0]}")
            proc = subprocess.Popen(try_cmd, **kwargs)
            # Check if process died immediately (within 0.5s)
            import time
            time.sleep(0.3)
            if proc.poll() is not None:
                rc = proc.returncode
                print(f"[launch] Strategy {i+1} exited immediately with code {rc}")
                last_error = OSError(f"Process exited immediately (code {rc})")
                continue
            print(f"[launch] Strategy {i+1} succeeded (pid={proc.pid})")
            return proc
        except OSError as e:
            print(f"[launch] Strategy {i+1} failed: {e}")
            last_error = e
            continue

    raise last_error or OSError("All launch strategies failed")


def _start_llama_server(model_path: str, n_ctx: int, n_threads: int,
                        on_progress: Optional[Callable[[float, str], None]] = None) -> bool:
    global _LLAMASERVER_PROC, _ANDROID_BINARY_ERROR
    exe = _server_exe()
    if exe is None:
        return False
    with _LLAMASERVER_LOCK:
        if _LLAMASERVER_PROC is not None:
            return True
        # Fast-path: the Android foreground service may have already started
        # llama-server.  If the port is responding we don't need a new process.
        if _probe_port(_LLAMASERVER_PORT):
            print("[llama-server] Already running (owned by service) \u2013 skipping launch.")
            if on_progress:
                on_progress(1.0, "AI engine ready!")
            return True
        profile = get_memory_profile()
        cmd = [
            str(exe),
            "--model", model_path,
            "--ctx-size", str(n_ctx),              # dynamic from profile
            "--threads", str(n_threads),           # dynamic from profile
            "--threads-batch", str(n_threads),
            "--port", str(_LLAMASERVER_PORT),
            "--host", "127.0.0.1",
            "--n-gpu-layers", "0",
            "--flash-attn", "on",
            "--cont-batching",
        ]

        # Adaptive flags based on RAM profile
        kv_type = profile.get("kv_cache_type", "q8_0")
        batch = profile.get("batch_size", 512)
        use_mmap = profile.get("use_mmap", False)

        cmd.extend(["--cache-type-k", kv_type,
                     "--cache-type-v", kv_type])
        if batch != 512:  # only override if non-default
            cmd.extend(["--batch-size", str(batch)])
        if not use_mmap:
            cmd.extend(["--no-mmap"])

        print(f"  Memory mode: {profile['profile']} "
              f"(mmap={'on' if use_mmap else 'off'}, cache={kv_type}, batch={batch})")
        print(f"[llama-server] Starting: {cmd[0]}")
        print(f"  Model: {Path(model_path).name}")
        print("  Loading model into memory, please wait ...")
        if on_progress:
            on_progress(0.02, f"Preparing the AI engine\u2026")

        try:
            _LLAMASERVER_PROC = _launch_binary(cmd)
        except Exception as exc:
            _ANDROID_BINARY_ERROR = f"Launch failed: {exc}"
            print(f"[llama-server] Launch failed: {exc}")
            return False

    ready = _wait_for_server(_LLAMASERVER_PORT, timeout=180, on_tick=on_progress)
    if not ready:
        _stop_llama_server()
        print("[llama-server] Timed out waiting for server.")
        return False

    print("[llama-server] Server ready.")
    return True


def start_nomic_server(model_path: str,
                       n_ctx: int = 512,
                       n_threads: int = 0,
                       kv_cache_type: str = "") -> bool:
    """
    Start a *second* llama-server process on _NOMIC_PORT (8083) loaded
    with the Nomic embedding model.  No-op if already running.
    Returns True when the server is ready.

    kv_cache_type: override KV-cache quantisation (default: read from
    memory profile; falls back to q4_0 to keep Nomic's footprint minimal).
    """
    if n_threads == 0:
        n_threads = _optimal_threads()
    # Use profile kv_cache_type if not explicitly provided
    if not kv_cache_type:
        try:
            from memory_management import get_profile
            kv_cache_type = get_profile().get("kv_cache_type", "q4_0")
        except Exception:
            kv_cache_type = "q4_0"
    global _NOMIC_PROC
    exe = _server_exe()
    if exe is None:
        print("[nomic-server] no llama-server binary available")
        return False
    with _NOMIC_LOCK:
        if _NOMIC_PROC is not None and _NOMIC_PROC.poll() is None:
            return True   # already running
        cmd = [
            str(exe),
            "--model",         model_path,
            "--ctx-size",      str(n_ctx),
            "--threads",       str(n_threads),
            "--threads-batch", str(n_threads),
            "--port",          str(_NOMIC_PORT),
            "--host",          "127.0.0.1",
            "--embedding",
            "--flash-attn",    "on",
            "--cache-type-k",  kv_cache_type,
            "--cache-type-v",  kv_cache_type,
        ]
        print(f"[nomic-server] Starting on port {_NOMIC_PORT} "
              f"(kv_cache={kv_cache_type})")
        print(f"  Model: {Path(model_path).name}")

        try:
            _NOMIC_PROC = _launch_binary(cmd)
        except Exception as exc:
            print(f"[nomic-server] Launch failed: {exc}")
            return False
    ready = _wait_for_server(_NOMIC_PORT, timeout=120)
    if not ready:
        _stop_nomic_server()
        print("[nomic-server] Timed out / crashed.")
        return False

    print("[nomic-server] Ready.")
    return True


def stop_nomic_server() -> None:
    global _NOMIC_PROC
    with _NOMIC_LOCK:
        if _NOMIC_PROC is not None:
            try:
                _NOMIC_PROC.terminate()
                _NOMIC_PROC.wait(timeout=5)
            except Exception:
                try:
                    _NOMIC_PROC.kill()
                except Exception:
                    pass
            _NOMIC_PROC = None
    # Notify memory_management that Nomic is stopped
    try:
        from memory_management import mark_nomic_stopped
        mark_nomic_stopped()
    except Exception:
        pass


def _nomic_server_available() -> Optional[int]:
    """Return the Nomic port if the server is available, else None."""
    if _NOMIC_PROC is not None and _NOMIC_PROC.poll() is None:
        return _NOMIC_PORT
    if _probe_port(_NOMIC_PORT):
        return _NOMIC_PORT
    return None


def _parse_embedding_response(data) -> "list[float] | None":
    """Parse embedding from llama-server response (handles multiple formats)."""
    if isinstance(data, list):
        emb = data[0].get("embedding") if data else None
    else:
        emb = data.get("embedding")
    # Unwrap double-nested [[floats]] -> [floats]
    if isinstance(emb, list) and emb and isinstance(emb[0], list):
        emb = emb[0]
    if isinstance(emb, list) and emb:
        return emb
    return None


def get_embedding(text: str) -> "list[float] | None":
    """
    Get a dense embedding vector for *text* via the DEDICATED Nomic
    llama-server running on the Nomic port.

    IMPORTANT: Do NOT fall back to the Qwen generation server.
    Qwen is a chat model — its /embedding endpoint returns garbage
    vectors that poison retrieval scores and cause hallucinated answers.

    Returns None if the Nomic server is not available.
    """
    port = _nomic_server_available()
    if port is None:
        return None
    import urllib.request
    import urllib.error
    payload = json.dumps({"content": text}).encode()
    url = f"http://127.0.0.1:{port}/embedding"
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            return _parse_embedding_response(data)
    except Exception as e:
        print(f"[embedding] failed: {e}")
        return None


def get_embeddings_batch(texts: list) -> "list[list[float] | None]":
    """Batch embedding — sends multiple texts in one HTTP round-trip.

    Falls back to serial get_embedding() if the batch endpoint is
    unsupported by the running llama-server version.

    Returns a list of embedding vectors (or None) in the same order.
    """
    if not texts:
        return []
    port = _nomic_server_available()
    if port is None:
        return [None] * len(texts)

    import urllib.request
    import urllib.error

    # Try batch request first (newer llama-server supports array content)
    try:
        payload = json.dumps({"content": texts}).encode()
        url = f"http://127.0.0.1:{port}/embedding"
        req = urllib.request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            if isinstance(data, list) and len(data) == len(texts):
                results = []
                for item in data:
                    emb = item.get("embedding") if isinstance(item, dict) else None
                    if isinstance(emb, list) and emb and isinstance(emb[0], list):
                        emb = emb[0]
                    results.append(emb if isinstance(emb, list) and emb else None)
                return results
            # Single-item fallback format
            emb = _parse_embedding_response(data)
            if emb and len(texts) == 1:
                return [emb]
    except Exception as e:
        print(f"[embedding-batch] batch failed, falling back to serial: {e}")

    # Fallback: serial embedding
    return [get_embedding(t) for t in texts]


def _stop_llama_server() -> None:
    global _LLAMASERVER_PROC
    with _LLAMASERVER_LOCK:
        if _LLAMASERVER_PROC is not None:
            try:
                _LLAMASERVER_PROC.terminate()
                _LLAMASERVER_PROC.wait(timeout=5)
            except Exception:
                try:
                    _LLAMASERVER_PROC.kill()
                except Exception:
                    pass
            _LLAMASERVER_PROC = None


def _gen_via_server(
    prompt: str, max_tokens: int, temperature: float,
    top_p: float, stream_cb,
) -> str:
    import urllib.request
    import urllib.error

    # ------------------------------------------------------------------ #
    #  Hard guard: ensure prompt_tokens + max_tokens never exceeds n_ctx.  #
    #  llama-server returns an error ("reduce the prompts") when they do.  #
    # ------------------------------------------------------------------ #
    try:
        from memory_management import get_profile
        _n_ctx = get_profile().get("n_ctx", 2048)
    except Exception:
        _n_ctx = 2048
    # Estimate prompt token count — 3.5 chars/token is accurate for English
    _prompt_tok_est = max(1, len(prompt) // 4)  # slightly conservative
    _safe_max = max(64, _n_ctx - _prompt_tok_est - 64)  # 64-token safety buffer
    if max_tokens > _safe_max:
        print(f"[llm] n_predict clamped {max_tokens} → {_safe_max} "
              f"(prompt≈{_prompt_tok_est} tok, n_ctx={_n_ctx})")
        max_tokens = _safe_max

    # llama-server native endpoint: /completion  (NOT /v1/completions)
    # cache_prompt:true instructs llama-server to cache the KV state for
    # the prompt prefix.  On follow-up queries that share the same system
    # prompt, the server skips re-computing the system prompt tokens —
    # typically saving 200-600 ms on the first token latency.
    payload = json.dumps({
        "prompt":        prompt,
        "n_predict":     max_tokens,
        "temperature":   temperature,
        "top_p":         top_p,
        "top_k":         20,
        "presence_penalty": 1.5,
        "cache_prompt":  True,         # KV-prefix caching for system prompt reuse
        "stream":        stream_cb is not None,
        "stop":          ["<|im_end|>", "<|im_start|>", "</s>"],
    }).encode()
    url = f"http://127.0.0.1:{_LLAMASERVER_PORT}/completion"
    print(f"[DEBUG] Sending request to: {url}")
    print(f"[DEBUG] Prompt: {prompt[:100]}")
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    # Dynamic timeout: 10s base + 3ms per output token
    # Streaming gets more headroom since tokens arrive incrementally.
    _req_timeout = 10 + max_tokens * 3
    for attempt in range(2):
        try:
            if stream_cb is not None:
                full = ""
                with urllib.request.urlopen(req, timeout=_req_timeout) as resp:
                    import api
                    for raw in resp:
                        if getattr(api, "_stop_flag", False):
                            print("[LLM] Stream stopped by user")
                            break
                        line = raw.decode("utf-8").strip()
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data == "[DONE]":
                            break
                        try:
                            token = json.loads(data).get("content", "")
                            full += token
                            stream_cb(token)
                        except Exception:
                            pass
                return full
            else:
                with urllib.request.urlopen(req, timeout=_req_timeout) as resp:
                    body = json.loads(resp.read())
                return body.get("content", "")
        except urllib.error.HTTPError as e:
            try:
                err_body = e.read().decode("utf-8", errors="replace")
            except Exception:
                err_body = "(no response body)"
            if attempt == 1:
                raise RuntimeError(f"llama-server HTTP {e.code}: {err_body[:300]}") from e
        except OSError as e:
            if attempt == 1:
                raise RuntimeError(f"llama-server unreachable: {e}") from e
        
        # Brief pause before retry
        import time
        time.sleep(0.3)
        
    return ""


# ------------------------------------------------------------------ #
#  Model directory                                                     #

def _ensure_writable_dir(path: Optional[str]) -> Optional[str]:
    if not path:
        return None
    try:
        os.makedirs(path, exist_ok=True)
        return path
    except Exception:
        return None


def _android_package_name_from_private() -> Optional[str]:
    # First preference: Android API package name.
    try:
        from android import mActivity  # type: ignore

        pkg = str(mActivity.getPackageName())
        if pkg and "." in pkg:
            return pkg
    except Exception:
        pass

    # Fallback: parse ANDROID_PRIVATE only.
    # Expected shapes include:
    # /data/user/0/<package>
    # /data/user/0/<package>/files
    # /data/data/<package>
    raw = _android_private_dir()
    parts = [p for p in raw.split("/") if p]
    if len(parts) >= 4 and parts[0] == "data" and parts[1] in {"user", "data"}:
        if parts[1] == "user" and len(parts) >= 5:
            pkg = parts[3]
        else:
            pkg = parts[2]
        if pkg and "." in pkg:
            return pkg
    return None


def _android_app_external_models_dir_direct() -> Optional[str]:
    pkg = _android_package_name_from_private()
    if not pkg:
        return None
    return f"/storage/emulated/0/Android/data/{pkg}/files/models"

def _models_dir() -> str:
    # Option 1: prefer app-specific external storage, then fallback to internal.
    if _is_android():
        direct_ext = _ensure_writable_dir(_android_app_external_models_dir_direct())
        if direct_ext:
            return direct_ext

        try:
            from android import mActivity  # type: ignore

            ext_dir = mActivity.getExternalFilesDir(None)
            if ext_dir is not None:
                ext_models = _ensure_writable_dir(os.path.join(str(ext_dir), "models"))
                if ext_models:
                    return ext_models
        except Exception:
            pass

    base = _android_private_dir() or os.path.expanduser("~")
    return os.path.join(base, "models")


def list_available_models() -> list[str]:
    """Return list of .gguf file paths found in the models directory."""
    pattern = os.path.join(_models_dir(), "*.gguf")
    return sorted(glob.glob(pattern))


# ------------------------------------------------------------------ #
#  LLM singleton                                                       #
# ------------------------------------------------------------------ #

class LlamaCppModel:
    """
    Unified LLM backend â€” tries each backend in priority order:
      1. llama-cpp-python  (in-process, best performance)
      2. Ollama            (if the server is running on localhost:11434)
      3. llama-server      (auto-extracted from llamacpp_bin.zip)
    """

    DEFAULT_CTX      = 2048    # fallback only; overridden by memory profile
    DEFAULT_MAX_TOK  = 512
    DEFAULT_TEMP     = 0.3
    DEFAULT_TOP_P    = 0.8
    DEFAULT_THREADS  = 0   # 0 = auto-detect

    def __init__(self) -> None:
        self._model      = None
        self._model_path: Optional[str] = None
        self._lock       = threading.Lock()
        self._backend    = "none"   # "llama_cpp"|"ollama"|"llama_server"|"none"
        self._ollama_name = ""
        self._last_thinking: str = ""  # raw <think> block from last generate call

    @property
    def last_thinking(self) -> str:
        """Return the raw thinking text extracted from the last generate() call."""
        return self._last_thinking

    # ---------------------------------------------------------------- #
    #  Loading                                                           #
    # ---------------------------------------------------------------- #

    def load(self, model_path: str, n_ctx: int = 0,
             n_threads: int = DEFAULT_THREADS, n_gpu_layers: int = 0,
             on_progress: Optional[Callable[[float, str], None]] = None) -> None:
        # Use adaptive memory profile for ctx and threads
        profile = get_memory_profile()
        if n_ctx == 0:
            n_ctx = profile["n_ctx"]
        if n_threads == 0:
            n_threads = profile["n_threads"]
        print(f"[LLM] Loading with ctx={n_ctx}, threads={n_threads} "
              f"(profile={profile['profile']})")
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
                detail = _ANDROID_BINARY_ERROR or "unknown error"
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
        if not _probe_port(_LLAMASERVER_PORT):
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
        max_tokens:  int   = 0,
        temperature: float = DEFAULT_TEMP,
        top_p:       float = DEFAULT_TOP_P,
        stream_cb:   Optional[Callable[[str], None]] = None,
    ) -> str:
        """
        Generate a response.  stream_cb (if given) is called with each
        new token fragment as it arrives.  Returns the full response text.
        Thinking-model reasoning blocks are automatically stripped.
        """
        if self._backend == "none":
            raise RuntimeError("No model loaded. Call load() first.")

        # Adaptive max_tokens from pressure-aware profile
        if max_tokens == 0:
            from memory_management import check_memory_pressure
            profile = check_memory_pressure()
            max_tokens = profile.get("max_tokens", self.DEFAULT_MAX_TOK)

        # Wrap stream_cb with the thinking-token filter
        filtered_cb = None
        think_filter: Optional[_ThinkingStreamFilter] = None
        if stream_cb is not None:
            think_filter = _ThinkingStreamFilter(stream_cb)
            filtered_cb  = think_filter

        if self._backend == "llama_cpp":
            raw = self._gen_llama_cpp(prompt, max_tokens, temperature, top_p, filtered_cb)
        elif self._backend == "ollama":
            raw = self._gen_ollama(prompt, max_tokens, temperature, top_p, filtered_cb)
        else:
            raw = _gen_via_server(prompt, max_tokens, temperature, top_p, filtered_cb)

        if think_filter is not None:
            think_filter.flush()

        # Strip thinking blocks (captures the thinking text), then sanitize
        cleaned, thinking = _strip_thinking(raw)
        self._last_thinking = thinking
        return _strip_leaked_prompt(cleaned)

    def _gen_llama_cpp(self, prompt, max_tokens, temp, top_p, stream_cb):
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

    def _gen_ollama(self, prompt, max_tokens, temp, top_p, stream_cb):
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

def _strip_thinking(text: str) -> tuple:
    """
    Remove internal reasoning blocks that thinking models emit before
    the real answer.  Handles several common tag styles.

    Returns (cleaned_text, thinking_text) so callers can display
    the model's reasoning in the UI if desired.
    """
    thinking_parts: list = []

    def _capture(m):
        thinking_parts.append(m.group(1).strip())
        return ''

    # Standard <think>...</think> (Qwen3, DeepSeek, GLM thinking variants)
    text = re.sub(r'<think>(.*?)</think>', _capture, text, flags=re.DOTALL)
    # Pipe-delimited variants  <|think|>...</|think|>
    text = re.sub(r'<\|think\|>(.*?)</\|think\|>', _capture, text, flags=re.DOTALL)
    # Some models wrap reasoning in triple-backtick reasoning blocks
    text = re.sub(r'```reasoning(.*?)```', _capture, text, flags=re.DOTALL)

    thinking_text = '\n\n'.join(p for p in thinking_parts if p)
    return text.strip(), thinking_text


class _ThinkingStreamFilter:
    """
    Wraps a stream_cb so that tokens inside <think>â€¦</think> blocks are
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
                # Not inside a think block â€” look for opening tag
                idx = self._buf.find("<think>")
                if idx == -1:
                    # No think tag anywhere â€” flush all buffered tokens
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
                # Inside a think block â€” look for closing tag
                idx = self._buf.find("</think>")
                if idx == -1:
                    # Haven't seen closing tag yet â€” keep buffering
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


# ------------------------------------------------------------------ #
#  Prompt builder                                                      #
# ------------------------------------------------------------------ #

def build_rag_prompt(context_chunks: list[str], question: str) -> str:
    """
    Build a RAG prompt using Qwen3.5 ChatML instruction format.
    (<|im_start|> / <|im_end|> tokens)

    Adaptive: caps total context size based on the active memory profile's
    n_ctx so the prompt never overflows the KV cache.

    Token budget math (conservative):
      - 3.5 chars ≈ 1 token for English text
      - 512 tokens reserved for the system message + ChatML overhead
      - max_tokens reserved for the answer
      - The rest is available for RAG context chunks
    """
    from memory_management import get_profile
    profile = get_profile()          # use base profile, not pressure-adjusted
    n_ctx      = profile.get("n_ctx", 2048)
    max_tokens = profile.get("max_tokens", 512)

    # Conservative token estimate: 3.5 chars/token, 512-token system overhead
    # Leave a 64-token safety buffer so we never hit the exact boundary.
    context_token_budget = max(64, n_ctx - max_tokens - 512 - 64)
    budget_chars = context_token_budget * 3  # 3 chars/token for chunk text

    # Fit as many chunks as the budget allows
    capped = []
    used = 0
    for c in context_chunks:
        avail = budget_chars - used
        if avail <= 100:
            break
        piece = c[:avail]
        capped.append(piece)
        used += len(piece)

    ctx_text = "\n\n---\n\n".join(capped)
    system_msg = (
        "You are an expert document analyst. Answer the user's question directly and concisely using only the provided context.\n"
        "If you need to analyze the question, determine complexity, or plan your response, wrap your reasoning inside <think> and </think> tags before writing your final answer.\n"
        "If the question is simple, provide a short 1-2 sentence answer. If the question is complex, provide a detailed multi-paragraph answer.\n"
        "Write your final answer in plain text paragraphs. Do not use bullet points or numbered lists.\n"
        "If the context does not contain the answer, say: \"I don't know based on the provided documents.\"\n"
        "Do not repeat the question. Just give the answer."
    )
    return (
        f"<|im_start|>system\n{system_msg}<|im_end|>\n"
        f"<|im_start|>user\n"
        f"Context:\n{ctx_text}\n\nQuestion: {question}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )


def _strip_leaked_prompt(text: str) -> str:
    """
    Post-processing safety net: remove any text that looks like the model
    echoed back system-prompt structure (numbered analysis steps, constraint
    lists, etc.) instead of giving a direct answer.
    """
    import re
    # Strip leading numbered sections like "1. Analyze the Request:" blocks
    # Pattern: one or more "N. Some Header:" sections followed by bullet lists
    text = re.sub(
        r'^(\d+\.\s+.+?:\s*\n(?:\s*[\*\-•].*\n)*)+',
        '',
        text,
        flags=re.MULTILINE,
    )
    # Strip lines that are clearly leaked constraint/instruction echoes
    leaked_patterns = [
        r'^\s*Constraint\s+\d+:.*$',
        r'^\s*Task:.*$',
        r'^\s*Analyze the (Request|Context|Question):.*$',
        r'^\s*Document Source:.*$',
    ]
    for pat in leaked_patterns:
        text = re.sub(pat, '', text, flags=re.MULTILINE | re.IGNORECASE)
    # Collapse multiple blank lines
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


def build_direct_prompt(
    question: str,
    history: list[tuple[str, str]] | None = None,
    summary: str = "",
) -> str:
    """
    Build a plain conversational prompt using Qwen 2.5's ChatML format.
    summary : compressed plain-text of older turns (no LLM call, first sentences).
    history : last 3 verbatim (user, assistant) pairs.
    """
    system_msg = (
        "You are a knowledgeable and direct AI assistant. Answer the user's question clearly and concisely.\n"
        "If you need to analyze the question, determine complexity, or plan your response, wrap your reasoning inside <think> and </think> tags before writing your final answer.\n"
        "If the question is simple, provide a short 1-2 sentence answer. If the question is complex, provide a detailed multi-paragraph answer.\n"
        "Write your final answer in plain text paragraphs. Do not use bullet points or numbered lists.\n"
        "Do not repeat the question. Just give the answer."
    )
    # Append compressed older context to system message so it takes fewer
    # tokens than full ChatML turns but still informs the model.
    if summary.strip():
        system_msg += (
            "\n\nEarlier in this conversation (summary):\n"
            + summary.strip()
        )
    parts: list[str] = [f"<|im_start|>system\n{system_msg}<|im_end|>\n"]

    # Last 3 verbatim turns
    for user_msg, asst_msg in (history or [])[-3:]:
        parts.append(
            f"<|im_start|>user\n{user_msg}<|im_end|>\n"
            f"<|im_start|>assistant\n{asst_msg}<|im_end|>\n"
        )

    parts.append(
        f"<|im_start|>user\n{question}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )
    return "".join(parts)


# Module-level singleton
llm = LlamaCppModel()

