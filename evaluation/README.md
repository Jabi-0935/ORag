# O-RAG — RAGAS Evaluation Harness

This directory contains the evaluation tooling for the **O-RAG** offline
retrieval-augmented generation pipeline using the
[RAGAS](https://docs.ragas.io) framework.

---

## Metrics evaluated

| Metric | What it measures |
|---|---|
| **Faithfulness** | Is the answer grounded in the retrieved context? |
| **Answer Relevancy** | Does the answer address the question? |
| **Context Recall** | Does the retrieved context cover the ground-truth answer? |
| **Context Precision** | Are the retrieved chunks relevant (low noise)? |

All four metrics are scored `[0, 1]` — higher is better.

---

## Quick Start

### 1. Install dependencies

```bash
pip install -r evaluation/requirements.txt
```

### 2. Set your OpenAI API key

RAGAS uses OpenAI as the judge LLM.

```powershell
# PowerShell (Windows)
$env:OPENAI_API_KEY = "sk-..."
```

### 3. Run the evaluation

**Full pipeline boot (models on disk):**

```bash
python evaluation/evaluate_rag.py \
    --dataset  evaluation/sample_dataset.json \
    --qwen-model  path/to/qwen2.5-0.5b-instruct-q4_k_m.gguf \
    --nomic-model path/to/nomic-embed-text-v1.5.Q4_K_M.gguf \
    --out evaluation/results/
```

**Servers already running externally:**

```bash
python evaluation/evaluate_rag.py \
    --dataset evaluation/sample_dataset.json \
    --no-boot \
    --out evaluation/results/
```

---

## Dataset format

`sample_dataset.json` is a JSON array. Each item supports:

```jsonc
{
  "question":     "What is RAG?",          // required
  "ground_truth": "RAG stands for ...",    // required
  "doc_paths":    ["docs/paper.pdf"],      // optional — ingested once
  "contexts":     ["RAG is a technique …"] // optional — skip live retrieval
}
```

- If **`contexts`** is provided, the script skips live retrieval and uses
  the pre-supplied passages for evaluation (useful for reproducible offline
  benchmarks).
- If **`doc_paths`** is provided, the documents are ingested into the live
  database before querying. Already-ingested documents are skipped.

---

## Output

A timestamped CSV report is written to `evaluation/results/`:

```
<YYYYMMDD_HHMMSS>_ragas.csv
```

Columns: `question`, `ground_truth`, `answer`, `num_contexts`,
`faithfulness`, `answer_relevancy`, `context_recall`, `context_precision`.

---

## Customising the judge model

The default judge LLM is `gpt-4o-mini`. Override it with:

```bash
python evaluation/evaluate_rag.py --judge-model gpt-4o
# or
$env:RAGAS_JUDGE_MODEL = "gpt-4o"
```
