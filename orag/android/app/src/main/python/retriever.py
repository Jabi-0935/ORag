"""
retriever.py — Optimized 2-Retriever system with Weighted RRF.

Retrievers:
  1. Sparse: SQLite FTS5 native BM25 (zero RAM overhead)
  2. Dense:  Nomic Embed v1.5 semantic cosine via llama-server /embedding

Re-ranking:
  - Weighted Reciprocal Rank Fusion (wRRF) with 0.7 dense + 0.3 sparse
  - Contextual pruning: drops chunks whose score < 40% of the top result

Small-to-Big expansion:
  - After pruning, expands matched small chunks to their parent (400-word)
    chunks from the parent_chunks table for richer LLM context.
"""
from __future__ import annotations

import math
import threading
from typing import List, Dict, Tuple, Optional


# ------------------------------------------------------------------ #
#  Dense similarity helper                                             #
# ------------------------------------------------------------------ #

def _cosine_dense(a: list, b: list) -> float:
    """Cosine similarity between two dense float vectors (pure Python)."""
    dot = sum(x * y for x, y in zip(a, b))
    na  = math.sqrt(sum(x * x for x in a)) or 1.0
    nb  = math.sqrt(sum(x * x for x in b)) or 1.0
    return dot / (na * nb)


# ------------------------------------------------------------------ #
#  Weighted Reciprocal Rank Fusion                                     #
# ------------------------------------------------------------------ #

def _wrrf_merge(
    sparse_results: List[Tuple[int, float]],
    dense_results: List[Tuple[int, float]],
    w_dense: float = 0.7,
    w_sparse: float = 0.3,
    k: int = 60,
) -> List[Tuple[int, float]]:
    """
    Merge two ranked result lists using Weighted Reciprocal Rank Fusion.

    Each result is (chunk_id, score).  RRF is rank-based so raw scores
    don't need normalization — only ordinal position matters.

    Returns merged list of (chunk_id, wrrf_score) sorted descending.
    """
    scores: Dict[int, float] = {}

    for rank, (cid, _) in enumerate(sparse_results):
        scores[cid] = scores.get(cid, 0.0) + w_sparse / (k + rank + 1)

    for rank, (cid, _) in enumerate(dense_results):
        scores[cid] = scores.get(cid, 0.0) + w_dense / (k + rank + 1)

    merged = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return merged


def _contextual_prune(
    results: List[Tuple[int, float]],
    max_results: int = 2,
    min_ratio: float = 0.4,
) -> List[Tuple[int, float]]:
    """
    Prune results with a dynamic score threshold.

    Drops any chunk whose score is less than min_ratio * top_score.
    Then caps at max_results to minimize LLM prefill latency.
    """
    if not results:
        return []

    top_score = results[0][1]
    if top_score <= 0:
        return results[:max_results]

    pruned = []
    for cid, score in results:
        if score / top_score >= min_ratio:
            pruned.append((cid, score))
        else:
            break  # Results are sorted, so all following are worse
        if len(pruned) >= max_results:
            break

    return pruned


# ------------------------------------------------------------------ #
#  Retriever                                                           #
# ------------------------------------------------------------------ #

class HybridRetriever:
    """
    Two-retriever system: FTS5 BM25 (sparse) + Nomic embeddings (dense).
    Uses Weighted RRF for fusion and contextual pruning for quality.

    Call reload() after new documents are ingested.
    """

    def __init__(self, alpha: float = 0.5):
        """
        alpha is kept for backward compatibility but no longer used.
        The wRRF weights (0.7 dense, 0.3 sparse) are used instead.
        """
        self.alpha = alpha
        self._chunks: List[dict] = []   # [{id, doc_id, text, tokens, tfidf_vec, parent_chunk_idx}, ...]
        self._avg_dl: float = 0.0
        # Semantic embedding cache: chunk_id -> list[float]
        self._embeddings: dict = {}
        self._embed_lock  = threading.Lock()
        self._embed_ready = False

    # --- loading ---

    def reload(self) -> None:
        """Re-read all chunks from the database and trigger embedding computation."""
        from storage import load_all_chunks
        self._chunks = load_all_chunks()
        with self._embed_lock:
            self._embeddings  = {}
            self._embed_ready = False
        if self._chunks:
            total = sum(len(c["tokens"]) for c in self._chunks)
            self._avg_dl = total / len(self._chunks)
            # Only compute dense embeddings if Nomic server is enabled
            try:
                from llm import get_memory_profile
                profile = get_memory_profile()
                if not profile.get("load_nomic", True):
                    print("[retriever] Nomic disabled (low RAM) — BM25 only mode")
                    return
            except Exception:
                pass
            # Compute dense embeddings in background — doesn't block the UI
            threading.Thread(
                target=self._compute_embeddings,
                daemon=True,
            ).start()
        else:
            self._avg_dl = 1.0

    def _compute_embeddings(self) -> None:
        """
        Background thread: call llama-server /embedding for every chunk
        and cache the result.  Capped at 50 chunks to avoid 100s of serial
        HTTP roundtrips on large documents (BM25 handles the rest).
        Gracefully no-ops if the server is down or embeddings are unsupported.
        """
        try:
            from llm import get_embedding
            computed = {}
            # Cap at 50 chunks — embed more for better coverage with Q8_0 model.
            chunks_to_embed = self._chunks[:50]
            for c in chunks_to_embed:
                cid  = c["id"]
                # Cap at 512 chars ≈ 150 tokens, matching Nomic ctx=512
                text = c["text"][:512]
                emb = get_embedding(text)
                if emb is None:
                    print("[retriever] embedding endpoint unavailable — "
                          "falling back to BM25 only")
                    return
                computed[cid] = emb
            with self._embed_lock:
                self._embeddings  = computed
                self._embed_ready = True
            print(f"[retriever] semantic embeddings ready "
                  f"({len(computed)} chunks)")
        except Exception as e:
            print(f"[retriever] embedding computation failed: {e}")

    def is_empty(self) -> bool:
        return len(self._chunks) == 0

    # --- chunk lookup ---

    def _chunk_by_id(self, chunk_id: int) -> Optional[dict]:
        """Fast lookup of chunk dict by ID."""
        for c in self._chunks:
            if c["id"] == chunk_id:
                return c
        return None

    # --- FTS5 BM25 sparse retrieval ---

    def _sparse_search(self, query: str, top_k: int = 10) -> List[Tuple[int, float]]:
        """Run FTS5 BM25 search. Returns [(chunk_id, bm25_score), ...]."""
        from storage import fts5_bm25_search
        return fts5_bm25_search(query, top_k=top_k)

    # --- Dense semantic retrieval ---

    def _dense_search(self, query_text: str, top_k: int = 10) -> List[Tuple[int, float]]:
        """
        Returns top_k (chunk_id, cosine_score) using cached embeddings.
        Returns empty list if embeddings aren't ready.
        """
        with self._embed_lock:
            if not self._embed_ready:
                return []
            embeddings = dict(self._embeddings)  # snapshot

        try:
            from llm import get_embedding
            q_emb = get_embedding(query_text[:300])
            if q_emb is None:
                return []

            scores = []
            for c in self._chunks:
                cid = c["id"]
                chunk_emb = embeddings.get(cid)
                if chunk_emb:
                    sim = _cosine_dense(q_emb, chunk_emb)
                    scores.append((cid, sim))

            scores.sort(key=lambda x: x[1], reverse=True)
            return scores[:top_k]
        except Exception as e:
            print(f"[retriever] dense search failed: {e}")
            return []

    # --- public query ---

    def query(self, text: str, top_k: int = 4) -> List[Tuple[str, float, int]]:
        """
        Returns list of (chunk_text, score, doc_id) sorted by relevance.

        Pipeline:
        1. Run FTS5 BM25 (sparse) and Dense (semantic) in parallel-ish
        2. Merge with Weighted RRF (0.7 dense, 0.3 sparse)
        3. Contextual pruning (drop chunks < 40% of top score)
        4. Cap at top 2 for minimal LLM prefill latency
        """
        if self.is_empty():
            return []

        # Step 1: Retrieve from both sources
        sparse = self._sparse_search(text, top_k=10)
        dense  = self._dense_search(text, top_k=10)

        if not sparse and not dense:
            return []

        # Step 2: Merge with Weighted RRF
        if dense:
            merged = _wrrf_merge(sparse, dense, w_dense=0.7, w_sparse=0.3)
        else:
            # Fallback: only sparse results available (no embeddings yet)
            merged = [(cid, score) for cid, score in sparse]

        # Step 3: Contextual pruning — drop low-relevance, cap at 2
        pruned = _contextual_prune(merged, max_results=top_k, min_ratio=0.4)

        # Step 4: Build result tuples
        seen_texts = set()
        top = []
        for cid, score in pruned:
            chunk = self._chunk_by_id(cid)
            if chunk is None:
                continue
            txt = chunk["text"].strip()
            if txt in seen_texts:
                continue
            seen_texts.add(txt)
            top.append((txt, score, chunk["doc_id"]))

        return top

    def query_with_expansion(self, text: str, top_k: int = 2) -> List[Tuple[str, float, int]]:
        """
        Small-to-Big query: retrieve small chunks, then expand to parent chunks.

        Returns list of (parent_chunk_text, score, doc_id).
        Falls back to small chunk text if parent is not available.
        """
        if self.is_empty():
            return []

        # Get pruned small chunks
        small_results = self.query(text, top_k=top_k)
        if not small_results:
            return []

        # Expand to parent chunks
        from storage import get_parent_chunk_text
        expanded = []
        seen_parents = set()
        for chunk_text, score, doc_id in small_results:
            # Find the chunk to get parent_chunk_idx
            chunk = None
            for c in self._chunks:
                if c["text"].strip() == chunk_text.strip() and c["doc_id"] == doc_id:
                    chunk = c
                    break

            if chunk and chunk.get("parent_chunk_idx", -1) >= 0:
                parent_key = (doc_id, chunk["parent_chunk_idx"])
                if parent_key in seen_parents:
                    continue
                seen_parents.add(parent_key)

                parent_text = get_parent_chunk_text(doc_id, chunk["parent_chunk_idx"])
                if parent_text:
                    expanded.append((parent_text, score, doc_id))
                    continue

            # Fallback: use the small chunk itself
            expanded.append((chunk_text, score, doc_id))

        return expanded

    def get_chunk_ids_for_results(
        self, results: list[tuple[str, float, int]]
    ) -> list[int]:
        """Map RAG query results back to chunk IDs for image lookup."""
        chunk_ids = []
        for text, score, doc_id in results:
            for c in self._chunks:
                if c["text"].strip() == text.strip() and c["doc_id"] == doc_id:
                    chunk_ids.append(c["id"])
                    break
        return chunk_ids
