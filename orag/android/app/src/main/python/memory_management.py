"""
memory_management.py — Adaptive resource management for O-RAG.

Central module that:
  1. Detects device RAM and selects an optimal profile
  2. Provides adaptive parameters for LLM context, threads, batch size
  3. Manages lazy Nomic server loading (deferred until first RAG query)
  4. Reports live memory/battery stats for the Settings UI
  5. Dynamically downgrades profile under memory pressure

Profiles:
  ULTRA_LOW (<=3GB):  ctx=512,  max_tok=256, 2 threads, Nomic ctx=128
  LOW       (<=4GB):  ctx=512,  max_tok=384, 2-4 threads, Nomic ctx=256
  MEDIUM    (<=6GB):  ctx=1024, max_tok=512, auto threads, Nomic ctx=384
  HIGH      (>6GB):   ctx=2048, max_tok=512, auto threads, Nomic ctx=512
"""
from __future__ import annotations

import json
import os
import threading
import time
from typing import Optional, Callable


# ------------------------------------------------------------------ #
#  RAM Detection                                                       #
# ------------------------------------------------------------------ #

def get_total_ram_gb() -> float:
    """Detect total device RAM in GB via /proc/meminfo or os.sysconf."""
    # Method 1: /proc/meminfo (Android + Linux)
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    return kb / (1024 * 1024)
    except Exception:
        pass
    # Method 2: os.sysconf (Linux/Mac)
    try:
        pages = os.sysconf('SC_PHYS_PAGES')
        page_size = os.sysconf('SC_PAGE_SIZE')
        if pages > 0 and page_size > 0:
            return (pages * page_size) / (1024 ** 3)
    except Exception:
        pass
    return 0.0


def get_available_ram_mb() -> float:
    """Detect available (free) RAM in MB via /proc/meminfo."""
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    kb = int(line.split()[1])
                    return kb / 1024.0
    except Exception:
        pass
    return 0.0


def get_app_memory_mb() -> float:
    """Get this process's RSS (Resident Set Size) in MB."""
    try:
        with open(f"/proc/{os.getpid()}/status", "r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    return kb / 1024.0
    except Exception:
        pass
    return 0.0


def get_app_vss_mb() -> float:
    """Get this process's VSS (Virtual memory Size) in MB."""
    try:
        with open(f"/proc/{os.getpid()}/status", "r") as f:
            for line in f:
                if line.startswith("VmSize:"):
                    kb = int(line.split()[1])
                    return kb / 1024.0
    except Exception:
        pass
    return 0.0


# ------------------------------------------------------------------ #
#  Battery Info                                                        #
# ------------------------------------------------------------------ #

def get_battery_info() -> dict:
    """
    Read battery info from Android sysfs.
    Returns {level: int, is_charging: bool, temperature: float, status: str}.
    """
    info = {"level": -1, "is_charging": False, "temperature": 0.0, "status": "unknown"}

    # Battery level (0-100)
    try:
        with open("/sys/class/power_supply/battery/capacity", "r") as f:
            info["level"] = int(f.read().strip())
    except Exception:
        pass

    # Charging status
    try:
        with open("/sys/class/power_supply/battery/status", "r") as f:
            status = f.read().strip()
            info["status"] = status
            info["is_charging"] = status.lower() in ("charging", "full")
    except Exception:
        pass

    # Temperature (in tenths of degree C)
    try:
        with open("/sys/class/power_supply/battery/temp", "r") as f:
            raw = int(f.read().strip())
            info["temperature"] = raw / 10.0
    except Exception:
        pass

    return info


# ------------------------------------------------------------------ #
#  Optimal Thread Count                                                #
# ------------------------------------------------------------------ #

def optimal_threads() -> int:
    """Half of logical CPUs, clamped to [2, 8]. Targets big.LITTLE perf cores."""
    try:
        count = os.cpu_count() or 4
        return max(2, min(8, count // 2))
    except Exception:
        return 4


# ------------------------------------------------------------------ #
#  Memory Profile                                                      #
# ------------------------------------------------------------------ #

def _compute_profile() -> dict:
    """
    Compute the adaptive profile based on detected RAM.

    All profiles load Nomic — but with adapted context sizes and
    embedding chunk limits to keep memory within safe bounds.
    """
    total = get_total_ram_gb()
    print(f"[memory] Total RAM: {total:.1f} GB")

    if total <= 0:
        print("[memory] RAM detection failed, using LOW profile")
        return {
            "profile": "LOW",
            "total_ram_gb": 0.0,
            "n_ctx": 512,
            "max_tokens": 384,
            "n_threads": 2,
            "nomic_ctx": 128,
            "nomic_lazy": True,
            "embed_chunk_limit": 20,
            "kv_cache_type": "q4_0",
            "batch_size": 64,
            "use_mmap": True,
        }

    if total <= 3.0:
        return {
            "profile": "ULTRA_LOW",
            "total_ram_gb": total,
            "n_ctx": 512,
            "max_tokens": 256,
            "n_threads": 2,
            "nomic_ctx": 128,
            "nomic_lazy": True,        # Lazy: start Nomic only on first RAG query
            "embed_chunk_limit": 15,   # Embed only top 15 chunks
            "kv_cache_type": "q4_0",
            "batch_size": 64,
            "use_mmap": True,          # Let OS page-in model on demand
        }

    if total <= 4.5:
        return {
            "profile": "LOW",
            "total_ram_gb": total,
            "n_ctx": 512,
            "max_tokens": 384,
            "n_threads": max(2, min(4, optimal_threads())),
            "nomic_ctx": 256,
            "nomic_lazy": True,
            "embed_chunk_limit": 25,
            "kv_cache_type": "q4_0",
            "batch_size": 64,
            "use_mmap": True,
        }

    if total <= 6.5:
        return {
            "profile": "MEDIUM",
            "total_ram_gb": total,
            "n_ctx": 1024,
            "max_tokens": 512,
            "n_threads": optimal_threads(),
            "nomic_ctx": 384,
            "nomic_lazy": False,       # Eager: load Nomic at startup
            "embed_chunk_limit": 50,
            "kv_cache_type": "q8_0",
            "batch_size": 512,
            "use_mmap": False,         # Full load for consistent latency
        }

    return {
        "profile": "HIGH",
        "total_ram_gb": total,
        "n_ctx": 2048,
        "max_tokens": 512,
        "n_threads": optimal_threads(),
        "nomic_ctx": 512,
        "nomic_lazy": False,
        "embed_chunk_limit": 100,
        "kv_cache_type": "q8_0",
        "batch_size": 512,
        "use_mmap": False,
    }


# Cached singleton
_PROFILE: Optional[dict] = None
_PROFILE_LOCK = threading.Lock()


def get_profile() -> dict:
    """Return the cached memory profile (computed once at first call)."""
    global _PROFILE
    if _PROFILE is None:
        with _PROFILE_LOCK:
            if _PROFILE is None:
                _PROFILE = _compute_profile()
                print(f"[memory] Profile: {_PROFILE['profile']} "
                      f"(ctx={_PROFILE['n_ctx']}, threads={_PROFILE['n_threads']}, "
                      f"nomic_ctx={_PROFILE['nomic_ctx']}, "
                      f"lazy={'yes' if _PROFILE['nomic_lazy'] else 'no'})")
    return _PROFILE


# ------------------------------------------------------------------ #
#  Dynamic pressure-aware profile adjustment                           #
# ------------------------------------------------------------------ #

_LAST_PRESSURE_CHECK = 0.0
_PRESSURE_CHECK_INTERVAL = 5.0   # seconds between checks


def check_memory_pressure() -> dict:
    """Check real-time memory pressure and return a (possibly downgraded) profile.

    Called before generation to dynamically adjust parameters if the
    device is running low on available RAM.  The base profile is never
    mutated — this returns a copy with overrides.

    Thresholds:
      < 200 MB free → EMERGENCY: ctx=256, max_tok=128
      < 400 MB free → WARNING:   cap ctx=512, max_tok=256
      >= 400 MB     → use base profile unchanged
    """
    global _LAST_PRESSURE_CHECK

    profile = get_profile()
    now = time.monotonic()

    # Throttle: don't read /proc/meminfo on every single call
    if now - _LAST_PRESSURE_CHECK < _PRESSURE_CHECK_INTERVAL:
        return profile

    _LAST_PRESSURE_CHECK = now
    available = get_available_ram_mb()

    if available <= 0:
        return profile  # Can't read — assume OK

    if available < 200:
        # EMERGENCY: device is about to OOM — force GC
        import gc
        gc.collect()
        adjusted = dict(profile)
        adjusted["n_ctx"] = 256
        adjusted["max_tokens"] = 128
        adjusted["embed_chunk_limit"] = 10
        adjusted["batch_size"] = 32
        adjusted["_pressure"] = "EMERGENCY"
        print(f"[memory] EMERGENCY pressure: {available:.0f} MB free — "
              f"downgraded to ctx=256, max_tok=128")
        return adjusted

    if available < 400:
        # WARNING: reduce parameters + opportunistic GC
        import gc
        gc.collect()
        adjusted = dict(profile)
        adjusted["n_ctx"] = min(profile["n_ctx"], 512)
        adjusted["max_tokens"] = min(profile["max_tokens"], 256)
        adjusted["embed_chunk_limit"] = min(profile["embed_chunk_limit"], 20)
        adjusted["_pressure"] = "WARNING"
        print(f"[memory] WARNING pressure: {available:.0f} MB free — "
              f"capped ctx={adjusted['n_ctx']}, max_tok={adjusted['max_tokens']}")
        return adjusted

    return profile


# ------------------------------------------------------------------ #
#  Lazy Nomic Server Manager                                           #
# ------------------------------------------------------------------ #

_nomic_started = False
_nomic_start_lock = threading.Lock()


def ensure_nomic_server(nomic_model_path: str) -> bool:
    """
    Start the Nomic embedding server if not already running.
    On low-RAM (lazy) profiles this is called on-demand at first RAG query.
    On high-RAM profiles this is called eagerly at init.

    Returns True if the server is ready.
    """
    global _nomic_started
    if _nomic_started:
        return True

    with _nomic_start_lock:
        if _nomic_started:
            return True

        if not os.path.isfile(nomic_model_path):
            print(f"[memory] Nomic model not found: {nomic_model_path}")
            return False

        profile = get_profile()
        print(f"[memory] Starting Nomic server "
              f"(ctx={profile['nomic_ctx']}, profile={profile['profile']})")

        try:
            from llm import start_nomic_server
            ok = start_nomic_server(
                nomic_model_path,
                n_ctx=profile["nomic_ctx"],
                n_threads=max(2, profile["n_threads"]),
            )
            if ok:
                _nomic_started = True
                print("[memory] Nomic server ready.")
            return ok
        except Exception as e:
            print(f"[memory] Nomic server failed: {e}")
            return False


def mark_nomic_stopped() -> None:
    """Mark the Nomic server as stopped (called after intentional shutdown)."""
    global _nomic_started
    _nomic_started = False


def is_nomic_running() -> bool:
    """Check if Nomic embedding server is currently alive."""
    try:
        from llm import probe_port, nomic_port
        return probe_port(nomic_port())
    except Exception:
        return _nomic_started


def should_stop_nomic_after_embedding() -> bool:
    """On low-RAM profiles, recommend stopping Nomic after batch embedding
    to reclaim ~140 MB of RAM for the LLM generation phase."""
    profile = get_profile()
    return profile["profile"] in ("ULTRA_LOW", "LOW")


# ------------------------------------------------------------------ #
#  Resource Usage Report (for Settings UI)                             #
# ------------------------------------------------------------------ #

def get_resource_report() -> dict:
    """
    Return a comprehensive resource report for display in the Settings UI.

    Returns JSON-serializable dict with:
      - profile info (name, total RAM, ctx, threads)
      - live memory usage (app RSS, available, percentage)
      - battery info (level, charging, temperature)
      - nomic status
    """
    profile = get_profile()
    total_ram = profile["total_ram_gb"]
    app_rss = get_app_memory_mb()
    available = get_available_ram_mb()
    battery = get_battery_info()

    # Calculate memory pressure percentage
    if total_ram > 0:
        used_pct = ((total_ram * 1024) - available) / (total_ram * 1024) * 100
    else:
        used_pct = 0.0

    return {
        # Profile
        "profile_name": profile["profile"],
        "total_ram_gb": round(total_ram, 1),
        "context_window": profile["n_ctx"],
        "max_tokens": profile["max_tokens"],
        "threads": profile["n_threads"],
        "kv_cache_type": profile["kv_cache_type"],
        "batch_size": profile["batch_size"],
        "use_mmap": profile["use_mmap"],
        "nomic_ctx": profile["nomic_ctx"],
        "nomic_lazy": profile["nomic_lazy"],
        "embed_chunk_limit": profile["embed_chunk_limit"],

        # Live memory
        "app_memory_mb": round(app_rss, 1),
        "available_ram_mb": round(available, 1),
        "memory_pressure_pct": round(used_pct, 1),

        # Battery
        "battery_level": battery["level"],
        "battery_charging": battery["is_charging"],
        "battery_temp_c": battery["temperature"],
        "battery_status": battery["status"],

        # Nomic
        "nomic_running": is_nomic_running(),

        # CPU
        "cpu_cores": os.cpu_count() or 0,
    }


def get_resource_report_json() -> str:
    """Return resource report as a JSON string (for method channel)."""
    return json.dumps(get_resource_report())
