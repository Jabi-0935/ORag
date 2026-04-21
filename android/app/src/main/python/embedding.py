"""
embedding.py — Nomic embedding server management and embedding API.

Extracted from llm.py (Phase 3 Step 17).

Responsibilities:
  - Start/stop the Nomic embedding llama-server process
  - GET /embedding endpoint for dense vectors
  - Query embedding LRU cache (moved from retriever.py)

Does NOT handle Qwen generation — that stays in llm.py / llm_client.py.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Optional

from config import NOMIC_SERVER_PORT


# ------------------------------------------------------------------ #
#  Port + process state                                                #
# ------------------------------------------------------------------ #

_NOMIC_PORT = NOMIC_SERVER_PORT
_NOMIC_PROC = None
_NOMIC_LOCK = threading.Lock()


def nomic_port() -> int:
    return _NOMIC_PORT


# ------------------------------------------------------------------ #
#  Health probe                                                        #
# ------------------------------------------------------------------ #

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


def probe_nomic_port() -> bool:
    """Public health probe for the Nomic server."""
    return _probe_port(_NOMIC_PORT)


# ------------------------------------------------------------------ #
#  Server binary helpers (delegated to llm_runtime)                    #
# ------------------------------------------------------------------ #

def _server_exe():
    """Get the llama-server binary path. Imports from llm_runtime at call time."""
    from llm_runtime import server_exe
    return server_exe()


def _optimal_threads() -> int:
    """Pick a sensible thread count for the device."""
    try:
        count = os.cpu_count() or 4
        return max(2, min(8, count // 2))
    except Exception:
        return 4


def _android_private_dir() -> str:
    """Get the private dir for log files."""
    from llm_runtime import android_private_dir
    return android_private_dir()


# ------------------------------------------------------------------ #
#  Nomic server lifecycle                                              #
# ------------------------------------------------------------------ #

def start_nomic_server(model_path: str,
                       n_ctx: int = 128,
                       n_threads: int = 0) -> bool:
    """
    Start a *second* llama-server process on _NOMIC_PORT loaded
    with the Nomic embedding model.  No-op if already running.
    Returns True when the server is ready.
    """
    if n_threads == 0:
        n_threads = _optimal_threads()
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
            "--cache-type-k",  "q8_0",
            "--cache-type-v",  "q8_0",
        ]
        print(f"[nomic-server] Starting on port {_NOMIC_PORT}")
        print(f"  Model: {Path(model_path).name}")
        cf = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        log_file = None
        priv = _android_private_dir()
        if priv:
            try:
                log_file = open(os.path.join(priv, "nomic_server.log"), "wb")
            except Exception:
                pass
        try:
            _NOMIC_PROC = subprocess.Popen(
                cmd,
                stdout=log_file if log_file else subprocess.DEVNULL,
                stderr=log_file if log_file else subprocess.DEVNULL,
                creationflags=cf,
            )
        except Exception as exc:
            if log_file:
                log_file.close()
            print(f"[nomic-server] Launch failed: {exc}")
            return False
    ready = _wait_for_nomic(timeout=120)
    if log_file:
        try:
            log_file.close()
        except Exception:
            pass
    if ready:
        print("[nomic-server] Ready.")
    else:
        print("[nomic-server] Timed out / crashed.")
    return ready


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


def _wait_for_nomic(timeout: int = 120) -> bool:
    """Wait for Nomic server to become healthy."""
    import urllib.request
    url = f"http://127.0.0.1:{_NOMIC_PORT}/health"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _NOMIC_PROC is not None and _NOMIC_PROC.poll() is not None:
            print(f"[nomic-server] process exited early (code={_NOMIC_PROC.returncode})")
            return False
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


# ------------------------------------------------------------------ #
#  Embedding API                                                       #
# ------------------------------------------------------------------ #

def get_embedding(text: str) -> "list[float] | None":
    """
    Get a dense embedding vector for *text* via the DEDICATED Nomic
    llama-server running on the Nomic port.

    IMPORTANT: Do NOT fall back to the Qwen generation server.
    Qwen is a chat model — its /embedding endpoint returns garbage
    vectors that poison retrieval scores and cause hallucinated answers.

    Returns None if the Nomic server is not available.
    """
    # ONLY use the dedicated Nomic embedding server
    if _NOMIC_PROC is not None and _NOMIC_PROC.poll() is None:
        port = _NOMIC_PORT
    elif _probe_port(_NOMIC_PORT):
        # Service-owned process on the Nomic port
        port = _NOMIC_PORT
    else:
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
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            # Newer llama-server: [{"index": 0, "embedding": [[float, ...]]}]
            # Older llama-server: {"embedding": [float, ...]}
            if isinstance(data, list):
                emb = data[0].get("embedding") if data else None
            else:
                emb = data.get("embedding")
            # Unwrap double-nested [[floats]] → [floats]
            if isinstance(emb, list) and emb and isinstance(emb[0], list):
                emb = emb[0]
            if isinstance(emb, list) and emb:
                return emb
            return None
    except Exception as e:
        print(f"[embedding] failed: {e}")
        return None


# ------------------------------------------------------------------ #
#  Query embedding cache (moved from retriever.py — Step 15)          #
# ------------------------------------------------------------------ #

MAX_QUERY_CACHE    = 64
_query_cache:      OrderedDict    = OrderedDict()
_query_cache_lock: threading.Lock = threading.Lock()


def get_cached_query_embedding(text: str) -> Optional[list]:
    with _query_cache_lock:
        if text in _query_cache:
            _query_cache.move_to_end(text)   # mark as recently used
            return _query_cache[text]
    return None


def set_cached_query_embedding(text: str, emb: list) -> None:
    with _query_cache_lock:
        if text in _query_cache:
            _query_cache.move_to_end(text)
        else:
            if len(_query_cache) >= MAX_QUERY_CACHE:
                _query_cache.popitem(last=False)   # evict oldest
            _query_cache[text] = emb
