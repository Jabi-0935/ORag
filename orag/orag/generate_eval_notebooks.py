import argparse
import json
import os

def create_notebook_structure(notebook_name, backend_path, test_docs, test_queries):
    """
    Creates a Jupyter Notebook dictionary structure manually to avoid requiring nbformat.
    """
    cells = []

    def add_md(text):
        cells.append({
            "cell_type": "markdown",
            "metadata": {},
            "source": [line + "\n" for line in text.splitlines()]
        })

    def add_code(text):
        cells.append({
            "cell_type": "code",
            "execution_count": None,
            "metadata": {},
            "outputs": [],
            "source": [line + "\n" if not line.endswith("\n") else line for line in text.splitlines()]
        })

    # Header Markdown
    add_md(f"# RAG Evaluation Notebook: {notebook_name}\n\nAutomated evaluation notebook for the ORag Python backend.")

    # Cell 1: Setup Path
    add_code(f'''import sys
import os
import json

# Add the local Android Python source path so we can import the RAG pipeline backend directly
backend_path = os.path.abspath(r"{backend_path}")
if backend_path not in sys.path:
    sys.path.append(backend_path)

from api import upload_document, chat, ask_rag, get_status
from pipeline import init as init_pipeline
from storage import init_db
from config import CHUNK_SIZE

print(f"Loaded ORag backend from: {{backend_path}}")
''')

    # Cell 2: Initialization
    add_md("## 1. System Initialization\nInitialize the database and load models (if running locally natively). Note: If you do not have llama-cpp-python working on this system natively, you might see failures here.")
    add_code('''# Initialize Database
init_db()
print("Database initialized.")

# Initialize pipeline (loads Qwen/Nomic models if available)
# Uncomment the line below to load models into memory locally before querying.
# init_pipeline()
print("Pipeline ready.")
''')

    # Cell 3: Upload Documents
    add_md("## 2. Ingest Test Documents")
    
    if test_docs:
        doc_str = "\n".join([f"res = upload_document(r'{d}')\nprint(res)" for d in test_docs])
    else:
        doc_str = "res = upload_document('path/to/your/document.pdf')\nprint(res)"
        
    add_code(f'''# Upload Test Documents
{doc_str}
''')

    # Cell 4: Queries
    add_md("## 3. Run Queries & Evaluate")
    
    class MockCallback:
        def invoke(self, cb):
            pass

    if test_queries:
        q_code = "\n".join([
            f'''print(f"\\n--- Query: {q} ---")
ans = ask_rag("{q}", None)
print(ans)''' for q in test_queries
        ])
    else:
        q_code = '''query = "What is the main topic of the document?"
print(f"\\n--- Query: {query} ---")
ans = ask_rag(query, None)
print(ans)'''

    add_code(q_code)

    # Footer metrics
    add_md("## 4. Evaluation Notes & Metrics\n* **Latency**: \n* **Relevance**: \n* **Hallucination Level**: ")

    notebook = {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3",
                "language": "python",
                "name": "python3"
            },
            "language_info": {
                "codemirror_mode": {"name": "ipython", "version": 3},
                "file_extension": ".py",
                "mimetype": "text/x-python",
                "name": "python",
                "nbconvert_exporter": "python",
                "pygments_lexer": "ipython3",
                "version": "3.8.0"
            }
        },
        "nbformat": 4,
        "nbformat_minor": 4
    }

    return notebook

def main():
    parser = argparse.ArgumentParser(description="Generate Evaluation Jupyter Notebooks for ORag")
    parser.add_argument("--count", type=int, default=1, help="Number of notebook variants to generate")
    parser.add_argument("--outdir", type=str, default="evaluation_notebooks", help="Output directory for the notebooks")
    parser.add_argument("--backend", type=str, default="orag/android/app/src/main/python", help="Path to the backend python files")
    parser.add_argument("--docs", type=str, nargs='*', default=[], help="List of documents to pre-fill in the ingest section")
    parser.add_argument("--queries", type=str, nargs='*', default=[], help="List of sample questions to ask")

    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    for i in range(args.count):
        file_name = f"eval_notebook_{i+1}.ipynb"
        out_path = os.path.join(args.outdir, file_name)
        
        # We can add variation mechanics here later based on iteration
        
        notebook_data = create_notebook_structure(
            notebook_name=file_name,
            backend_path=args.backend,
            test_docs=args.docs,
            test_queries=args.queries
        )
        
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(notebook_data, f, indent=2)
            
        print(f"Created {out_path}")

if __name__ == "__main__":
    main()
