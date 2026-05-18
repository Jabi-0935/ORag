import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Represents the current state of the model initialization pipeline.
enum InitState { idle, downloading, loading, ready, error }

class InitStatus {
  final InitState state;
  final double progress; // 0.0 – 1.0
  final String message;

  const InitStatus({
    this.state = InitState.idle,
    this.progress = 0.0,
    this.message = '',
  });

  bool get isReady => state == InitState.ready;
  bool get isBusy =>
      state == InitState.downloading || state == InitState.loading;
  bool get isError => state == InitState.error;
}

/// Typed wrapper around the native platform channels (Kotlin ↔ Flutter).
class PlatformService {
  static const _method = MethodChannel('orag');
  static const _streamChannel = EventChannel('orag_stream');
  static const _initChannel = EventChannel('orag_init_progress');

  // ---- Init / bootstrap ----

  /// Start Python + download models + load LLM.
  /// Returns a stream of [InitStatus] updates.
  ///
  /// Uses a dual approach: listens for push events via EventChannel AND
  /// polls getStatus every 3s as a fallback. This ensures the UI
  /// always reflects the current state, even if the EventChannel stream
  /// temporarily disconnects (which happens on Android when
  /// receiveBroadcastStream() resubscribes).
  Stream<InitStatus> initPython(String modelPath) {
    final controller = StreamController<InitStatus>();
    bool finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      if (!controller.isClosed) controller.close();
    }

    void addStatus(InitStatus status) {
      if (controller.isClosed) return;
      controller.add(status);
      if (status.isReady || status.isError) {
        finish();
      }
    }

    // 1. Listen to EventChannel push events
    StreamSubscription? eventSub;
    eventSub = _initChannel.receiveBroadcastStream().listen(
      (event) {
        try {
          final map = event is Map
              ? event.cast<String, dynamic>()
              : jsonDecode(event.toString()) as Map<String, dynamic>;
          addStatus(InitStatus(
            state: _parseState(map['state'] as String? ?? 'idle'),
            progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
            message: map['message'] as String? ?? '',
          ));
        } catch (e) {
          debugPrint('[PlatformService] initPython event parse error: $e');
        }
      },
      onError: (e) {
        // EventChannel stream error — don't treat as fatal,
        // the polling fallback will keep the UI updated.
        debugPrint('[PlatformService] initPython EventChannel error: $e');
      },
      onDone: () {
        // EventChannel stream ended — polling fallback will take over.
      },
    );

    // 2. Trigger init (fire-and-forget — progress comes via EventChannel)
    _method.invokeMethod('initPython', {'model_path': modelPath}).catchError(
      (e) {
        addStatus(InitStatus(
          state: InitState.error,
          progress: 1.0,
          message: 'Init failed: $e',
        ));
      },
    );

    // 3. Polling fallback: every 3 seconds, check cached status
    //    This is non-blocking on Android (returns cached Kotlin-level state).
    Timer.periodic(const Duration(seconds: 3), (timer) {
      if (finished) {
        timer.cancel();
        eventSub?.cancel();
        return;
      }
      getStatus().then((status) {
        if (finished) return;
        addStatus(status);
      }).catchError((e) {
        debugPrint('[PlatformService] polling fallback error: $e');
      });
    });

    return controller.stream;
  }

  /// One-shot status check (polling fallback).
  Future<InitStatus> getStatus() async {
    try {
      final result = await _method.invokeMethod('getStatus');
      if (result is Map) {
        final map = result.cast<String, dynamic>();
        return InitStatus(
          state: _parseState(map['state'] as String? ?? 'idle'),
          progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
          message: map['message'] as String? ?? '',
        );
      }
    } catch (e) {
      debugPrint('[PlatformService] getStatus error: $e');
    }
    return const InitStatus();
  }

  // ---- Chat ----

  /// Start streaming chat. Returns a record of (tokenStream, resultFuture).
  /// Tokens stream as they arrive. The result future resolves with
  /// {answer, thinking} JSON when generation is complete.
  ({Stream<String> tokens, Future<Map<String, dynamic>> result}) chatStream(String query, {bool longerAnswers = false}) {
    final tokenController = StreamController<String>();
    final resultCompleter = Completer<Map<String, dynamic>>();

    StreamSubscription? sub;
    sub = _streamChannel.receiveBroadcastStream().listen(
      (event) {
        final token = event.toString();
        if (token == '__STREAM_END__') {
          sub?.cancel();
          tokenController.close();
        } else {
          tokenController.add(token);
        }
      },
      onError: (error) {
        tokenController.addError(error);
        tokenController.close();
      },
    );

    _method.invokeMethod('chatStream', {
      'query': query,
      'longer_answers': longerAnswers,
    }).then((result) {
      try {
        final json = jsonDecode(result as String) as Map<String, dynamic>;
        resultCompleter.complete(json);
      } catch (e) {
        resultCompleter.complete({});
      }
    }).catchError((e) {
      if (!tokenController.isClosed) {
        tokenController.addError(e);
        tokenController.close();
      }
      resultCompleter.complete({});
    });

    return (tokens: tokenController.stream, result: resultCompleter.future);
  }

  /// Stop current generation.
  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (e) {
      debugPrint('[PlatformService] stop error: $e');
    }
  }

  /// Clear conversation memory.
  Future<void> clearMemory() async {
    await _method.invokeMethod('clearMemory');
  }

  // ---- Documents ----

  /// Upload a document (PDF/TXT) for RAG ingestion.
  /// Returns {success: bool, message: String}
  Future<Map<String, dynamic>> uploadDocument(String filePath) async {
    try {
      final result = await _method.invokeMethod(
        'uploadDocument',
        {'file_path': filePath},
      );
      return jsonDecode(result as String) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'message': 'Upload failed: $e'};
    }
  }

  /// List all ingested documents.
  Future<List<Map<String, dynamic>>> listDocuments() async {
    try {
      final result = await _method.invokeMethod('listDocuments');
      final list = jsonDecode(result as String) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[PlatformService] listDocuments error: $e');
      return [];
    }
  }

  /// Delete a document by ID.
  Future<bool> deleteDocument(int docId) async {
    try {
      final result = await _method.invokeMethod(
        'deleteDocument',
        {'doc_id': docId},
      );
      final json = jsonDecode(result as String) as Map<String, dynamic>;
      return json['success'] == true;
    } catch (e) {
      debugPrint('[PlatformService] deleteDocument error: $e');
      return false;
    }
  }

  /// Clear all documents.
  Future<bool> clearDocuments() async {
    try {
      final result = await _method.invokeMethod('clearDocuments');
      final json = jsonDecode(result as String) as Map<String, dynamic>;
      return json['success'] == true;
    } catch (e) {
      debugPrint('[PlatformService] clearDocuments error: $e');
      return false;
    }
  }

  // ---- RAG query ----

  /// Start a RAG streaming query. Streams tokens, then returns sources via
  /// the MethodChannel result (JSON with answer + sources).
  /// Returns a record of (tokenStream, sourcesFuture).
  ({Stream<String> tokens, Future<Map<String, dynamic>> result}) ragStream(String query, {bool longerAnswers = false}) {
    final tokenController = StreamController<String>();
    final resultCompleter = Completer<Map<String, dynamic>>();

    StreamSubscription? sub;
    sub = _streamChannel.receiveBroadcastStream().listen(
      (event) {
        final token = event.toString();
        if (token == '__STREAM_END__') {
          sub?.cancel();
          tokenController.close();
        } else {
          tokenController.add(token);
        }
      },
      onError: (error) {
        tokenController.addError(error);
        tokenController.close();
      },
    );

    // Invoke ragStream — the result contains sources JSON
    _method.invokeMethod('ragStream', {
      'query': query,
      'longer_answers': longerAnswers,
    }).then((result) {
      try {
        final json = jsonDecode(result as String) as Map<String, dynamic>;
        resultCompleter.complete(json);
      } catch (e) {
        resultCompleter.complete({});
      }
    }).catchError((e) {
      if (!tokenController.isClosed) {
        tokenController.addError(e);
        tokenController.close();
      }
      resultCompleter.complete({});
    });

    return (tokens: tokenController.stream, result: resultCompleter.future);
  }

  // ---- Engine health ----

  /// Get engine health info for settings screen.
  Future<Map<String, dynamic>> getEngineHealth() async {
    try {
      final result = await _method.invokeMethod('getEngineHealth');
      return jsonDecode(result as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[PlatformService] getEngineHealth error: $e');
      return {};
    }
  }

  /// Get live resource usage (memory, battery, profile) for settings screen.
  Future<Map<String, dynamic>> getResourceUsage() async {
    try {
      final result = await _method.invokeMethod('getResourceUsage');
      return jsonDecode(result as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[PlatformService] getResourceUsage error: $e');
      return {};
    }
  }

  // ---- Diagnostics ----
  
  /// Get init logs for debugging.
  Future<String> getInitLogs() async {
    try {
      final result = await _method.invokeMethod('getInitLogs');
      return result.toString();
    } catch (e) {
      return 'Failed to fetch logs: $e';
    }
  }

  // ---- Helpers ----

  static InitState _parseState(String s) {
    switch (s) {
      case 'downloading':
        return InitState.downloading;
      case 'loading':
        return InitState.loading;
      case 'ready':
        return InitState.ready;
      case 'error':
        return InitState.error;
      default:
        return InitState.idle;
    }
  }
}

