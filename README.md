# ORag Multimodal

ORag is a fully private, offline Retrieval-Augmented Generation (RAG) assistant built natively for Android. The project integrates a Flutter frontend with an embedded Python engine (via Chaquopy) and native C++ execution (via llama.cpp) to run everything on-device without internet access.

## Key Features
- **Local Inferencing**: Leverages `llama-server` compiled specifically for Android `arm64-v8a` to provide fast, local large language model interactions.
- **On-Device RAG Pipeline**: Employs an exact vector search alongside BM25 indexing over your PDF/TXT documents, orchestrated entirely in on-device Python.
- **Streaming Generation**: The Flutter UI hooks directly into the server chunk stream to provide real-time typography with `ChatML` templates.
- **Privacy First**: Zero data leaves your device. Documents, models, and queries remain in local storage.

## Building and Distributing

If you wish to create a release build (with your production Keystore):

```powershell
flutter build apk --release --target-platform android-arm64
```

The resulting optimized `.apk` will be available in `build/app/outputs/flutter-apk/app-release.apk`.

## Requirements
- Flutter SDK (latest stable)
- Android SDK, NDK (Version 26+), and CMake
- Android device with `arm64-v8a` processor
