import 'package:flutter/material.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';

/// Settings & engine health screen.
class SettingsScreen extends StatefulWidget {
  final PlatformService platform;
  final VoidCallback onClearChat;

  const SettingsScreen({
    super.key,
    required this.platform,
    required this.onClearChat,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic> _health = {};
  Map<String, dynamic> _resources = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  Future<void> _loadHealth() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      widget.platform.getEngineHealth(),
      widget.platform.getResourceUsage(),
    ]);
    if (mounted) {
      setState(() {
        _health = results[0];
        _resources = results[1];
        _loading = false;
      });
    }
  }

  Future<void> _clearDocs() async {
    final confirmed = await _showConfirm(
      'Clear all documents?',
      'This removes all documents and chunks from the AI\'s knowledge base.',
    );
    if (confirmed) {
      await widget.platform.clearDocuments();
      _loadHealth();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All documents cleared'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    }
  }

  Future<void> _clearChat() async {
    final confirmed = await _showConfirm(
      'Clear conversation?',
      'This will erase all chat messages and conversation memory.',
    );
    if (confirmed) {
      widget.onClearChat();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Conversation cleared'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    }
  }

  Future<bool> _showConfirm(String title, String content) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(title,
                style: const TextStyle(color: AppColors.textPrimary)),
            content: Text(content,
                style: const TextStyle(color: AppColors.textSecondary)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm',
                    style: TextStyle(color: AppColors.error)),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildAppBar(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : RefreshIndicator(
                    onRefresh: _loadHealth,
                    color: AppColors.primary,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      children: [
                        _buildResourceMonitorSection(),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 4,
        right: 16,
        bottom: 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 22),
            color: AppColors.textPrimary,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 4),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.settings_rounded,
                size: 17, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          const Text(
            'Settings',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 21),
            color: AppColors.textSecondary,
            onPressed: _loadHealth,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  // ---- Sections ----

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider, width: 1),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildRow(String label, String value,
      {Color? valueColor, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13.5),
            ),
          ),
          ?trailing,
          if (trailing == null)
            Flexible(
              child: Text(
                value,
                style: TextStyle(
                  color: valueColor ?? AppColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusDot(bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? AppColors.success : AppColors.error,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColors.success.withValues(alpha: 0.4),
                      blurRadius: 6,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          active ? 'Online' : 'Offline',
          style: TextStyle(
            color: active ? AppColors.success : AppColors.error,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _divider() {
    return const Divider(color: AppColors.divider, height: 1);
  }

  // ---- Resource Monitor ----

  Widget _buildResourceMonitorSection() {
    final appMem = (_resources['app_memory_mb'] as num?)?.toDouble() ?? 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Resource Monitor', Icons.monitor_heart_rounded, const Color(0xFF6C5CE7)),
        _buildCard(children: [
          _buildRow('App Memory (RSS)', '${appMem.toStringAsFixed(0)} MB'),
        ]),
      ],
    );
  }



  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }
}
