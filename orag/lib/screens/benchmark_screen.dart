import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/benchmark_controller.dart';
import '../theme/app_theme.dart';

class BenchmarkScreen extends ConsumerStatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  ConsumerState<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends ConsumerState<BenchmarkScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(benchmarkControllerProvider);

    ref.listen(benchmarkControllerProvider, (previous, next) {
      if (previous?.logs.length != next.logs.length) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.glassBackground,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: colors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Engine Benchmark',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, state),
              const SizedBox(height: 20),
              if (state.phase == BenchmarkPhase.idle)
                Expanded(
                  child: Center(
                    child: ElevatedButton.icon(
                      onPressed: () => ref.read(benchmarkControllerProvider.notifier).startBenchmark(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Start Benchmark', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                )
              else ...[
                _buildLiveLogs(context, state),
                const SizedBox(height: 20),
                if (state.phase == BenchmarkPhase.finished) ...[
                  _buildResultsTable(context, state),
                  const SizedBox(height: 16),
                  Center(
                    child: OutlinedButton.icon(
                      onPressed: () => ref.read(benchmarkControllerProvider.notifier).exportReport(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.primary,
                        side: BorderSide(color: scheme.primary),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Export Report as Markdown', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, BenchmarkState state) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, color: scheme.primary, size: 24),
              const SizedBox(width: 8),
              Text(
                'Status: ${_getPhaseString(state.phase)}',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (state.phase != BenchmarkPhase.idle && state.phase != BenchmarkPhase.finished) ...[
            const SizedBox(height: 16),
            Text(
              state.currentTask,
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.phase == BenchmarkPhase.finished ? 1.0 : (state.progress > 0 ? state.progress : null),
                backgroundColor: colors.surfaceLight,
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                minHeight: 6,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveLogs(BuildContext context, BenchmarkState state) {
    final colors = context.colors;

    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider, width: 0.5),
        ),
        child: ListView.builder(
          controller: _scrollController,
          itemCount: state.logs.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: Text(
                '> ${state.logs[index]}',
                style: TextStyle(
                  color: colors.success, // using success color to look like a green terminal
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildResultsTable(BuildContext context, BenchmarkState state) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Icon(Icons.bar_chart_rounded, color: scheme.secondary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Benchmark Results',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingTextStyle: TextStyle(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              dataTextStyle: TextStyle(
                color: colors.textPrimary,
                fontSize: 13,
              ),
              columns: const [
                DataColumn(label: Text('Metric')),
                DataColumn(label: Text('AI Mode')),
                DataColumn(label: Text('RAG Mode')),
              ],
              rows: [
                _buildDataRow(
                  'Device Profile',
                  '${state.aiResults['profile_name'] ?? '-'}',
                  '${state.ragResults['profile_name'] ?? '-'}',
                ),
                _buildDataRow(
                  'Avg CPU Usage',
                  '${state.aiResults['avg_cpu_percent']?.toStringAsFixed(1)}%',
                  '${state.ragResults['avg_cpu_percent']?.toStringAsFixed(1)}%',
                ),
                _buildDataRow(
                  'Peak App RAM / Total RAM',
                  '${state.aiResults['peak_ram_mb']?.toStringAsFixed(0)} MB / ${state.aiResults['total_ram_gb']?.toStringAsFixed(1)} GB',
                  '${state.ragResults['peak_ram_mb']?.toStringAsFixed(0)} MB / ${state.ragResults['total_ram_gb']?.toStringAsFixed(1)} GB',
                ),
                _buildDataRow(
                  'Avg TTFT',
                  '${state.aiResults['avg_ttft_ms']?.toStringAsFixed(0)} ms',
                  '${state.ragResults['avg_ttft_ms']?.toStringAsFixed(0)} ms',
                ),
                _buildDataRow(
                  'Avg Response Time',
                  '${state.aiResults['avg_response_ms']?.toStringAsFixed(0)} ms',
                  '${state.ragResults['avg_response_ms']?.toStringAsFixed(0)} ms',
                ),
                _buildDataRow(
                  'Avg Tokens/sec',
                  '${state.aiResults['avg_tokens_per_sec']?.toStringAsFixed(1)}',
                  '${state.ragResults['avg_tokens_per_sec']?.toStringAsFixed(1)}',
                ),
                if ((state.aiResults['snippets'] as List?)?.isNotEmpty == true)
                  _buildDataRow(
                    'Sample Response',
                    (state.aiResults['snippets'] as List).first.toString(),
                    (state.ragResults['snippets'] as List).first.toString(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  DataRow _buildDataRow(String metric, String aiVal, String ragVal) {
    return DataRow(
      cells: [
        DataCell(Text(metric, style: const TextStyle(fontWeight: FontWeight.w500))),
        DataCell(Text(aiVal)),
        DataCell(Text(ragVal)),
      ],
    );
  }

  String _getPhaseString(BenchmarkPhase phase) {
    switch (phase) {
      case BenchmarkPhase.idle: return 'Ready';
      case BenchmarkPhase.runningAI: return 'Running AI Tests';
      case BenchmarkPhase.generatingDoc: return 'Generating Document';
      case BenchmarkPhase.ingestingDoc: return 'Ingesting Document';
      case BenchmarkPhase.runningRAG: return 'Running RAG Tests';
      case BenchmarkPhase.finished: return 'Completed';
      case BenchmarkPhase.error: return 'Failed';
    }
  }
}
