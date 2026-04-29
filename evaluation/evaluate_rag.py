"""
evaluate_rag.py — RAGAS evaluation harness for the O-RAG offline pipeline.

What it does
------------
1. Spins up the Qwen generation server and the Nomic embedding server locally
   (or reuses already-running instances).
2. Loads the RAGAS evaluation dataset from a JSON file
   (see evaluation/sample_dataset.json for the expected schema).
3. Runs each question through the full RAG pipeline  →  retrieves context
   + generates an answer the same way the mobile app does.
4. Evaluates with RAGAS metrics:
     • faithfulness          – answer is grounded in context
     • answer_relevancy      – answer addresses the question
     • context_recall        – retrieved context covers the ground-truth answer
     • context_precision     – retrieved chunks are relevant (no noise)
5. Writes a detailed CSV report to evaluation/results/<timestamp>_ragas.csv
   and prints a human-readable summary table.

Prerequisites
-------------
    pip install ragas datasets langchain-openai openai

The script uses ragas + OpenAI's API to judge the answers.
Set the OPENAI_API_KEY environment variable before running.
You can override the judge model via RAGAS_JUDGE_MODEL (default: gpt-4o-mini).

Running
-------
    # From the repo root:
    python evaluation/evaluate_rag.py \
        --dataset  evaluation/sample_dataset.json \
        --qwen-model path/to/qwen.gguf \
        --nomic-model path/to/nomic.gguf \
        --out evaluation/results/

    # Skip model boot (if servers are already running externally):
    python evaluation/evaluate_rag.py --no-boot
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import datetime
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Add the Python backend to sys.path so we can import pipeline / retriever
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).resolve().parent.parent
_PYTHON_SRC = _REPO_ROOT / "orag" / "android" / "app" / "src" / "main" / "python"
sys.path.insert(0, str(_PYTHON_SRC))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="RAGAS evaluation for the O-RAG pipeline",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "--dataset",
        default=str(_REPO_ROOT / "evaluation" / "sample_dataset.json"),
        help="Path to the RAGAS evaluation dataset JSON file.",
    )
    p.add_argument(
        "--qwen-model",
        default=None,
        help="Path to the Qwen .gguf model file. Required when --no-boot is NOT set.",
    )
    p.add_argument(
        "--nomic-model",
        default=None,
        help="Path to the Nomic .gguf embedding model. Required when --no-boot is NOT set.",
    )
    p.add_argument(
        "--no-boot",
        action="store_true",
        default=False,
        help="Skip starting llama-server (assumes servers are already running).",
    )
    p.add_argument(
        "--out",
        default=str(_REPO_ROOT / "evaluation" / "results"),
        help="Output directory for the CSV report.",
    )
    p.add_argument(
        "--top-k",
        type=int,
        default=4,
        help="Number of chunks to retrieve per query.",
    )
    p.add_argument(
        "--judge-model",
        default=os.environ.get("RAGAS_JUDGE_MODEL", "gpt-4o-mini"),
        help="OpenAI model used by RAGAS as the judge LLM.",
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=5,
        help="Number of QA pairs to send to RAGAS in a single batch.",
    )
    return p.parse_args()


# ---------------------------------------------------------------------------
# Server boot helpers
# ---------------------------------------------------------------------------

def _boot_servers(qwen_model: Optional[str], nomic_model: Optional[str]) -> None:
    """Start llama-server (Qwen) and nomic-server if not already running."""
    import llm as llm_mod

    from config import QWEN_SERVER_PORT, NOMIC_SERVER_PORT

    # Qwen generation server
    if llm_mod._probe_port(QWEN_SERVER_PORT):
        print(f"[boot] Qwen server already running on port {QWEN_SERVER_PORT}.")
    else:
        if not qwen_model or not Path(qwen_model).is_file():
            raise FileNotFoundError(
                f"Qwen model not found: {qwen_model!r}. "
                "Pass --qwen-model <path> or start the server manually and use --no-boot."
            )
        print(f"[boot] Starting Qwen server with model: {qwen_model}")
        n_threads = llm_mod._optimal_threads()
        ok = llm_mod._start_llama_server(
            model_path=qwen_model,
            n_ctx=2048,
            n_threads=n_threads,
        )
        if not ok:
            raise RuntimeError("Failed to start Qwen llama-server.")
        print("[boot] Qwen server ready.")

    # Nomic embedding server
    if llm_mod._probe_port(NOMIC_SERVER_PORT):
        print(f"[boot] Nomic server already running on port {NOMIC_SERVER_PORT}.")
    else:
        if not nomic_model or not Path(nomic_model).is_file():
            print("[boot] WARNING: Nomic model not found — dense retrieval disabled.")
        else:
            print(f"[boot] Starting Nomic server with model: {nomic_model}")
            n_threads = llm_mod._optimal_threads()
            ok = llm_mod.start_nomic_server(
                model_path=nomic_model,
                n_ctx=512,
                n_threads=n_threads,
            )
            if not ok:
                print("[boot] WARNING: Nomic server failed to start — falling back to BM25 only.")
            else:
                print("[boot] Nomic server ready.")


# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------

def _load_dataset(path: str) -> list[dict]:
    """
    Load the evaluation dataset from a JSON file.

    Expected schema (list of objects):
    [
      {
        "question": "What is the capital of France?",
        "ground_truth": "The capital of France is Paris.",
        "contexts": ["Paris is the capital of France ...", "..."],   // optional
        "doc_paths": ["path/to/doc.pdf"]                             // optional
      },
      ...
    ]

    - `question`     (required) — the user query.
    - `ground_truth` (required) — the reference answer for evaluation.
    - `contexts`     (optional) — pre-retrieved contexts (skips live retrieval
                                  if present; useful for offline eval).
    - `doc_paths`    (optional) — documents to ingest before asking the question
                                  (ingested once; re-ingest is a no-op).
    """
    data_path = Path(path)
    if not data_path.is_file():
        raise FileNotFoundError(f"Dataset not found: {path}")

    with open(data_path, encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, list) or not data:
        raise ValueError("Dataset must be a non-empty JSON array.")

    required = {"question", "ground_truth"}
    for i, item in enumerate(data):
        missing = required - set(item.keys())
        if missing:
            raise ValueError(f"Item #{i} is missing required keys: {missing}")

    print(f"[dataset] Loaded {len(data)} QA pairs from {data_path.name}")
    return data


# ---------------------------------------------------------------------------
# RAG pipeline helpers
# ---------------------------------------------------------------------------

def _ingest_docs_if_needed(doc_paths: list[str]) -> None:
    """Ingest documents into the live pipeline if they haven't been already."""
    if not doc_paths:
        return

    import pipeline as pipe_mod
    from storage import list_documents as _list_docs

    already_ingested = {d["name"] for d in _list_docs()}
    for doc_path in doc_paths:
        name = Path(doc_path).name
        if name in already_ingested:
            print(f"  [ingest] '{name}' already ingested — skipping.")
            continue
        if not Path(doc_path).is_file():
            print(f"  [ingest] WARNING: doc not found: {doc_path}")
            continue
        ok, msg = pipe_mod.ingest_document(doc_path)
        print(f"  [ingest] {'OK' if ok else 'FAIL'}: {msg}")


def _run_rag_query(question: str, top_k: int = 4) -> tuple[str, list[str]]:
    """
    Run a live RAG query through the pipeline.

    Returns (answer, contexts) where contexts is a list of retrieved chunk texts.
    """
    import pipeline as pipe_mod
    from storage import list_documents as _list_docs

    ok, answer, sources = pipe_mod.ask(question)
    if not ok:
        return answer, []

    # Re-run retrieval to collect raw contexts (ask() only returns short previews)
    results = pipe_mod.retriever.query_with_expansion(question, top_k=top_k)
    if not results:
        results = pipe_mod.retriever.query(question, top_k=top_k)

    contexts = [text for text, _score, _doc_id in results]
    return answer, contexts


# ---------------------------------------------------------------------------
# RAGAS evaluation
# ---------------------------------------------------------------------------

def _build_ragas_dataset(records: list[dict]) -> "datasets.Dataset":
    """Convert collected records into a HuggingFace Dataset for RAGAS."""
    from datasets import Dataset

    data = {
        "question": [r["question"] for r in records],
        "answer": [r["answer"] for r in records],
        "contexts": [r["contexts"] for r in records],
        "ground_truth": [r["ground_truth"] for r in records],
    }
    return Dataset.from_dict(data)


def _run_ragas_evaluation(dataset, judge_model: str) -> dict:
    """Run RAGAS metrics and return a dict of metric_name → score."""
    from ragas import evaluate
    from ragas.metrics import (
        faithfulness,
        answer_relevancy,
        context_recall,
        context_precision,
    )
    from langchain_openai import ChatOpenAI, OpenAIEmbeddings

    judge_llm = ChatOpenAI(model=judge_model, temperature=0)
    judge_embeddings = OpenAIEmbeddings(model="text-embedding-3-small")

    result = evaluate(
        dataset=dataset,
        metrics=[
            faithfulness,
            answer_relevancy,
            context_recall,
            context_precision,
        ],
        llm=judge_llm,
        embeddings=judge_embeddings,
        raise_exceptions=False,
    )
    return result


# ---------------------------------------------------------------------------
# Report helpers
# ---------------------------------------------------------------------------

def _print_summary(records: list[dict], ragas_result) -> None:
    """Print a human-readable evaluation summary to stdout."""
    scores = ragas_result.to_pandas()

    metric_names = [
        "faithfulness",
        "answer_relevancy",
        "context_recall",
        "context_precision",
    ]

    print("\n" + "=" * 70)
    print("  O-RAG RAGAS Evaluation Summary")
    print("=" * 70)
    print(f"  Questions evaluated : {len(records)}")
    print(f"  Evaluation time     : {datetime.datetime.now():%Y-%m-%d %H:%M:%S}")
    print()
    print(f"  {'Metric':<28} {'Mean':>8}  {'Min':>8}  {'Max':>8}")
    print("  " + "-" * 50)
    for m in metric_names:
        if m in scores.columns:
            col = scores[m].dropna()
            print(f"  {m:<28} {col.mean():>8.4f}  {col.min():>8.4f}  {col.max():>8.4f}")
        else:
            print(f"  {m:<28} {'N/A':>8}")
    print("=" * 70 + "\n")


def _write_csv(records: list[dict], ragas_result, out_dir: str) -> Path:
    """Write per-question scores + answers to a CSV file."""
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = out_path / f"{ts}_ragas.csv"

    scores_df = ragas_result.to_pandas()

    metric_names = [
        "faithfulness",
        "answer_relevancy",
        "context_recall",
        "context_precision",
    ]

    fieldnames = [
        "question",
        "ground_truth",
        "answer",
        "num_contexts",
        *metric_names,
    ]

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for i, rec in enumerate(records):
            row: dict = {
                "question": rec["question"],
                "ground_truth": rec["ground_truth"],
                "answer": rec["answer"],
                "num_contexts": len(rec["contexts"]),
            }
            if i < len(scores_df):
                for m in metric_names:
                    row[m] = round(float(scores_df[m].iloc[i]), 4) if m in scores_df.columns else ""
            writer.writerow(row)

    print(f"[report] CSV report written → {csv_path}")
    return csv_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    args = _parse_args()

    # ── 0. Check OPENAI_API_KEY ───────────────────────────────────────────
    if not os.environ.get("OPENAI_API_KEY"):
        print(
            "ERROR: OPENAI_API_KEY is not set.\n"
            "RAGAS uses OpenAI as a judge LLM. Please set the environment variable:\n"
            "  $env:OPENAI_API_KEY='sk-...'"
        )
        return 1

    # ── 1. Import RAGAS (check installation) ─────────────────────────────
    try:
        import ragas  # noqa: F401
        from datasets import Dataset  # noqa: F401
    except ImportError as e:
        print(
            f"ERROR: Missing dependency — {e}\n"
            "Install with:\n"
            "  pip install ragas datasets langchain-openai openai"
        )
        return 1

    # ── 2. Load dataset ───────────────────────────────────────────────────
    eval_data = _load_dataset(args.dataset)

    # ── 3. Boot servers ───────────────────────────────────────────────────
    if not args.no_boot:
        _boot_servers(args.qwen_model, args.nomic_model)
    else:
        print("[boot] --no-boot flag set; assuming servers are already running.")

    # ── 4. Initialize pipeline (storage + retriever) ──────────────────────
    print("[pipeline] Initializing storage and retriever...")
    from storage import init_db
    import pipeline as pipe_mod

    init_db()
    pipe_mod.retriever.reload()
    print("[pipeline] Ready.")

    # ── 5. Run queries and collect results ────────────────────────────────
    collected: list[dict] = []

    for idx, item in enumerate(eval_data):
        question    = item["question"]
        ground_truth = item["ground_truth"]
        doc_paths   = item.get("doc_paths", [])
        pre_contexts = item.get("contexts")  # optional pre-supplied contexts

        print(f"\n[eval] [{idx+1}/{len(eval_data)}] Q: {question[:80]}")

        # Ingest any docs referenced by this sample
        if doc_paths:
            _ingest_docs_if_needed(doc_paths)

        # Retrieve + generate
        if pre_contexts is not None:
            # Use pre-supplied contexts (offline mode)
            contexts = pre_contexts
            from llm import build_rag_prompt
            prompt = build_rag_prompt(contexts, question)
            import pipeline as _p
            ok, answer = _p.chat_direct(question=question)
            if not ok:
                answer = f"ERROR: {answer}"
            print(f"  → answer (pre-ctx): {answer[:120]}")
        else:
            answer, contexts = _run_rag_query(question, top_k=args.top_k)
            print(f"  → answer: {answer[:120]}")
            print(f"  → contexts retrieved: {len(contexts)}")

        collected.append({
            "question":     question,
            "ground_truth": ground_truth,
            "answer":       answer,
            "contexts":     contexts if contexts else [""],
        })

    # ── 6. Build RAGAS dataset ────────────────────────────────────────────
    print("\n[ragas] Building evaluation dataset...")
    ragas_ds = _build_ragas_dataset(collected)

    # ── 7. Run RAGAS evaluation ───────────────────────────────────────────
    print(f"[ragas] Running evaluation with judge model: {args.judge_model}")
    ragas_result = _run_ragas_evaluation(ragas_ds, judge_model=args.judge_model)

    # ── 8. Report ─────────────────────────────────────────────────────────
    _print_summary(collected, ragas_result)
    _write_csv(collected, ragas_result, args.out)

    return 0


if __name__ == "__main__":
    sys.exit(main())
