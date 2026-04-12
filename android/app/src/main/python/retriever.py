"""
retriever.py — Hybrid BM25 + TF-IDF + Semantic retriever.

Retrieval pipeline
------------------
* BM25     : classic probabilistic keyword ranking (no external deps).
* TF-IDF   : sparse cosine over per-chunk vectors stored in the DB.
* Semantic : dense cosine over Nomic embeddings fetched from the
             llama-server /embedding endpoint.

Scoring when semantic embeddings are available:
    0.30 * bm25_norm  +  0.20 * tfidf_norm  +  0.50 * semantic_norm

Fallback when semantic is unavailable:
    alpha * bm25_norm  +  (1 - alpha) * tfidf_norm

Phase 1 changes (carried forward)
-----------------------------------
- Embedding persistence: computed embeddings saved to DB on each chunk,
  loaded back on reload() so they survive app restarts.
- Version guard: background embed threads abort when superseded.
- 30-chunk cap removed: all chunks embedded incrementally.
- Incremental mutations: add_chunks / remove_doc / clear.
- Score threshold: query() returns [] below RELEVANCE_THRESHOLD.

Phase 2 changes (this version)
--------------------------------
Step 13 — Inverted index for BM25:
  _build_index() precomputes at reload/add_chunks time:
    self._index       : term -> sorted list of chunk indices
    self._tf_maps     : per-chunk {term: raw_count}
    self._doc_lengths : per-chunk token count
  _bm25_scores_sparse() does index lookup instead of full scan.
  Complexity: O(candidates x query_tokens) vs old O(N x query_tokens).

Step 14 — Two-stage retrieval:
  query() runs BM25 first to get top BM25_CANDIDATE_K=50 candidates,
  then runs semantic scoring only on those 50 rather than full corpus.
  TF-IDF cosine is also restricted to the same candidate set.

Step 15 — Query embedding cache:
  Repeated or near-duplicate queries skip the Nomic HTTP call.
  LRU eviction with MAX_QUERY_CACHE=64 entries.
"""
from __future__ import annotations

import math
import threading
from collections import OrderedDict
from typing import Dict, List, Optional, Set, Tuple

from chunker import tokenise

# ------------------------------------------------------------------ #
#  BM25 parameters                                                     #
# ------------------------------------------------------------------ #
K1 = 1.5    # term-frequency saturation
B  = 0.75   # length normalisation weight

# ------------------------------------------------------------------ #
#  Retrieval quality gates                                             #
# ------------------------------------------------------------------ #
RELEVANCE_THRESHOLD = 0.15
MIN_MARGIN          = 0.05

# ------------------------------------------------------------------ #
#  Query embedding cache (Step 15)                                    #
# ------------------------------------------------------------------ #
MAX_QUERY_CACHE    = 64
_query_cache:      OrderedDict    = OrderedDict()
_query_cache_lock: threading.Lock = threading.Lock()


def _get_cached_query_embedding(text: str) -> Optional[list]:
    with _query_cache_lock:
        if text in _query_cache:
            _query_cache.move_to_end(text)   # mark as recently used
            return _query_cache[text]
    return None


def _set_cached_query_embedding(text: str, emb: list) -> None:
    with _query_cache_lock:
        if text in _query_cache:
            _query_cache.move_to_end(text)
        else:
            if len(_query_cache) >= MAX_QUERY_CACHE:
                _query_cache.popitem(last=False)   # evict oldest
            _query_cache[text] = emb


# ------------------------------------------------------------------ #
#  Math helpers                                                        #
# ------------------------------------------------------------------ #

def _dot(a: Dict[str, float], b: Dict[str, float]) -> float:
    if len(a) > len(b):
        a, b = b, a
    return sum(a[t] * b[t] for t in a if t in b)


def _norm(v: Dict[str, float]) -> float:
    return math.sqrt(sum(x * x for x in v.values())) or 1.0


def _cosine_sparse(a: Dict[str, float], b: Dict[str, float]) -> float:
    return _dot(a, b) / (_norm(a) * _norm(b))


def _cosine_dense(a: list, b: list) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na  = math.sqrt(sum(x * x for x in a)) or 1.0
    nb  = math.sqrt(sum(x * x for x in b)) or 1.0
    return dot / (na * nb)


def _normalise_scores(scores: List[float]) -> List[float]:
    """Min-max normalise to [0, 1]. Returns zeros if all values equal."""
    mn  = min(scores)
    mx  = max(scores)
    rng = mx - mn or 1.0
    return [(s - mn) / rng for s in scores]


def _recalc_avg_dl(chunks: List[dict]) -> float:
    if not chunks:
        return 1.0
    return sum(len(c["tokens"]) for c in chunks) / len(chunks)


# ------------------------------------------------------------------ #
#  Retriever                                                           #
# ------------------------------------------------------------------ #

class HybridRetriever:
    """
    Loads all chunks into memory once and answers queries quickly.

    Public mutation API
    -------------------
    reload()              -- full reload from DB (init only)
    add_chunks(chunks)    -- append newly ingested chunks
    remove_doc(doc_id)    -- drop all chunks for a deleted document
    clear()               -- reset everything without a DB round-trip
    """

    # BM25 candidates passed to semantic re-ranker (Stage 2)
    BM25_CANDIDATE_K = 50

    def __init__(self, alpha: float = 0.5) -> None:
        self.alpha = alpha

        # Core corpus state
        self._chunks:       List[dict] = []
        self._avg_dl:       float      = 1.0

        # Inverted index (Step 13)
        self._index:        Dict[str, List[int]] = {}   # term -> [chunk_idx]
        self._tf_maps:      List[Dict[str, int]] = []   # per-chunk raw counts
        self._doc_lengths:  List[int]            = []   # per-chunk token count
        self._index_lock    = threading.Lock()

        # Semantic embedding cache  {chunk_id: list[float]}
        self._embeddings:   dict       = {}
        self._embed_lock               = threading.Lock()
        self._embed_ready:  bool       = False

        # Version counter for background embed thread guard
        self._version:      int        = 0

    # ---------------------------------------------------------------- #
    #  Index construction (Step 13)                                     #
    # ---------------------------------------------------------------- #

    def _build_index(self) -> None:
        """
        Build inverted index and per-chunk structures from scratch.
        Single pass over self._chunks: O(total_tokens).
        Called after reload() and after remove_doc() (which shifts indices).
        """
        index:       Dict[str, List[int]] = {}
        tf_maps:     List[Dict[str, int]] = []
        doc_lengths: List[int]            = []

        for i, chunk in enumerate(self._chunks):
            tokens = chunk["tokens"]
            dl     = len(tokens)
            doc_lengths.append(dl)

            tf_map: Dict[str, int] = {}
            for t in tokens:
                tf_map[t] = tf_map.get(t, 0) + 1
            tf_maps.append(tf_map)

            for t in tf_map:
                index.setdefault(t, []).append(i)

        with self._index_lock:
            self._index       = index
            self._tf_maps     = tf_maps
            self._doc_lengths = doc_lengths

    def _extend_index(self, new_chunks: List[dict], start_idx: int) -> None:
        """
        Extend index incrementally for newly appended chunks.
        O(new_tokens) -- does not touch existing entries.
        Called by add_chunks() after chunks are already appended.
        """
        for i, chunk in enumerate(new_chunks):
            tokens = chunk["tokens"]
            dl     = len(tokens)

            tf_map: Dict[str, int] = {}
            for t in tokens:
                tf_map[t] = tf_map.get(t, 0) + 1

            chunk_idx = start_idx + i
            with self._index_lock:
                self._doc_lengths.append(dl)
                self._tf_maps.append(tf_map)
                for t in tf_map:
                    self._index.setdefault(t, []).append(chunk_idx)

    # ---------------------------------------------------------------- #
    #  Corpus mutation                                                   #
    # ---------------------------------------------------------------- #

    def reload(self) -> None:
        """Full reload from DB. Only called from pipeline.init()."""
        from storage import load_all_chunks

        chunks       = load_all_chunks()
        self._chunks = chunks
        self._avg_dl = _recalc_avg_dl(chunks)

        self._build_index()

        persisted = {
            c["id"]: c["embedding"]
            for c in chunks
            if c["embedding"] is not None
        }

        with self._embed_lock:
            self._version    += 1
            current_version   = self._version
            self._embeddings  = persisted
            self._embed_ready = bool(persisted)

        print(f"[retriever] reload: {len(chunks)} chunks, "
              f"{len(persisted)} embeddings persisted, "
              f"{len(self._index)} index terms")

        unembedded = [c for c in chunks if c["id"] not in persisted]
        if unembedded:
            threading.Thread(
                target=self._compute_embeddings,
                args=(current_version,),
                daemon=True,
            ).start()
        else:
            print("[retriever] all chunks already embedded")

    def add_chunks(self, new_chunks: List[dict]) -> None:
        """Append freshly ingested chunks. Extends the index incrementally."""
        if not new_chunks:
            return

        start_idx = len(self._chunks)
        self._chunks.extend(new_chunks)
        self._avg_dl = _recalc_avg_dl(self._chunks)

        self._extend_index(new_chunks, start_idx)

        with self._embed_lock:
            self._version   += 1
            current_version  = self._version

        threading.Thread(
            target=self._compute_embeddings,
            args=(current_version,),
            daemon=True,
        ).start()

    def remove_doc(self, doc_id: int) -> None:
        """
        Remove all chunks for doc_id and rebuild the index.
        Full rebuild is required because chunk indices shift on removal.
        """
        self._chunks = [c for c in self._chunks if c["doc_id"] != doc_id]
        self._avg_dl = _recalc_avg_dl(self._chunks)
        self._build_index()

        surviving_ids = {c["id"] for c in self._chunks}
        with self._embed_lock:
            self._version   += 1
            self._embeddings = {
                k: v for k, v in self._embeddings.items()
                if k in surviving_ids
            }
            self._embed_ready = bool(self._embeddings)

    def clear(self) -> None:
        """Reset everything in memory without touching the DB."""
        self._chunks = []
        self._avg_dl = 1.0
        with self._index_lock:
            self._index       = {}
            self._tf_maps     = []
            self._doc_lengths = []
        with self._embed_lock:
            self._version    += 1
            self._embeddings  = {}
            self._embed_ready = False

    def is_empty(self) -> bool:
        return not self._chunks

    # ---------------------------------------------------------------- #
    #  Background embedding                                              #
    # ---------------------------------------------------------------- #

    def _compute_embeddings(self, version: int) -> None:
        """
        Background thread: embed unembedded chunks, persist each to DB,
        update in-memory cache. Version guard aborts stale threads.
        """
        try:
            from llm import get_embedding
            from storage import save_chunk_embedding

            with self._embed_lock:
                if self._version != version:
                    return
                already_have = set(self._embeddings.keys())

            chunks_to_embed = [
                c for c in self._chunks
                if c["id"] not in already_have
            ]

            if not chunks_to_embed:
                with self._embed_lock:
                    self._embed_ready = True
                return

            print(f"[retriever] embedding {len(chunks_to_embed)} chunk(s) "
                  f"(version={version})")

            computed: Dict[int, list] = {}

            for c in chunks_to_embed:
                with self._embed_lock:
                    if self._version != version:
                        print(f"[retriever] embed thread v{version} superseded — stopping")
                        return

                emb = get_embedding(c["text"][:300])

                if emb is None:
                    print("[retriever] embedding endpoint unavailable — "
                          "falling back to BM25+TF-IDF")
                    return

                computed[c["id"]] = emb
                try:
                    save_chunk_embedding(c["id"], emb)
                except Exception as db_exc:
                    print(f"[retriever] failed to persist embedding "
                          f"for chunk {c['id']}: {db_exc}")

            with self._embed_lock:
                if self._version != version:
                    print(f"[retriever] embed thread v{version} superseded "
                          f"before cache commit — discarding")
                    return
                self._embeddings.update(computed)
                self._embed_ready = True

            print(f"[retriever] embeddings ready "
                  f"({len(computed)} new, {len(self._embeddings)} total)")

        except Exception as exc:
            print(f"[retriever] embedding computation failed: {exc}")

    # ---------------------------------------------------------------- #
    #  Scoring                                                           #
    # ---------------------------------------------------------------- #

    def _bm25_scores_sparse(
        self, query_tokens: List[str]
    ) -> Dict[int, float]:
        """
        BM25 using inverted index (Step 13).
        Returns sparse {chunk_idx: score} — only matched chunks.
        Unmatched chunks are not in the dict (implicitly zero).

        Complexity: O(matched_chunks x query_tokens)
        vs old:     O(all_chunks x query_tokens)
        """
        N = len(self._chunks)
        if N == 0:
            return {}

        scores: Dict[int, float] = {}

        with self._index_lock:
            index       = self._index
            tf_maps     = self._tf_maps
            doc_lengths = self._doc_lengths

        for qt in set(query_tokens):
            candidate_indices = index.get(qt, [])
            if not candidate_indices:
                continue

            df  = len(candidate_indices)
            idf = math.log((N - df + 0.5) / (df + 0.5) + 1.0)

            for i in candidate_indices:
                if i >= len(tf_maps):
                    continue   # index briefly ahead of tf_maps during add
                tf = tf_maps[i].get(qt, 0)
                if tf == 0:
                    continue
                dl = doc_lengths[i] or 1
                scores[i] = scores.get(i, 0.0) + idf * (
                    tf * (K1 + 1)
                    / (tf + K1 * (1 - B + B * dl / self._avg_dl))
                )

        return scores

    def _cosine_scores_candidates(
        self, query_tokens: List[str], candidate_indices: List[int]
    ) -> Dict[int, float]:
        """TF-IDF cosine for candidate subset only (Step 14)."""
        from collections import Counter
        tf    = Counter(query_tokens)
        total = len(query_tokens) or 1
        q_vec: Dict[str, float] = {t: cnt / total for t, cnt in tf.items()}

        return {
            i: _cosine_sparse(q_vec, self._chunks[i]["tfidf_vec"])
            for i in candidate_indices
            if i < len(self._chunks)
        }

    def _semantic_scores_candidates(
        self, query_text: str, candidate_indices: List[int]
    ) -> Optional[Dict[int, float]]:
        """
        Dense cosine for candidate subset (Step 14).
        Uses query embedding cache (Step 15) to avoid repeated HTTP calls.
        Returns None if Nomic is unavailable or embeddings not ready.
        """
        with self._embed_lock:
            if not self._embed_ready:
                return None
            embeddings = dict(self._embeddings)

        try:
            from llm import get_embedding

            # Step 15: cache check before HTTP call
            q_emb = _get_cached_query_embedding(query_text)
            if q_emb is None:
                q_emb = get_embedding(query_text[:300])
                if q_emb is None:
                    return None
                _set_cached_query_embedding(query_text, q_emb)

            scores: Dict[int, float] = {}
            for i in candidate_indices:
                if i >= len(self._chunks):
                    continue
                chunk_emb = embeddings.get(self._chunks[i]["id"])
                if chunk_emb is not None:
                    scores[i] = _cosine_dense(q_emb, chunk_emb)
            return scores

        except Exception as exc:
            print(f"[retriever] semantic query failed: {exc}")
            return None

    # ---------------------------------------------------------------- #
    #  Public query (Step 14: two-stage)                                #
    # ---------------------------------------------------------------- #

    def query(
        self, text: str, top_k: int = 4
    ) -> List[Tuple[str, float, int]]:
        """
        Two-stage retrieval:

        Stage 1: BM25 (index-based) selects top BM25_CANDIDATE_K chunks.
                 Only chunks matching at least one query token are scored.

        Stage 2: Semantic re-ranks the Stage 1 candidates (when available).
                 TF-IDF cosine also runs on candidates only.

        Final scores are combined, gated by RELEVANCE_THRESHOLD, and
        deduplicated before returning top_k results.

        Returns [] when nothing clears the relevance threshold.
        """
        if self.is_empty():
            return []

        q_tokens = tokenise(text)

        # ---- Stage 1: BM25 candidate selection ----
        bm25_sparse = self._bm25_scores_sparse(q_tokens) if q_tokens else {}
        bm25_ranked = sorted(
            bm25_sparse.items(), key=lambda x: x[1], reverse=True
        )
        candidate_indices: List[int] = [
            i for i, _ in bm25_ranked[:self.BM25_CANDIDATE_K]
        ]

        # Fallback: if BM25 found nothing (e.g. query tokens all filtered
        # as stopwords, or very short query), use all chunks for semantic.
        if not candidate_indices:
            if self._embed_ready:
                candidate_indices = list(range(len(self._chunks)))
            else:
                return []

        # ---- Stage 2: score candidates ----
        sem_sparse = self._semantic_scores_candidates(text, candidate_indices)

        # Normalise BM25 over candidates only
        if bm25_sparse and candidate_indices:
            cand_bm25_vals = [bm25_sparse.get(i, 0.0) for i in candidate_indices]
            norm_bm25      = _normalise_scores(cand_bm25_vals)
            bm25_norm_map  = dict(zip(candidate_indices, norm_bm25))
        else:
            bm25_norm_map = {}

        if q_tokens and candidate_indices:
            cos_sparse     = self._cosine_scores_candidates(q_tokens, candidate_indices)
            cand_cos_vals  = [cos_sparse.get(i, 0.0) for i in candidate_indices]
            cos_norm_map   = dict(zip(candidate_indices, _normalise_scores(cand_cos_vals)))
        else:
            cos_norm_map = {}

        if sem_sparse is not None and candidate_indices:
            cand_sem_vals  = [sem_sparse.get(i, 0.0) for i in candidate_indices]
            sem_norm_map   = dict(zip(candidate_indices, _normalise_scores(cand_sem_vals)))
        else:
            sem_norm_map = None

        # ---- Combine ----
        combined: List[Tuple[int, float]] = []
        for i in candidate_indices:
            b = bm25_norm_map.get(i, 0.0)
            c = cos_norm_map.get(i, 0.0)
            if sem_norm_map is not None:
                s     = sem_norm_map.get(i, 0.0)
                score = 0.30 * b + 0.20 * c + 0.50 * s
            else:
                score = self.alpha * b + (1.0 - self.alpha) * c
            combined.append((i, score))

        combined.sort(key=lambda x: x[1], reverse=True)

        if not combined:
            return []

        # ---- Relevance gate ----
        top_score = combined[0][1]
        if top_score < RELEVANCE_THRESHOLD:
            print(f"[retriever] best score {top_score:.3f} < "
                  f"threshold {RELEVANCE_THRESHOLD} — no relevant context")
            return []

        if len(combined) > 1:
            margin = top_score - combined[1][1]
            if top_score < (RELEVANCE_THRESHOLD * 2) and margin < MIN_MARGIN:
                print(f"[retriever] borderline result "
                      f"(score={top_score:.3f}, margin={margin:.3f})")

        # ---- Deduplicate and collect top_k ----
        seen_texts: Set[str] = set()
        top: List[Tuple[str, float, int]] = []

        for idx, score in combined:
            if score < RELEVANCE_THRESHOLD:
                break
            if idx >= len(self._chunks):
                continue
            txt = self._chunks[idx]["text"].strip()
            if txt in seen_texts:
                continue
            seen_texts.add(txt)
            top.append((txt, score, self._chunks[idx]["doc_id"]))
            if len(top) >= top_k:
                break

        return top