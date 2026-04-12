# O-RAG Android Backend Architecture

This document provides a detailed overview of the core Python files being utilized in the Android side of the O-RAG Flutter application. These scripts are run locally on the user's Android device through the **Chaquopy** runtime and manage the entirety of the local Retrieval-Augmented Generation (RAG) pipeline—from downloading offline models and ingesting documents, to performing hybrid similarity searches and generating AI responses.

All files discussed below are located in the `android/app/src/main/python/` directory.

### Core Interface
* **`api.py`**
  This is the primary gateway between the Dart (Flutter) UI and the underlying Python pipeline. It exports the functions invoked via Chaquopy for loading the pipeline, ingesting documents, listing/deleting documents, querying the AI (both direct and RAG mode), and managing generation stream callbacks. It heavily manages thread locks, memory and status tracking to prevent the Flutter UI from freezing.

### Setup and Lifecycle
* **`config.py`**
  A centralized file containing shared constants (like backend server ports, app name, system environment aliases).
  
* **`downloader.py`**
  Handles the automated download logic of the compressed GGUF models directly from Hugging Face into a writable local directory (`models/` folder). It includes routines for HTTP polling, chunking large binaries, and dispatching progress signals to the UI.
  
* **`pipeline.py`**
  Orchestrates the entire system. It acts as the "Controller" bridging `downloader`, `chunker`, `llm`, and `storage`. It is responsible for triggering database creation, initializing models, inserting chunks for retrieval, managing RAG queries, and dispatching requests directly to the LLM backend.

### Retrieval & Ingestion
* **`chunker.py`**
  A pure-Python document processor. It uses PyMuPDF (or `pypdf` on mobile) to extract plain text from PDFs or native URI contents on Android. The file handles naive sentence splitting, overlapping sequence chunking, tokenization, stopping words, and computation of the localized term-frequency (TF-IDF).
  
* **`retriever.py`**
  The search engine core. It implements a Hybrid Retriever employing:
  1. **BM25 algorithm** for probabilistic keyword matching.
  2. **TF-IDF mapping** via a sparse dot-cosine product computed from the metadata from `chunker.py`.
  3. **Semantic Dense Vectors** relying on the embeddings endpoint from the Nomic embedding server.
  Rankings are aggregated dynamically depending on offline hardware availability.

* **`storage.py`**
  A lightweight `SQLite3` store. Documents and their subdivided vector chunks are cached persistently using normalized schema relations, avoiding the necessity of heavy external vector-DB dependencies out-of-process.

* **`db.py`**
  A backwards-compatibility alias script serving only to re-export existing symbols from `storage.py` to legacy imports.

### Execution Backends (LLM)
* **`llm.py`**
  Abstracts away the execution of Large Language Models. In an Android context, the primary execution path defaults to the bundled ARM64 `llama-server.so` C++ binary running passively. This file ensures to launch the subprocess securely from the private Android `nativeLibraryDir` scope, ping health checks over sockets, and process raw HTTP completions with the server.

* **`runtime/` module**
  This module encapsulates the lower-level behaviors of starting sub-servers (`BootstrapCoordinator`) and defines the abstract factory pattern definitions (`LlamaModelRuntime`) which orchestrate whether a local model executes effectively.
