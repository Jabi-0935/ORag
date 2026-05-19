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
                          horizontal: 16, vertical: 16),
                      children: [
                        _buildEngineStatusSection(),
                        const SizedBox(height: 20),
                        _buildResourceMonitorSection(),
                        const SizedBox(height: 20),
                        _buildDevelopersSection(),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ---- App Bar ----

  Widget _buildAppBar() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 8,
        right: 8,
        bottom: 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          _buildIconButton(
            Icons.arrow_back_rounded,
            onPressed: () => Navigator.pop(context),
            bordered: true,
          ),
          const SizedBox(width: 10),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.settings_rounded,
                size: 16, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          const Text(
            'Settings',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          _buildIconButton(
            Icons.refresh_rounded,
            onPressed: _loadHealth,
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon,
      {required VoidCallback onPressed, bool bordered = false}) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: bordered ? AppColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: bordered
              ? Border.all(color: AppColors.divider, width: 0.5)
              : null,
        ),
        child: Icon(icon, size: 18, color: AppColors.textSecondary),
      ),
    );
  }

  // ---- Shared Widgets ----

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _divider() => const Divider(color: AppColors.divider, height: 0.5, thickness: 0.5);

  Widget _buildRow(String label, {Widget? trailing, String? value}) {
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
          if (trailing != null) trailing,
          if (trailing == null && value != null)
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionRow(
      String label, IconData icon, Color color, Color bgColor, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 16,
                color: AppColors.textSecondary.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill(bool active) {
    final color = active ? AppColors.success : AppColors.error;
    final bg = active
        ? AppColors.success.withValues(alpha: 0.12)
        : AppColors.error.withValues(alpha: 0.10);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Text(
            active ? 'Online' : 'Offline',
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
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
            'Engine status', Icons.memory_rounded, AppColors.primary),
        _buildCard(children: [
          // Backend tag row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Backend',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 11)),
                const SizedBox(height: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.laptop_rounded,
                          size: 13, color: AppColors.primary),
                      const SizedBox(width: 5),
                      Text(
                        backend,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _divider(),
          _buildRow('Qwen LLM', trailing: _buildStatusPill(qwenReady)),
          _divider(),
          _buildRow('Nomic embeddings', trailing: _buildStatusPill(nomicReady)),
          _divider(),
          // Stat boxes
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: _buildStatBox('Documents loaded', '$docCount')),
                const SizedBox(width: 10),
                Expanded(child: _buildStatBox('Total chunks', '$chunkCount')),
              ],
            ),
          ),
        ]),
      ],
    );
  }

  Widget _buildStatBox(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              )),
        ],
      ),
    );
  }

  // ---- Resource Monitor ----

  Widget _buildResourceMonitorSection() {
    final profile = _resources['profile_name'] as String? ?? 'Unknown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Resources', Icons.monitor_heart_rounded,
            const Color(0xFF0F6E56)),
        _buildCard(children: [
          _buildRow('Device profile', value: profile),
          _divider(),
          _buildActionRow(
            'Clear knowledge base',
            Icons.delete_sweep_rounded,
            const Color(0xFFA32D2D),
            const Color(0xFFFCEBEB),
            _clearDocs,
          ),
          _divider(),
          _buildActionRow(
            'Clear conversation',
            Icons.clear_all_rounded,
            const Color(0xFF854F0B),
            const Color(0xFFFAEEDA),
            _clearChat,
          ),
        ]),
      ],
    );
  }

  // ---- Developers ----

  Widget _buildDevelopersSection() {
    const developers = [
      ('Ismaeel', 'IS'),
      ('Rashmitha', 'RA'),
      ('Suchitha', 'SU'),
      ('Mokshagna', 'MO'),
    ];

    const avatarColors = [
      (Color(0xFFEEEDFE), Color(0xFF534AB7)),
      (Color(0xFFE1F5EE), Color(0xFF0F6E56)),
      (Color(0xFFFBEAF0), Color(0xFF993556)),
      (Color(0xFFFAEEDA), Color(0xFF854F0B)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Developers', Icons.people_alt_rounded, const Color(0xFF0F6E56)),
        _buildCard(
          children: [
            for (int i = 0; i < developers.length; i++) ...[
              if (i > 0) _divider(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: avatarColors[i].$1,
                      ),
                      child: Center(
                        child: Text(
                          developers[i].$2,
                          style: TextStyle(
                            color: avatarColors[i].$2,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      developers[i].$1,
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