"""
chunker.py — Load .txt and .pdf files, split into overlapping chunks,
and compute per-chunk TF-IDF vectors (stored for hybrid retrieval).
No heavy NLP libraries — pure Python + PyMuPDF.
"""
import re
import math
from pathlib import Path
from typing import List, Dict, Tuple
from collections import Counter

# ---- optional PDF support (PyMuPDF or pypdf fallback) ----
try:
    import fitz  # PyMuPDF (desktop)
    PDF_SUPPORT  = True
    _PDF_BACKEND = "pymupdf"
except ImportError:
    try:
        import pypdf as _pypdf  # pure-Python fallback (Android)
        PDF_SUPPORT  = True
        _PDF_BACKEND = "pypdf"
    except ImportError:
        PDF_SUPPORT  = False
        _PDF_BACKEND = None


# ------------------------------------------------------------------ #
#  Constants                                                           #
# ------------------------------------------------------------------ #

CHUNK_SIZE    = 100   # tokens (approx words) per small chunk — smaller for embedding precision
CHUNK_OVERLAP = 20    # overlapping tokens between consecutive small chunks
PARENT_CHUNK_SIZE    = 400   # tokens per parent chunk for Small-to-Big expansion
PARENT_CHUNK_OVERLAP = 50    # overlap between parent chunks

# Minimal English stopwords (keeps index small)
_STOP = frozenset(
    "a an the is are was were be been being have has had do does did "
    "will would could should may might shall can of in on at to for "
    "from by with about as into through during including before after "
    "above below between each other than and or but not this that "
    "these those i me my we our you your he she it its they them their "
    "what which who whom when where why how all both each few more most "
    "other some such no nor only same so than too very just".split()
)


# ------------------------------------------------------------------ #
#  Text extraction                                                     #
# ------------------------------------------------------------------ #

def _extract_txt(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def _extract_pdf(path: str) -> str:
    if not PDF_SUPPORT:
        raise RuntimeError(
            "No PDF library available. Install pymupdf or pypdf."
        )
    if _PDF_BACKEND == "pymupdf":
        doc = fitz.open(path)
        pages = [page.get_text("text") for page in doc]
        doc.close()
        return "\n".join(pages)
    else:
        # pypdf fallback
        reader = _pypdf.PdfReader(path)
        return "\n".join(
            (p.extract_text() or "") for p in reader.pages
        )


def resolve_uri(path: str) -> str:
    """
    On Android, plyer.filechooser returns a content:// URI instead of a
    real file path.  Copy the content into app-private storage and return
    the real path so Python's open() / pypdf can read it.
    On all other platforms (or if path is already a file path) returns path
    unchanged.
    """
    import os
    if not path:
        raise ValueError("resolve_uri received an empty/None path")
    if not path.startswith("content://"):
        return path
    try:
        from jnius import autoclass  # type: ignore
        PythonActivity   = autoclass("org.kivy.android.PythonActivity")
        Uri              = autoclass("android.net.Uri")
        ctx = PythonActivity.mActivity
        uri = Uri.parse(path)
        # Get the display name from the content resolver
        name = "attachment"
        cursor = ctx.getContentResolver().query(uri, None, None, None, None)
        if cursor:
            try:
                if cursor.moveToFirst():
                    idx = cursor.getColumnIndex("_display_name")
                    if idx >= 0:
                        name = cursor.getString(idx)
            finally:
                cursor.close()
        # Copy bytes to private storage.
        # Use getFd() + os.dup() so Python owns its own fd while the
        # PFD is closed normally — avoids IllegalStateException from
        # calling close() after detachFd().
        dest_dir = os.path.join(
            os.environ.get("ANDROID_PRIVATE", "/tmp"), "attachments"
        )
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, name)
        pfd = ctx.getContentResolver().openFileDescriptor(uri, "r")
        if pfd is None:
            raise RuntimeError(f"openFileDescriptor returned None for URI: {path}")
        try:
            fd_dup = os.dup(pfd.getFd())     # duplicate — Python owns this fd
            # Stream in 1 MB chunks to avoid OOM on large PDFs
            with os.fdopen(fd_dup, "rb") as src_f, open(dest, "wb") as out_f:
                while True:
                    chunk = src_f.read(1 * 1024 * 1024)
                    if not chunk:
                        break
                    out_f.write(chunk)
        finally:
            pfd.close()                      # safe: pfd still owns the original fd
        return dest
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise RuntimeError(f"Could not read file from device: {e}") from e


def extract_text(path: str) -> str:
    """Return plain text from .txt or .pdf file (resolves content:// URIs)."""
    path = resolve_uri(path)
    ext = Path(path).suffix.lower()
    if ext == ".pdf":
        return _extract_pdf(path)
    return _extract_txt(path)


# ------------------------------------------------------------------ #
#  Tokenisation                                                        #
# ------------------------------------------------------------------ #

_RE_WORD = re.compile(r"[a-z0-9]+")


def tokenise(text: str) -> List[str]:
    """Lowercase, strip punctuation, remove stopwords."""
    raw = _RE_WORD.findall(text.lower())
    return [t for t in raw if t not in _STOP and len(t) > 1]


# ------------------------------------------------------------------ #
#  Chunking                                                            #
# ------------------------------------------------------------------ #

def _split_sentences(text: str) -> List[str]:
    """Sentence splitter that avoids breaking on common abbreviations.

    Uses a negative lookbehind so that 'Dr. Smith', 'e.g. this', 'U.S. Army',
    'Ph.D. program' etc. are not incorrectly split into separate sentences.
    Falls back gracefully if the regex engine rejects the pattern.
    """
    try:
        # Negative lookbehind: don't split after known abbreviations
        abbrev_pattern = (
            r'(?<!'
            r'(?:Dr|Mr|Mrs|Ms|Prof|St|vs|etc|e\.g|i\.e|U\.S|Ph\.D|Fig|No|Vol|approx|dept)'
            r')'
        )
        parts = re.split(abbrev_pattern + r'(?<=[.!?])\s+(?=[A-Z\"\'])', text.strip())
        return [p.strip() for p in parts if p.strip()]
    except re.error:
        # Fallback to naive split if lookbehind fails
        parts = re.split(r'(?<=[.!?])\s+', text.strip())
        return [p.strip() for p in parts if p.strip()]


def chunk_text(text: str, preamble_chars: int = 200) -> List[str]:
    """
    Split text into overlapping chunks of ~CHUNK_SIZE words.
    Prepends the document preamble (first preamble_chars characters) to every
    chunk after the first, so metadata like title/author is always retrievable.
    Returns list of raw (un-tokenised) chunk strings.
    """
    preamble = text[:preamble_chars].strip()
    words = text.split()
    chunks: List[str] = []
    start = 0
    while start < len(words):
        end = min(start + CHUNK_SIZE, len(words))
        chunk_body = " ".join(words[start:end])
        # Prepend preamble to every chunk after the first so document
        # metadata (title, author, etc.) is always findable by retrieval.
        if start > 0 and preamble:
            chunk = f"[Document Info: {preamble}]\n\n{chunk_body}"
        else:
            chunk = chunk_body
        chunks.append(chunk)
        if end == len(words):
            break
        start += CHUNK_SIZE - CHUNK_OVERLAP
    return chunks


def chunk_text_semantic(
    text: str,
    target_size: int = CHUNK_SIZE,
    preamble_chars: int = 200,
) -> List[str]:
    """
    Sentence-boundary chunker — never cuts mid-sentence.

    Groups sentences until ~target_size words is reached, then starts a new
    chunk keeping the last 2 sentences as overlap for context continuity.
    Falls back to word-split chunking if sentence splitting yields nothing.
    """
    preamble = text[:preamble_chars].strip()
    sentences = _split_sentences(text)
    if not sentences:
        return chunk_text(text, preamble_chars)  # graceful fallback

    max_size = int(target_size * 1.5)  # allow up to 150 words before forcing a split
    chunks: List[str] = []
    current: List[str] = []
    current_len: int = 0

    for sent in sentences:
        sent_len = len(sent.split())
        if current_len + sent_len > max_size and current:
            chunk_body = " ".join(current)
            chunk = (
                f"[Document Info: {preamble}]\n\n{chunk_body}"
                if chunks and preamble
                else chunk_body
            )
            chunks.append(chunk)
            # Overlap: keep last 2 sentences for continuity
            current = current[-2:]
            current_len = sum(len(s.split()) for s in current)
        current.append(sent)
        current_len += sent_len

    if current:
        chunk_body = " ".join(current)
        chunk = (
            f"[Document Info: {preamble}]\n\n{chunk_body}"
            if chunks and preamble
            else chunk_body
        )
        chunks.append(chunk)

    return chunks if chunks else [text]


# ------------------------------------------------------------------ #
#  TF-IDF helpers                                                      #
# ------------------------------------------------------------------ #

def _compute_tf(tokens: List[str]) -> Dict[str, float]:
    counts = Counter(tokens)
    total = len(tokens) or 1
    return {term: cnt / total for term, cnt in counts.items()}


def compute_tfidf_vecs(
    all_token_lists: List[List[str]],
) -> Tuple[List[Dict[str, float]], Dict[str, float]]:
    """
    Compute TF-IDF for each chunk.
    Returns (list_of_tfidf_dicts, idf_dict).
    """
    N = len(all_token_lists)
    # Document frequency
    df: Dict[str, int] = {}
    for toks in all_token_lists:
        for t in set(toks):
            df[t] = df.get(t, 0) + 1

    idf: Dict[str, float] = {
        t: math.log((N + 1) / (cnt + 1)) + 1.0
        for t, cnt in df.items()
    }

    vecs = []
    for toks in all_token_lists:
        tf = _compute_tf(toks)
        vecs.append({t: tf[t] * idf[t] for t in tf})
    return vecs, idf


# ------------------------------------------------------------------ #
#  Public API                                                          #
# ------------------------------------------------------------------ #

def process_document(path: str) -> List[dict]:
    """
    Full pipeline: extract → chunk → tokenise → TF-IDF.

    Returns list of chunk dicts:
        {chunk_idx, text, tokens, tfidf_vec}
    """
    raw_text   = extract_text(path)
    raw_chunks = chunk_text_semantic(raw_text)
    token_lists = [tokenise(c) for c in raw_chunks]
    tfidf_vecs, _ = compute_tfidf_vecs(token_lists)

    result = []
    for idx, (text, tokens, vec) in enumerate(
        zip(raw_chunks, token_lists, tfidf_vecs)
    ):
        result.append(
            {
                "chunk_idx": idx,
                "text": text,
                "tokens": tokens,
                "tfidf_vec": vec,
            }
        )
    return result


def _chunk_text_sized(text: str, size: int, overlap: int,
                     preamble_chars: int = 200) -> List[str]:
    """Generic chunker with configurable size and overlap."""
    preamble = text[:preamble_chars].strip()
    words = text.split()
    chunks: List[str] = []
    start = 0
    while start < len(words):
        end = min(start + size, len(words))
        chunk_body = " ".join(words[start:end])
        if start > 0 and preamble:
            chunk = f"[Document Info: {preamble}]\n\n{chunk_body}"
        else:
            chunk = chunk_body
        chunks.append(chunk)
        if end == len(words):
            break
        start += size - overlap
    return chunks


def process_document_hierarchical_from_text(
    raw_text: str,
) -> Tuple[List[dict], List[dict]]:
    """
    Small-to-Big pipeline operating on already-extracted text.

    Identical to process_document_hierarchical() but accepts the raw text
    string directly instead of a file path — avoids reading the file a
    second time when the caller (pipeline.ingest_document) has already
    extracted the text once.

    Returns (small_chunks, parent_chunks) — same contract as the path-based
    variant.
    """
    # Generate parent (big) chunks
    raw_parents = _chunk_text_sized(
        raw_text, PARENT_CHUNK_SIZE, PARENT_CHUNK_OVERLAP, preamble_chars=200
    )
    parent_chunks = [
        {"parent_chunk_idx": idx, "text": text}
        for idx, text in enumerate(raw_parents)
    ]

    # Generate small chunks
    raw_smalls = chunk_text_semantic(raw_text)
    token_lists = [tokenise(c) for c in raw_smalls]
    tfidf_vecs, _ = compute_tfidf_vecs(token_lists)

    # Map each small chunk to its parent by word position overlap
    parent_word_ranges = []
    words_all = raw_text.split()
    pos = 0
    for pidx in range(len(raw_parents)):
        end_pos = min(pos + PARENT_CHUNK_SIZE, len(words_all))
        parent_word_ranges.append((pos, end_pos))
        if end_pos >= len(words_all):
            break
        pos += PARENT_CHUNK_SIZE - PARENT_CHUNK_OVERLAP

    small_chunks = []
    small_pos = 0
    for idx, (text, tokens, vec) in enumerate(
        zip(raw_smalls, token_lists, tfidf_vecs)
    ):
        small_end = min(small_pos + CHUNK_SIZE, len(words_all))
        small_mid = (small_pos + small_end) // 2

        parent_idx = 0
        for pidx, (pstart, pend) in enumerate(parent_word_ranges):
            if pstart <= small_mid < pend:
                parent_idx = pidx
                break

        small_chunks.append({
            "chunk_idx": idx,
            "text": text,
            "tokens": tokens,
            "tfidf_vec": vec,
            "parent_chunk_idx": parent_idx,
        })

        if small_end >= len(words_all):
            small_pos = small_end
        else:
            small_pos += CHUNK_SIZE - CHUNK_OVERLAP

    return small_chunks, parent_chunks


def process_document_hierarchical(path: str) -> Tuple[List[dict], List[dict]]:
    """
    Small-to-Big pipeline: extract → small chunks + parent chunks → TF-IDF.

    Returns (small_chunks, parent_chunks) where:
    - small_chunks: list of {chunk_idx, text, tokens, tfidf_vec, parent_chunk_idx}
    - parent_chunks: list of {parent_chunk_idx, text}

    Small chunks (100 words) are embedded and indexed for retrieval.
    Parent chunks (400 words) provide expanded context for the LLM.
    Each small chunk maps to its enclosing parent chunk.
    """
    raw_text = extract_text(path)

    # Generate parent (big) chunks
    raw_parents = _chunk_text_sized(
        raw_text, PARENT_CHUNK_SIZE, PARENT_CHUNK_OVERLAP, preamble_chars=200
    )
    parent_chunks = [
        {"parent_chunk_idx": idx, "text": text}
        for idx, text in enumerate(raw_parents)
    ]

    # Generate small chunks
    raw_smalls = chunk_text_semantic(raw_text)
    token_lists = [tokenise(c) for c in raw_smalls]
    tfidf_vecs, _ = compute_tfidf_vecs(token_lists)

    # Map each small chunk to its parent by word position overlap
    parent_word_ranges = []
    words_all = raw_text.split()
    pos = 0
    for pidx in range(len(raw_parents)):
        end_pos = min(pos + PARENT_CHUNK_SIZE, len(words_all))
        parent_word_ranges.append((pos, end_pos))
        if end_pos >= len(words_all):
            break
        pos += PARENT_CHUNK_SIZE - PARENT_CHUNK_OVERLAP

    small_chunks = []
    small_pos = 0
    for idx, (text, tokens, vec) in enumerate(
        zip(raw_smalls, token_lists, tfidf_vecs)
    ):
        small_end = min(small_pos + CHUNK_SIZE, len(words_all))
        small_mid = (small_pos + small_end) // 2

        # Find the parent whose range contains this small chunk's midpoint
        parent_idx = 0
        for pidx, (pstart, pend) in enumerate(parent_word_ranges):
            if pstart <= small_mid < pend:
                parent_idx = pidx
                break

        small_chunks.append({
            "chunk_idx": idx,
            "text": text,
            "tokens": tokens,
            "tfidf_vec": vec,
            "parent_chunk_idx": parent_idx,
        })

        if small_end >= len(words_all):
            small_pos = small_end
        else:
            small_pos += CHUNK_SIZE - CHUNK_OVERLAP

    return small_chunks, parent_chunks


