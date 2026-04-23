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

Optimizations:
  - Nomic search_document: / search_query: prefixes for correct embedding space
  - Batch embedding via single HTTP request (N-in-1)
  - Parallel sparse + dense retrieval via ThreadPoolExecutor
  - O(1) chunk ID lookups via dict index
  - Embedding persistence in SQLite (survives app restarts)
"""
from __future__ import annotations

import math
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import List, Dict, Tuple, Optional


# ------------------------------------------------------------------ #
#  Dense similarity helper                                             #
# ------------------------------------------------------------------ #

def _cosine_dense(a: list, b: list) -> float:
    """Cosine similarity — single-pass for 3x speedup over naive 3-pass."""
    dot = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    denom = math.sqrt(na * nb)
    return dot / denom if denom > 0 else 0.0


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

    Optimizations over baseline:
      - O(1) chunk lookup via _chunk_index dict
      - Embedding cache persisted in SQLite
      - Batch embedding computation (N-in-1 HTTP request)
      - Parallel sparse+dense retrieval
      - Nomic search_document:/search_query: prefixes

    Call reload() after new documents are ingested.
    """

    def __init__(self, alpha: float = 0.5):
        """
        alpha is kept for backward compatibility but no longer used.
        The wRRF weights (0.7 dense, 0.3 sparse) are used instead.
        """
        self.alpha = alpha
        self._chunks: List[dict] = []   # [{id, doc_id, text, tokens, parent_chunk_idx}, ...]
        self._chunk_index: Dict[int, int] = {}  # chunk_id -> list index (O(1) lookup)
        self._text_index: Dict[tuple, int] = {}  # (doc_id, text) -> list index (O(1) lookup)
        self._avg_dl: float = 0.0
        # Semantic embedding cache: chunk_id -> list[float]
        self._embeddings: dict = {}
        self._embed_lock  = threading.Lock()
        self._embed_ready = False

    # --- loading ---

    def reload(self) -> None:
        """Re-read all chunks from the database and trigger embedding computation."""
        from storage import load_all_chunks, load_cached_embeddings
        self._chunks = load_all_chunks()
        # Build O(1) indexes for fast lookup
        self._chunk_index = {c["id"]: i for i, c in enumerate(self._chunks)}
        self._text_index = {
            (c["doc_id"], c["text"].strip()): i
            for i, c in enumerate(self._chunks)
        }

        # Load persisted embeddings from SQLite first
        cached = load_cached_embeddings()
        with self._embed_lock:
            self._embeddings = cached
            self._embed_ready = bool(cached)

        if self._chunks:
            total = sum(len(c["tokens"]) for c in self._chunks)
            self._avg_dl = total / len(self._chunks)
            # Lazy-start Nomic server if needed (on low-RAM, it defers to here)
            try:
                from memory_management import ensure_nomic_server
                from downloader import NOMIC_MODEL, model_dest_path
                nomic_path = model_dest_path(NOMIC_MODEL["filename"])
                ensure_nomic_server(nomic_path)
            except Exception as e:
                print(f"[retriever] Nomic lazy-start skipped: {e}")
            # Compute dense embeddings in background — doesn't block the UI
            threading.Thread(
                target=self._compute_embeddings,
                daemon=True,
            ).start()
        else:
            self._avg_dl = 1.0

    def _compute_embeddings(self) -> None:
        """
        Background thread: compute embeddings for chunks that don't have
        cached embeddings yet.  Uses batch embedding for speed.

        Uses Nomic's search_document: prefix for proper embedding space.
        Persists results to SQLite so they survive app restarts.
        On low-RAM profiles, stops the Nomic server after completion.
        """
        try:
            from llm import get_embeddings_batch, get_embedding
            from storage import save_embeddings_batch

            # Adaptive chunk limit from memory profile
            try:
                from memory_management import get_profile
                limit = get_profile().get("embed_chunk_limit", 50)
            except Exception:
                limit = 50

            # Filter out chunks that already have cached embeddings
            with self._embed_lock:
                cached_ids = set(self._embeddings.keys())

            chunks_to_embed = [
                c for c in self._chunks[:limit]
                if c["id"] not in cached_ids
            ]

            if not chunks_to_embed:
                with self._embed_lock:
                    self._embed_ready = True
                print(f"[retriever] all embeddings cached "
                      f"({len(cached_ids)} chunks)")
                return

            # Prepare texts with Nomic search_document: prefix
            texts = [
                "search_document: " + c["text"][:480]
                for c in chunks_to_embed
            ]

            # Batch embedding: one HTTP round-trip for all texts
            print(f"[retriever] computing {len(texts)} embeddings (batch)...")
            embeddings_list = get_embeddings_batch(texts)

            new_embeddings = {}
            for c, emb in zip(chunks_to_embed, embeddings_list):
                if emb is not None:
                    new_embeddings[c["id"]] = emb

            if not new_embeddings and chunks_to_embed:
                # Batch failed completely — try serial fallback for first chunk
                first_emb = get_embedding("search_document: " + chunks_to_embed[0]["text"][:480])
                if first_emb is None:
                    print("[retriever] embedding endpoint unavailable — "
                          "falling back to BM25 only")
                    return
                # Serial fallback for remaining chunks
                for c in chunks_to_embed:
                    emb = get_embedding("search_document: " + c["text"][:480])
                    if emb is not None:
                        new_embeddings[c["id"]] = emb

            # Merge with existing cache
            with self._embed_lock:
                self._embeddings.update(new_embeddings)
                self._embed_ready = True

            # Persist new embeddings to SQLite
            if new_embeddings:
                try:
                    save_embeddings_batch(new_embeddings)
                except Exception as e:
                    print(f"[retriever] embedding persistence failed: {e}")

            total = len(self._embeddings)
            print(f"[retriever] semantic embeddings ready "
                  f"({total} total, {len(new_embeddings)} new)")

            # On low-RAM: stop Nomic server to reclaim ~140 MB
            try:
                from memory_management import should_stop_nomic_after_embedding
                if should_stop_nomic_after_embedding():
                    from llm import stop_nomic_server
                    stop_nomic_server()
                    print("[retriever] Nomic server stopped to free memory "
                          "(low-RAM profile)")
            except Exception:
                pass

        except Exception as e:
            print(f"[retriever] embedding computation failed: {e}")

    def is_empty(self) -> bool:
        return len(self._chunks) == 0

    # --- chunk lookup ---

    def _chunk_by_id(self, chunk_id: int) -> Optional[dict]:
        """O(1) lookup of chunk dict by ID via index."""
        idx = self._chunk_index.get(chunk_id)
        if idx is not None and idx < len(self._chunks):
            return self._chunks[idx]
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
        Uses Nomic's search_query: prefix for proper embedding space.
        Reads embeddings under lock without copying the entire dict.
        """
        with self._embed_lock:
            if not self._embed_ready or not self._embeddings:
                return []
            # Read under lock — no dict copy needed since we only read
            chunk_ids_with_emb = [
                (cid, emb) for cid, emb in self._embeddings.items()
            ]

        try:
            from llm import get_embedding
            q_emb = get_embedding("search_query: " + query_text[:280])
            if q_emb is None:
                return []

            scores = []
            for cid, chunk_emb in chunk_ids_with_emb:
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
        1. Run FTS5 BM25 (sparse) and Dense (semantic) in parallel
        2. Merge with Weighted RRF (0.7 dense, 0.3 sparse)
        3. Contextual pruning (drop chunks < 40% of top score)
        4. Cap at top 2 for minimal LLM prefill latency
        """
        if self.is_empty():
            return []

        # Step 1: Retrieve from both sources in parallel
        with ThreadPoolExecutor(max_workers=2) as pool:
            sparse_fut = pool.submit(self._sparse_search, text, 10)
            dense_fut = pool.submit(self._dense_search, text, 10)
            try:
                sparse = sparse_fut.result(timeout=5)
            except Exception:
                sparse = []
            try:
                dense = dense_fut.result(timeout=5)
            except Exception:
                dense = []

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
        Uses O(1) reverse-text index instead of linear scan.
        """
        if self.is_empty():
            return []

        small_results = self.query(text, top_k=top_k)
        if not small_results:
            return []

        from storage import get_parent_chunk_text
        expanded = []
        seen_parents = set()
        for chunk_text, score, doc_id in small_results:
            # O(1) lookup via _text_index instead of O(N) linear scan
            chunk = self._find_chunk_by_text(chunk_text, doc_id)

            if chunk and chunk.get("parent_chunk_idx", -1) >= 0:
                parent_key = (doc_id, chunk["parent_chunk_idx"])
                if parent_key in seen_parents:
                    continue
                seen_parents.add(parent_key)

                parent_text = get_parent_chunk_text(doc_id, chunk["parent_chunk_idx"])
                if parent_text:
                    expanded.append((parent_text, score, doc_id))
                    continue

            expanded.append((chunk_text, score, doc_id))

        return expanded

    def _find_chunk_by_text(self, text: str, doc_id: int) -> Optional[dict]:
        """O(1) chunk lookup by text+doc_id via reverse index."""
        key = (doc_id, text.strip())
        idx = self._text_index.get(key)
        if idx is not None and idx < len(self._chunks):
            return self._chunks[idx]
        return None

    def get_chunk_ids_for_results(
        self, results: list[tuple[str, float, int]]
    ) -> list[int]:
        """Map RAG query results back to chunk IDs for image lookup.
        Uses O(1) text index for fast matching.
        """
        chunk_ids = []
        for text, score, doc_id in results:
            chunk = self._find_chunk_by_text(text, doc_id)
            if chunk:
                chunk_ids.append(chunk["id"])
        return chunk_ids
