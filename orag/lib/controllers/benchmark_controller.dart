import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../services/platform_service.dart';
import '../utils/benchmark_mock_data.dart';

enum BenchmarkPhase {
  idle,
  runningAI,
  generatingDoc,
  ingestingDoc,
  runningRAG,
  finished,
  error,
}

class BenchmarkState {
  final BenchmarkPhase phase;
  final String currentTask;
  final double progress;
  final List<String> logs;
  final Map<String, dynamic> aiResults;
  final Map<String, dynamic> ragResults;

  BenchmarkState({
    this.phase = BenchmarkPhase.idle,
    this.currentTask = '',
    this.progress = 0.0,
    this.logs = const [],
    this.aiResults = const {},
    this.ragResults = const {},
  });

  BenchmarkState copyWith({
    BenchmarkPhase? phase,
    String? currentTask,
    double? progress,
    List<String>? logs,
    Map<String, dynamic>? aiResults,
    Map<String, dynamic>? ragResults,
  }) {
    return BenchmarkState(
      phase: phase ?? this.phase,
      currentTask: currentTask ?? this.currentTask,
      progress: progress ?? this.progress,
      logs: logs ?? this.logs,
      aiResults: aiResults ?? this.aiResults,
      ragResults: ragResults ?? this.ragResults,
    );
  }
}

class BenchmarkController extends StateNotifier<BenchmarkState> {
  final PlatformService _platform;

  BenchmarkController(this._platform) : super(BenchmarkState());

  void _log(String message) {
    state = state.copyWith(logs: [...state.logs, message]);
  }

  Future<void> startBenchmark() async {
    if (state.phase != BenchmarkPhase.idle && state.phase != BenchmarkPhase.finished && state.phase != BenchmarkPhase.error) {
      return;
    }

    state = BenchmarkState(phase: BenchmarkPhase.runningAI, currentTask: 'Preparing AI test...');

    try {
      final aiQuestions = [
        "Explain the theory of relativity in 3 sentences.",
        "Write a haiku about a robot.",
        "What are the main benefits of using Flutter?"
      ];

      final aiMetrics = await _runTestPhase(aiQuestions, isRag: false);

      state = state.copyWith(
        phase: BenchmarkPhase.generatingDoc,
        currentTask: 'Generating mock document (~50 chunks)...',
        progress: 0.0,
        aiResults: aiMetrics,
      );

      _log('AI Test completed.');
      _log('Generating temporary document...');

      // Generate mock document
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/benchmark_mock.txt');
      
      final mockText = BenchmarkMockData.generateMockDocument();
      await tempFile.writeAsString(mockText);

      state = state.copyWith(
        phase: BenchmarkPhase.ingestingDoc,
        currentTask: 'Ingesting mock document...',
      );
      _log('Uploading temporary document to knowledge base...');

      final uploadResult = await _platform.uploadDocument(tempFile.path);
      if (uploadResult['success'] != true) {
        throw Exception('Failed to upload document: ${uploadResult['message']}');
      }

      state = state.copyWith(
        phase: BenchmarkPhase.runningRAG,
        currentTask: 'Running RAG tests...',
      );
      _log('Document ingested successfully.');

      final ragQuestions = [
        "What is the O-RAG system?",
        "Why do mobile devices benefit from local models?",
        "How does the system prevent Out-Of-Memory errors?"
      ];

      final ragMetrics = await _runTestPhase(ragQuestions, isRag: true);
      _log('RAG Test completed.');

      // Cleanup
      _log('Cleaning up temporary document...');
      final docs = await _platform.listDocuments();
      for (var doc in docs) {
        if (doc['name'] == 'benchmark_mock.txt') {
          await _platform.deleteDocument(doc['id']);
        }
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      state = state.copyWith(
        phase: BenchmarkPhase.finished,
        currentTask: 'Benchmark Complete',
        progress: 1.0,
        ragResults: ragMetrics,
      );
      _log('Cleanup completed. Benchmark finished.');

    } catch (e) {
      state = state.copyWith(
        phase: BenchmarkPhase.error,
        currentTask: 'Error occurred',
        logs: [...state.logs, 'Error: $e'],
      );
    }
  }

  Future<Map<String, dynamic>> _runTestPhase(List<String> questions, {required bool isRag}) async {
    double totalTtftMs = 0;
    double totalResponseMs = 0;
    int totalTokens = 0;
    double peakRamMb = 0;
    
    // Get baseline stats
    final initialUsage = await _platform.getResourceUsage();
    peakRamMb = (initialUsage['app_memory_mb'] as num?)?.toDouble() ?? 0.0;
    final initialCpuSec = (initialUsage['cpu_time_sec'] as num?)?.toDouble() ?? 0.0;
    final profileName = initialUsage['profile_name'] as String? ?? 'Unknown';
    final availableRamMb = (initialUsage['available_ram_mb'] as num?)?.toDouble() ?? 0.0;
    final totalRamGb = (initialUsage['total_ram_gb'] as num?)?.toDouble() ?? 0.0;
    
    final phaseStartTime = DateTime.now();
    List<String> snippets = [];

    for (int i = 0; i < questions.length; i++) {
      final question = questions[i];
      state = state.copyWith(
        currentTask: 'Running ${isRag ? 'RAG' : 'AI'} query ${i + 1}/${questions.length}...',
        progress: i / questions.length,
      );
      _log('Query: $question');

      final startTime = DateTime.now();
      DateTime? firstTokenTime;
      int tokenCount = 0;
      final responseBuffer = StringBuffer();

      final streamResult = isRag
          ? _platform.ragStream(question, responseStyle: 'concise')
          : _platform.chatStream(question, responseStyle: 'concise');

      final tokenSub = streamResult.tokens.listen((token) {
        if (firstTokenTime == null && token.isNotEmpty) {
          firstTokenTime = DateTime.now();
        }
        tokenCount += 1;
        responseBuffer.write(token);
      });

      await streamResult.result;
      await tokenSub.cancel();

      final endTime = DateTime.now();
      firstTokenTime ??= endTime;

      final ttftMs = firstTokenTime!.difference(startTime).inMilliseconds;
      final responseMs = endTime.difference(startTime).inMilliseconds;

      totalTtftMs += ttftMs;
      totalResponseMs += responseMs;
      totalTokens += tokenCount;
      
      final fullResponse = responseBuffer.toString().trim();
      _log('  -> Response: $fullResponse');
      _log('  -> TTFT: ${ttftMs}ms, Response: ${responseMs}ms, Tokens: $tokenCount');
      
      String snippet = fullResponse.replaceAll('\n', ' ');
      if (snippet.length > 40) {
        snippet = '${snippet.substring(0, 37)}...';
      }
      snippets.add(snippet);

      // Check RAM
      final usage = await _platform.getResourceUsage();
      final currentRam = (usage['app_memory_mb'] as num?)?.toDouble() ?? 0.0;
      if (currentRam > peakRamMb) {
        peakRamMb = currentRam;
      }
    }
    
    final phaseEndTime = DateTime.now();
    final finalUsage = await _platform.getResourceUsage();
    final finalCpuSec = (finalUsage['cpu_time_sec'] as num?)?.toDouble() ?? 0.0;
    
    final deltaCpuSec = finalCpuSec - initialCpuSec;
    final deltaWallSec = phaseEndTime.difference(phaseStartTime).inMilliseconds / 1000.0;
    
    double avgCpuPercent = 0.0;
    if (deltaWallSec > 0) {
      avgCpuPercent = (deltaCpuSec / deltaWallSec) * 100.0;
    }

    final avgTtft = totalTtftMs / questions.length;
    final avgResponse = totalResponseMs / questions.length;
    final avgTokensPerSec = totalResponseMs > 0 ? (totalTokens / (totalResponseMs / 1000)) : 0.0;

    return {
      'avg_ttft_ms': avgTtft,
      'avg_response_ms': avgResponse,
      'avg_tokens_per_sec': avgTokensPerSec,
      'peak_ram_mb': peakRamMb,
      'available_ram_mb': availableRamMb,
      'total_ram_gb': totalRamGb,
      'profile_name': profileName,
      'avg_cpu_percent': avgCpuPercent,
      'snippets': snippets,
    };
  }

  Future<void> exportReport() async {
    if (state.phase != BenchmarkPhase.finished) return;

    final ai = state.aiResults;
    final rag = state.ragResults;

    final buffer = StringBuffer();
    buffer.writeln('# O-RAG Benchmark Report');
    buffer.writeln('**Generated on:** ${DateTime.now().toIso8601String()}');
    buffer.writeln('');
    
    buffer.writeln('## Device & Resources');
    buffer.writeln('- **Profile:** ${ai['profile_name']}');
    buffer.writeln('- **Total Device RAM:** ${ai['total_ram_gb']?.toStringAsFixed(1)} GB');
    buffer.writeln('');

    buffer.writeln('## Performance Comparison');
    buffer.writeln('| Metric | Direct AI Mode | RAG Mode |');
    buffer.writeln('|---|---|---|');
    buffer.writeln('| **Average TTFT** | ${ai['avg_ttft_ms']?.toStringAsFixed(0)} ms | ${rag['avg_ttft_ms']?.toStringAsFixed(0)} ms |');
    buffer.writeln('| **Average Response** | ${ai['avg_response_ms']?.toStringAsFixed(0)} ms | ${rag['avg_response_ms']?.toStringAsFixed(0)} ms |');
    buffer.writeln('| **Tokens/sec** | ${ai['avg_tokens_per_sec']?.toStringAsFixed(1)} | ${rag['avg_tokens_per_sec']?.toStringAsFixed(1)} |');
    buffer.writeln('| **Peak App RAM** | ${ai['peak_ram_mb']?.toStringAsFixed(0)} MB | ${rag['peak_ram_mb']?.toStringAsFixed(0)} MB |');
    buffer.writeln('| **Avg CPU Usage** | ${ai['avg_cpu_percent']?.toStringAsFixed(1)}% | ${rag['avg_cpu_percent']?.toStringAsFixed(1)}% |');
    buffer.writeln('');
    
    buffer.writeln('## Execution Logs');
    buffer.writeln('```');
    for (var log in state.logs) {
      buffer.writeln(log);
    }
    buffer.writeln('```');

    try {
      // Try writing to the public Downloads folder first
      File file = File('/storage/emulated/0/Download/orag_benchmark_report.md');
      
      try {
        await file.writeAsString(buffer.toString());
      } catch (_) {
        // Fallback to app-specific external directory if public Downloads is restricted
        final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
        file = File('${directory.path}/orag_benchmark_report.md');
        await file.writeAsString(buffer.toString());
      }

      _log('Report exported successfully to: ${file.path}');
    } catch (e) {
      _log('Failed to export report: $e');
    }
  }
}

final benchmarkControllerProvider = StateNotifierProvider.autoDispose<BenchmarkController, BenchmarkState>((ref) {
  final platform = PlatformService();
  return BenchmarkController(platform);
});
