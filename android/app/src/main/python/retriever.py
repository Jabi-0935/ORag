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

Changes from previous version
------------------------------
- Embedding persistence: computed embeddings are saved to DB immediately
  so they survive app restarts.  On reload() the DB-persisted embeddings
  are loaded into memory instead of being recomputed from scratch.
- Version guard: every background embed thread carries the _version token
  it was spawned with.  Before writing results it re-checks _version; if a
  newer reload/add has happened the thread discards its work silently.
  This prevents a slow old thread from overwriting fresher state.
- 30-chunk cap removed: all chunks without a persisted embedding are
  processed incrementally.  The version guard makes this safe.
- Incremental mutations: add_chunks() / remove_doc() / clear() replace
  full reload() at every call site except init().
- Score threshold: query() returns [] when the best score is below
  RELEVANCE_THRESHOLD, so the pipeline never injects irrelevant context.
- Embedding HTTP timeout reduced to 10 s (was 60 s in llm.get_embedding).
"""
from __future__ import annotations

import math
import threading
from typing import Dict, List, Optional, Tuple

from chunker import tokenise

# ------------------------------------------------------------------ #
#  BM25 parameters                                                     #
# ------------------------------------------------------------------ #
K1 = 1.5    # term-frequency saturation
B  = 0.75   # length normalisation weight

# ------------------------------------------------------------------ #
#  Retrieval quality gates                                             #
# ------------------------------------------------------------------ #
RELEVANCE_THRESHOLD = 0.15   # minimum combined score to be considered relevant
MIN_MARGIN          = 0.05   # top result must beat second result by at least this


# ------------------------------------------------------------------ #
#  Math helpers                                                        #
# ------------------------------------------------------------------ #

def _dot(a: Dict[str, float], b: Dict[str, float]) -> float:
    """Sparse dot product — iterates the smaller dict."""
    if len(a) > len(b):
        a, b = b, a
    return sum(a[t] * b[t] for t in a if t in b)


def _norm(v: Dict[str, float]) -> float:
    return math.sqrt(sum(x * x for x in v.values())) or 1.0


def _cosine_sparse(a: Dict[str, float], b: Dict[str, float]) -> float:
    return _dot(a, b) / (_norm(a) * _norm(b))


def _cosine_dense(a: list, b: list) -> float:
    """Cosine similarity between two dense float vectors (pure Python)."""
    dot = sum(x * y for x, y in zip(a, b))
    na  = math.sqrt(sum(x * x for x in a)) or 1.0
    nb  = math.sqrt(sum(x * x for x in b)) or 1.0
    return dot / (na * nb)


def _normalise_scores(scores: List[float]) -> List[float]:
    """Min-max normalise a list to [0, 1].  Returns zeros if all equal."""
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
    reload()              — full reload from DB (init only)
    add_chunks(chunks)    — append newly ingested chunks
    remove_doc(doc_id)    — drop all chunks for a deleted document
    clear()               — reset everything without a DB round-trip
    """

    def __init__(self, alpha: float = 0.5) -> None:
        """
        alpha: BM25/TF-IDF blend weight used when semantic is unavailable.
            alpha=1.0 → pure BM25
            alpha=0.0 → pure TF-IDF cosine
        """
        self.alpha = alpha

        # Core corpus state
        self._chunks:      List[dict]  = []   # {id, doc_id, text, tokens, tfidf_vec, embedding}
        self._avg_dl:      float       = 1.0  # average document (chunk) length in tokens

        # Semantic embedding cache  {chunk_id: list[float]}
        self._embeddings:  dict        = {}
        self._embed_lock               = threading.Lock()
        self._embed_ready: bool        = False

        # Version counter — incremented on every corpus mutation.
        # Background threads carry their birth version and abort if stale.
        self._version:     int         = 0

    # ---------------------------------------------------------------- #
    #  Corpus mutation                                                   #
    # ---------------------------------------------------------------- #

    def reload(self) -> None:
        """
        Full reload from the database.
        Should only be called from pipeline.init() — all other call
        sites should use add_chunks / remove_doc / clear.
        """
        from storage import load_all_chunks

        chunks = load_all_chunks()
        self._chunks  = chunks
        self._avg_dl  = _recalc_avg_dl(chunks)

        # Bootstrap embedding cache from DB-persisted values.
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
              f"{len(persisted)} embeddings already persisted")

        # Kick off background embedding for any chunks that still need it.
        unembedded = [c for c in chunks if c["id"] not in persisted]
        if unembedded:
            threading.Thread(
                target=self._compute_embeddings,
                args=(current_version,),
                daemon=True,
            ).start()
        else:
            print("[retriever] all chunks already embedded — skipping background job")

    def add_chunks(self, new_chunks: List[dict]) -> None:
        """
        Append freshly ingested chunks without rebuilding the entire corpus.
        Triggers a background embedding pass for the new chunks only.
        """
        if not new_chunks:
            return

        self._chunks.extend(new_chunks)
        self._avg_dl = _recalc_avg_dl(self._chunks)

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
        Remove all chunks belonging to doc_id from in-memory state.
        Called after a document is deleted from the DB.
        """
        self._chunks = [c for c in self._chunks if c["doc_id"] != doc_id]
        self._avg_dl = _recalc_avg_dl(self._chunks)

        surviving_ids = {c["id"] for c in self._chunks}
        with self._embed_lock:
            self._version   += 1
            # Prune embedding cache — don't hold vectors for deleted chunks.
            self._embeddings = {
                k: v for k, v in self._embeddings.items()
                if k in surviving_ids
            }
            self._embed_ready = bool(self._embeddings)

    def clear(self) -> None:
        """
        Reset everything in memory without touching the DB.
        Called by pipeline.clear_all_documents().
        """
        self._chunks  = []
        self._avg_dl  = 1.0
        with self._embed_lock:
            self._version   += 1
            self._embeddings = {}
            self._embed_ready = False

    def is_empty(self) -> bool:
        return not self._chunks

    # ---------------------------------------------------------------- #
    #  Background embedding                                              #
    # ---------------------------------------------------------------- #

    def _compute_embeddings(self, version: int) -> None:
        """
        Background thread: embed every chunk that doesn't yet have a
        persisted vector, then update the in-memory cache.

        version guard
        -------------
        The thread checks self._version before each HTTP call and before
        committing its batch to memory.  If the corpus has changed since
        this thread was spawned (version mismatch) the thread exits
        immediately and discards all computed results — the newer thread
        spawned by the mutation will handle those chunks.

        Persistence
        -----------
        Each embedding is saved to the DB immediately after computation
        so it survives app restarts.  A future reload() will load it
        from the DB directly, skipping the HTTP call.
        """
        try:
            from llm import get_embedding
            from storage import save_chunk_embedding

            # Snapshot the list of chunks that still need embedding.
            # We take this snapshot once; the version guard handles
            # any mutations that arrive while we're running.
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
                  f"in background (version={version})")

            computed: Dict[int, list] = {}

            for c in chunks_to_embed:
                # --- version check before each HTTP call ---
                with self._embed_lock:
                    if self._version != version:
                        print(f"[retriever] embed thread v{version} superseded "
                              f"by v{self._version} — stopping")
                        return

                emb = get_embedding(c["text"][:300])

                if emb is None:
                    # Nomic server not available — stop gracefully.
                    # BM25+TF-IDF will handle retrieval until it comes up.
                    print("[retriever] embedding endpoint unavailable — "
                          "falling back to BM25+TF-IDF")
                    return

                computed[c["id"]] = emb
                # Persist to DB immediately so restarts don't lose this work.
                try:
                    save_chunk_embedding(c["id"], emb)
                except Exception as db_exc:
                    print(f"[retriever] failed to persist embedding "
                          f"for chunk {c['id']}: {db_exc}")

            # --- final version check before updating in-memory cache ---
            with self._embed_lock:
                if self._version != version:
                    print(f"[retriever] embed thread v{version} superseded "
                          f"before cache commit — discarding results")
                    return
                self._embeddings.update(computed)
                self._embed_ready = True

            print(f"[retriever] semantic embeddings ready "
                  f"({len(computed)} new, "
                  f"{len(self._embeddings)} total)")

        except Exception as exc:
            print(f"[retriever] embedding computation failed: {exc}")

    # ---------------------------------------------------------------- #
    #  Scoring                                                           #
    # ---------------------------------------------------------------- #

    def _bm25_scores(self, query_tokens: List[str]) -> List[float]:
        """
        BM25 score for every chunk.
        O(chunks × query_tokens) — will be replaced by an inverted
        index in Phase 2 (Step 13).
        """
        N      = len(self._chunks)
        scores = []

        # Per-token IDF across the corpus
        idf: Dict[str, float] = {}
        for qt in set(query_tokens):
            df       = sum(1 for c in self._chunks if qt in c["tokens"])
            idf[qt]  = math.log((N - df + 0.5) / (df + 0.5) + 1.0)

        for chunk in self._chunks:
            tokens = chunk["tokens"]
            dl     = len(tokens) or 1

            # Build tf_map for this chunk
            tf_map: Dict[str, int] = {}
            for t in tokens:
                tf_map[t] = tf_map.get(t, 0) + 1

            score = 0.0
            for qt in query_tokens:
                if qt not in tf_map:
                    continue
                tf     = tf_map[qt]
                score += idf.get(qt, 0.0) * (
                    tf * (K1 + 1)
                    / (tf + K1 * (1 - B + B * dl / self._avg_dl))
                )
            scores.append(score)

        return scores

    def _cosine_scores(self, query_tokens: List[str]) -> List[float]:
        """TF-IDF sparse cosine score for every chunk."""
        from collections import Counter
        tf    = Counter(query_tokens)
        total = len(query_tokens) or 1
        q_vec: Dict[str, float] = {t: cnt / total for t, cnt in tf.items()}
        return [_cosine_sparse(q_vec, c["tfidf_vec"]) for c in self._chunks]

    def _semantic_scores(
        self, query_text: str
    ) -> Optional[List[float]]:
        """
        Return per-chunk cosine similarity against the query embedding,
        or None if embeddings are not ready or the server is down.
        """
        with self._embed_lock:
            if not self._embed_ready:
                return None
            embeddings = dict(self._embeddings)   # snapshot — don't hold lock

        try:
            from llm import get_embedding
            q_emb = get_embedding(query_text[:300])
            if q_emb is None:
                return None

            scores = []
            for c in self._chunks:
                chunk_emb = embeddings.get(c["id"])
                scores.append(
                    _cosine_dense(q_emb, chunk_emb) if chunk_emb else 0.0
                )
            return scores

        except Exception as exc:
            print(f"[retriever] semantic query failed: {exc}")
            return None

    # ---------------------------------------------------------------- #
    #  Public query                                                      #
    # ---------------------------------------------------------------- #

    def query(
        self, text: str, top_k: int = 4
    ) -> List[Tuple[str, float, int]]:
        """
        Return the top_k most relevant (chunk_text, score, doc_id) tuples.

        Returns an empty list when:
        - The corpus is empty.
        - No tokens can be extracted and semantic is unavailable.
        - The best combined score is below RELEVANCE_THRESHOLD (i.e. the
          query has no meaningful match — avoids hallucination from noise).
        """
        if self.is_empty():
            return []

        q_tokens = tokenise(text)
        sem      = self._semantic_scores(text)

        if not q_tokens and sem is None:
            return []

        # --- compute raw scores ---
        zeros = [0.0] * len(self._chunks)

        bm25 = self._bm25_scores(q_tokens) if q_tokens else zeros
        cos  = self._cosine_scores(q_tokens) if q_tokens else zeros

        bm25_n = _normalise_scores(bm25) if q_tokens else zeros
        cos_n  = _normalise_scores(cos)  if q_tokens else zeros

        if sem is not None:
            sem_n    = _normalise_scores(sem)
            combined = [
                (i, 0.30 * b + 0.20 * c + 0.50 * s)
                for i, (b, c, s) in enumerate(zip(bm25_n, cos_n, sem_n))
            ]
        else:
            # Semantic not ready — fall back to BM25 + TF-IDF blend
            combined = [
                (i, self.alpha * b + (1.0 - self.alpha) * c)
                for i, (b, c) in enumerate(zip(bm25_n, cos_n))
            ]

        combined.sort(key=lambda x: x[1], reverse=True)

        if not combined:
            return []

        # --- relevance gate ---
        top_score = combined[0][1]

        if top_score < RELEVANCE_THRESHOLD:
            print(f"[retriever] best score {top_score:.3f} < threshold "
                  f"{RELEVANCE_THRESHOLD} — no relevant context found")
            return []

        # Optional margin check: if corpus has more than one chunk and the
        # top result barely beats the second, it's a weak signal.
        if len(combined) > 1:
            margin = top_score - combined[1][1]
            if top_score < (RELEVANCE_THRESHOLD * 2) and margin < MIN_MARGIN:
                print(f"[retriever] low-confidence result "
                      f"(score={top_score:.3f}, margin={margin:.3f}) — "
                      f"returning anyway but score is borderline")
                # We log but still return — a borderline result is better
                # than nothing when the score exceeds the hard threshold.

        # --- deduplicate and collect top_k ---
        seen_texts: set = set()
        top: List[Tuple[str, float, int]] = []

        for idx, score in combined:
            # Skip chunks below threshold (list is sorted, so we can break)
            if score < RELEVANCE_THRESHOLD:
                break
            txt = self._chunks[idx]["text"].strip()
            if txt in seen_texts:
                continue
            seen_texts.add(txt)
            top.append((txt, score, self._chunks[idx]["doc_id"]))
            if len(top) >= top_k:
                break

        return top