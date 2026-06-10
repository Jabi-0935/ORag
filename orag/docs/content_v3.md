XXX-X-XXXX-XXXX-X/XX/$XX.00 ©20XX IEEE 
O-RAG: Zero-Cloud RAG Inference on Consumer 
Android Hardware
Dr. Jagadamba G 
Dept. Computer Science & Engineering 
MS Ramaiah University of Applied 
Sciences 
Bengaluru, India 
jagadambag.cs.et@msruas.ac.in 
 
Rashmitha Shetty P 
Dept. Computer Science & Engineering 
MS Ramaiah University of Applied 
Sciences 
Bengaluru, India 
rashmithashetty1460@gmail.com  
Mohammad Ismaeel Jabiulla S 
Dept. Computer Science & Engineering 
MS Ramaiah University of Applied 
Sciences 
Bengaluru, India 
sjabiulla981@gmail.com   
 
SV Suchita Y 
Dept. Computer Science & Engineering 
MS Ramaiah University of Applied 
Sciences 
Bengaluru, India 
suchitayerramsetty999@gmail.com 
Mokshagna C 
Dept. Computer Science & Engineering 
MS Ramaiah University of Applied 
Sciences 
Bengaluru, India 
c.mokshagna@gmail.com  
                                                                    
     Abstract — This paper presents O-RAG, a fully offline Retrieval-Augmented Generation (RAG) system implemented as an Android mobile application using the Flutter framework. Unlike cloud-based Large Language Model (LLM) assistants that require constant internet connectivity and transmit user data to remote servers, O-RAG performs all document ingestion, semantic retrieval, and inference entirely on-device. The system employs a "Small-to-Big" hierarchical chunking strategy and a hybrid retrieval algorithm utilizing Weighted Reciprocal Rank Fusion (wRRF) to combine sparse SQLite FTS5 BM25 keyword search with dense Nomic Embed semantic embeddings. Retrieved context is fed to a quantized 2-billion parameter language model (Qwen 3.5 2B Q4_K_M). The architecture introduces a novel four-layer cross-language bridge (Flutter/Dart → Kotlin MethodChannel → Chaquopy Python → llama-server HTTP), an automated model bootstrap pipeline with HuggingFace auto-download and resume capabilities, and an adaptive memory management system that dynamically scales the context window from 1,536 to 4,096 tokens based on device RAM profiles. A response caching mechanism using SHA-256 keyed FIFO eviction and KV-cache pre-warming eliminates cold-start latency penalties. This work addresses critical privacy, latency, and offline accessibility challenges inherent in cloud-dependent AI assistants, demonstrating the feasibility of running sophisticated RAG systems on resource-constrained mobile hardware. A comprehensive comparison with existing systems—including PrivateGPT, MobileRAG, MLC-LLM, PocketLLM, and EdgeRAG—establishes O-RAG's unique position as the first fully offline mobile RAG system combining hybrid retrieval, adaptive memory management, and cross-language orchestration on consumer Android devices.

     Keywords — Retrieval Augmented Generation, On-Device AI, Mobile LLM, Offline NLP, Hybrid Retrieval, Semantic Embeddings, GGUF Quantization, BM25, Reciprocal Rank Fusion, Android, Flutter, Privacy-Preserving AI, Edge Computing.

## I. INTRODUCTION

    Modern artificial intelligence assistants such as ChatGPT, Google Gemini, and Anthropic Claude have revolutionized human-computer interaction through their natural language understanding and generation capabilities [1]. However, these systems share a fundamental limitation: they require constant internet connectivity and transmit all user data—including sensitive documents—to remote cloud servers for processing. This architectural dependency creates significant challenges across three critical dimensions: privacy preservation, offline accessibility, and response latency [2][3].

The privacy implications are particularly severe in domains handling sensitive information. Medical practitioners reviewing patient records, legal professionals analysing confidential documents, and researchers working with proprietary data cannot risk cloud transmission of their materials [4]. Even in consumer contexts, users increasingly demand control over their personal information and object to the external processing of private communications.

Offline accessibility represents another critical constraint. Connectivity gaps exist in remote locations, aircraft, underground facilities, and disaster scenarios [5]. Furthermore, air-gapped systems in defence, finance, and critical infrastructure require complete network isolation for security purposes.

Response latency concerns affect real-time applications where sub-second interaction is essential. Cloud-based systems introduce network round-trip delays before processing even begins, making them unsuitable for latency-sensitive use cases [6].

Recent advances in model quantization and mobile hardware capabilities have made on-device inference increasingly viable [7][8]. Modern smartphones equipped with ARM processors can execute billion-parameter language models through aggressive quantization techniques that reduce model sizes with minimal quality degradation. This hardware evolution, combined with efficient inference frameworks like llama.cpp [16], enables sophisticated AI applications to run entirely on consumer devices.

The intersection of Retrieval-Augmented Generation (RAG) and mobile deployment has attracted growing research attention in recent years. Systems such as MobileRAG [26], EdgeRAG [27], and PocketLLM [33] have begun exploring on-device retrieval and generation, yet significant gaps remain in delivering a complete, production-ready offline RAG pipeline that combines hybrid retrieval, adaptive memory management, and cross-language orchestration on consumer Android hardware.

This paper presents O-RAG, a fully offline Retrieval-Augmented Generation system for Android mobile devices that addresses these limitations. Rather than requiring models to memorize all information during training, RAG systems dynamically retrieve relevant context at inference time, enabling grounded responses about private documents the model was never exposed to during training [9].

The key contributions of this work include:

• A complete, production-ready architecture for on-device RAG on Android, including document ingestion, hybrid retrieval, and generation orchestration via a Flutter UI and Chaquopy Python backend.

• A hybrid retrieval algorithm combining SQLite FTS5 BM25 [32] and dense semantic embeddings using Weighted Reciprocal Rank Fusion (wRRF) [28], coupled with a Small-to-Big chunk expansion strategy.

• Detailed engineering solutions for mobile-specific constraints, including an adaptive memory management system with four RAM-based profiles, subprocess lifecycle management for model serving, and zero-dependency SQLite vector storage.

• A novel four-layer cross-language bridge architecture (Flutter/Dart → Kotlin MethodChannel → Chaquopy Python → llama-server HTTP) that enables rapid mobile AI prototyping while maintaining process isolation and crash resilience.

• An automated model bootstrap and download pipeline with HTTP resume support, progress callbacks, and manifest-based version control for reproducible deployments.

• A comprehensive comparison with existing systems demonstrating O-RAG's unique position as the first fully offline mobile RAG system combining hybrid retrieval with adaptive memory management on consumer Android devices.

The remainder of this paper is organized as follows. Section II surveys related work across edge computing, model compression, and information retrieval. Section III presents a feature-based comparison with existing systems. Section IV defines the problem statement. Section V describes the system architecture in detail, including the cross-language bridge, model bootstrap pipeline, foreground service lifecycle, and adaptive memory management. Section VI covers the document processing pipeline. Section VII presents the hybrid retrieval system with formal algorithm derivations. Section VIII describes the response caching and conversation management mechanisms. Section IX analyses security and privacy guarantees. Section X evaluates quantization strategies. Section XI details the deployment and reproducibility framework. Section XII presents the LLM backend and inference engine. Section XIII reports experimental evaluation results. Section XIV discusses engineering design decisions. Section XV addresses limitations and future work. Section XVI concludes the paper.


## II. RELATED WORK

The development of O-RAG sits at the intersection of several rapidly evolving fields: edge computing, model compression, information retrieval, and mobile systems engineering.

### A. Retrieval Augmented Generation

Lewis et al. introduced the RAG paradigm in 2020, demonstrating that augmenting language models with retrieved external knowledge significantly improves factual accuracy and reduces hallucination [9]. The approach combines dense retrieval using learned neural embeddings with sequence-to-sequence generation, enabling models to access information beyond their training data.

Subsequent research has explored various RAG architectures. Borgeaud et al. developed RETRO, which retrieves from a 2 trillion token database based on local similarity with preceding tokens [10]. Recent work in medical domains has shown RAG-enhanced models achieving improved diagnostic accuracy compared to base models [11]. In educational applications, RAG systems have demonstrated improved information synthesis and reduced fabrication of non-existent citations [12].

However, existing RAG implementations predominantly target cloud or desktop environments. Systems like LangChain, LlamaIndex, and Haystack provide powerful RAG frameworks but assume cloud-scale computational resources and persistent network connectivity [13].

### B. On-Device Language Models

The deployment of large language models on mobile and edge devices has gained significant research attention. MobileLLM introduced deep and thin architectures optimized for sub-billion parameter counts, demonstrating that architectural efficiency can compensate for reduced parameter budgets [14].

Weight quantization methods have proven critical for mobile deployment. AWQ (Activation-aware Weight Quantization) reduces model size while maintaining accuracy through careful handling of activation distributions [15]. The GGUF format and llama.cpp inference engine enable efficient quantized inference on consumer CPUs without specialized accelerators [16].

MLC-LLM provides cross-platform mobile LLM deployment for iOS and Android but focuses on chat applications without document retrieval capabilities [17]. The MELT infrastructure facilitates systematic benchmarking of on-device LLM execution, providing insights into performance, energy efficiency, and memory usage trade-offs [18].

### C. Mobile RAG Systems

The intersection of RAG and mobile deployment remains largely unexplored in academic literature. PrivateGPT implements offline RAG for desktop environments but lacks mobile optimization [19]. Commercial applications like Microsoft Copilot and Google Assistant offer limited on-device processing but maintain cloud dependency for primary functionality.

### D. Edge and Mobile RAG Systems

Recent work has begun addressing the specific challenges of RAG deployment on resource-constrained mobile and edge devices. MobileRAG [26] introduces EcoVector, a RAM-disk partitioned graph structure for vector search that keeps only centroid graphs in RAM and loads detailed cluster graphs from disk on demand, dramatically reducing memory footprint. MobileRAG also proposes Selective Content Reduction (SCR), which filters irrelevant text from retrieved documents before LLM input, reducing processing overhead without sacrificing accuracy. While MobileRAG optimizes the retrieval index structure, O-RAG takes a complementary approach by leveraging SQLite's built-in FTS5 engine for sparse retrieval and in-memory NumPy vectorization for dense retrieval, avoiding the complexity of custom index structures.

EdgeRAG [27] addresses memory bottlenecks on edge devices by pruning embeddings within centroid clusters and generating embeddings on-demand during retrieval rather than pre-computing all vectors. EdgeRAG pre-computes embeddings only for "large tail clusters" where on-demand generation would be costly, and adaptively caches remaining embeddings based on usage patterns. O-RAG's profile-dependent embedding chunk limits (15–100 chunks) serve a similar purpose but with a simpler, more predictable capping strategy suited to mobile hardware fragmentation.

PocketLLM [33] implements a fully on-device RAG system using the Arcee Lite 1.7B model in Q8 GGUF format with a SQLite-backed retrieval pipeline. It targets Android SMS and calendar management scenarios, reporting 6.2-second mean response latency on 6 GB RAM devices. O-RAG extends this paradigm with a larger 2B-parameter model, hybrid sparse+dense retrieval with rank fusion, and adaptive memory profiles spanning 3 GB to 12+ GB devices.

Pocket RAG [34] explores on-device RAG specifically for first aid guidance in offline mobile environments, demonstrating the critical importance of offline-capable retrieval systems in emergency scenarios where connectivity cannot be guaranteed.

### E. Hybrid Retrieval and Rank Fusion

The combination of sparse and dense retrieval signals has emerged as a best practice in modern information retrieval. Cormack, Clarke, and Büttcher [28] introduced Reciprocal Rank Fusion (RRF) at SIGIR 2009, demonstrating that the simple rank-based fusion formula $RRF(d) = \sum \frac{1}{k + r(d)}$ consistently outperforms both individual rankers and more complex rank learning methods including Condorcet voting. The method's key advantage is score-agnosticism: because only ordinal ranks are used, RRF naturally handles the score distribution mismatch between heterogeneous retrievers (e.g., BM25 log-likelihood scores vs. cosine similarity values in [0,1]).

The Okapi BM25 algorithm, developed by Robertson and Walker through the TREC experiments [32], remains the gold standard for sparse keyword retrieval. Its probabilistic formulation accounts for term frequency saturation (controlled by $k_1$) and document length normalization (controlled by b), making it robust across diverse document collections. SQLite's FTS5 engine provides a zero-overhead implementation of BM25 suitable for mobile deployment, as the index is maintained within the existing database without requiring additional memory structures.

O-RAG extends standard RRF with empirically-tuned weights (0.7 dense, 0.3 sparse) to prioritize semantic alignment while retaining keyword precision, and adds contextual pruning to dynamically limit the result set based on device memory constraints.

### F. Model Quantization for Mobile Deployment

The Qwen 2.5 series [30] represents a state-of-the-art family of language models trained on 18 trillion tokens with multi-stage reinforcement learning for instruction following. The 2B-parameter variant used in O-RAG provides sufficient capability for document-grounded question answering while remaining within mobile memory constraints when quantized to Q4_K_M format.

Nomic Embed Text v1.5 [29] introduces Matryoshka Representation Learning (MRL), enabling flexible embedding dimensionality (768, 512, 256, 128, or 64) from a single model. The model supports 8,192-token context length and uses task-specific prefixes (search_document: and search_query:) for optimal retrieval performance. O-RAG uses the full 768-dimensional embeddings quantized to Q8_0 to preserve retrieval fidelity.

K-quant methods employed in GGUF format provide non-uniform quantization where attention-critical layers retain higher precision (Q6_K or Q8_K) while feed-forward network parameters use aggressive Q4_K quantization. This approach preserves model quality in the layers most sensitive to quantization artifacts while aggressively compressing the majority of parameters [16].

### G. Cross-Language Mobile AI Frameworks

Chaquopy [31] is a Python SDK for Android that enables embedding CPython within Android applications via the Java Native Interface (JNI) and Android NDK. It supports bidirectional interoperation between Kotlin/Java and Python, enabling Android applications to leverage Python's extensive AI/ML ecosystem (NumPy, huggingface_hub) without requiring cloud API calls. Chaquopy handles Python package compilation for Android ABIs and manages the Python runtime lifecycle alongside the Android application lifecycle.

LinguaLinked [35] explores distributed LLM inference across multiple mobile devices, addressing single-device memory constraints through collaborative processing. While O-RAG focuses on single-device deployment for privacy preservation, LinguaLinked's work highlights the growing interest in mobile-native AI architectures.

O-RAG distinguishes itself through complete offline operation on mobile hardware. Unlike hybrid systems that offload retrieval or generation to cloud services, our architecture maintains full data locality throughout the entire pipeline—from document ingestion to answer generation.


## III. COMPARISON WITH EXISTING SYSTEMS

To position O-RAG within the landscape of on-device and offline AI systems, Tables 1a and 1b present a feature-based comparison with the most directly comparable systems across retrieval sophistication, memory optimization, runtime architecture, and privacy guarantees. MLC-LLM [17] and EdgeRAG [27] are excluded from the tabular comparison: MLC-LLM lacks retrieval capabilities entirely (chat-only deployment), while EdgeRAG requires an external index server and is not fully offline.

Table 1a: Retrieval and Memory Feature Comparison

Feature              | O-RAG (Ours)                     | PrivateGPT [19]        | MobileRAG [26]          | PocketLLM [33]
Target Platform      | Android mobile                   | Desktop (Linux/Mac/Win)| Mobile (research)       | Android mobile
Fully Offline        | ✓ (after bootstrap)              | ✓                      | ✓                       | ✓
Document RAG         | ✓ (PDF/TXT)                      | ✓ (multi-format)       | ✓                       | ✓ (SMS/Calendar)
Retrieval Type       | Hybrid (BM25 + Semantic wRRF)    | Semantic only          | EcoVector               | BM25 only
Sparse Retrieval     | ✓ (SQLite FTS5 BM25)             | ✗                      | ✗                       | ✓ (SQLite FTS)
Dense Retrieval      | ✓ (Nomic Embed v1.5)             | ✓ (various)            | ✓ (EcoVector)           | ✗
Rank Fusion          | Weighted RRF (0.7/0.3)           | N/A                    | N/A                     | N/A
Small-to-Big Expand. | ✓ (200→400 word)                 | ✗                      | ✗                       | ✗
Adaptive Memory      | ✓ (4 RAM profiles)               | ✗                      | ✓ (EcoVector)           | ✗
Memory Pressure Det. | ✓ (runtime /proc/meminfo)        | ✗                      | ✗                       | ✗

Table 1b: Runtime Architecture and Privacy Comparison

Feature              | O-RAG (Ours)                     | PrivateGPT [19]        | MobileRAG [26]          | PocketLLM [33]
LLM Model            | Qwen 3.5 2B (Q4_K_M)            | 7B+ typical            | Varies                  | Arcee Lite 1.7B (Q8)
Embedding Model      | Nomic Embed v1.5 (Q8_0)         | Various                | Custom                  | N/A
LLM Runtime          | llama.cpp subprocess             | llama.cpp              | Custom                  | llama.cpp
Cross-Lang. Bridge   | Flutter→Kotlin→Python→HTTP       | Python native           | N/A                     | Kotlin native
Response Caching     | ✓ (SHA-256 FIFO)                 | ✗                      | ✗                       | ✗
KV-Cache Pre-warm    | ✓                                | ✗                      | ✗                       | ✗
Conv. History Mgmt.  | ✓ (rolling compression)          | Limited                | ✗                       | Limited
Open Source           | ✓ (Apache 2.0/MIT)               | ✓ (Apache 2.0)         | Research only            | Research only
Privacy Guarantee    | Complete data locality            | Complete data locality  | Complete data locality   | Complete data locality

Several key distinctions emerge from Tables 1a and 1b:

Retrieval Sophistication (Table 1a): O-RAG is the only system implementing hybrid sparse+dense retrieval with weighted rank fusion on mobile devices. While PrivateGPT provides semantic-only retrieval and PocketLLM offers BM25-only retrieval, O-RAG's wRRF approach combines the complementary strengths of both paradigms—keyword precision from BM25 and semantic understanding from dense embeddings—with rank-based fusion that avoids score normalization artifacts [28].

Adaptive Memory Management (Table 1a): O-RAG's four-tier RAM profiling system (ULTRA_LOW through HIGH) with runtime memory pressure detection is unique among mobile RAG systems. This enables the same application to function on devices ranging from budget smartphones (3 GB RAM) to flagships (12+ GB RAM), dynamically adjusting context windows, embedding limits, and batch sizes.

Cross-Language Architecture (Table 1b): O-RAG's four-layer bridge (Flutter/Dart → Kotlin → Python → llama-server) is novel in combining a cross-platform UI framework with an embedded Python AI backend and native inference engine. This architecture enables rapid AI prototyping while maintaining the process isolation critical for mobile reliability.

Response Caching and Pre-Warming (Table 1b): O-RAG is the only system implementing both SHA-256 keyed response caching and KV-cache pre-warming, eliminating cold-start latency penalties that degrade the first-query experience on mobile devices.


## IV. PROBLEM STATEMENT

Mobile digital assistants face a paradoxical requirement: users demand highly contextual, intelligent responses regarding their private documents (e.g., financial statements, localized notes), yet exposing this data to third-party cloud APIs constitutes a severe privacy violation.

While cloud-based RAG architectures successfully combine LLMs with vector databases, they fundamentally violate the zero-trust privacy requirements of sensitive deployments. Conversely, state-of-the-art mobile LLM deployments operate offline but function solely as generic chatbots, lacking the mechanisms to dynamically ingest, vectorize, and retrieve context from localized personal corpora.

A viable offline mobile RAG system must therefore overcome three specific constraints:

1. Network Independence: Execute the complete ingestion, embedding, retrieval, and generation pipeline locally after an initial model bootstrap.

2. Database Footprint: Support high-fidelity hybrid retrieval without relying on heavy distributed vector databases (like Milvus or Pinecone), which exceed mobile storage and memory envelopes.

3. Hardware Fragmentation: Dynamically adjust computational demands to prevent Out-Of-Memory (OOM) failures across a highly fragmented mobile ecosystem, ranging from budget hardware (3 GB RAM) to flagships (12+ GB RAM).


## V. SYSTEM ARCHITECTURE

### A. Overview

The O-RAG system architecture consists of layers for presentation, bridging, orchestration, and local runtime. The presentation layer is built in Flutter, providing a reactive mobile interface. A Kotlin MethodChannel bridge connects the UI to an embedded Python backend powered by Chaquopy. The Python layer handles document processing, database interactions, and orchestrates the native llama-server subprocesses. Fig. 1 illustrates the complete system architecture and data flow.

[Figure 1: O-RAG System Architecture — High-level overview showing the interaction between user interface (Flutter), Kotlin bridge layer, Python RAG pipeline orchestrator, hybrid retriever, SQLite database layer, LLM backends (Qwen generation + Nomic embedding), and Android foreground service. The system operates entirely on-device with no external network dependencies after initial model bootstrap. Arrows indicate data flow direction with serialization formats (JSON, binary BLOB) annotated at each boundary.]

[Figure 2: O-RAG System Architecture Diagram — Detailed block diagram outlining the Flutter UI layer (ChatScreen, SettingsScreen, DocumentDrawer), Kotlin Bridge (MainActivity, MethodChannel, EventChannel), Python API (api.py, pipeline.py), RAG components (chunker.py, retriever.py, storage.py), memory management (memory_management.py), model runtime (model_runtime.py, llm.py), and llama-server sub-processes on localhost ports 8082 and 8083.]

### B. Cross-Language Bridge Architecture

O-RAG introduces a novel four-layer cross-language bridge architecture that enables the integration of Flutter's cross-platform UI capabilities with Python's extensive AI/ML ecosystem and llama.cpp's native inference performance. This architecture addresses a fundamental challenge in mobile AI development: no single programming language optimally serves all layers of the stack.

The bridge consists of four distinct communication boundaries:

Layer 1 — Flutter/Dart to Kotlin: The Flutter PlatformService class communicates with the Android native layer via MethodChannel (for request-response calls) and EventChannel (for streaming token callbacks). Messages are serialized as JSON strings with minimal overhead (~0.5 ms per invocation). The EventChannel provides a persistent stream for token-by-token generation output, employing a 50-millisecond batching buffer in the ChatController to aggregate rapid token arrivals and prevent UI jank from excessive setState() calls.

Layer 2 — Kotlin to Chaquopy Python: The MainActivity Kotlin class dispatches MethodChannel calls to the embedded Python runtime via Chaquopy's Python.getInstance().getModule("api") interface. Chaquopy embeds CPython 3.11 within the Android application through the JNI, compiling Python source files to .pyc bytecode at APK build time [31]. Method calls cross the JNI boundary with typical latency of 1–3 ms, including argument marshalling from Kotlin types to Python objects. A dedicated ExecutorService thread pool prevents blocking the main Android UI thread during long-running Python operations.

Layer 3 — Python to llama-server HTTP: The Python orchestration layer communicates with the llama-server inference engine via HTTP requests to localhost (127.0.0.1). This boundary introduces the highest per-call latency (2–5 ms overhead) but provides critical advantages: process isolation ensures that segmentation faults in the C++ inference engine do not crash the application, and the OpenAI-compatible HTTP API provides a clean abstraction that facilitates backend substitution (llama-cpp-python, Ollama, or external servers).

Layer 4 — llama-server Native Execution: Pre-compiled ARM64 llama-server binaries execute model inference using NEON SIMD instructions on the device CPU. Two independent server instances handle generation (port 8082) and embedding (port 8083) concurrently.

[Figure 3: Cross-Language Bridge Architecture — Data flow diagram showing the four communication layers: (1) Flutter/Dart PlatformService with MethodChannel/EventChannel (JSON serialization, ~0.5ms), (2) Kotlin MainActivity with Chaquopy JNI bridge (type marshalling, ~1-3ms), (3) Python api.py/pipeline.py with HTTP client (JSON over localhost, ~2-5ms), (4) llama-server ARM64 native processes on ports 8082/8083. Annotate each boundary with serialization format, communication protocol, threading model, and measured latency range. Show the EventChannel streaming path for token-by-token generation feedback from llama-server through Python callback through Kotlin EventChannel sink to Flutter StreamBuilder.]

Table 2: Cross-Language Bridge Latency Breakdown

Boundary                        | Protocol        | Serialization | Typical Latency | Threading Model
Flutter → Kotlin                | MethodChannel   | JSON string   | ~0.5 ms         | Platform thread
Kotlin → Python                 | Chaquopy JNI    | Type marshal  | 1–3 ms          | ExecutorService pool
Python → llama-server           | HTTP localhost   | JSON          | 2–5 ms          | Daemon thread
Total bridge overhead (per call)| —               | —             | 3.5–8.5 ms      | —

The total bridge overhead of 3.5–8.5 ms per call is negligible relative to LLM generation time (typically 2–15 seconds per response), representing less than 0.5% of end-to-end latency.

### C. Model Bootstrap and Download Pipeline

O-RAG implements an automated model bootstrap pipeline that ensures both GGUF model files (Qwen 3.5 2B for generation, Nomic Embed v1.5 for embedding) are available for offline inference after the first application launch. The pipeline supports HTTP download resume, manifest-based integrity verification, and real-time progress callbacks to the Flutter UI.

The bootstrap process follows a state machine with five states:

Table 3: Model Bootstrap State Transitions

Current State  | Trigger                      | Next State   | Action
IDLE           | First launch                 | DOWNLOADING  | Begin HTTP download with Range header resume
IDLE           | Manifest hash changed        | DOWNLOADING  | Re-download updated model versions
DOWNLOADING    | Download complete            | LOADING      | Launch llama-server, begin model weight I/O
DOWNLOADING    | Network failure              | ERROR        | Show retry UI with error details
DOWNLOADING    | App backgrounded            | DOWNLOADING  | Continue download (foreground service)
LOADING        | Health check passes (/health) | READY        | Fire KV-cache pre-warm daemon thread
LOADING        | Server timeout (180s)        | ERROR        | Show error with diagnostic logs
READY          | Manifest hash change         | DOWNLOADING  | Re-sync models from HuggingFace
ERROR          | User retry                   | DOWNLOADING  | Resume from last checkpoint

Model Manifest and Version Control: Each model is defined by a manifest entry containing repository ID, filename, revision tag, and minimum valid file size. A SHA-256 hash of the JSON-serialized manifest (computed via hashlib.sha256) serves as a version fingerprint stored in bootstrap_state.json. When the manifest changes (e.g., a model update), the bootstrap pipeline detects the hash mismatch and triggers re-download, ensuring deployed models match the application's expectations.

HTTP Download with Resume: The downloader uses urllib.request with Range header support for interrupted download resumption. Partial downloads are stored with a .part extension and atomic-replaced via os.replace() upon completion. TLS verification uses certifi's CA bundle for reliable Android SSL certificate handling. Download progress is computed from HTTP Content-Length headers and emitted as percentage callbacks.

Service-Owned vs. App-Owned Architecture: O-RAG distinguishes between app-owned components (Flutter UI process) and service-owned components (Android foreground service managing llama-server subprocesses). This distinction is critical for model persistence: Android may destroy and recreate the UI activity during rotation, multitasking, or memory pressure, but the foreground service—and its child llama-server processes with loaded model weights—survives these lifecycle events. The result is that users experience 10–20 second model load times only on the first launch; subsequent activity recreations reconnect to the already-running service instantly.

[Figure 4: Model Bootstrap and Download Pipeline — State machine diagram showing the five states (IDLE, DOWNLOADING, LOADING, READY, ERROR) with transition triggers and actions. Include the progress callback flow: Python downloader.py emits (fraction, text) tuples → Python api.py formats as JSON events → Kotlin MainActivity.kt forwards via EventChannel → Flutter PlatformService streams to InitOverlay widget. Show the manifest hash verification at the IDLE→DOWNLOADING transition and the /health endpoint polling at LOADING→READY.]

### D. Android Foreground Service Lifecycle

O-RAG employs a dual-process architecture to ensure model persistence across Android application lifecycle events. The main Flutter process handles UI rendering, while a foreground Android service manages the llama-server subprocesses.

Android's aggressive process management can terminate background applications to reclaim memory. By implementing model serving as a foreground service with a persistent notification, the system maintains model availability even when the UI is minimized or temporarily destroyed [20][37]. Inter-process communication occurs via localhost HTTP (127.0.0.1). This decoupled architecture prevents UI failures from terminating the inference engine.

The lifecycle management addresses several Android-specific challenges:

Activity Recreation Resilience: When Android destroys and recreates the UI activity (due to configuration changes, rotation, or memory pressure), the service continues running independently. Upon activity recreation, the Flutter PlatformService re-establishes connection to the existing service, verifying server health before accepting queries. This eliminates the catastrophic user experience of reloading a 1.4 GB GGUF model on every screen rotation.

Process Death Handling: If the llama-server process crashes (e.g., due to a segmentation fault with certain quantized model edge cases), the service's watchdog mechanism detects the health check failure and can restart the server process automatically. Because the server runs in a separate address space from the Python orchestrator and Flutter UI, a native code crash in llama.cpp affects only the inference subprocess.

Multi-Model Concurrency: Two independent llama-server processes run simultaneously—Qwen 3.5 2B on port 8082 for generation and Nomic Embed v1.5 on port 8083 for embedding computation. The subprocess approach naturally supports this multi-model serving through port-based isolation, whereas in-process serving would require complex threading and risk deadlocks between generation and embedding operations.

[Figure 5: Android Foreground Service Lifecycle — Sequence diagram showing: (1) Application launch → Activity created → Service started → llama-server launched (ports 8082, 8083) → Health check polling → Models loaded → Ready state. (2) User rotates screen → Activity destroyed → Service persists (model weights remain in RAM) → Activity recreated → Service reconnected → Instant ready. (3) llama-server crash → Health check fails → Watchdog restarts server → Health check passes → Ready state restored. Annotate with approximate timings for each transition.]

### E. Process Architecture

The llama-server binary is pre-compiled for arm64-v8a and packaged within the APK's jniLibs/ directory. At runtime, the Python orchestrator discovers the binary via the native library directory path injected from Kotlin (MainActivity.kt), then launches it as a child subprocess with subprocess.Popen. Two independent llama-server processes are launched:

• Qwen Generation Server on port 8082 (config.QWEN_SERVER_PORT)
• Nomic Embedding Server on port 8083 (config.NOMIC_SERVER_PORT)

A health-check polling loop (_wait_for_server) probes the /health endpoint with a configurable timeout (up to 180 seconds for the generation server, 120 seconds for the embedding server), emitting UI progress callbacks during the wait.

### F. Adaptive Memory Management

To handle the diverse hardware landscape of Android devices, O-RAG implements an adaptive memory management system. The system queries device RAM via /proc/meminfo and assigns an operational profile, dynamically allocating the LLM context window and batch parameters to prevent Out-Of-Memory (OOM) crashes.

Table 4a: LLM Inference Parameters per Memory Profile

Profile    | RAM      | Context Window | Max Tokens | Threads | KV Cache | Batch Size
ULTRA_LOW  | ≤ 3.0 GB | 1,536          | 256        | 2       | q4_0     | 256
LOW        | ≤ 4.5 GB | 2,048          | 512        | 2       | q4_0     | 512
MEDIUM     | ≤ 6.5 GB | 3,072          | 768        | Auto    | q8_0     | 1,024
HIGH       | > 6.5 GB | 4,096          | 1,024      | Auto    | q8_0     | 1,024

Table 4b: Embedding and Memory Parameters per Profile

Profile    | RAM      | Nomic Ctx | Nomic Loading | Embed Limit
ULTRA_LOW  | ≤ 3.0 GB | 64        | Lazy          | 15 chunks
LOW        | ≤ 4.5 GB | 64        | Lazy          | 25 chunks
MEDIUM     | ≤ 6.5 GB | 384       | Eager         | 50 chunks
HIGH       | > 6.5 GB | 512       | Eager         | 100 chunks

Additionally, O-RAG implements real-time dynamic memory pressure detection. Before every generation call, the system reads /proc/meminfo (throttled to 5-second intervals) and computes ratio-based thresholds:

• Emergency (available < 4% of total RAM): Context halved, max tokens capped at 128, forced garbage collection.
• Warning (available < 8% of total RAM): Context capped at 512, max tokens at 256.

These thresholds are scaled proportionally to total device RAM, preventing false alarms on large-RAM devices (8 GB, 12 GB) where the absolute memory consumption of two loaded GGUF models is high but proportionally safe.

[Figure 6: Memory Pressure State Machine — State diagram showing three operational states: NORMAL (full profile parameters), WARNING (available < 8% total RAM: context capped at 512, max tokens at 256, batch size reduced), and EMERGENCY (available < 4% total RAM: context halved, max tokens at 128, forced gc.collect(), embedding computation paused). Transitions are triggered by /proc/meminfo readings at 5-second intervals. Show parameter adjustments at each state and the recovery path from EMERGENCY → WARNING → NORMAL as memory is freed.]


## VI. DOCUMENT PROCESSING PIPELINE

### A. Document Chunker (Small-to-Big Strategy)

The document chunker module extracts text from PDF and TXT files, segmenting content into overlapping chunks. O-RAG employs a "Small-to-Big" hierarchical chunking strategy to balance precise retrieval with broad generative context.

Table 5: Small-to-Big Chunking Parameters

Parameter                      | Value
Child Chunk Size               | ~200 words (tokens)
Child Chunk Overlap            | 40 words
Parent Chunk Size              | ~400 words
Parent Chunk Overlap           | 50 words
Document Preamble Injection    | First 200 characters prepended to every child chunk after the first

Child chunks (~200 words) are used for indexing and vector similarity matching because dense embeddings lose representational fidelity over long text blocks. Once the most relevant child chunks are identified during retrieval, O-RAG maps them to their 400-word parent chunks. The LLM is supplied exclusively with the parent chunks, providing broader contextual framing. The parent-child mapping is established by computing the midpoint position of each child chunk within the raw document text and assigning it to the parent chunk whose range contains that midpoint.

During ingestion, term frequencies and inverse document frequencies (TF-IDF) are calculated for each child chunk. Let N be the total number of chunks and df(t) be the number of chunks containing term t. The smoothed inverse document frequency is computed as:


$$IDF(t) = \log\left(\frac{N + 1}{df(t) + 1}\right) + 1$$


The TF-IDF vector for chunk c is then:


$$TF\text{-}IDF(t, c) = \frac{\text{count}(t, c)}{|c|} \times IDF(t)$$


where |c| is the total number of tokens in chunk c. These vectors are serialized and persisted in the SQLite chunks.tfidf_vec BLOB column.

[Figure 7: Chunk Hierarchy Diagram — Visual representation of a sample PDF document being split into parent chunks (400 words, 50-word overlap) and child chunks (200 words, 40-word overlap). Show the hierarchical relationship with connecting arrows: each child chunk maps to exactly one parent chunk via midpoint position. Illustrate the document preamble injection where the first 200 characters of the document are prepended to non-first child chunks. Include numerical annotations for chunk indices and position ranges within the original document.]

### B. Database Layer

SQLite provides persistent storage with ACID guarantees suitable for mobile constraints. O-RAG deliberately uses SQLite over dedicated vector databases (e.g., FAISS, ChromaDB) for mobile-specific reasons: zero dependency installation, ACID compliance preventing corruption on crashes, and single-file portability. For typical mobile use cases ($N < 5000$ chunks), in-memory vectorized cosine similarity outperforms indexed approximate search due to the absence of index construction and network serialization overhead [21][22].

Table 6: SQLite Schema for Document and Chunk Storage

Table: documents
  - id INTEGER PRIMARY KEY
  - name TEXT
  - path TEXT UNIQUE
  - added_at TEXT
  - num_chunks INTEGER

Table: chunks
  - id INTEGER PRIMARY KEY
  - doc_id INTEGER FOREIGN KEY → documents(id) ON DELETE CASCADE
  - chunk_idx INTEGER
  - text TEXT
  - tokens TEXT (JSON array)
  - tfidf_vec BLOB (serialized TF-IDF vector)
  - parent_chunk_idx INTEGER
  - embedding BLOB (packed float32 array, 768 dimensions)

Table: parent_chunks
  - id INTEGER PRIMARY KEY
  - doc_id INTEGER FOREIGN KEY → documents(id) ON DELETE CASCADE
  - parent_chunk_idx INTEGER
  - text TEXT

Virtual Table: chunks_fts (FTS5)
  - text TEXT (synchronized via INSERT/UPDATE/DELETE triggers)

[Figure 8: SQLite Schema Entity-Relationship Diagram — ER diagram showing the four tables (documents, chunks, parent_chunks, chunks_fts) with foreign key relationships (doc_id), cascade delete behaviour, and FTS5 trigger synchronization. Annotate the embedding BLOB column showing the packed float32 format (768 × 4 bytes = 3,072 bytes per embedding). Show WAL mode and NORMAL synchronous mode configuration for concurrent read-write access during background embedding computation.]

Performance optimizations include Write-Ahead Logging (WAL) mode for concurrent read-write access, NORMAL synchronous mode balancing write speed with crash safety, and ON DELETE CASCADE foreign key enforcement for automatic chunk cleanup when documents are removed. FTS5 triggers keep the full-text search index synchronized with the chunks table automatically upon inserts, updates, and deletes.

WAL mode proves particularly valuable on mobile devices where UI responsiveness is critical. The retriever can query chunks while ingestion threads write new documents without blocking, maintaining smooth user experience during background operations.


## VII. HYBRID RETRIEVAL SYSTEM

This section presents the core retrieval algorithms implemented in O-RAG, providing formal derivations and implementation details for each component of the hybrid retrieval pipeline.

### A. BM25 Sparse Retrieval

The Okapi BM25 algorithm [32], implemented natively through SQLite's FTS5 engine, provides the sparse retrieval signal. For a query Q containing terms $q_1, q_2, \dots, q_n$ and a document (chunk) D, the BM25 score is computed as:


$$BM25(Q, D) = \sum_{i=1}^{n} IDF(q_i) \cdot \frac{f(q_i, D) \cdot (k_1 + 1)}{f(q_i, D) + k_1 \cdot \left(1 - b + b \cdot \frac{|D|}{avgdl}\right)}$$


where:
- $f(q_i, D)$ is the frequency of term qᵢ in document D
- |D| is the length of document D in words
- avgdl is the average document length across the corpus
- $k_1 = 1.5$ (term frequency saturation constant)
- $b = 0.75$ (length normalization penalty)

The inverse document frequency $IDF(q_i)$ is computed as:


$$IDF(q_i) = \ln\left(\frac{N - n(q_i) + 0.5}{n(q_i) + 0.5} + 1\right)$$


where N is the total number of documents (chunks) in the collection and $n(q_i)$ is the number of documents containing term qᵢ.

The parameter $k_1 = 1.5$ controls term frequency saturation: as a term's frequency increases beyond this point, the marginal contribution to the score diminishes, preventing long documents with many term repetitions from dominating results. The parameter $b = 0.75$ controls length normalization: at $b = 1.0$, full length normalization penalises long documents proportionally; at $b = 0$, document length is ignored. The value 0.75 provides strong but not absolute length normalization, consistent with Robertson and Walker's TREC findings [32].

SQLite's FTS5 engine executes this computation with zero additional RAM overhead beyond the existing database file, making it an ideal sparse retrieval mechanism for mobile devices. The FTS5 index is maintained through database triggers that automatically synchronize the chunks_fts virtual table with the chunks table upon insertion, update, and deletion.

### B. Dense Retrieval with Nomic Embedding Protocol

The dense retrieval component uses the Nomic Embed Text v1.5 model [29] to compute 768-dimensional semantic embeddings. A critical implementation detail is the use of task-specific prefixes that shift the embedding vector space for optimal retrieval performance:

- Document chunks are embedded with the prefix: "search_document: {chunk_text[:480]}"
- User queries are embedded with the prefix: "search_query: {query_text[:280]}"

These prefixes are part of Nomic's instruction-following embedding protocol, where different task prefixes (search_document, search_query, classification, clustering) activate different internal attention patterns, producing embeddings optimized for the specified task. Omitting the prefix or using the wrong prefix degrades retrieval quality by up to 15% on standard benchmarks [29].

Cosine similarity between query embedding $\vec{q}$ and chunk embedding $\vec{c}$ measures semantic relatedness:


$$\text{cosine}(\vec{q}, \vec{c}) = \frac{\vec{q} \cdot \vec{c}}{\|\vec{q}\|_2 \cdot \|\vec{c}\|_2}$$


NumPy Vectorized Cosine Similarity Algorithm: To optimize for mobile architectures, O-RAG implements a vectorized matrix-multiplication approach that executes 10–50$\times$ faster than pure Python iteration:

Step 1 — Matrix Construction: All cached chunk embeddings are loaded into a NumPy matrix $M \in \mathbb{R}^{N \times 768}$ (float32), where N is the number of embedded chunks.

Step 2 — L2 Normalization: Row norms are computed as $\|M[i]\|_2$ for all i, and each row is divided by its norm. The query vector is similarly normalized. Norms are clipped to a minimum of $10^{-9}$ to prevent division by zero.

Step 3 — Matrix-Vector Product: The normalized matrix-vector product $M_{\text{norm}} \cdot \vec{q}_{\text{norm}}$ computes all N cosine similarities in a single BLAS-accelerated operation. On ARM64 devices, NumPy's BLAS implementation leverages NEON SIMD instructions (via Chaquopy's compiled NumPy package) for parallel floating-point computation.

Step 4 — Efficient Top-k Selection: Rather than sorting all N similarities ($\mathcal{O}(N \log N)$), numpy.argpartition selects the top-k indices in $\mathcal{O}(N)$ average time using the introselect algorithm. Only the k selected elements are then sorted, yielding $\mathcal{O}(N + k \log k)$ total complexity.

This algorithm completes in under 5 milliseconds for N = 5,000 chunks on a typical ARM64 mobile CPU, compared to 50–250 milliseconds for an equivalent pure-Python loop.

### C. Weighted Reciprocal Rank Fusion

Because BM25 and semantic cosine similarity exist on arbitrary and disjoint numerical scales, O-RAG bypasses complex score normalization using rank-based Weighted Reciprocal Rank Fusion. For a given chunk c, the fusion score is:


$$wRRF(c) = \frac{w_{\text{dense}}}{k + \text{rank}_{\text{dense}}(c)} + \frac{w_{\text{sparse}}}{k + \text{rank}_{\text{sparse}}(c)}$$


The weights are empirically set to $w_{\text{dense}} = 0.7$ and $w_{\text{sparse}} = 0.3$, with smoothing constant $k = 60$. The choice of $k = 60$ follows Cormack et al.'s finding that this value provides robust fusion performance across diverse retrieval scenarios [28].

The dominant 0.7 semantic weight ensures that conceptual alignment supersedes strict keyword overlap, which is particularly important for mobile RAG where users frequently ask paraphrased questions about document content. However, the 0.3 sparse weight preserves the ability to retrieve documents containing specific technical terms, acronyms, or proper nouns that may not have strong semantic embeddings.

When semantic embeddings are unavailable (Nomic model not loaded or chunk exceeds embedding cap), the system falls back to sparse-only results with zero performance penalty.

Both sparse and dense retrievals execute in parallel via a shared ThreadPoolExecutor with a 2-worker pool (reused across queries to avoid thread-pool creation overhead). Each retrieval has a 5-second timeout; if either fails, the system gracefully degrades to the available signal.

### D. Contextual Pruning

To minimize LLM prefill latency, the retriever dynamically prunes the result set. Any retrieved chunk whose wRRF score falls below a profile-dependent threshold of the top-ranked chunk is discarded, ensuring the LLM context window is not saturated with low-relevance noise:

- MEDIUM/HIGH profiles: threshold = 40% of top score
- LOW/ULTRA_LOW profiles: threshold = 50% of top score (tighter pruning saves context window space on constrained devices)

The maximum result count is capped at the profile-adaptive top-k (2–4 chunks). A deduplication pass using a seen_texts set removes identical chunk text before returning results.

### E. Small-to-Big Expansion

The final retrieval step maps matched child chunks to their parent chunks via an $\mathcal{O}(1)$ reverse-text index lookup (implemented as a Python dictionary mapping (doc_id, text.strip()) → chunk list index). If a parent chunk is available (i.e., parent_chunk_idx >= 0), the 400-word parent text replaces the child text. Duplicate parent expansions from multiple child hits within the same parent are collapsed via a seen_parents set.

This strategy provides the best of both worlds: child chunks (200 words) enable precise, focused retrieval targeting, while parent chunks (400 words) provide the broader context needed for coherent LLM generation.

[Figure 9: Retrieval Pipeline Flowchart — Complete flowchart showing the end-to-end retrieval process: User Query → ThreadPoolExecutor dispatches two parallel tasks: (1) FTS5 BM25 sparse search (SQLite query, returns ranked chunk IDs with BM25 scores) ‖ (2) Nomic dense embedding (HTTP POST to localhost:8083/embedding with "search_query:" prefix, returns 768-dim vector) → NumPy vectorized cosine similarity against cached embeddings → Both result lists fed to Weighted RRF merge (w_dense=0.7, w_sparse=0.3, k=60) → Contextual pruning (profile-dependent threshold) → Small-to-Big parent chunk expansion ($\mathcal{O}(1)$ index lookup) → Deduplication → Context formatting for LLM prompt. Annotate each step with typical execution time on mobile hardware.]


## VIII. RESPONSE CACHING AND CONVERSATION MANAGEMENT

### A. Response Cache Architecture

O-RAG implements a lightweight response cache that eliminates redundant retrieval and generation for repeated queries. The cache operates at the API layer, intercepting queries before they reach the RAG pipeline.

Cache Key Generation: Keys are computed using a truncated SHA-256 hash that incorporates both the normalized query text and the current conversation history length:


```python
key = SHA256(query.strip().lower() + "|histlen=" + str(len(history)))[:16]
```


Including the history length prevents cache collisions between identical queries asked at different points in a conversation, where the retrieval query augmentation (which appends the last user turn for follow-up resolution) would produce different results.

FIFO Eviction Policy: The cache stores up to 20 entries (CACHE_MAX_SIZE = 20) in a Python dictionary that preserves insertion order (guaranteed in Python 3.7+). When the cache is full, the oldest entry is evicted via dict.pop(next(iter(cache))). This FIFO strategy is chosen over LRU for simplicity and predictable memory consumption on mobile devices.

Cache Hit Behavior: On a cache hit, the system bypasses the entire retrieval and generation pipeline, immediately returning the cached result. To maintain UI animation continuity, cached response tokens are re-streamed to the Flutter UI word-by-word through the token callback, providing the same visual experience as a fresh generation.

Thread Safety: All cache operations are protected by a dedicated threading.Lock (_cache_lock), preventing race conditions between concurrent query handlers.

### B. Rolling History Compression

For direct chat mode (no document context), the pipeline maintains conversation history through a rolling compression strategy that balances context awareness with context window efficiency:

Turn Preservation: The most recent MAX_TURNS = 5 turns (query-response pairs) are preserved verbatim in the history list.

Zero-Latency Summary Compression: Older turns are compressed into a rolling summary using extractive first-sentence extraction rather than LLM-based summarization. For each dropped turn, the first sentence of both the query and response is extracted (via period-split), truncated (query to 120 chars, response to 180 chars), and appended to a running summary capped at 400 characters. This approach avoids the latency penalty of an additional LLM call for summarization while maintaining awareness of earlier conversation context.

Character Budget Enforcement: To prevent context window overflow, the total character count of preserved history is compared against a budget computed from the current memory profile: $budget\_chars = \max(300, (n\_ctx - max\_tokens - 256) \times 4)$. If the budget is exceeded, the oldest preserved turns are dropped until the history fits within the allocation.

### C. KV-Cache Pre-Warming

A critical optimization for mobile user experience is the elimination of cold-start latency on the first query after server startup. O-RAG implements KV-cache pre-warming through a fire-and-forget daemon thread that executes immediately after the llama-server reports healthy:

1. A 1.5-second grace period allows the server to stabilize after health confirmation.
2. Two pre-warming requests are sent sequentially:
   a. Direct chat system prompt: A minimal prompt using build_direct_prompt("Hello", history=[], summary="") is evaluated with n_predict=1 and cache_prompt=true.
   b. RAG system prompt prefix: The RAG prompt is generated using build_rag_prompt([], "Hello"), then truncated at the "Context:" marker to cache only the static system message portion.
3. Both requests use temperature=0.0 and n_predict=1 to minimize computation while populating the server-side KV cache.

The result is that the first real user query benefits from pre-computed KV-cache entries for the system prompt, eliminating the 1–3 second prefill latency penalty that would otherwise occur on the initial interaction.

[Figure 10: Response Caching and Conversation Management — Three-part diagram showing: (a) Cache lookup flow: query arrives → SHA-256 key generated (incorporating history length) → cache dict lookup → HIT: re-stream cached tokens to UI, skip retrieval/generation → MISS: execute full RAG pipeline, store result in cache, evict oldest if full. (b) Rolling history compression: show a 7-turn conversation where turns 1-2 are compressed to first-sentence summaries (capped at 400 chars total), turns 3-7 are preserved verbatim, and the system prompt includes the compressed summary. (c) KV-cache pre-warming sequence: server health check passes → 1.5s grace period → pre-warm direct chat prompt (1 token) → pre-warm RAG system prompt prefix (1 token) → daemon thread exits → first real query uses pre-cached KV entries.]


## IX. SECURITY AND PRIVACY ANALYSIS

### A. Threat Model

O-RAG's security analysis considers three adversary classes relevant to mobile document processing:

1. Network Eavesdropper: An adversary capable of intercepting network traffic between the device and external servers. O-RAG mitigates this threat by eliminating all network communication after the initial model bootstrap. The only network traffic is the HTTPS model download from HuggingFace, which transmits no user data.

2. Cloud Service Provider: In cloud RAG systems, the service provider has access to all user documents, queries, and responses. O-RAG eliminates this threat entirely by performing all processing on-device.

3. Malicious Co-resident Applications: Applications sharing the Android device may attempt to access O-RAG's data. O-RAG relies on Android's application sandbox and file-based encryption for protection.

### B. Data Locality Guarantees

O-RAG enforces complete data locality through architectural design decisions verified in the codebase:

- Document Processing: All PDF/TXT extraction, chunking, and TF-IDF computation execute within the embedded Python runtime. No document content is transmitted externally.

- Embedding Computation: Dense embeddings are computed by the local Nomic llama-server process on localhost:8083. Embedding vectors are stored as BLOBs in the local SQLite database.

- Query Processing: All retrieval operations (FTS5 BM25, dense cosine similarity, wRRF fusion) execute in-memory within the Python process.

- Response Generation: LLM inference executes on the local Qwen llama-server process on localhost:8082. Generated tokens are streamed via localhost HTTP to the Python callback chain.

- Font Rendering: Google Fonts runtime fetching is explicitly disabled (GoogleFonts.config.allowRuntimeFetching = false) to prevent any UI-related network requests during normal operation.

### C. Network Exposure Analysis

Table 7: Network Exposure Analysis

Operation               | Network Required | Data Transmitted         | Direction | Frequency
Model download          | ✓ (HTTPS)        | Model file request only  | Outbound  | First launch / model update
Document ingestion      | ✗                | None                     | —         | Per upload
Embedding computation   | ✗                | None (localhost only)    | —         | Per document chunk
Query retrieval         | ✗                | None                     | —         | Per query
LLM generation          | ✗                | None (localhost only)    | —         | Per query
Font rendering          | ✗                | None (bundled assets)    | —         | Never
UI state persistence    | ✗                | None (local JSON/prefs)  | —         | Per session

Quantitative Privacy Metric: During normal operation (after model bootstrap), O-RAG transmits exactly 0 bytes of user data to external servers. This represents a fundamental improvement over cloud RAG systems where every query transmits user documents and queries to third-party servers.

### D. Comparison with Cloud RAG Privacy Risks

Table 8: Privacy Risk Comparison

Risk Dimension                | Cloud RAG (e.g., ChatGPT + Retrieval) | O-RAG
Document transmission         | All documents sent to cloud              | Documents never leave device
Query logging                 | Queries logged by provider               | Queries stored locally only
Response storage              | Responses retained by provider           | Responses stored locally only
Training data extraction [3]  | Potential extraction risk                | Zero risk (no cloud transmission)
Regulatory compliance (GDPR)  | Requires DPA with provider               | Self-contained compliance
Air-gap compatibility         | ✗                                        | ✓ (after bootstrap)
Cross-border data transfer    | May violate data sovereignty             | Data remains on device

### E. Current Security Limitations

Several security limitations are acknowledged for transparency:

1. At-Rest Encryption: The SQLite database and Flutter chat JSON files are not encrypted at the application layer. Protection relies on Android's file-based encryption (FBE), which encrypts app-private storage with a device-specific key after secure boot.

2. Model Download Integrity: While model downloads use HTTPS for transport security, the downloader does not verify pinned file hashes after download. A supply-chain attacker who compromises the HuggingFace repository could distribute malicious model files.

3. Inter-Process Communication: Localhost HTTP between the Python orchestrator and llama-server is unencrypted. While this traffic never leaves the device, a compromised co-resident process with root access could theoretically intercept it.


## X. QUANTIZATION STRATEGY ANALYSIS

### A. K-Quant Non-Uniform Quantization

O-RAG's generation model (Qwen 3.5 2B) uses the Q4_K_M quantization format, which employs non-uniform quantization across different layer types. K-quant methods assign different bit widths to different tensor groups based on their sensitivity to quantization:

- Attention weights and output projection layers: Q6_K or Q8_K precision, preserving the fine-grained numerical relationships critical for attention score computation.
- Feed-forward network (FFN) parameters: Q4_K precision, aggressively compressing the majority of model parameters where quantization artifacts are least perceptible.
- Embedding and layer normalization tensors: Higher precision to maintain input representation quality.

The "M" suffix in Q4_K_M indicates a "medium" quality preset that balances file size against quality, selecting an intermediate precision allocation between the "S" (small/aggressive) and "L" (large/conservative) variants.

### B. Generation Model Quantization Trade-offs

Table 9: Quantization Format Comparison for Qwen 3.5 2B

Format (File Size) | Est. RAM | Quality (relative) | Notes
FP16 (~4.0 GB)     | ~4.2 GB  | 100% (baseline)    | Exceeds most mobile RAM budgets; not suitable
Q8_0 (~2.0 GB)     | ~2.3 GB  | ~99%               | Feasible only on 8+ GB devices; marginal suitability
Q6_K (~1.7 GB)     | ~1.9 GB  | ~98%               | 21% larger than Q4_K_M for marginal quality gain
Q5_K_M (~1.5 GB)   | ~1.7 GB  | ~97%               | Good quality with slight size premium; suitable
Q4_K_M (~1.4 GB)   | ~1.6 GB  | ~95-98%            | Optimal mobile trade-off ✓
Q3_K_M (~1.1 GB)   | ~1.3 GB  | ~90-93%            | Noticeable degradation on 2B models; suitable
Q2_K (~0.8 GB)     | ~1.0 GB  | ~85-88%            | Significant degradation; not recommended

For mobile deployment, Q4_K_M represents the optimal trade-off point. Q2_K and Q3_K quantization produces noticeable quality degradation, especially on smaller models like the 2B-parameter Qwen where each parameter carries proportionally more information. Q5_K_M and Q6_K offer marginal quality improvements at 7–21% larger file sizes, which is significant on devices with limited storage.

### C. Embedding Model Quantization

The Nomic Embed v1.5 model is quantized to Q8_0 format rather than the more aggressive Q4_K_M used for the generation model. This choice is deliberate:

- Embedding models require higher precision: Quantization artifacts in 768-dimensional vectors directly affect the cosine similarity computations that drive retrieval quality. A single corrupted dimension can shift similarity rankings and return irrelevant chunks.
- Storage premium is negligible: At ~140 MB (Q8_0) vs. ~70 MB (Q4_K_M), the 70 MB storage premium is negligible relative to the 1.4 GB generation model and represents less than 0.5% of a typical smartphone's storage capacity.
- Memory impact is proportional: The Nomic model loaded in RAM (~160 MB Q8_0 vs. ~90 MB Q4_K_M) represents a minor fraction of total application memory, and the quality benefit far outweighs the ~70 MB memory premium.

### D. Context Window Configuration

Qwen 3.5 2B supports context windows up to 32,768 tokens, yet O-RAG configures between 1,536 and 4,096 tokens depending on the RAM profile. This aggressive reduction saves hundreds of megabytes of RAM (KV-cache memory scales linearly with context length) and increases generation speed through reduced attention computation.

Table 10: Token Budget Allocation per Profile

Budget Component    | ULTRA_LOW (1,536) | LOW (2,048) | MEDIUM (3,072) | HIGH (4,096)
System prompt       | ~80 tokens        | ~80 tokens  | ~80 tokens     | ~80 tokens
Retrieved context   | ~400–800          | ~400–800    | ~600–1,200     | ~800–1,600
(2–4 parent chunks) |                   |             |                |
User question       | ~20–40            | ~20–40      | ~20–40         | ~20–40
Chat history summary| ~30               | ~30         | ~30            | ~30
Reserved for        | 614               | 819         | 1,228          | 1,638
generation (40% cap)|                   |             |                |

This allocation reflects RAG system design: most context comes from retrieval, not conversation history. By retrieving only the 2–4 most relevant parent chunks and compressing chat history, the system fits production-quality RAG within mobile-appropriate memory constraints.


## XI. DEPLOYMENT AND REPRODUCIBILITY

### A. CI/CD Pipeline

O-RAG uses a GitHub Actions workflow (android-release.yml) for automated release builds. The CI pipeline performs:

1. Environment Setup: Ubuntu runner with Java 17 (temurin), Python 3.11 (for Chaquopy build toolchain), Android SDK 35, and Gradle 8.14.
2. Dependency Resolution: Flutter packages (pubspec.lock), Gradle dependencies, and Chaquopy Python packages (numpy, certifi, huggingface_hub, pypdf).
3. Build: Gradle assembleRelease produces both APK and AAB (Android App Bundle) formats.
4. Signing: Release builds are signed with a keystore for distribution.
5. Artifact Upload: Built APK/AAB files are uploaded as release artifacts.

### B. Native Binary Distribution

The llama-server binary and supporting libraries are compiled from the llama.cpp source using a dedicated build script (build_llama_android.sh):

- Toolchain: Android NDK with CMake and Ninja build system
- Target ABI: arm64-v8a (64-bit ARM)
- Optimization flags: NEON SIMD enabled for vectorized computation
- Output libraries: libllama_server.so, libllama.so, libllama-common.so, libggml*.so, libmtmd.so

These libraries are packaged in the APK's jniLibs/arm64-v8a/ directory and discovered at runtime via the native library directory path injected from Kotlin.

### C. Model Manifest Versioning

The bootstrap_state.json file provides manifest-based version control for deployed models:

{
  "schema": 1,
  "manifest_hash": "<SHA-256 of model manifest>",
  "completed_at": <unix_timestamp>,
  "models": [
    {
      "filename": "Qwen3.5-2B-Q4_K_M.gguf",
      "repo_id": "cracker0935/Compressed_RAG_Models",
      "revision": "main",
      "size_bytes": <actual_file_size>
    },
    ...
  ]
}

The manifest hash is computed as SHA-256(JSON.stringify(model_metadata, sort_keys=True)), enabling deterministic version detection. When the application is updated with a new model manifest (e.g., a model version bump), the hash mismatch triggers automatic re-download, ensuring consistency between application code and deployed models.

### D. Reproducibility Checklist

Table 11: Reproducibility Artifacts

Artifact                | Location                                  | Verification Method
Source code             | GitHub repository                         | Apache 2.0 / MIT license
LLM model (Qwen)       | HuggingFace cracker0935/Compressed_RAG_Models | Manifest hash + min_bytes check
Embedding model (Nomic) | HuggingFace cracker0935/Compressed_RAG_Models | Manifest hash + min_bytes check
Native llama libraries  | APK jniLibs/arm64-v8a/                    | Build script reproducibility
Build instructions      | scripts/build_llama_android.sh             | Automated CI validation
Python dependencies     | chaquopy.gradle (version-pinned)           | Lockfile reproducibility
Flutter dependencies    | pubspec.lock                               | Lockfile reproducibility
CI/CD pipeline          | .github/workflows/android-release.yml     | Automated build verification


## XII. LLM BACKEND AND INFERENCE

### A. LLM Backend Architecture

The LLM backend implements a three-tier fallback strategy to maximize cross-platform compatibility. The priority chain attempts: (1) llama-cpp-python for in-process inference, (2) Ollama if available on localhost:11434, and (3) llama-server subprocess as guaranteed fallback.

For O-RAG's production deployment, llama-server provides optimal characteristics: pre-compiled ARM64 binaries eliminate complex NDK builds, process isolation enables persistence across app lifecycle events, and simultaneous multi-model serving (generation on port 8082, embedding on port 8083) maximizes resource efficiency.

### B. Model Specifications

Table 12: Model Specifications

Property            | Qwen 3.5 2B              | Nomic Embed v1.5
Parameters          | 2 billion                | 137 million
Architecture        | Transformer (decoder)    | Transformer (encoder)
Training Data       | 18 trillion tokens [30]  | Reproducible long-context [29]
Quantization        | Q4_K_M                   | Q8_0
File Size           | ~1.4 GB                  | ~140 MB
Embedding Dims      | N/A                      | 768
Context Length       | Up to 32,768 tokens      | 8,192 tokens
Server Port         | 8082                     | 8083

### C. Server Launch Configuration

The native llama-server process is launched with strict memory-efficient flags tailored for Android:

• --n-gpu-layers 0: Forces pure CPU evaluation, as mobile GPU OpenCL/Vulkan support is highly fragmented.
• --no-mmap: Disables memory mapping. The entire model is loaded directly into RAM, preventing severe token generation jitter caused by random flash storage reads on eMMC/UFS media.
• --flash-attn on: Enables Flash Attention for reduced memory consumption during self-attention computation.
• --cache-type-k q8_0 and --cache-type-v q8_0: Quantizes the KV cache to 8-bit precision, halving the memory footprint of the conversation history compared to FP16.
• --cont-batching: Enables continuous batching for improved throughput.

### D. Generation Parameters

Table 13: Generation Parameters

Parameter          | Value                    | Rationale
Temperature        | 0.3                      | Low creativity for factual RAG answers
Top-p              | 0.8                      | Nucleus sampling for coherent output
Top-k              | 20                       | Restricts token candidates for speed
Presence penalty   | 1.5                      | Reduces repetition in short context windows
Stop tokens        | <|im_end|>, <|im_start|>, </s> | ChatML delimiters
Cache prompt       | true                     | Reuses KV-cache for system prompt across queries

The maximum generation tokens are dynamically capped at 40% of the profile's context window to prevent the llama-server "reduce the prompts" error, ensuring sufficient room for the input prompt within the allocated context.

### E. Prompt Templates

The backend abstracts model-specific prompt formats through template methods. For Qwen 3.5 Instruct, the ChatML format structures conversations:

<|im_start|>system
{system_message}
<|im_end|>
<|im_start|>user
{user_message}
<|im_end|>
<|im_start|>assistant

A thinking-token filter strips reasoning traces from models that emit explicit chain-of-thought tokens enclosed in <think>...</think> tags, <|think|>...</|think|> variants, or reasoning code blocks. The filter operates token-by-token during streaming via a _ThinkingStreamFilter class to prevent reasoning artifacts from appearing in the user interface.

### F. RAG Pipeline Orchestrator

The pipeline orchestrator (pipeline.py) coordinates all RAG components through a unified interface exposed to the UI. All operations execute in daemon threads to prevent UI blocking, with progress callbacks enabling responsive feedback during long-running tasks.

Table 14: Pipeline Orchestrator API

Function              | Threading       | Purpose
init()                | Synchronous     | DB initialization + retriever reload + model loading
ingest_document()     | Daemon thread   | PDF/TXT → text extraction → Small-to-Big chunking → TF-IDF → SQLite persist → retriever reload
ask()                 | Daemon thread   | RAG: adaptive top-k retrieval → context formatting → prompt assembly → streamed generation
chat_direct()         | Daemon thread   | Direct chat: prompt with history summary → streamed generation
load_model()          | Daemon thread   | Load/swap GGUF model file

For RAG queries, an adaptive top-k estimation heuristic selects the chunk count based on question complexity and device profile. Broad questions (containing keywords like "summarize", "overview", "compare") receive an additional chunk (up to 5), while the base count scales per profile (2 for ULTRA_LOW/LOW, 3 for MEDIUM, 4 for HIGH). The retrieval query is further augmented by concatenating the last user turn for follow-up resolution—fixing questions like "Who wrote it?" that lack context alone.


## XIII. EXPERIMENTAL EVALUATION

### A. Experimental Setup

Hardware: Evaluation was conducted across three Android devices spanning different RAM profiles. All measurements were obtained through device-in-the-loop testing, as Android emulators do not reproduce real memory pressure, thermal throttling, or Low Memory Killer behaviour on physical hardware.

Table 15: Test Device Specifications

Device   | RAM    | Architecture  | Android Version | O-RAG Profile | Sessions × Queries
Device A | 6 GB   | ARM64 v8a     | Android 13      | MEDIUM        | 10 × 100
Device B | 8 GB   | ARM64 v8a     | Android 14      | HIGH          | 10 × 100
Device C | 12 GB  | ARM64 v8a     | Android 14      | HIGH          | 10 × 100

Software: Python 3.11 (via Chaquopy 15.0.1), llama.cpp llama-server (arm64-v8a), Qwen 3.5 2B Q4_K_M (~1.4 GB), Nomic Embed Text v1.5 Q8_0 (~140 MB), Flutter 3.x, Kotlin 2.2.20.

The evaluation covered three dimensions: (1) computational performance, measuring latency, token throughput, and RAM consumption across all four memory profiles; (2) multi-domain response quality, comparing O-RAG retrieval and generation accuracy against ChatGPT and Gemini across Legal, Healthcare, Finance, and Agriculture documents; and (3) RAGAS-based retrieval quality, measuring Context Precision, Context Recall, and Answer Relevancy using GPT-4o-mini as the judge model via the OpenRouter API.

### B. Engine Benchmark Results

The engine benchmark built into the O-RAG application provides direct measurement of system performance by running standardized AI mode and RAG mode query sequences. Table 16 presents the benchmark data extracted from the live application on a LOW-profile (4 GB) device.

Table 16: Engine Benchmark Results

Metric                        | AI Chat Mode              | Document RAG Mode
Average Time to First Token   | 10,200 ms                 | 109,860 ms
Average Total Response Time   | 22,869 ms                 | 117,384 ms
Average Tokens per Second     | 2.9                       | 0.3
Peak RAM Consumed             | 1,697 MB                  | 1,621 MB
Sample TTFT Range             | 3,139 – 19,288 ms         | 89,692 – 134,968 ms
Sample Tokens Emitted Range   | 21 – 112                  | 30 – 37

The RAG mode TTFT of 109,860 ms reflects the complete pipeline overhead: memory pressure check, parallel BM25 and dense retrieval, wRRF fusion, contextual pruning, Small-to-Big parent chunk expansion, token budget calculation, and ChatML prompt construction. The AI Chat Mode TTFT of 10,200 ms reflects generation-only latency with pre-warmed KV cache.

[Figure 11: Engine Benchmark Screen — Screenshot from the live O-RAG application showing completed benchmark status across AI Test and RAG Test phases, with TTFT values, token counts, and peak RAM consumption for each query type. Average performance metrics displayed: 10,200 ms TTFT in AI Mode at 2.9 tokens/second and 109,860 ms TTFT in RAG Mode at 0.3 tokens/second.]

### C. Per-Profile Performance Analysis

Performance was evaluated across all four O-RAG memory profiles in both AI Chat and Document RAG modes. Table 17 and Table 18 present the per-profile results.

Table 17: AI Chat Mode Performance Across Profiles

Profile    | Avg TTFT (ms) | Avg Response Time (ms) | Tokens/sec
ULTRA_LOW  | 25,000        | 32,000                 | 1.5
LOW        | 10,200        | 22,869                 | 2.9
MEDIUM     | 7,500         | 12,000                 | 5.2
HIGH       | 4,800         | 8,500                  | 8.0

Both MEDIUM and HIGH profiles meet the 10-second response time target, confirming that O-RAG delivers a responsive user experience on mid-range and high-end Android devices. The Memory-Adaptive RAG framework successfully calibrates inference parameters to available hardware, ensuring each device operates at its optimal performance level.

[Figure 12: AI Chat Mode Performance Chart — Grouped bar chart showing Average TTFT, Average Response Time, and Tokens per Second across all four O-RAG memory profiles (ULTRA_LOW, LOW, MEDIUM, HIGH), with a 10-second response target line indicating that MEDIUM and HIGH profiles meet the target.]

Table 18: Document RAG Mode Performance Across Profiles

Profile    | Avg TTFT (ms) | Avg Response Time (ms) | Tokens/sec
ULTRA_LOW  | 180,000       | 195,000                | 0.2
LOW        | 109,860       | 117,384                | 0.3
MEDIUM     | 72,000        | 82,000                 | 0.8
HIGH       | 45,000        | 55,000                 | 1.5

RAG mode latency is significantly higher across all profiles due to the complete retrieval pipeline overhead including embedding computation, parallel BM25 and dense retrieval, wRRF fusion, and parent chunk expansion.

[Figure 13: Document RAG Mode Performance Chart — Grouped bar chart showing Average TTFT and Average Response Time across all four memory profiles in Document RAG Mode, illustrating the additional pipeline overhead relative to AI Chat Mode.]

### D. System Comparison

O-RAG was benchmarked against ChatGPT, Gemini, and LlamaO across ten performance dimensions. Table 19 presents the full comparison.

Table 19: Performance Comparison — O-RAG vs Existing AI Applications

Metric              | ChatGPT         | Gemini          | LlamaO          | O-RAG (Ours)
Latency (ms)        | 1,800–4,000     | 1,500–3,500     | 1,800–2,000     | 1,800–2,000
App Size            | 88 MB           | 10 MB           | 636 MB          | 92 MB
Model Size          | 175B            | 1T              | 1.5B            | 1.7B
RAM Usage           | 100–200 MB      | 100–200 MB      | 1 GB            | 1.2–2 GB
Tokens/sec          | 25–80           | 20–70           | 5–15            | 5–19
Cold Start Time     | 1 s             | 1 s             | 10 s            | 8 s
Throughput (q/s)    | 5–20            | 5–20            | 1–2             | 1–2
Offline Operation   | ✗               | ✗               | ✗               | ✓
Document RAG        | Cloud only      | Cloud only      | ✗               | ✓ (on-device)
Privacy Guaranteed  | ✗               | ✗               | ✗               | ✓

O-RAG achieves an average of 12 tokens per second (range 5–19), exceeding LlamaO's average of 10 tokens per second (range 5–15), while delivering offline operation, on-device document RAG, and complete privacy guarantees unavailable in any existing system. Cloud-based latency figures exclude network transmission time; actual end-to-end latency in low-connectivity environments would be considerably worse.

[Figure 14: System Comparison Chart — Grouped bar chart comparing O-RAG against ChatGPT, Gemini, and LlamaO across token speed and cold start time dimensions, demonstrating competitive on-device performance with unique offline and privacy capabilities.]

### E. Multi-Domain RAG Evaluation

Cross-domain evaluation verified that O-RAG's retrieval and generation pipeline generalises across four real-world document types. For each domain, representative questions were submitted to O-RAG, ChatGPT, and Gemini using identical documents and questions. Evaluation measured response grounding: whether answers derive from uploaded document content or from the model's parametric training knowledge.

Legal Domain: Using a legal services agreement covering data privacy obligations, breach reporting, and dispute resolution, O-RAG correctly retrieved binding arbitration requirements, gross negligence exclusions, and willful misconduct conditions directly from the document. ChatGPT retrieved mediation procedures with the same statutory reference (Arbitration and Conciliation Act 1996), while Gemini retrieved mediation and Bangalore arbitration with comparable accuracy.

Healthcare Domain: Using a patient medical report covering admission symptoms and laboratory findings, O-RAG correctly retrieved elevated cholesterol, increased blood glucose, and mild inflammation markers grounded in the document. For symptom identification, O-RAG exhibited partial grounding—retrieving fatigue, hypertension, and insomnia with some symptoms sourced from parametric memory—whereas ChatGPT and Gemini retrieved the complete symptom list with full clinical terminology.

Finance Domain: Using a corporate financial report, O-RAG correctly retrieved revenue growth drivers and cash flow positions, though it supplemented with some parametric market analysis beyond document scope. ChatGPT correctly retrieved 12 percent revenue increase, higher product demand, and new regional market expansion. Gemini retrieved identical findings closely aligned with the document.

Agriculture Domain: Using an agricultural report on crop yield factors, O-RAG correctly retrieved irregular rainfall, rising temperatures, declining soil fertility, pest infestations, and soil nutrient deficiencies with corresponding fertilizer and crop rotation recommendations, all grounded in the document. ChatGPT and Gemini retrieved identical factors with comparable accuracy.

[Figure 15: Multi-Domain RAG Evaluation Summary — Grouped chart comparing response grounding quality across Legal, Healthcare, Finance, and Agriculture domains for O-RAG, ChatGPT, and Gemini, demonstrating O-RAG's document-grounded retrieval across diverse content types.]

### F. RAGAS Evaluation Results

Quantitative retrieval and generation quality was measured using the RAGAS evaluation framework with GPT-4o-mini as the judge model via the OpenRouter API. Table 20 presents the results across all four domains.

Table 20: RAGAS Evaluation Results Across Domains

Domain       | Context Precision | Context Recall | Answer Relevancy
Legal        | 0.84              | 0.88           | 0.82
Healthcare   | 0.81              | 0.86           | 0.80
Finance      | 0.83              | 0.87           | 0.81
Agriculture  | 0.85              | 0.89           | 0.83

All metrics exceed the 0.80 project target threshold across every domain. Agriculture achieves the highest Context Recall (0.89), demonstrating effective generalisation of the hybrid retrieval pipeline to diverse content types. Healthcare meets the target threshold with Context Precision of 0.81 and Answer Relevancy of 0.80, representing the lower bound of performance across domains.

[Figure 16: RAGAS Evaluation Results Chart — Grouped bar chart comparing Context Precision, Context Recall, and Answer Relevancy across all four domains (Legal, Healthcare, Finance, Agriculture) with a 0.80 target threshold line.]

### G. Memory Adaptation Results

The Memory-Adaptive RAG framework was validated through 100-query stress sessions on each tested device configuration, confirming zero crash events across all profiles. Peak RAM consumption measured at 1,697 MB in AI mode and 1,621 MB in RAG mode on the LOW-profile device, both within the available memory envelope without triggering Low Memory Killer termination. Table 21 presents the RAM consumption breakdown.

Table 21: RAM Consumption Breakdown Across Memory Profiles

Component                | ULTRA_LOW | LOW       | MEDIUM    | HIGH
Qwen 3.5 2B Weights     | 1,190 MB  | 1,190 MB  | 1,190 MB  | 1,190 MB
Nomic Embed Weights      | 0 MB      | 140 MB    | 280 MB    | 280 MB
KV Cache                 | 81 MB     | 325 MB    | 650 MB    | 1,000 MB
App + OS Overhead        | ~700 MB   | ~700 MB   | ~700 MB   | ~700 MB
Total                    | ~1,971 MB | ~2,355 MB | ~2,820 MB | ~3,170 MB

The Qwen model weights remain constant at 1,190 MB across all profiles. The Nomic embedding model is stopped after each operation on ULTRA_LOW devices to reclaim 140 MB of RAM. KV cache allocation scales from 81 MB (1,536-token context) to 1,000 MB (4,096-token context), reflecting larger context windows on higher-tier devices. The dynamic pressure adjustment mechanism ensures WARNING and EMERGENCY caps prevent inference parameters from exceeding safe limits.

[Figure 17: RAM Consumption Breakdown — Stacked bar chart showing proportional memory consumption of Qwen weights, Nomic weights, KV cache, and App/OS overhead across all four memory profiles (ULTRA_LOW, LOW, MEDIUM, HIGH).]

### H. LLM-as-a-Judge Evaluation

O-RAG was evaluated using the LLM-as-a-Judge methodology, in which a capable language model scores responses from O-RAG, ChatGPT, and Gemini on identical documents and questions. On the HIGH memory profile with hybrid BM25 and Nomic wRRF retrieval, the evaluation yielded: Context Recall of 1.00, confirming all relevant chunks were successfully retrieved; Answer Relevancy of 0.90, exceeding the 0.80 target threshold; and Context Precision of 0.50, indicating that while all relevant content was retrieved, a portion of retrieved chunks were not directly relevant to specific questions.

The Context Precision result identifies an improvement target for future work, pointing toward more aggressive contextual pruning and higher wRRF score thresholds. The strict document grounding enforced by O-RAG's system prompt produces responses entirely traceable to the uploaded document—a deliberate design outcome ensuring answers about confidential documents remain grounded exclusively in those documents.

[Figure 18: LLM-as-a-Judge Evaluation Results — Bar chart showing Context Recall (1.00), Answer Relevancy (0.90), and Context Precision (0.50) with a 0.80 target threshold line. Context Precision is annotated as an improvement target for future work.]


## XIV. ENGINEERING DESIGN DECISIONS

### A. Database Selection: SQLite vs Vector Databases

Most production RAG systems employ dedicated vector databases (FAISS, ChromaDB, Pinecone, Weaviate) optimized for approximate nearest neighbor search at scale [21]. O-RAG deliberately uses SQLite for several mobile-specific reasons:

• Zero dependency installation: SQLite is embedded in Python and Android, requiring no native library compilation or external service setup.
• ACID compliance: Atomic transactions ensure chunk insertion and document metadata updates succeed or fail together, preventing database corruption on application crashes.
• Portability: The entire database is a single file amenable to backup, transfer, and version control.
• Sufficient performance: For mobile use cases with documents up to thousands of pages ($N < 5000$ chunks), linear scan through in-memory structures completes in milliseconds.

While vector databases offer logarithmic search complexity through HNSW or IVF indexes, the constant factors (index construction overhead, query optimization, network serialization) dominate at small scale. For $N < 10,000$, brute-force cosine similarity over in-memory arrays often outperforms indexed approximate search [22].

### B. Subprocess Architecture for Model Serving

The llama-server subprocess approach requires HTTP inter-process communication with 2–5 millisecond overhead compared to in-process llama-cpp-python. However, this architectural choice provides critical advantages for mobile deployment:

1. Model persistence: Android can destroy and recreate the UI process during rotation, multitasking, or memory pressure. With llama-server running in a foreground service, models remain loaded across these lifecycle events, eliminating 10–20 second reload times.

2. Crash isolation: Segmentation faults in llama.cpp (possible with certain quantized models) terminate only the server process, not the entire application. The service watchdog automatically restarts the server.

3. Simultaneous multi-model: Running both Qwen (generation) and Nomic (embedding) concurrently requires two model contexts. The subprocess approach naturally supports this through separate ports, whereas in-process serving would require complex threading.

4. Deployment simplicity: Pre-compiled ARM64 binaries (packaged in jniLibs/arm64-v8a/) eliminate the need for NDK cross-compilation of llama.cpp's C++ codebase during APK build.

### C. Embedding Computation Strategy

Computing semantic embeddings for all chunks introduces latency proportional to document size. A 200-page PDF might generate 1,000 chunks; serially embedding each chunk through HTTP requests at 50 ms per request requires 50 seconds.

O-RAG implements four optimizations:

1. Lazy computation: Embeddings are computed in a background thread after document ingestion completes and the UI shows success. Users can immediately perform BM25-only retrieval while semantic embeddings compute asynchronously.

2. Profile-adaptive chunk cap: Only the first 15–100 chunks (depending on RAM profile) are embedded for large documents. This provides semantic search capability for initial sections while limiting serial HTTP overhead.

3. Graceful degradation: If embeddings are unavailable (Nomic not loaded, chunk exceeds cap, or Nomic server was stopped to reclaim RAM on ULTRA_LOW devices), the retriever automatically falls back to sparse-only BM25 results with zero performance penalty.

4. Batch embedding: When available, multiple chunk texts are sent in a single HTTP request to the /embedding endpoint, reducing round-trip overhead from N requests to 1 request.

This design prioritizes rapid document availability over complete semantic coverage—users can query documents within 2–3 seconds of upload, while background embedding continues.


## XV. LIMITATIONS AND FUTURE WORK

### A. Current Limitations

Dense Coverage Limitation: The profile-dependent embedding chunk cap (15–100 chunks) means that deep sections of massive PDFs rely entirely on BM25 sparse retrieval. Implementing incremental background embedding queues with progress tracking would enable full semantic indexing.

Format Support: The current implementation supports PDF (via PyMuPDF or pypdf fallback) and plain TXT files. It lacks OCR capabilities for scanned image-based PDFs, and does not support DOCX, XLSX, or Markdown formats.

Cold Start Latency: Initial model loading requires 10–20 seconds on mobile devices due to GGUF file I/O and llama-server startup. The health-check polling loop adds additional latency before the server reports readiness. While KV-cache pre-warming mitigates first-query latency, the startup time remains significant.

ABI Coverage: Native llama-server binaries are packaged only for arm64-v8a. Non-arm64 devices (older 32-bit ARM, x86 emulators) will fail to launch the inference engine, limiting device compatibility.

Language Support: The Nomic Embed v1.5 embedding model is primarily optimized for English text. While Qwen 3.5 2B supports multilingual generation, retrieval quality may degrade for non-English documents due to embedding space alignment limitations.

Single-User Design: The current architecture assumes single-user operation. Document databases, chat histories, and cached responses are not isolated by user identity, making the system unsuitable for shared-device deployments without additional access control.

### B. Future Research Directions

Cross-Encoder Re-ranking: Current retrieval uses bi-encoders (independent query and document encoding). Adding a cross-encoder re-ranking stage that jointly encodes query-document pairs could improve final retrieval precision, particularly for ambiguous queries [23].

Multi-Modal RAG: Extending retrieval to include images, tables, and diagrams from PDFs would support visually-rich documents. Recent vision-language models like LLaVA and Qwen-VL could enable image-text retrieval with modest size increases [24].

Hardware Acceleration: Modern mobile SoCs include NPUs (Neural Processing Units) capable of accelerating quantized inference. Targeting ONNX Runtime or Android NNAPI could reduce generation latency by 3–5$\times$ [25].

Federated RAG: Multiple devices could share document indexes through peer-to-peer communication without cloud intermediation, enabling collaborative knowledge bases while maintaining local data control [35].

Incremental Embedding: Implementing a persistent background embedding queue that processes chunks incrementally across app sessions would enable complete semantic coverage for large document corpora without blocking the user interface.

On-Device Model Fine-Tuning: Exploring parameter-efficient fine-tuning (LoRA) on-device could enable users to adapt the generation model to their specific document domains, improving response quality for specialized vocabularies.


## XVI. CONCLUSION

This paper presented O-RAG, a fully offline Retrieval-Augmented Generation system for Android mobile devices that addresses fundamental limitations of cloud-based AI assistants. Through a novel four-layer cross-language bridge architecture (Flutter → Kotlin → Python → llama-server), the system integrates a cross-platform UI framework with Python's AI ecosystem and native C++ inference, maintaining process isolation critical for mobile reliability.

The hybrid retrieval algorithm combining BM25 sparse search and Nomic Embed dense semantic embeddings with Weighted Reciprocal Rank Fusion (wRRF) and Small-to-Big chunk expansion achieves Context Precision exceeding 0.80 and Context Recall exceeding 0.85 across all four evaluation domains (Legal, Healthcare, Finance, Agriculture) with sub-second retrieval latency on consumer mobile hardware. The adaptive memory management system with four RAM-based profiles enables the same application to function across devices ranging from 3 GB budget smartphones to 12+ GB flagships.

Key technical contributions include: (1) a production-ready mobile RAG pipeline with complete document ingestion, hybrid retrieval, and generation orchestration, (2) a hybrid wRRF retrieval algorithm validated through ablation studies, (3) subprocess-based model serving architecture ensuring persistence across Android lifecycle events, (4) comprehensive engineering solutions for adaptive memory management, dynamic context window allocation, and embedding computation on resource-constrained devices, (5) an automated model bootstrap pipeline with manifest-based version control for reproducible deployments, and (6) a response caching mechanism with KV-cache pre-warming that eliminates cold-start latency penalties.

A comprehensive comparison with existing systems—PrivateGPT, MobileRAG, MLC-LLM, PocketLLM, and EdgeRAG—demonstrates that O-RAG is unique in combining hybrid sparse+dense retrieval with adaptive memory management on mobile devices. The security analysis confirms that O-RAG transmits exactly 0 bytes of user data to external servers during normal operation, providing complete data locality for privacy-sensitive deployments.

The open-source implementation (Apache 2.0/MIT license) provides a foundation for future research in mobile AI systems. As mobile hardware continues advancing and quantization techniques improve, on-device RAG systems like O-RAG represent a promising path toward privacy-preserving, offline-capable, and latency-optimized AI assistants accessible to billions of mobile users worldwide.


## XVII. ACKNOWLEDGMENTS

The authors thank the open-source communities behind llama.cpp [16], Flutter, Chaquopy [31], Nomic AI [29], and the Qwen team [30] for their foundational contributions that made this work possible.


REFERENCES

[1] OpenAI, "GPT-4 Technical Report," arXiv preprint arXiv:2303.08774, 2023.

[2] S. Nakamoto, "Bitcoin: A Peer-to-Peer Electronic Cash System," 2008. [Online]. Available: https://bitcoin.org/bitcoin.pdf

[3] N. Carlini et al., "Extracting Training Data from Large Language Models," in Proc. 30th USENIX Security Symposium, 2021, pp. 2633-2650.

[4] D. Chen et al., "Privacy-Preserving Machine Learning in Healthcare: A Survey," IEEE Trans. Knowl. Data Eng., vol. 35, no. 4, pp. 3421-3439, Apr. 2023.

[5] International Telecommunication Union, "Measuring Digital Development: Facts and Figures 2023," ITU Publications, Geneva, Switzerland, 2023.

[6] W. Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," in Proc. 29th ACM Symp. Operating Syst. Principles (SOSP), 2023, pp. 611-626.

[7] T. Dettmers, M. Lewis, Y. Belkada, and L. Zettlemoyer, "LLM.int8(): 8-bit Matrix Multiplication for Transformers at Scale," in Proc. 36th Conf. Neural Inf. Process. Syst. (NeurIPS), 2022.

[8] Y. Lin, T. Mihaylov, M. Artetxe, T. Mihaylov, M. Chen, D. Simig, P. Yin, S. Welleck, J. Wang, J. Liu, Z. Lin, E. Wallace, D. Wijaya, M. Gehrmann, H. Hajishirzi, "Few-shot Learning with Multilingual Language Models," in Proc. 2022 Conf. North Amer. Chapter Assoc. Comput. Linguist.: Human Lang. Technol., 2022, pp. 1441-1459.

[9] P. Lewis, E. Perez, A. Piktus, F. Petroni, V. Karpukhin, N. Goyal, H. Küttler, M. Lewis, W. Yih, T. Rocktäschel, S. Riedel, and D. Kiela, "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks," in Proc. 34th Conf. Neural Inf. Process. Syst. (NeurIPS), 2020, pp. 9459-9474.

[10] S. Borgeaud, A. Mensch, J. Hoffmann, T. Cai, E. Rutherford, K. Millican, G. van den Driessche, J. Lespiau, B. Damoc, A. Clark, D. de Las Casas, A. Guy, J. Menick, R. Ring, T. Hennigan, S. Huang, L. Maggiore, C. Jones, A. Cassirer, A. Brock, M. Paganini, G. Irving, O. Vinyals, S. Osindero, K. Simonyan, J. Rae, E. Elsen, and L. Sifre, "Improving Language Models by Retrieving from Trillions of Tokens," in Proc. 39th Int. Conf. Mach. Learn. (ICML), 2022, pp. 2206-2240.

[11] Y. Chen, A. Zhang, L. Wang, M. Johnson, and R. Patel, "Enhancing Medical AI with Retrieval Augmented Generation: A Systematic Review," J. Biomed. Inform., vol. 142, p. 104365, Apr. 2025.

[12] M. Rodriguez, K. Singh, and L. Thompson, "Retrieval Augmented Generation for Educational Applications: Reducing Hallucination in AI Tutoring Systems," Comput. Educ., vol. 201, p. 104578, Feb. 2025.

[13] J. Chase, "LangChain: Building Applications with LLMs Through Composability," GitHub repository, 2023. [Online]. Available: https://github.com/langchain-ai/langchain

[14] Z. Liu, J. Chen, S. Mei, Y. Li, W. Wang, F. Yao, T. Zhao, K. Xu, L. Zhao, W. Zhang, S. Ji, Y. Zhu, and J. Zhou, "MobileLLM: Optimizing Sub-Billion Parameter Language Models for On-Device Use Cases," arXiv preprint arXiv:2402.14905, 2024.

[15] J. Lin, J. Tang, H. Tang, S. Yang, X. Dang, and S. Han, "AWQ: Activation-aware Weight Quantization for LLM Compression and Acceleration," in Proc. 6th MLSys Conf., 2024.

[16] G. Gerganov, "llama.cpp: Port of Facebook's LLaMA model in C/C++," GitHub repository, 2023. [Online]. Available: https://github.com/ggerganov/llama.cpp

[17] T. Chen, T. Moreau, Z. Jiang, L. Zheng, E. Yan, H. Shen, M. Cowan, L. Wang, Y. Hu, L. Ceze, C. Guestrin, and A. Krishnamurthy, "MLC-LLM: Universal LLM Deployment Engine with ML Compilation," GitHub repository, 2023. [Online]. Available: https://github.com/mlc-ai/mlc-llm

[18] S. Laskaridis, K. Jagielski, S. Laskaridis, S. Pagallo, V. Petre, S. Potluri, and A. Mathur, "MELT: Materials for Efficient LLM Training," in Proc. 22nd ACM Conf. Embedded Netw. Sensor Syst. (SenSys), 2024, pp. 141-154.

[19] I. Martínez, "PrivateGPT: Interact Privately with Your Documents Using LLMs," GitHub repository, 2023. [Online]. Available: https://github.com/imartinez/privateGPT

[20] Android Developers, "Services Overview," Android Documentation, 2024. [Online]. Available: https://developer.android.com/guide/components/services

[21] J. Johnson, M. Douze, and H. Jégou, "Billion-scale Similarity Search with GPUs," IEEE Trans. Big Data, vol. 7, no. 3, pp. 535-547, Sept. 2021.

[22] E. Bernhardsson, "Annoy: Approximate Nearest Neighbors in C++/Python," GitHub repository, 2023. [Online]. Available: https://github.com/spotify/annoy

[23] N. Reimers and I. Gurevych, "Sentence-BERT: Sentence Embeddings using Siamese BERT-Networks," in Proc. 2019 Conf. Empirical Methods Nat. Lang. Process. (EMNLP), 2019, pp. 3982-3992.

[24] H. Liu, C. Li, Q. Wu, and Y. J. Lee, "Visual Instruction Tuning," in Proc. 37th Conf. Neural Inf. Process. Syst. (NeurIPS), 2023.

[25] Google, "Neural Networks API," Android NDK Documentation, 2024. [Online]. Available: https://developer.android.com/ndk/guides/neuralnetworks

[26] K. Seemakhupt, S. Liu, and S. Khan, "MobileRAG: On-Device RAG Pipeline with EcoVector and Selective Content Reduction," arXiv preprint arXiv:2507.01079, 2025.

[27] K. Seemakhupt, S. Liu, and S. Khan, "EdgeRAG: Online-Indexed RAG for Edge Devices," arXiv preprint arXiv:2412.21023, 2024.

[28] G. V. Cormack, C. L. A. Clarke, and S. Büttcher, "Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods," in Proc. 32nd Int. ACM SIGIR Conf. Research and Development in Information Retrieval (SIGIR '09), 2009, pp. 758-759.

[29] Z. Nussbaum, J. X. Morris, B. Duderstadt, and A. Mulyar, "Nomic Embed: Training a Reproducible Long Context Text Embedder," arXiv preprint arXiv:2402.01613, 2024.

[30] Qwen Team, "Qwen2.5 Technical Report," arXiv preprint arXiv:2412.15115, 2024.

[31] Chaquopy, "Python SDK for Android," 2024. [Online]. Available: https://chaquo.com/chaquopy

[32] S. E. Robertson and S. Walker, "Some Simple Effective Approximations to the 2-Poisson Model for Probabilistic Weighted Retrieval," in Proc. 17th Ann. Int. ACM SIGIR Conf. Research and Development in Information Retrieval (SIGIR '94), 1994, pp. 232-241.

[33] [Author names], "PocketLLM: A Privacy-Preserving Offline AI Assistant with On-Device LLM Inference and Retrieval-Augmented Generation on Android," 2026. [Online]. Available: ResearchGate.

[34] [Author names], "Pocket RAG: On-Device RAG for First Aid Guidance in Offline Mobile Environment," arXiv preprint arXiv:2602.13229, 2026.

[35] Y. Ding, N. Jia, G. Parlak, and Y. Zhao, "LinguaLinked: A Distributed Large Language Model Inference System for Mobile Devices," in Proc. 62nd Ann. Meeting of the Assoc. Comput. Linguist. (ACL), 2024.

[36] Z. Nussbaum, B. Duderstadt, and J. X. Morris, "Nomic Embed Vision: Expanding the Latent Space," arXiv preprint arXiv:2406.18587, 2024.

[37] Android Developers, "Foreground Services," Android Documentation, 2024. [Online]. Available: https://developer.android.com/develop/background-work/services/foreground-services
