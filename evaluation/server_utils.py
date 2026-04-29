"""
server_utils.py — Self-contained llama-server boot helper for the evaluation notebook.

Zero dependency on the app's llm.py / config.py / memory_management.py.
Works on Windows (creationflags) and Linux/macOS (fallback path).
"""
from __future__ import annotations

import os
import subprocess
import time
import urllib.request
from pathlib import Path


# ---------------------------------------------------------------------------
# Health probe
# ---------------------------------------------------------------------------

def probe(port: int, timeout: float = 1.0) -> bool:
    """Return True if a llama-server is responding on *port*."""
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health", timeout=timeout
        ) as r:
            return r.status == 200
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _n_threads() -> int:
    count = os.cpu_count() or 4
    return max(2, min(8, count // 2))


def _wait_ready(port: int, timeout: int = 120) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if probe(port):
            return True
        time.sleep(1.0)
    return False


def _launch(
    binary: str,
    model_path: str,
    port: int,
    n_ctx: int,
    extra_flags: list[str] | None = None,
) -> tuple[bool, subprocess.Popen | None]:
    """
    Start llama-server as a background subprocess.

    Returns (success, proc).  proc is None when the binary is missing.
    """
    if not Path(binary).is_file():
        print(f"  WARN: llama-server binary not found:\n        {binary}")
        print("  Set LLAMA_SERVER_BIN in cell 0 to the correct path.")
        return False, None

    n_t = _n_threads()
    cmd = [
        binary,
        "--model",         model_path,
        "--ctx-size",      str(n_ctx),
        "--threads",       str(n_t),
        "--threads-batch", str(n_t),
        "--port",          str(port),
        "--host",          "127.0.0.1",
        "--no-mmap",
        "--flash-attn", "on",
        "--cont-batching",
    ] + (extra_flags or [])

    kwargs: dict = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    proc = subprocess.Popen(cmd, **kwargs)
    ready = _wait_ready(port, timeout=120)
    if not ready:
        proc.terminate()
        return False, None
    return True, proc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def launch_servers(
    no_boot: bool,
    qwen_port: int,
    nomic_port: int,
    qwen_model: str,
    nomic_model: str,
    binary: str,
) -> dict[str, subprocess.Popen | None]:
    """
    Start Qwen and Nomic llama-server instances as needed.

    Parameters
    ----------
    no_boot     : If True, skip starting (assumes servers already running).
    qwen_port   : Port for the Qwen generation server.
    nomic_port  : Port for the Nomic embedding server.
    qwen_model  : Absolute path to the Qwen .gguf model file.
    nomic_model : Absolute path to the Nomic .gguf model file.
    binary      : Absolute path to the llama-server executable.

    Returns
    -------
    dict with keys "qwen_proc" and "nomic_proc" (subprocess.Popen or None).
    """
    procs: dict = {"qwen_proc": None, "nomic_proc": None}

    if no_boot:
        print("NO_BOOT=True — assuming servers are already running.")
    else:
        # ── Qwen generation server ────────────────────────────────────────
        if probe(qwen_port):
            print(f"  Qwen  already running on :{qwen_port}")
        elif not Path(qwen_model).is_file():
            print(f"  WARN: Qwen model not found:\n        {qwen_model}")
        else:
            print(f"  Starting Qwen  on :{qwen_port} …  (may take 1-2 min)")
            ok, proc = _launch(binary, qwen_model, qwen_port, n_ctx=2048)
            procs["qwen_proc"] = proc
            print("  Qwen  server:", "READY ✓" if ok else "FAILED ✗")

        # ── Nomic embedding server ────────────────────────────────────────
        if probe(nomic_port):
            print(f"  Nomic already running on :{nomic_port}")
        elif not Path(nomic_model).is_file():
            print(f"  Nomic model not found — dense retrieval disabled.")
        else:
            print(f"  Starting Nomic on :{nomic_port} …")
            ok, proc = _launch(
                binary, nomic_model, nomic_port, n_ctx=512,
                extra_flags=["--embedding"],
            )
            procs["nomic_proc"] = proc
            print("  Nomic server:", "READY ✓" if ok else "FAILED ✗ (BM25 fallback)")

    # ── Final health report ───────────────────────────────────────────────
    print(f"\n  Qwen  health : {'OK' if probe(qwen_port)  else 'DOWN'}")
    print(f"  Nomic health : {'OK' if probe(nomic_port) else 'DOWN'}")
    return procs


def stop_servers(procs: dict) -> None:
    """Terminate server processes started by launch_servers()."""
    for key, proc in procs.items():
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=5)
                print(f"  Stopped {key}")
            except Exception as e:
                print(f"  Could not stop {key}: {e}")
