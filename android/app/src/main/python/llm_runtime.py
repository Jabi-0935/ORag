"""
llm_runtime.py — Process lifecycle for the Qwen llama-server.

Extracted from llm.py (Phase 3 Step 17).

Responsibilities:
  - Android native binary detection and path injection
  - Starting / stopping the Qwen llama-server process
  - Desktop binary extraction from ZIP
  - Model directory management
  - Health-check waiting during startup
"""
from __future__ import annotations

import glob
import os
import subprocess
import threading
import time
import zipfile
from pathlib import Path
from typing import Callable, Optional

from config import QWEN_SERVER_PORT


# App root: rag/llm_runtime.py → ../..
_APP_ROOT = Path(__file__).resolve().parent.parent.parent

# ------------------------------------------------------------------ #
#  Android detection                                                   #
# ------------------------------------------------------------------ #

# Paths injected from Kotlin (MainActivity) before Python init runs.
_ANDROID_NATIVE_LIB_DIR: Optional[str] = None
_ANDROID_FILES_DIR: Optional[str] = None


def set_android_paths(native_lib_dir: str, files_dir: str) -> None:
    """Called from Kotlin to inject Android-specific paths before init."""
    global _ANDROID_NATIVE_LIB_DIR, _ANDROID_FILES_DIR
    _ANDROID_NATIVE_LIB_DIR = native_lib_dir
    _ANDROID_FILES_DIR = files_dir
    print(f"[llm_runtime] Android paths injected: native_lib={native_lib_dir}, files={files_dir}")


def is_android() -> bool:
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


def android_private_dir() -> str:
    """Return the best available private directory for the app on Android."""
    if _ANDROID_FILES_DIR:
        return _ANDROID_FILES_DIR
    priv = os.environ.get("ANDROID_PRIVATE", "")
    if priv:
        return priv
    return ""


# ------------------------------------------------------------------ #
#  Thread count helper                                                 #
# ------------------------------------------------------------------ #

def _optimal_threads() -> int:
    """Pick a sensible thread count for the device.
    Use half the logical CPUs (targets performance cores on big.LITTLE),
    clamped to [2, 8].  Falls back to 4 if cpu_count is unavailable.
    """
    try:
        count = os.cpu_count() or 4
        return max(2, min(8, count // 2))
    except Exception:
        return 4


# ------------------------------------------------------------------ #
#  Server binary location                                              #
# ------------------------------------------------------------------ #

_ANDROID_EXE_PATH: Optional[str] = None
_ANDROID_BINARY_ERROR: str = ""


def _bin_dir() -> Path:
    return _APP_ROOT / "llamacpp_bin"


def _ensure_android_binary() -> Optional[str]:
    """
    Android-specific: locate the bundled ARM64 llama-server binary.

    The binary is bundled as lib/arm64-v8a/llama-server.so (or legacy
    libllama_server.so) in the APK.
    Android's package installer extracts all .so files from lib/<abi>/ to
    the app's nativeLibraryDir at install time with correct SELinux labels
    that allow execve() — the ONLY reliable way to run native code on
    modern Android (code_cache / data dirs block exec via SELinux).

    No runtime extraction needed — just find the pre-installed path.
    """
    global _ANDROID_EXE_PATH, _ANDROID_BINARY_ERROR
    if _ANDROID_EXE_PATH is not None:
        return _ANDROID_EXE_PATH

    if not is_android():
        return None

    priv = android_private_dir()
    dbg: list[str] = [f"ANDROID_PRIVATE={priv}"]
    print(f"[llama-server] is_android()=True, priv={priv}")

    # Primary: use path injected from Kotlin (most reliable)
    native_lib_dir: Optional[str] = _ANDROID_NATIVE_LIB_DIR
    if native_lib_dir:
        dbg.append(f"nativeLibraryDir (from Kotlin)={native_lib_dir}")
    else:
        # Fallback: try mActivity (may not work in Flutter threading context)
        try:
            from android import mActivity  # type: ignore
            native_lib_dir = str(mActivity.getApplicationInfo().nativeLibraryDir)
            dbg.append(f"nativeLibraryDir (from mActivity)={native_lib_dir}")
        except Exception as e:
            dbg.append(f"getApplicationInfo failed: {e}")

    if native_lib_dir:
        candidates = ["llama-server.so", "libllama_server.so"]
        for name in candidates:
            exe = os.path.join(native_lib_dir, name)
            dbg.append(f"checking {exe}")
            if os.path.isfile(exe):
                sz = os.path.getsize(exe)
                dbg.append(f"FOUND: {name} ({sz // 1024} KB)")
                print(f"[llama-server] native lib: {exe} ({sz // 1024} KB)")
                try:
                    Path(priv, "llama_debug.txt").write_text("\n".join(dbg))
                except Exception:
                    pass
                _ANDROID_EXE_PATH = exe
                return exe

        # List what IS in nativeLibraryDir so we can diagnose wrong names
        try:
            present = os.listdir(native_lib_dir)
            dbg.append(f"NOT FOUND. nativeLibraryDir contains: {present}")
            _ANDROID_BINARY_ERROR = (
                f"No llama server binary found in {native_lib_dir}.\n"
                f"Expected one of: {candidates}\n"
                f"Directory contains: {present}"
            )
        except Exception as le:
            dbg.append(f"listdir failed: {le}")
            _ANDROID_BINARY_ERROR = (
                f"No llama server binary found in {native_lib_dir} "
                f"(listdir failed: {le})"
            )
    else:
        _ANDROID_BINARY_ERROR = "Could not determine nativeLibraryDir"

    try:
        Path(priv, "llama_debug.txt").write_text("\n".join(dbg))
    except Exception:
        pass
    print(f"[llama-server] binary not found: {_ANDROID_BINARY_ERROR}")
    return None


def server_exe():
    """Return path to the llama-server binary (Android or desktop)."""
    # 1. Android: use bundled ARM64 binary from nativeLibraryDir
    if is_android():
        return _ensure_android_binary()

    # 2. Desktop: look in llamacpp_bin/ dir
    for p in [_bin_dir() / "llama-server.exe", _bin_dir() / "llama-server"]:
        if p.exists():
            return p
    return None


def extract_zip_if_needed() -> bool:
    if is_android():
        return server_exe() is not None
    if server_exe() is not None:
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
    return server_exe() is not None


# ------------------------------------------------------------------ #
#  Qwen llama-server process lifecycle                                 #
# ------------------------------------------------------------------ #

_LLAMASERVER_PORT = QWEN_SERVER_PORT
_LLAMASERVER_PROC = None
_LLAMASERVER_LOCK = threading.Lock()


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


def _wait_for_server(port: int, timeout: int = 120,
                     on_tick: Optional[Callable[[float, str], None]] = None) -> bool:
    import urllib.request
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.time() + timeout
    started  = time.time()
    last_tick = 0.0
    while time.time() < deadline:
        proc = _LLAMASERVER_PROC
        if proc is not None and proc.poll() is not None:
            print(f"[llama-server port={port}] process exited early (code={proc.returncode})")
            return False
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
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
            on_tick(pct, f"Loading model into memory\u2026 {int(elapsed)}s")
        time.sleep(0.5)
    return False


def start_llama_server(model_path: str, n_ctx: int, n_threads: int,
                       on_progress: Optional[Callable[[float, str], None]] = None) -> bool:
    global _LLAMASERVER_PROC, _ANDROID_BINARY_ERROR
    exe = server_exe()
    if exe is None:
        return False
    with _LLAMASERVER_LOCK:
        if _LLAMASERVER_PROC is not None:
            return True
        # Fast-path: the Android foreground service may have already started
        # llama-server.  If the port is responding we don't need a new process.
        if _probe_port(_LLAMASERVER_PORT):
            print("[llama-server] Already running (owned by service) — skipping launch.")
            if on_progress:
                on_progress(1.0, "AI engine ready!")
            return True
        cmd = [
            str(exe),
            "--model", model_path,
            "--ctx-size", str(n_ctx),
            "--threads", str(n_threads),
            "--threads-batch", str(n_threads),
            "--port", str(_LLAMASERVER_PORT),
            "--host", "127.0.0.1",

            # performance flags (important)
            "--flash-attn", "on",
            "--cont-batching",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
        ]
        print(f"[llama-server] Starting: {cmd[0]}")
        print(f"  Model: {Path(model_path).name}")
        print("  Loading model into memory, please wait ...")
        if on_progress:
            on_progress(0.02, f"Starting AI engine\u2026 ({Path(model_path).name})")
        cf = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        log_file = None
        priv = android_private_dir()
        if priv:
            try:
                log_path = os.path.join(priv, "llama_server.log")
                log_file = open(log_path, "wb")
            except Exception:
                pass
        try:
            _LLAMASERVER_PROC = subprocess.Popen(
                cmd,
                stdout=log_file if log_file else subprocess.DEVNULL,
                stderr=log_file if log_file else subprocess.DEVNULL,
                creationflags=cf,
            )
        except Exception as exc:
            if log_file:
                log_file.close()
            _ANDROID_BINARY_ERROR = f"Popen failed: {type(exc).__name__}: {exc}"
            print(f"[llama-server] Launch failed: {exc}")
            return False
    ready = _wait_for_server(_LLAMASERVER_PORT, timeout=180, on_tick=on_progress)
    if not ready:
        stop_llama_server()
        priv = android_private_dir()
        if priv:
            try:
                log_path = os.path.join(priv, "llama_server.log")
                if os.path.isfile(log_path):
                    with open(log_path, "rb") as lf:
                        lf.seek(max(0, os.path.getsize(log_path) - 1000))
                        tail = lf.read().decode("utf-8", errors="replace")
                    _ANDROID_BINARY_ERROR = f"Server log tail: {tail}"
                    print(f"[llama-server] server log: {tail}")
            except Exception:
                pass
        print("[llama-server] Timed out / crashed waiting for server.")
        return False
    if log_file:
        try:
            log_file.close()
        except Exception:
            pass
    print("[llama-server] Server ready.")
    return True


def stop_llama_server() -> None:
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


def get_android_binary_error() -> str:
    """Return the last binary extraction error message."""
    return _ANDROID_BINARY_ERROR


# ------------------------------------------------------------------ #
#  Model directory                                                     #
# ------------------------------------------------------------------ #

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
    raw = android_private_dir()
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


def models_dir() -> str:
    """Return the directory where GGUF models are stored."""
    if is_android():
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

    base = android_private_dir() or os.path.expanduser("~")
    return os.path.join(base, "models")


def list_available_models() -> list[str]:
    """Return list of .gguf file paths found in the models directory."""
    pattern = os.path.join(models_dir(), "*.gguf")
    return sorted(glob.glob(pattern))
