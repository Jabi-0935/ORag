import re

with open(r'd:\Work\8th_Sem\ORagFlutter\orag\docs\content_v3.txt', 'r', encoding='utf-8') as f:
    text = f.read()

# Replace block formulas
text = text.replace(
    'IDF(t) = log((N + 1) / (df(t) + 1)) + 1',
    '\n$$IDF(t) = \\log\\left(\\frac{N + 1}{df(t) + 1}\\right) + 1$$\n'
)

text = text.replace(
    'TF-IDF(t, c) = (count(t, c) / |c|) × IDF(t)',
    '\n$$TF\\text{-}IDF(t, c) = \\frac{\\text{count}(t, c)}{|c|} \\times IDF(t)$$\n'
)

text = text.replace(
    'BM25(Q, D) = Σᵢ₌₁ⁿ IDF(qᵢ) · [f(qᵢ, D) · (k₁ + 1)] / [f(qᵢ, D) + k₁ · (1 - b + b · |D|/avgdl)]',
    '\n$$BM25(Q, D) = \\sum_{i=1}^{n} IDF(q_i) \\cdot \\frac{f(q_i, D) \\cdot (k_1 + 1)}{f(q_i, D) + k_1 \\cdot \\left(1 - b + b \\cdot \\frac{|D|}{avgdl}\\right)}$$\n'
)

text = text.replace(
    'IDF(qᵢ) = ln((N - n(qᵢ) + 0.5) / (n(qᵢ) + 0.5) + 1)',
    '\n$$IDF(q_i) = \\ln\\left(\\frac{N - n(q_i) + 0.5}{n(q_i) + 0.5} + 1\\right)$$\n'
)

text = text.replace(
    'cosine(q⃗, c⃗) = (q⃗ · c⃗) / (‖q⃗‖₂ · ‖c⃗‖₂)',
    '\n$$\\text{cosine}(\\vec{q}, \\vec{c}) = \\frac{\\vec{q} \\cdot \\vec{c}}{\\|\\vec{q}\\|_2 \\cdot \\|\\vec{c}\\|_2}$$\n'
)

text = text.replace(
    'wRRF(c) = w_dense / (k + rank_dense(c)) + w_sparse / (k + rank_sparse(c))',
    '\n$$wRRF(c) = \\frac{w_{\\text{dense}}}{k + \\text{rank}_{\\text{dense}}(c)} + \\frac{w_{\\text{sparse}}}{k + \\text{rank}_{\\text{sparse}}(c)}$$\n'
)

# Inline formulas
text = text.replace(
    'RRF(d) = Σ 1/(k + r(d))',
    '$RRF(d) = \\sum \\frac{1}{k + r(d)}$'
)

text = text.replace(
    'budget_chars = max(300, (n_ctx - max_tokens - 256) × 4)',
    '$budget\\_chars = \\max(300, (n\\_ctx - max\\_tokens - 256) \\times 4)$'
)

# Replace symbols
text = text.replace('M ∈ ℝᴺˣ⁷⁶⁸', '$M \\in \\mathbb{R}^{N \\times 768}$')
text = text.replace('‖M[i]‖₂', '$\\|M[i]\\|_2$')
text = text.replace('M_norm · q⃗_norm', '$M_{\\text{norm}} \\cdot \\vec{q}_{\\text{norm}}$')
text = text.replace('q⃗_norm', '$\\vec{q}_{\\text{norm}}$')
text = text.replace('O(N log N)', '$\\mathcal{O}(N \\log N)$')
text = text.replace('O(N)', '$\\mathcal{O}(N)$')
text = text.replace('O(N + k log k)', '$\\mathcal{O}(N + k \\log k)$')
text = text.replace('O(1)', '$\\mathcal{O}(1)$')

text = text.replace('q₁, q₂, ..., qₙ', '$q_1, q_2, \\dots, q_n$')
text = text.replace('f(qᵢ, D)', '$f(q_i, D)$')
text = text.replace('IDF(qᵢ)', '$IDF(q_i)$')
text = text.replace('n(qᵢ)', '$n(q_i)$')

text = text.replace('k₁ = 1.5', '$k_1 = 1.5$')
text = text.replace('k₁', '$k_1$')

text = text.replace('b = 0.75', '$b = 0.75$')
text = text.replace('b = 1.0', '$b = 1.0$')
text = text.replace('b = 0,', '$b = 0$,')

text = text.replace('w_dense = 0.7', '$w_{\\text{dense}} = 0.7$')
text = text.replace('w_sparse = 0.3', '$w_{\\text{sparse}} = 0.3$')

# Only replace standalone variables if they look like variables
text = text.replace(' w_dense ', ' $w_{\\text{dense}}$ ')
text = text.replace(' w_sparse ', ' $w_{\\text{sparse}}$ ')
text = text.replace(' k = 60 ', ' $k = 60$ ')
text = text.replace(' k = 60.', ' $k = 60$.')

text = text.replace('q⃗', '$\\vec{q}$')
text = text.replace('c⃗', '$\\vec{c}$')
text = text.replace('10⁻⁹', '$10^{-9}$')

text = text.replace('N < 5000', '$N < 5000$')
text = text.replace('N < 10,000', '$N < 10,000$')

text = text.replace('10–50×', '10–50$\\times$')
text = text.replace('3–5×', '3–5$\\times$')

# Fix code blocks
text = text.replace(
    'key = SHA256(query.strip().lower() + "|histlen=" + str(len(history)))[:16]',
    '\n```python\nkey = SHA256(query.strip().lower() + "|histlen=" + str(len(history)))[:16]\n```\n'
)

# Markdown headings
text = re.sub(r'^(I|II|III|IV|V|VI|VII|VIII|IX|X|XI|XII|XIII|XIV|XV|XVI|XVII)\.\s+(.*)$', r'## \1. \2', text, flags=re.MULTILINE)
text = re.sub(r'^([A-Z])\.\s+(.*)$', r'### \1. \2', text, flags=re.MULTILINE)

with open(r'd:\Work\8th_Sem\ORagFlutter\orag\docs\content_v3.md', 'w', encoding='utf-8') as f:
    f.write(text)
