import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../utils/top_snackbar.dart';

/// Slide-out panel for managing documents used in RAG.
class DocumentDrawer extends StatefulWidget {
  final PlatformService platform;

  const DocumentDrawer({super.key, required this.platform});

  @override
  State<DocumentDrawer> createState() => _DocumentDrawerState();
}

class _DocumentDrawerState extends State<DocumentDrawer> {
  List<Map<String, dynamic>> _docs = [];
  bool _isLoading = true;
  bool _isUploading = false;
  String _uploadStatus = '';
  final Stopwatch _uploadStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _loadDocs();
  }

  Future<void> _loadDocs() async {
    setState(() => _isLoading = true);
    try {
      final docs = await widget.platform.listDocuments();
      if (mounted) {
        setState(() {
          _docs = docs;
          _isLoading = false;
        });
      }
    } catch (e, st) {
      debugPrint('[DocumentDrawer] listDocuments error: $e\n$st');
      if (mounted) {
        setState(() {
          _docs = [];
          _isLoading = false;
        });
        showTopSnackBar(
          context,
          message: 'Failed to list documents: $e',
          backgroundColor: context.colors.error,
        );
      }
    }
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.single.path;
    if (path == null) return;

    setState(() {
      _isUploading = true;
      _uploadStatus = 'Reading file...';
      _uploadStopwatch
        ..reset()
        ..start();
    });

    final statusTimer = Stream.periodic(const Duration(seconds: 2), (i) => i)
        .listen((_) {
          if (mounted && _isUploading) {
            final elapsed = _uploadStopwatch.elapsed.inSeconds;
            setState(() => _uploadStatus = 'Processing... ${elapsed}s');
          }
        });

    Map<String, dynamic> response = {'success': false, 'message': 'Upload failed'};
    try {
      response = await widget.platform.uploadDocument(path);
    } catch (e, st) {
      debugPrint('[DocumentDrawer] uploadDocument exception: $e\n$st');
      response = {'success': false, 'message': 'Upload exception: $e'};
    }
    statusTimer.cancel();
    _uploadStopwatch.stop();
    final success = response['success'] == true;
    final message = response['message'] as String? ?? '';

    if (!mounted) return;
    setState(() {
      _isUploading = false;
      _uploadStatus = '';
    });
    showTopSnackBar(
      context,
      message: '$message (${_uploadStopwatch.elapsed.inSeconds}s)',
      backgroundColor: success ? context.colors.success : context.colors.error,
    );
    if (success) _loadDocs();
  }

  Future<void> _deleteDoc(int docId, String name) async {
    final confirmed = await _showConfirm(
      'Delete document?',
      'Remove "$name" and its chunks from the AI knowledge?',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await widget.platform.deleteDocument(docId);
      _loadDocs();
    }
  }

  Future<void> _clearAll() async {
    if (_docs.isEmpty) return;
    final confirmed = await _showConfirm(
      'Clear all documents?',
      'This removes all documents from the AI knowledge base.',
      confirmLabel: 'Clear All',
    );
    if (confirmed) {
      await widget.platform.clearDocuments();
      _loadDocs();
    }
  }

  Future<bool> _showConfirm(
    String title,
    String content, {
    required String confirmLabel,
  }) async {
    final colors = context.colors;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: colors.surface,
            title: Text(title, style: TextStyle(color: colors.textPrimary)),
            content: Text(
              content,
              style: TextStyle(color: colors.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  confirmLabel,
                  style: TextStyle(color: colors.error),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      backgroundColor: colors.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: scheme.secondary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.folder_rounded,
                      size: 18,
                      color: scheme.secondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Documents',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_docs.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_rounded, size: 20),
                      tooltip: 'Clear all',
                      onPressed: _clearAll,
                      color: colors.textDim,
                    ),
                ],
              ),
            ),
            Divider(color: colors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isUploading ? null : _pickAndUpload,
                  icon: _isUploading
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.upload_file_rounded, size: 18),
                  label: Text(
                    _isUploading
                        ? _uploadStatus.isNotEmpty
                              ? _uploadStatus
                              : 'Uploading...'
                        : 'Upload PDF / TXT',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(color: scheme.primary),
                    )
                  : _docs.isEmpty
                  ? _buildEmptyState()
                  : _buildDocList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final colors = context.colors;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 48,
            color: colors.textDim.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 12),
          Text(
            'No documents yet',
            style: TextStyle(color: colors.textDim, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'Upload a PDF or TXT to enable\nAI-powered document Q&A',
            style: TextStyle(color: colors.textDim, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDocList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _docs.length,
      separatorBuilder: (context, idx) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final doc = _docs[index];
        final name = doc['name'] as String? ?? 'Untitled';
        final chunks = doc['num_chunks'] as int? ?? 0;
        final docId = doc['id'] as int? ?? 0;
        final isPdf = name.toLowerCase().endsWith('.pdf');
        return _buildDocItem(name, chunks, docId, isPdf);
      },
    );
  }

  Widget _buildDocItem(String name, int chunks, int docId, bool isPdf) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final docColor = isPdf ? colors.error : scheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: docColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            isPdf ? Icons.picture_as_pdf_rounded : Icons.text_snippet_rounded,
            size: 18,
            color: docColor,
          ),
        ),
        title: Text(
          name,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$chunks chunks',
          style: TextStyle(color: colors.textDim, fontSize: 12),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          color: colors.textDim,
          onPressed: () => _deleteDoc(docId, name),
        ),
      ),
    );
  }
}
