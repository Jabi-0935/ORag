"""
evaluate.py — RAGAS evaluation module for the O-RAG pipeline.

Sits alongside pipeline.py and can be:
  1. Imported and called programmatically:
       from evaluate import run_evaluation
       results = run_evaluation("path/to/dataset.json")

  2. Run directly from the command line:
       python evaluate.py --dataset path/to/dataset.json

Architecture
------------
  - Uses the local Qwen server (port 8080) as the RAGAS judge LLM via the
    OpenAI-compatible /v1/chat/completions endpoint.
  - Uses the local Nomic server (port 8081) as RAGAS embeddings via the
    OpenAI-compatible /v1/embeddings endpoint.
  - Falls back to sentence-transformers (embedding-only metrics) when the
    Qwen server is unavailable or the judge model is too small.
  - No external API keys are required.

Dataset schema (JSON array)
---------------------------
[
  {
    "question":     "What is RAG?",           // required
    "ground_truth": "RAG stands for ...",     // required
    "contexts":     ["RAG is a technique…"],  // optional — skip live retrieval
    "doc_paths":    ["docs/paper.pdf"]        // optional — ingest before querying
  },
  ...
]
"""
from __future__ import annotations

import csv
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Optional

from config import QWEN_SERVER_PORT, NOMIC_SERVER_PORT

# Repo root: orag/android/app/src/main/python -> up 6 levels -> repo root
_REPO_ROOT = Path(__file__).resolve().parents[6]


# Force UTF-8 stdout so special chars don't crash on Windows cp1252
import io as _io
if hasattr(sys.stdout, 'buffer'):
    sys.stdout = _io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')


def _find_llama_bin() -> str:
    """
    Auto-discover the llama-server binary.
    Checks known locations in priority order (with and without .exe).
    Returns the first existing path found, or an empty string if none found.
    """
    candidates = [
        # Build from source (llama.cpp desktop build)
        Path("D:/Work/8th_Sem/llama.cpp/build-android/bin/llama-server"),
        Path("D:/Work/8th_Sem/llama.cpp/build/bin/llama-server"),
        Path("D:/Work/8th_Sem/llama.cpp/build/bin/llama-server.exe"),
        # In-repo bundled binary
        _REPO_ROOT / "orag" / "android" / "app" / "llamacpp_bin" / "llama-server.exe",
        _REPO_ROOT / "orag" / "android" / "app" / "llamacpp_bin" / "llama-server",
        _REPO_ROOT / "orag" / "llamacpp_bin" / "llama-server.exe",
        _REPO_ROOT / "orag" / "llamacpp_bin" / "llama-server",
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    return ""  # will be caught by _launch_server's WARN


# ──────────────────────────────────────────────────────────────────────────────
#  Health helpers (no dependency on llm.py)
# ──────────────────────────────────────────────────────────────────────────────

def _probe(port: int, timeout: float = 1.0) -> bool:
    """Return True if a llama-server is responding on *port*."""
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health", timeout=timeout
        ) as r:
            return r.status == 200
    except Exception:
        return False


def qwen_available() -> bool:
    """True if the Qwen generation server is up."""
    return _probe(QWEN_SERVER_PORT)


def nomic_available() -> bool:
    """True if the Nomic embedding server is up."""
    return _probe(NOMIC_SERVER_PORT)


# ──────────────────────────────────────────────────────────────────────────────
#  Server boot  (self-contained — no dependency on llm.py)
# ──────────────────────────────────────────────────────────────────────────────

def _wait_ready(port: int, timeout: int = 120) -> bool:
    """Poll /health until the server is up or timeout expires."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _probe(port):
            return True
        time.sleep(1.0)
    return False


def _n_threads() -> int:
    count = os.cpu_count() or 4
    return max(2, min(8, count // 2))


def _launch_server(
    binary: str,
    model_path: str,
    port: int,
    n_ctx: int,
    extra_flags: list[str] | None = None,
) -> tuple[bool, Optional[subprocess.Popen]]:
    """
    Start a llama-server binary as a background process.
    Returns (success, proc). proc is None when the binary is missing.
    """
    if not Path(binary).is_file():
        print(f"  WARN: llama-server binary not found: {binary}")
        return False, None
    if not Path(model_path).is_file():
        print(f"  WARN: model file not found: {model_path}")
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
        "--flash-attn",    "on",
        "--cont-batching",
    ] + (extra_flags or [])

    kwargs: dict = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    proc = subprocess.Popen(cmd, **kwargs)
    ok = _wait_ready(port, timeout=120)
    if not ok:
        proc.terminate()
        return False, None
    return True, proc


def boot_servers(
    llama_bin: str,
    qwen_model: str,
    nomic_model: str,
) -> dict[str, Optional[subprocess.Popen]]:
    """
    Start Qwen (generation) and Nomic (embedding) llama-server processes.

    Parameters
    ----------
    llama_bin   : Absolute path to the llama-server(.exe) binary.
    qwen_model  : Absolute path to the Qwen .gguf model file.
    nomic_model : Absolute path to the Nomic .gguf model file.

    Returns
    -------
    dict with "qwen_proc" and "nomic_proc" keys (Popen or None).
    Call stop_servers() on this dict when done.
    """
    procs: dict = {"qwen_proc": None, "nomic_proc": None}

    # Qwen generation server
    if _probe(QWEN_SERVER_PORT):
        print(f"  [boot] Qwen  already running on :{QWEN_SERVER_PORT}")
    else:
        print(f"  [boot] Starting Qwen  on :{QWEN_SERVER_PORT} …  (may take 1-2 min)")
        ok, proc = _launch_server(llama_bin, qwen_model, QWEN_SERVER_PORT, n_ctx=2048)
        procs["qwen_proc"] = proc
        print(f"  [boot] Qwen  server: {'READY OK' if ok else 'FAILED'}")

    # Nomic embedding server
    if _probe(NOMIC_SERVER_PORT):
        print(f"  [boot] Nomic already running on :{NOMIC_SERVER_PORT}")
    elif not Path(nomic_model).is_file():
        print(f"  [boot] Nomic model not found — dense retrieval disabled.")
    else:
        print(f"  [boot] Starting Nomic on :{NOMIC_SERVER_PORT} …")
        ok, proc = _launch_server(
            llama_bin, nomic_model, NOMIC_SERVER_PORT, n_ctx=512,
            extra_flags=["--embedding"],
        )
        procs["nomic_proc"] = proc
        print(f"  [boot] Nomic server: {'READY OK' if ok else 'FAILED (BM25 only)'}")

    print(f"\n  Qwen  health: {'OK' if _probe(QWEN_SERVER_PORT)  else 'DOWN'}")
    print(f"  Nomic health: {'OK' if _probe(NOMIC_SERVER_PORT) else 'DOWN'}")
    return procs


def stop_servers(procs: dict) -> None:
    """Terminate server processes returned by boot_servers()."""
    for key, proc in procs.items():
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=5)
                print(f"  [stop] {key} terminated.")
            except Exception as e:
                print(f"  [stop] Could not stop {key}: {e}")


# ──────────────────────────────────────────────────────────────────────────────
#  Dataset loading
# ──────────────────────────────────────────────────────────────────────────────

def load_dataset(path: str) -> list[dict]:
    """
    Load and validate the evaluation dataset from a JSON file.

    Required keys per item: "question", "ground_truth"
    Optional keys: "contexts", "doc_paths"

    The path is resolved in this order:
      1. As-is (absolute or relative to cwd)
      2. Relative to the repo root  (useful when running from the python/ dir)
    """
    p = Path(path)
    if not p.is_file():
        # Try resolving from the repo root
        p = _REPO_ROOT / path
    if not p.is_file():
        raise FileNotFoundError(
            f"Dataset not found: {path!r}\n"
            f"  Tried cwd-relative  : {Path(path).resolve()}\n"
            f"  Tried repo-relative : {_REPO_ROOT / path}\n"
            f"  Tip: run from the repo root and pass a path like\n"
            f"       evaluation/sample_dataset.json"
        )

    with open(p, encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, list) or not data:
        raise ValueError("Dataset must be a non-empty JSON array.")

    required = {"question", "ground_truth"}
    for i, item in enumerate(data):
        missing = required - set(item.keys())
        if missing:
            raise ValueError(f"Item #{i} is missing required keys: {missing}")

    print(f"[eval] Loaded {len(data)} QA pairs from '{p.name}'")
    return data


# ──────────────────────────────────────────────────────────────────────────────
#  Document ingestion
# ──────────────────────────────────────────────────────────────────────────────

def _ingest_if_needed(doc_paths: list[str]) -> None:
    """Ingest documents into the live pipeline, skipping already-ingested ones."""
    if not doc_paths:
        return

    import pipeline as pipe_mod
    from storage import list_documents

    already = {d["name"] for d in list_documents()}
    for doc_path in doc_paths:
        name = Path(doc_path).name
        if name in already:
            print(f"  [ingest] skip  : '{name}' (already indexed)")
            continue
        if not Path(doc_path).is_file():
            print(f"  [ingest] WARN  : not found — {doc_path}")
            continue
        ok, msg = pipe_mod.ingest_document(doc_path)
        print(f"  [ingest] {'OK   ' if ok else 'FAIL '}: {msg}")


# ──────────────────────────────────────────────────────────────────────────────
#  RAG query
# ──────────────────────────────────────────────────────────────────────────────

def _run_query(question: str, top_k: int = 4) -> tuple[str, list[str]]:
    """
    Run a full RAG query through the pipeline.

    Returns (answer, contexts) where contexts is a list of retrieved chunk texts.
    """
    import pipeline as pipe_mod

    ok, answer, _ = pipe_mod.ask(question)
    if not ok:
        answer = f"[ERROR] {answer}"

    # Re-fetch raw chunk texts for RAGAS (ask() only returns short previews)
    results = pipe_mod.retriever.query_with_expansion(question, top_k=top_k)
    if not results:
        results = pipe_mod.retriever.query(question, top_k=top_k)

    contexts = [text for text, _score, _doc_id in results]
    return answer, contexts


# ──────────────────────────────────────────────────────────────────────────────
#  RAGAS judge setup
# ──────────────────────────────────────────────────────────────────────────────

def _build_ragas_judges(
    qwen_model_name: str = "qwen",
    nomic_model_name: str = "nomic-embed-text-v1.5",
):
    """
    Build RAGAS-compatible LLM and Embeddings wrappers pointing at the
    local llama-server instances.  No OpenAI key required.

    llama-server exposes an OpenAI-compatible REST API:
      /v1/chat/completions  (Qwen, port 8080)
      /v1/embeddings        (Nomic, port 8081)

    Raises ImportError if ragas / langchain_openai are not installed.
    """
    from langchain_openai import ChatOpenAI, OpenAIEmbeddings
    from ragas.llms import LangchainLLMWrapper
    from ragas.embeddings import LangchainEmbeddingsWrapper

    qwen_base  = f"http://127.0.0.1:{QWEN_SERVER_PORT}/v1"
    nomic_base = f"http://127.0.0.1:{NOMIC_SERVER_PORT}/v1"

    judge_llm = LangchainLLMWrapper(
        ChatOpenAI(
            model=qwen_model_name,
            openai_api_key="local",         # placeholder — not sent to OpenAI
            openai_api_base=qwen_base,
            temperature=0,
            max_tokens=512,
            request_timeout=60,
        )
    )

    judge_embeddings = LangchainEmbeddingsWrapper(
        OpenAIEmbeddings(
            model=nomic_model_name,
            openai_api_key="local",
            openai_api_base=nomic_base,
            check_embedding_ctx_length=False,
        )
    )

    return judge_llm, judge_embeddings


# ──────────────────────────────────────────────────────────────────────────────
#  RAGAS evaluation
# ──────────────────────────────────────────────────────────────────────────────

def _evaluate_with_ragas(
    records: list[dict],
    judge_llm,
    judge_embeddings,
) -> "pandas.DataFrame":
    """
    Run RAGAS on collected records. Returns a per-row scores DataFrame.

    Metrics:
      faithfulness        — LLM-judge: answer grounded in context
      answer_relevancy    — Embedding: answer addresses the question
      context_recall      — LLM-judge: context covers the ground-truth
      context_precision   — LLM-judge: context chunks are relevant
      answer_similarity   — Embedding: semantic closeness to ground-truth
    """
    from datasets import Dataset
    from ragas import evaluate
    from ragas.metrics import (
        faithfulness,
        answer_relevancy,
        context_recall,
        context_precision,
        answer_similarity,
    )

    ds = Dataset.from_dict({
        "question":     [r["question"]     for r in records],
        "answer":       [r["answer"]       for r in records],
        "contexts":     [r["contexts"]     for r in records],
        "ground_truth": [r["ground_truth"] for r in records],
    })

    result = evaluate(
        dataset=ds,
        metrics=[
            faithfulness,
            answer_relevancy,
            context_recall,
            context_precision,
            answer_similarity,
        ],
        llm=judge_llm,
        embeddings=judge_embeddings,
        raise_exceptions=False,  # don't crash on small-model JSON parse failures
    )

    return result.to_pandas()


# ── Embedding helpers used by the fallback evaluator ─────────────────────────

def _http_embed(text: str) -> Optional[list[float]]:
    """
    Get an embedding vector via the Nomic llama-server HTTP endpoint.
    Returns None if the server is down.
    Zero external dependencies — pure urllib.
    """
    if not _probe(NOMIC_SERVER_PORT):
        return None
    payload = json.dumps({"content": text}).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{NOMIC_SERVER_PORT}/embedding",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        # Normalise multiple llama-server response shapes
        if isinstance(data, list):
            emb = data[0].get("embedding") if data else None
        else:
            emb = data.get("embedding")
        if isinstance(emb, list) and emb and isinstance(emb[0], list):
            emb = emb[0]   # unwrap double-nested [[floats]]
        return emb if isinstance(emb, list) and emb else None
    except Exception:
        return None


def _vec_cosine(a: list[float], b: list[float]) -> float:
    """Cosine similarity — pure Python, no numpy."""
    dot = sum(x * y for x, y in zip(a, b))
    na  = sum(x * x for x in a) ** 0.5
    nb  = sum(x * x for x in b) ** 0.5
    return dot / (na * nb) if na * nb > 0 else 0.0


def _bow_cosine(a: str, b: str) -> float:
    """
    Bag-of-words cosine similarity — pure Python, zero imports.
    Used as ultimate fallback when the Nomic server is also down.
    """
    import re
    from collections import Counter

    def _tok(t: str) -> Counter:
        return Counter(re.findall(r"\w+", t.lower()))

    va, vb = _tok(a), _tok(b)
    keys = set(va) | set(vb)
    dot  = sum(va[k] * vb[k] for k in keys)
    na   = sum(v ** 2 for v in va.values()) ** 0.5
    nb   = sum(v ** 2 for v in vb.values()) ** 0.5
    return dot / (na * nb) if na * nb > 0 else 0.0


def _evaluate_embedding_only(records: list[dict]) -> "pandas.DataFrame":
    """
    Fallback evaluator: compute proxy metrics without RAGAS or sentence-transformers.

    Strategy (in priority order):
      1. Use the Nomic llama-server HTTP endpoint for embeddings (if running).
      2. Fall back to pure-Python Bag-of-Words cosine similarity (zero deps).

    Proxy metrics:
      answer_relevancy   — cosine(question, answer)
      answer_similarity  — cosine(answer, ground_truth)
      context_relevance  — mean cosine(question, context_i)
    """
    try:
        import pandas as pd
    except ImportError:
        raise ImportError("pandas is required. Install with: pip install pandas")

    use_nomic = _probe(NOMIC_SERVER_PORT)
    if use_nomic:
        print("[eval] Fallback: using Nomic server embeddings (HTTP).")
    else:
        print("[eval] Fallback: Nomic server down — using Bag-of-Words cosine.")

    def _sim(a: str, b: str) -> float:
        if use_nomic:
            ea = _http_embed("search_query: " + a[:280])
            eb = _http_embed("search_document: " + b[:480])
            if ea and eb:
                return _vec_cosine(ea, eb)
        return _bow_cosine(a, b)

    rows = []
    for rec in records:
        q  = rec["question"]
        a  = rec["answer"]
        gt = rec["ground_truth"]
        ctxs = [c for c in rec["contexts"] if c.strip()]

        ans_rel = _sim(q, a)
        ans_sim = _sim(a, gt)
        ctx_rel = sum(_sim(q, c) for c in ctxs) / len(ctxs) if ctxs else 0.0

        rows.append({
            "question":          q,
            "ground_truth":      gt,
            "answer":            a,
            "num_contexts":      len(ctxs),
            "answer_relevancy":  round(ans_rel, 4),
            "answer_similarity": round(ans_sim, 4),
            "context_relevance": round(ctx_rel, 4),
        })

    return pd.DataFrame(rows)


# ──────────────────────────────────────────────────────────────────────────────
#  Reporting
# ──────────────────────────────────────────────────────────────────────────────

_RAGAS_METRICS = [
    "faithfulness",
    "answer_relevancy",
    "context_recall",
    "context_precision",
    "answer_similarity",
]

_FALLBACK_METRICS = [
    "answer_relevancy",
    "answer_similarity",
    "context_relevance",
]


def _print_summary(scores_df, metrics: list[str], mode: str) -> None:
    import pandas as pd

    avail = [m for m in metrics if m in scores_df.columns]
    print("\n" + "=" * 64)
    print(f"  O-RAG RAGAS Evaluation  [{mode}]")
    print("=" * 64)
    print(f"  {'Metric':<26} {'Mean':>8}  {'Min':>8}  {'Max':>8}")
    print("  " + "-" * 52)
    for m in avail:
        col = scores_df[m].dropna()
        if col.empty:
            print(f"  {m:<26} {'N/A':>8}")
        else:
            print(f"  {m:<26} {col.mean():>8.4f}  {col.min():>8.4f}  {col.max():>8.4f}")
    print("=" * 64 + "\n")


def _save_csv(
    records: list[dict],
    scores_df,
    metrics: list[str],
    output_dir: str,
) -> Path:
    import pandas as pd

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = out / f"{ts}_ragas.csv"

    avail = [m for m in metrics if m in scores_df.columns]
    fieldnames = ["question", "ground_truth", "answer", "num_contexts", *avail]

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for i, rec in enumerate(records):
            row: dict = {
                "question":     rec["question"],
                "ground_truth": rec["ground_truth"],
                "answer":       rec["answer"],
                "num_contexts": len([c for c in rec["contexts"] if c.strip()]),
            }
            if i < len(scores_df):
                for m in avail:
                    val = scores_df[m].iloc[i]
                    row[m] = round(float(val), 4) if pd.notna(val) else ""
            writer.writerow(row)

    print(f"[eval] Report saved → {csv_path}")
    return csv_path


# ──────────────────────────────────────────────────────────────────────────────
#  Public entry point
# ──────────────────────────────────────────────────────────────────────────────

def run_evaluation(
    dataset_path: str,
    output_dir: str = "evaluation/results",
    top_k: int = 4,
    force_fallback: bool = False,
    qwen_model_name: str = "qwen",
    nomic_model_name: str = "nomic-embed-text-v1.5",
    # ── Optional server boot ───────────────────────────────────────────
    boot: bool = False,
    llama_bin: Optional[str] = None,
    qwen_model_path: Optional[str] = None,
    nomic_model_path: Optional[str] = None,
) -> dict:
    """
    Run the full RAGAS evaluation against the O-RAG pipeline.

    Parameters
    ----------
    dataset_path     : Path to the JSON evaluation dataset.
    output_dir       : Directory to write the CSV report.
    top_k            : Number of chunks to retrieve per query.
    force_fallback   : If True, skip RAGAS and use embedding-only metrics.
    qwen_model_name  : Model name label sent to the Qwen llama-server.
    nomic_model_name : Model name label sent to the Nomic llama-server.

    Returns
    -------
    dict with keys:
        "records"    — list of collected QA records
        "scores_df"  — pandas DataFrame of per-row metric scores
        "csv_path"   — Path to the saved CSV report
        "mode"       — "ragas" | "embedding_fallback"
    """
    # ── 0. Boot servers if requested ─────────────────────────────────────────
    _server_procs: dict = {"qwen_proc": None, "nomic_proc": None}
    if boot:
        if not llama_bin or not qwen_model_path:
            raise ValueError(
                "--boot requires --llama-bin and --qwen-model to be set."
            )
        _server_procs = boot_servers(
            llama_bin   = llama_bin,
            qwen_model  = qwen_model_path,
            nomic_model = nomic_model_path or "",
        )
        # Abort early if the Qwen generation server failed to start;
        # without it we cannot generate answers and evaluation is meaningless.
        if not qwen_available():
            stop_servers(_server_procs)
            raise RuntimeError(
                "[boot] Qwen server failed to start.\n"
                f"  Binary checked : {llama_bin}\n"
                f"  Model checked  : {qwen_model_path}\n"
                "  Make sure llama-server.exe exists at --llama-bin and\n"
                "  the model path is correct, then re-run."
            )

    # ── 1. Load dataset ───────────────────────────────────────────────────────
    eval_data = load_dataset(dataset_path)

    # ── 2. Initialize storage + retriever ─────────────────────────────────────
    from storage import init_db
    import pipeline as pipe_mod

    print("[eval] Initializing pipeline...")
    init_db()
    pipe_mod.retriever.reload()
    print(f"[eval] Docs in DB: {len(pipe_mod.list_documents())}")

    # ── 3. Ingest any referenced documents ───────────────────────────────────
    for item in eval_data:
        _ingest_if_needed(item.get("doc_paths", []))

    # ── 4. Collect answers + contexts ─────────────────────────────────────────
    records: list[dict] = []
    n = len(eval_data)

    for i, item in enumerate(eval_data):
        question     = item["question"]
        ground_truth = item["ground_truth"]
        pre_contexts = item.get("contexts")  # use if provided (offline mode)

        print(f"\n[eval] [{i+1}/{n}] {question[:80]}")

        if pre_contexts is not None:
            # Offline mode: use pre-supplied contexts, generate answer directly
            contexts = pre_contexts
            _ok, answer = pipe_mod.chat_direct(question=question)
            if not _ok:
                answer = f"[ERROR] {answer}"
            print(f"  mode   : offline (pre-supplied contexts)")
        else:
            # Live mode: full hybrid retrieval → generation
            answer, contexts = _run_query(question, top_k=top_k)
            print(f"  mode   : live retrieval")

        print(f"  answer : {answer[:100]}")
        print(f"  ctx    : {len(contexts)} chunk(s)")

        records.append({
            "question":     question,
            "ground_truth": ground_truth,
            "answer":       answer,
            "contexts":     contexts if contexts else [""],
        })

    # ── 5. Choose evaluation mode ─────────────────────────────────────────────
    use_ragas = (not force_fallback) and qwen_available() and nomic_available()

    try:
        if use_ragas:
            _check_ragas_installed()
    except ImportError as e:
        print(f"[eval] RAGAS not installed ({e}) — falling back to embedding-only metrics.")
        use_ragas = False

    if use_ragas:
        print("\n[eval] Running RAGAS evaluation (local Qwen + Nomic)…")
        judge_llm, judge_embeddings = _build_ragas_judges(
            qwen_model_name, nomic_model_name
        )
        scores_df = _evaluate_with_ragas(records, judge_llm, judge_embeddings)
        metrics = _RAGAS_METRICS
        mode = "ragas"
    else:
        reason = "force_fallback=True" if force_fallback else "servers not running"
        print(f"\n[eval] Using embedding-only fallback ({reason})…")
        scores_df = _evaluate_embedding_only(records)
        metrics = _FALLBACK_METRICS
        mode = "embedding_fallback"

    # ── 6. Report ─────────────────────────────────────────────────────────────
    _print_summary(scores_df, metrics, mode)
    csv_path = _save_csv(records, scores_df, metrics, output_dir)

    result = {
        "records":   records,
        "scores_df": scores_df,
        "csv_path":  csv_path,
        "mode":      mode,
    }

    # ── 7. Cleanup booted servers ─────────────────────────────────────────────
    if boot:
        stop_servers(_server_procs)

    return result


def _check_ragas_installed() -> None:
    """Raise ImportError if ragas or its dependencies are missing."""
    import ragas          # noqa: F401
    from datasets import Dataset  # noqa: F401
    from langchain_openai import ChatOpenAI  # noqa: F401


# ──────────────────────────────────────────────────────────────────────────────
#  CLI
# ──────────────────────────────────────────────────────────────────────────────

def _cli() -> None:
    import argparse

    p = argparse.ArgumentParser(
        description="Run RAGAS evaluation for the O-RAG pipeline",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    # ── Core ──────────────────────────────────────────────────────────────────
    p.add_argument("--dataset",   required=True,
                   help="Path to the JSON evaluation dataset.")
    p.add_argument("--out",       default="evaluation/results",
                   help="Output directory for the CSV report.")
    p.add_argument("--top-k",     type=int, default=4,
                   help="Number of chunks to retrieve per query.")
    p.add_argument("--fallback",  action="store_true",
                   help="Force embedding-only fallback metrics (no server needed).")
    # ── Server boot ───────────────────────────────────────────────────────────
    p.add_argument("--boot",      action="store_true",
                   help="Start Qwen + Nomic servers before evaluating.")
    p.add_argument("--llama-bin",
                   default=_find_llama_bin(),
                   help="Path to the llama-server binary.")
    p.add_argument("--qwen-model",  default=None,
                   help="Path to the Qwen .gguf model (required with --boot).")
    p.add_argument("--nomic-model", default=None,
                   help="Path to the Nomic .gguf model (optional with --boot).")
    # ── Judge labels ──────────────────────────────────────────────────────────
    p.add_argument("--qwen-name",  default="qwen",
                   help="Model name label for the Qwen server.")
    p.add_argument("--nomic-name", default="nomic-embed-text-v1.5",
                   help="Model name label for the Nomic server.")
    args = p.parse_args()

    result = run_evaluation(
        dataset_path     = args.dataset,
        output_dir       = args.out,
        top_k            = args.top_k,
        force_fallback   = args.fallback,
        qwen_model_name  = args.qwen_name,
        nomic_model_name = args.nomic_name,
        boot             = args.boot,
        llama_bin        = args.llama_bin,
        qwen_model_path  = args.qwen_model,
        nomic_model_path = args.nomic_model,
    )
    sys.exit(0 if result else 1)


if __name__ == "__main__":
    _cli()
