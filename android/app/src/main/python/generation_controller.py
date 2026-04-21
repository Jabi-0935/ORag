"""
generation_controller.py — Thread-safe cancellation token for LLM generation.

Created in Phase 3 Step 18.

Usage:
    controller = GenerationController()
    # Pass to generate(), which checks is_cancelled() in the streaming loop
    llm.generate(prompt, stream_cb=cb, cancel_event=controller.event)
    # From another thread:
    controller.cancel()   # breaks the streaming loop
"""
from __future__ import annotations

import threading


class GenerationController:
    """One controller per generation task. Check is_cancelled() in the
    streaming loop to exit early. Call cancel() from any thread."""

    def __init__(self) -> None:
        self._event = threading.Event()

    def cancel(self) -> None:
        """Signal cancellation. Thread-safe."""
        self._event.set()

    def is_cancelled(self) -> bool:
        return self._event.is_set()

    @property
    def event(self) -> threading.Event:
        """The raw Event, for passing to lower-level APIs."""
        return self._event

    def reset(self) -> None:
        self._event.clear()
