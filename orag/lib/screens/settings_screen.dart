import 'package:flutter/material.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../utils/top_snackbar.dart';

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
        showTopSnackBar(
          context,
          message: 'All documents cleared',
          backgroundColor: AppColors.success,
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
        showTopSnackBar(
          context,
          message: 'Conversation cleared',
          backgroundColor: AppColors.success,
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
                        _buildEngineStatusSection(),
                        const SizedBox(height: 16),
                        _buildResourceMonitorSection(),
                        const SizedBox(height: 16),
                        _buildAboutSection(),
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

  Widget _buildActionRow(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textSecondary.withValues(alpha: 0.5)),
          ],
        ),
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

  // ---- Engine Status ----

  Widget _buildEngineStatusSection() {
    final qwenReady = _health['qwen_ready'] as bool? ?? false;
    final nomicReady = _health['nomic_ready'] as bool? ?? false;
    final docCount = _health['doc_count'] as int? ?? 0;
    final chunkCount = _health['chunk_count'] as int? ?? 0;
    final backend = _health['backend'] as String? ?? 'On-device';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Engine Status', Icons.memory_rounded, AppColors.primary),
        _buildCard(children: [
          _buildRow('Backend', backend),
          _divider(),
          _buildRow(
            'Qwen LLM',
            '',
            trailing: _statusDot(qwenReady),
          ),
          _divider(),
          _buildRow(
            'Nomic Embeddings',
            '',
            trailing: _statusDot(nomicReady),
          ),
          _divider(),
          _buildRow('Documents Loaded', '$docCount'),
          _divider(),
          _buildRow('Total Chunks', '$chunkCount'),
        ]),
      ],
    );
  }

  // ---- Resource Monitor ----

  Widget _buildResourceMonitorSection() {
    final appMem = (_resources['app_memory_mb'] as num?)?.toDouble() ?? 0.0;
    final availMem = (_resources['available_ram_mb'] as num?)?.toDouble() ?? 0.0;
    final profile = _resources['profile_name'] as String? ?? 'Unknown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Resource Monitor', Icons.monitor_heart_rounded, const Color(0xFF6C5CE7)),
        _buildCard(children: [
          _buildRow('Device Profile', profile),
          _divider(),
          _buildRow('Total Memory Used', '${appMem.toStringAsFixed(0)} MB'),
          _divider(),
          _buildRow('Available RAM', '${availMem.toStringAsFixed(0)} MB'),
          _divider(),
          _buildActionRow('Clear Knowledge Base', Icons.delete_sweep_rounded, AppColors.error, _clearDocs),
          _divider(),
          _buildActionRow('Clear Conversation History', Icons.clear_all_rounded, const Color(0xFFFF7675), _clearChat),
        ]),
      ],
    );
  }



  Widget _buildAboutSection() {
    const developers = ['Ismeel', 'Rashmitha', 'Suchitha', 'Mokshagna'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Developers', Icons.people_alt_rounded, const Color(0xFF00B894)),
        _buildCard(
          children: [
            for (int i = 0; i < developers.length; i++) ...[
              if (i > 0) _divider(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary.withValues(alpha: 0.10),
                      ),
                      child: const Icon(Icons.person_rounded,
                          size: 16, color: AppColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      developers[i],
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
