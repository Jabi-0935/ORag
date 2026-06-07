class BenchmarkMockData {
  static const List<String> distinctChunks = [
    "Artificial intelligence is the simulation of human intelligence processes by machines, especially computer systems.",
    "Flutter is an open-source UI software development kit created by Google, used to develop cross-platform applications.",
    "Retrieval-Augmented Generation (RAG) is a technique that grants AI models access to external knowledge bases.",
    "The Dart programming language was initially designed by Lars Bak and Kasper Lund and released by Google.",
    "Quantization in machine learning reduces the precision of the numbers used to represent a model's parameters.",
    "Mobile edge computing allows data processing to occur closer to the data source, reducing latency and bandwidth use.",
    "State management in Flutter can be achieved using various approaches, including Provider, Riverpod, and BLoC.",
    "Transformer architectures rely heavily on the self-attention mechanism to process sequences of data efficiently.",
    "Vector databases are optimized to store and query high-dimensional vectors, making them essential for semantic search.",
    "Out-Of-Memory (OOM) errors occur when an application attempts to allocate more RAM than the operating system can provide.",
    "The integration of SQLite on mobile devices provides a lightweight, serverless relational database for local storage.",
    "ONNX (Open Neural Network Exchange) provides a standard format to represent deep learning models across frameworks.",
    "Garbage collection in Dart operates in generations, optimizing the cleanup of short-lived objects.",
    "Hardware acceleration uses specialized hardware, like GPUs or NPUs, to perform computing tasks faster than a CPU.",
    "Embeddings are dense numerical representations of text, capturing semantic meaning and context in continuous vector space.",
    "A MethodChannel in Flutter allows seamless communication between Dart code and platform-specific native code.",
    "Inference is the process of using a trained machine learning model to make predictions on new, unseen data.",
    "Memory-mapped files (mmap) allow an application to access a file on disk as if it were loaded entirely into RAM.",
    "Zero-shot learning refers to a model's ability to complete a task without receiving any specific training examples for it.",
    "The context window of a Large Language Model determines the maximum number of tokens it can process in a single pass.",
    "Thermal throttling happens when a device slows down its processor speed to prevent overheating during intensive tasks.",
    "Federated learning enables models to be trained across multiple decentralized devices holding local data samples.",
    "Declarative UI frameworks, like Flutter and Jetpack Compose, build the interface based on the current state.",
    "Cosine similarity is a widely used metric to measure the semantic similarity between two embedding vectors.",
    "Llama.cpp is a popular C/C++ port of the LLaMA model inference engine, optimized for running on consumer hardware.",
    "Hot reload in Flutter injects updated source code files into the running Dart Virtual Machine, speeding up development.",
    "Knowledge graphs structure information as nodes and edges, offering a highly connected way to represent facts.",
    "Differential privacy adds statistical noise to data, ensuring individual privacy while maintaining aggregate utility.",
    "Asynchronous programming in Dart uses Futures and Streams to handle non-blocking operations efficiently.",
    "Prompt engineering is the art of structuring input queries to guide AI models toward generating optimal outputs.",
    "Neural Processing Units (NPUs) are specialized microprocessors designed specifically to accelerate AI operations.",
    "A token in the context of LLMs is a fundamental unit of text, which can be a word, part of a word, or a single character.",
    "JIT (Just-In-Time) compilation compiles code at runtime, while AOT (Ahead-Of-Time) compilation compiles before execution.",
    "Semantic chunks are segments of text divided based on meaning and context rather than strict character limits.",
    "Cross-entropy loss is a common loss function used in classification tasks to measure the performance of a model.",
    "The Flutter engine is written primarily in C++, providing low-level rendering support using Skia or Impeller.",
    "Fine-tuning involves taking a pre-trained model and training it further on a domain-specific dataset.",
    "Background isolates in Dart allow developers to run heavy computations on separate threads to keep the UI smooth.",
    "K-Nearest Neighbors (KNN) algorithms are often used to find the most relevant documents in a vector space.",
    "Battery optimization on mobile devices often restricts background processes to extend the device's operational time.",
    "Generative Adversarial Networks (GANs) consist of a generator and a discriminator competing against each other.",
    "A widget in Flutter is an immutable description of part of a user interface, forming the building blocks of the app.",
    "Local AI execution ensures data privacy by keeping sensitive information strictly on the user's personal device.",
    "The attention mechanism allows models to weigh the importance of different parts of the input sequence dynamically.",
    "BM25 is a robust and highly effective ranking function used in information retrieval to score document relevance.",
    "Platform channels serialize data using standard message codecs to pass variables securely between Dart and Native code.",
    "An activation function in a neural network defines the output of a node given an input or set of inputs.",
    "Static typing in Dart helps catch errors at compile-time rather than at runtime, improving code reliability.",
    "Context stuffing is the process of appending retrieved chunks to a user's prompt before passing it to the language model.",
    "The transition to mobile AI represents a major shift toward edge computing, reducing reliance on expensive cloud infrastructure."
  ];

  static String generateMockDocument() {
    final buffer = StringBuffer();
    for (int i = 0; i < distinctChunks.length; i++) {
      buffer.writeln('Chunk ${i + 1}: ${distinctChunks[i]}\n');
    }
    return buffer.toString();
  }
}
