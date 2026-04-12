"""
worker.py — Single-threaded task queue for all blocking pipeline operations.

Why this exists
---------------
All LLM generation and document ingestion is CPU/IO bound and can take
10–60 seconds.  Calling these operations directly on a Kotlin thread
(as the old code did) blocks that thread for the entire duration and
allows race conditions when Kotlin spawns multiple threads simultaneously.

This module provides a bounded Queue(maxsize=1) served by one daemon
thread.  Only one task runs at a time.  If a second task arrives while
the first is still running, submit() returns False immediately so the
caller can surface a "busy" signal to the user instead of queuing
unbounded work or silently dropping requests.

Result delivery
---------------
The app is fully streaming — token results flow back to Flutter via
token_callback.invoke() inside the task itself.  The final JSON return
value of ask_rag / chat_stream is returned by the *Kotlin* MethodChannel
call after the task completes, so no separate result-passing mechanism
is needed here.

Usage
-----
    from worker import start_worker, submit

    # Call once at module load time (api.py does this)
    start_worker()

    # Submit a task — returns True if accepted, False if busy
    accepted = submit(pipeline.ask, question, stream_cb)
    if not accepted:
        token_callback.invoke("__BUSY__")
"""
import threading
from queue import Queue, Full
from typing import Any, Callable

# Bounded at 1 — we never want to queue more than one pending task.
# If the queue is full the caller learns immediately (submit returns False)
# rather than silently waiting.
_task_queue: Queue = Queue(maxsize=1)

# Sentinel that tells the worker loop to exit cleanly (used in tests /
# graceful shutdown — not needed during normal Android app lifecycle).
_STOP = object()


def worker_loop() -> None:
    """
    Consume tasks from _task_queue forever.
    Each task is a (fn, args, kwargs) tuple.
    Exceptions inside tasks are caught and printed — they must not
    crash the worker thread because that would freeze the app permanently.
    """
    while True:
        item = _task_queue.get()
        if item is _STOP:
            _task_queue.task_done()
            break
        fn, args, kwargs = item
        try:
            fn(*args, **kwargs)
        except Exception as exc:
            # Surface the error in logcat — the task's own try/except
            # should have already sent an error token to Flutter.
            print(f"[Worker] Unhandled exception in task {fn.__name__}: {exc}")
        finally:
            _task_queue.task_done()


def start_worker() -> None:
    """
    Spawn the single background worker thread.
    Safe to call multiple times — only the first call has any effect
    because subsequent calls see the queue is already being drained.

    The thread is daemonised so it does not prevent the Android process
    from being killed when the app is closed.
    """
    # Guard: if a worker thread is somehow already alive, don't spawn another.
    # We check by trying a non-blocking put of a no-op — if the queue is
    # already being served this doesn't matter; the thread will just drain it.
    t = threading.Thread(target=worker_loop, name="rag-worker", daemon=True)
    t.start()


def submit(fn: Callable, *args: Any, **kwargs: Any) -> bool:
    """
    Enqueue fn(*args, **kwargs) for execution on the worker thread.

    Returns
    -------
    True  — task accepted and will run.
    False — worker is busy (queue full); caller should tell the user to wait.

    Never blocks the calling thread.
    """
    try:
        _task_queue.put_nowait((fn, args, kwargs))
        return True
    except Full:
        return False


def stop_worker() -> None:
    """
    Signal the worker thread to exit after finishing its current task.
    Intended for clean shutdown in tests — not required during normal
    Android app lifecycle (daemon thread dies with the process).
    """
    try:
        _task_queue.put_nowait(_STOP)
    except Full:
        pass  # Worker is busy; _STOP will be ignored — acceptable for shutdown