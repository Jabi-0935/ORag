"""
llm_client.py — HTTP client for the Qwen llama-server /completion endpoint.

Extracted from llm.py (Phase 3 Step 17).

Responsibilities:
  - Send prompts to the running Qwen llama-server
  - Handle streaming (SSE) and non-streaming responses
  - Port constants for the Qwen generation server
"""
from __future__ import annotations

import json
import threading
from typing import Callable, Optional

from config import QWEN_SERVER_PORT


# ------------------------------------------------------------------ #
#  Port constant                                                       #
# ------------------------------------------------------------------ #

_LLAMASERVER_PORT = QWEN_SERVER_PORT


def qwen_port() -> int:
    return _LLAMASERVER_PORT


# ------------------------------------------------------------------ #
#  Health probe                                                        #
# ------------------------------------------------------------------ #

def probe_qwen_port() -> bool:
    """Return True if the Qwen server is responding on its port."""
    import urllib.request
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{_LLAMASERVER_PORT}/health", timeout=1
        ) as r:
            return r.status == 200
    except Exception:
        return False


# ------------------------------------------------------------------ #
#  Generation via llama-server /completion endpoint                    #
# ------------------------------------------------------------------ #

def gen_via_server(
    prompt: str, max_tokens: int, temperature: float,
    top_p: float, stream_cb: Optional[Callable[[str], None]] = None,
    cancel_event: Optional[threading.Event] = None,
) -> str:
    """
    Send a completion request to the Qwen llama-server.

    If stream_cb is provided, tokens are delivered incrementally via
    Server-Sent Events (SSE).  Returns the full response text.
    """
    import urllib.request
    import urllib.error
    # llama-server native endpoint: /completion  (NOT /v1/completions)
    payload = json.dumps({
        "prompt":      prompt,
        "n_predict":   max_tokens,
        "temperature": temperature,
        "top_p":       top_p,
        "stream":      stream_cb is not None,
        "stop":        ["<|im_end|>", "<|im_start|>", "</s>"],
    }).encode()
    url = f"http://127.0.0.1:{_LLAMASERVER_PORT}/completion"
    print(f"[DEBUG] Sending request to: {url}")
    print(f"[DEBUG] Prompt: {prompt[:100]}")
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    for attempt in range(2):
        try:
            if stream_cb is not None:
                full = ""
                with urllib.request.urlopen(req, timeout=60) as resp:

                    for raw in resp:
                        # Check cancellation before processing each token
                        if cancel_event is not None and cancel_event.is_set():
                            print("[llm_client] Generation cancelled by user")
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
                with urllib.request.urlopen(req, timeout=60) as resp:
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

        # Give it a tiny bit of breathing room before second try
        import time
        time.sleep(1)

    return ""
