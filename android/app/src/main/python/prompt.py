"""
prompt.py — ChatML prompt builders for Qwen 2.5.

Extracted from llm.py (Phase 3 Step 17) — isolated responsibility.
"""
from __future__ import annotations


def build_rag_prompt(context_chunks: list[str], question: str) -> str:
    """
    Build a RAG prompt using Qwen 2.5's ChatML instruction format.
    (<|im_start|> / <|im_end|> tokens)
    Each chunk is capped at 800 chars to stay within ctx=768 budget.
    """
    # Cap each chunk so total prompt stays within context window:
    # 2 chunks × 800 chars ≈ 300 tokens, + system (~80) + question (~30) = ~410 tokens
    # leaving ~350 tokens for the reply (max_tok=256 + overhead).
    capped = [c[:800] for c in context_chunks]
    ctx_text = "\n\n---\n\n".join(capped)
    system_msg = (
        "You are a helpful assistant. "
        "Answer ONLY based on the provided context. "
        "Write at least 2-3 sentences — never give a one-word answer. "
        "Do NOT just repeat the question. "
        "If the answer is not in the context, say \"I don't know.\". "
        "Reply with only your final answer — no reasoning steps."
    )
    return (
        f"<|im_start|>system\n{system_msg}<|im_end|>\n"
        f"<|im_start|>user\n"
        f"Context:\n{ctx_text}\n\nQuestion: {question}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )


def build_direct_prompt(
    question: str,
    history: list[tuple[str, str]] | None = None,
    summary: str = "",
) -> str:
    """
    Build a plain conversational prompt using Qwen 2.5's ChatML format.
    summary : compressed plain-text of older turns (no LLM call, first sentences).
    history : last 3 verbatim (user, assistant) pairs.
    """
    system_msg = (
        "You are a knowledgeable, helpful AI assistant. "
        "Answer the user's question directly and completely. "
        "Write at least 2-3 sentences. "
        "Do NOT just repeat the question or echo back one word. "
        "Reply with only your final answer — no reasoning steps."
    )
    # Append compressed older context to system message so it takes fewer
    # tokens than full ChatML turns but still informs the model.
    if summary.strip():
        system_msg += (
            "\n\nEarlier in this conversation (summary):\n"
            + summary.strip()
        )
    parts: list[str] = [f"<|im_start|>system\n{system_msg}<|im_end|>\n"]

    # Last 3 verbatim turns
    for user_msg, asst_msg in (history or [])[-3:]:
        parts.append(
            f"<|im_start|>user\n{user_msg}<|im_end|>\n"
            f"<|im_start|>assistant\n{asst_msg}<|im_end|>\n"
        )

    parts.append(
        f"<|im_start|>user\n{question}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )
    return "".join(parts)
