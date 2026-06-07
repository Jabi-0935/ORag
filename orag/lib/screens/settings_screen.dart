import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/theme_controller.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../utils/top_snackbar.dart';
import 'benchmark_screen.dart';

/// Settings, appearance, and engine health screen.
class SettingsScreen extends ConsumerStatefulWidget {
  final PlatformService platform;
  final VoidCallback onClearChat;

  const SettingsScreen({
    super.key,
    required this.platform,
    required this.onClearChat,
  });

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
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
    if (!mounted) return;
    setState(() {
      _health = results[0];
      _resources = results[1];
      _loading = false;
    });
  }

  Future<void> _clearDocs() async {
    final confirmed = await _showConfirm(
      'Clear all documents?',
      'This removes all documents and chunks from the AI knowledge base.',
    );
    if (!confirmed) return;

    await widget.platform.clearDocuments();
    _loadHealth();
    if (mounted) {
      showTopSnackBar(
        context,
        message: 'All documents cleared',
        backgroundColor: context.colors.success,
      );
    }
  }

  Future<void> _clearChat() async {
    final confirmed = await _showConfirm(
      'Clear conversation?',
      'This will erase all chat messages and conversation memory.',
    );
    if (!confirmed) return;

    widget.onClearChat();
    if (mounted) {
      showTopSnackBar(
        context,
        message: 'Conversation cleared',
        backgroundColor: context.colors.success,
      );
    }
  }

  Future<bool> _showConfirm(String title, String content) async {
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
                child: Text('Confirm', style: TextStyle(color: colors.error)),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          _buildAppBar(),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadHealth,
                    color: Theme.of(context).colorScheme.primary,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      children: [
                        _buildAppearanceSection(),
                        const SizedBox(height: 20),
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

  Widget _buildAppBar() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 8,
        right: 8,
        bottom: 12,
      ),
      decoration: BoxDecoration(
        color: colors.glassBackground,
        border: Border(bottom: BorderSide(color: colors.divider, width: 0.5)),
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
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.settings_rounded,
              size: 16,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Settings',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _buildIconButton(Icons.refresh_rounded, onPressed: _loadHealth),
        ],
      ),
    );
  }

  Widget _buildIconButton(
    IconData icon, {
    required VoidCallback onPressed,
    bool bordered = false,
  }) {
    final colors = context.colors;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: bordered ? colors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: bordered
              ? Border.all(color: colors.divider, width: 0.5)
              : null,
        ),
        child: Icon(icon, size: 18, color: colors.textSecondary),
      ),
    );
  }

  Widget _buildAppearanceSection() {
    final scheme = Theme.of(context).colorScheme;
    final themeMode = ref.watch(themeControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          'Appearance',
          Icons.palette_outlined,
          scheme.primary,
        ),
        _buildCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: _themeChoice(
                      mode: ThemeMode.system,
                      label: 'System',
                      icon: Icons.brightness_auto_rounded,
                      selected: themeMode == ThemeMode.system,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _themeChoice(
                      mode: ThemeMode.light,
                      label: 'Light',
                      icon: Icons.light_mode_outlined,
                      selected: themeMode == ThemeMode.light,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _themeChoice(
                      mode: ThemeMode.dark,
                      label: 'Dark',
                      icon: Icons.dark_mode_outlined,
                      selected: themeMode == ThemeMode.dark,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _themeChoice({
    required ThemeMode mode,
    required String label,
    required IconData icon,
    required bool selected,
  }) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () =>
          ref.read(themeControllerProvider.notifier).setThemeMode(mode),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.12)
              : colors.surfaceLight.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.38)
                : colors.divider,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? scheme.primary : colors.textSecondary,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? scheme.primary : colors.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    final colors = context.colors;

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
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    final colors = context.colors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _divider() =>
      Divider(color: context.colors.divider, height: 0.5, thickness: 0.5);

  Widget _buildRow(String label, {Widget? trailing, String? value}) {
    final colors = context.colors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: colors.textSecondary, fontSize: 13.5),
            ),
          ),
          if (trailing != null || value != null)
            trailing ??
                Text(
                  value!,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildActionRow(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    final colors = context.colors;

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
                color: color.withValues(alpha: 0.12),
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
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: colors.textSecondary.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill(bool active) {
    final colors = context.colors;
    final color = active ? colors.success : colors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
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
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEngineStatusSection() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final qwenReady = _health['qwen_ready'] as bool? ?? false;
    final nomicReady = _health['nomic_ready'] as bool? ?? false;
    final docCount = _health['doc_count'] as int? ?? 0;
    final chunkCount = _health['chunk_count'] as int? ?? 0;
    final backend = _health['backend'] as String? ?? 'On-device';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          'Engine status',
          Icons.memory_rounded,
          scheme.primary,
        ),
        _buildCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Backend',
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.laptop_rounded,
                          size: 13,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          backend,
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
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
            _buildRow(
              'Nomic embeddings',
              trailing: _buildStatusPill(nomicReady),
            ),
            _divider(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: _buildStatBox('Documents loaded', '$docCount'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _buildStatBox('Total chunks', '$chunkCount')),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatBox(String label, String value) {
    final colors = context.colors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: colors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResourceMonitorSection() {
    final colors = context.colors;
    final profile = _resources['profile_name'] as String? ?? 'Unknown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          'Resources',
          Icons.monitor_heart_rounded,
          colors.success,
        ),
        _buildCard(
          children: [
            _buildRow('Device profile', value: profile),
            _divider(),
            _buildActionRow(
              'Clear knowledge base',
              Icons.delete_sweep_rounded,
              colors.error,
              _clearDocs,
            ),
            _divider(),
            _buildActionRow(
              'Clear conversation',
              Icons.clear_all_rounded,
              colors.warning,
              _clearChat,
            ),
            _divider(),
            _buildActionRow(
              'Run Benchmark',
              Icons.speed_rounded,
              Theme.of(context).colorScheme.primary,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BenchmarkScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDevelopersSection() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    const developers = [
      ('Ismaeel', 'IS'),
      ('Rashmitha', 'RA'),
      ('Suchitha', 'SU'),
      ('Mokshagna', 'MO'),
    ];

    final avatarColors = [
      scheme.primary,
      colors.success,
      scheme.secondary,
      colors.warning,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          'Developers',
          Icons.people_alt_rounded,
          scheme.secondary,
        ),
        _buildCard(
          children: [
            for (int i = 0; i < developers.length; i++) ...[
              if (i > 0) _divider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: avatarColors[i].withValues(alpha: 0.14),
                      ),
                      child: Center(
                        child: Text(
                          developers[i].$2,
                          style: TextStyle(
                            color: avatarColors[i],
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      developers[i].$1,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
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
