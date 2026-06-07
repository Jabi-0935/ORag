# O-RAG — Offline Retrieval-Augmented Generation

A fully offline mobile AI assistant that runs on-device with no cloud dependency. Upload PDF/TXT documents and ask questions — the AI retrieves relevant passages and generates answers using local LLMs.

## Architecture

```
Flutter UI  ←→  Kotlin (MainActivity)  ←→  Python (Chaquopy)
                MethodChannel/EventChannel
```

| Layer | Key Files | Purpose |
|-------|-----------|---------|
| **Flutter** | `lib/screens/chat_screen.dart` | Chat UI with Riverpod state management |
| **Flutter** | `lib/controllers/chat_controller.dart` | Centralized business logic |
| **Flutter** | `lib/services/platform_service.dart` | Flutter ↔ native bridge |
| **Kotlin** | `android/.../MainActivity.kt` | Chaquopy Python runtime + channel routing |
| **Python** | `android/.../python/pipeline.py` | Orchestrates ingest, retrieval, generation |
| **Python** | `android/.../python/retriever.py` | Hybrid BM25 + Dense retriever with wRRF |
| **Python** | `android/.../python/llm.py` | llama-server management + prompt building |

### RAG Pipeline

1. **Ingest:** PDF/TXT → Small chunks (100 words) + Parent chunks (400 words) → TF-IDF + FTS5 index
2. **Retrieve:** Query → FTS5 BM25 (sparse) + Nomic Embed (dense) → Weighted RRF fusion → Contextual pruning
3. **Expand:** Top-2 small chunks → parent chunk expansion (Small-to-Big)
4. **Generate:** Expanded context + query → Qwen 3.5 2B (Q4_K_M) via llama-server

### Models

| Model | Purpose | Size | Quantization |
|-------|---------|------|-------------|
| Qwen 3.5 2B | Chat & RAG generation | ~1.5 GB | Q4_K_M |
| Nomic Embed v1.5 | Dense semantic search | ~140 MB | Q8_0 |

Models are auto-downloaded on first launch from Hugging Face.

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Flutter | 3.22+ | `flutter doctor` must pass |
| Java/JDK | 17 | Required by AGP |
| Python | 3.11 | Chaquopy runtime target |
| Android SDK | API 34 | With NDK for native binaries |
| Git LFS | 3.x+ | For `libllama_server.so` (>100 MB) |

### Git LFS Setup

The native `libllama_server.so` binary is stored via Git LFS. After cloning:

```bash
git lfs install
git lfs pull
```

Verify the binary is not a pointer file:

```bash
file orag/android/app/src/main/jniLibs/arm64-v8a/libllama_server.so
# Should show: ELF 64-bit LSB shared object, ARM aarch64
```

---

## Local Development

### 1. Clone & Setup

```bash
git clone <repo-url>
cd orag/orag
flutter pub get
```

### 2. USB Debugging (Recommended)

Connect an Android device via USB with Developer Options + USB Debugging enabled:

```bash
flutter devices          # verify device is listed
flutter run --release    # deploy to device
```

### 3. Environment Variables (Optional)

| Variable | Effect |
|----------|--------|
| `CHAQUOPY_PYTHON=3.11` | Explicit Python version for Chaquopy |
| `ORAG_FORCE_BOOTSTRAP_DOWNLOAD=1` | Force re-download of models |

---

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/android-release.yml`) triggers on pushes to the `moksha` branch:

1. **Setup:** Java 17, Flutter, Python 3.11, Git LFS
2. **Test:** `flutter test` (unit + widget tests)
3. **Build:** Universal APK + AAB with Chaquopy
4. **Artifact:** Uploads APK/AAB as GitHub release artifacts

### Key Gradle Settings

- **ABI filters:** `armeabi-v7a`, `arm64-v8a`, `x86_64` (required by Chaquopy)
- **Memory:** `-Xmx8g -XX:MaxMetaspaceSize=4g` (prevents CI OOM)
- **Native packaging:** `useLegacyPackaging = true` (jniLibs accessible at runtime)

---

## Project Structure

```
orag/
├── lib/
│   ├── controllers/     # Riverpod state controllers
│   ├── models/          # ChatMessage, SourceAttribution, SourceImage
│   ├── screens/         # ChatScreen, SplashScreen, SettingsScreen
│   ├── services/        # PlatformService (native bridge)
│   ├── theme/           # AppTheme, AppColors
│   └── widgets/         # ChatBubble, ChatInputBar, InitOverlay, etc.
├── android/app/src/main/
│   ├── kotlin/.../MainActivity.kt   # Chaquopy bridge
│   ├── python/                       # RAG backend
│   │   ├── api.py                    # Flutter ↔ Python API surface
│   │   ├── pipeline.py               # Ingest + query orchestration
│   │   ├── retriever.py              # Hybrid BM25 + Dense + wRRF
│   │   ├── chunker.py                # Text extraction + chunking
│   │   ├── storage.py                # SQLite + FTS5 storage
│   │   ├── llm.py                    # LLM backend management
│   │   ├── downloader.py             # Model download + bootstrap
│   │   └── runtime/                  # Model lifecycle
│   └── jniLibs/                      # Native binaries (Git LFS)
├── test/                             # Unit + widget tests
└── pubspec.yaml
```

---

## License

See [LICENSE](LICENSE) for details.
