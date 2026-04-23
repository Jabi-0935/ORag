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
                        _buildEngineSection(),
                        const SizedBox(height: 16),
                        _buildResourceMonitorSection(),
                        const SizedBox(height: 16),
                        _buildAdaptiveProfileSection(),
                        const SizedBox(height: 16),
                        _buildDocumentsSection(),
                        const SizedBox(height: 16),
                        _buildActionsSection(),
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

  // ---- Engine ----

  Widget _buildEngineSection() {
    final backend = _health['backend'] as String? ?? 'On-device';
    final qwenReady = _health['qwen_ready'] == true;
    final nomicReady = _health['nomic_ready'] == true;
    final modelLoaded = _health['model_loaded'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'AI Engine', Icons.memory_rounded, AppColors.primary),
        _buildCard(children: [
          _buildRow('Status', modelLoaded ? 'Loaded' : 'Not loaded',
              valueColor: modelLoaded ? AppColors.success : AppColors.textDim),
          _divider(),
          _buildRow('Backend', backend),
          _divider(),
          _buildRow('Chat Engine', '',
              trailing: _statusDot(qwenReady)),
          _divider(),
          _buildRow('Embedding Engine', '',
              trailing: _statusDot(nomicReady)),
        ]),
      ],
    );
  }

  // ---- Documents ----

  Widget _buildDocumentsSection() {
    final docCount = _health['doc_count'] as int? ?? 0;
    final chunkCount = _health['chunk_count'] as int? ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Knowledge Base', Icons.folder_rounded, AppColors.secondary),
        _buildCard(children: [
          _buildRow('Documents', '$docCount'),
          _divider(),
          _buildRow('Total Chunks', '$chunkCount'),
        ]),
      ],
    );
  }

  // ---- Actions ----

  Widget _buildActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Data Management', Icons.storage_rounded, AppColors.warning),
        _buildCard(children: [
          _buildActionRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Clear Conversation',
            subtitle: 'Erase all chat messages',
            onTap: _clearChat,
          ),
          _divider(),
          _buildActionRow(
            icon: Icons.folder_delete_outlined,
            label: 'Clear All Documents',
            subtitle: 'Remove all ingested documents & chunks',
            onTap: _clearDocs,
            destructive: true,
          ),
        ]),
      ],
    );
  }

  Widget _buildActionRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? AppColors.error : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.textDim, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppColors.textDim),
          ],
        ),
      ),
    );
  }

  // ---- Resource Monitor ----

  Widget _buildResourceMonitorSection() {
    final appMem = (_resources['app_memory_mb'] as num?)?.toDouble() ?? 0.0;
    final availMem = (_resources['available_ram_mb'] as num?)?.toDouble() ?? 0.0;
    final pressure = (_resources['memory_pressure_pct'] as num?)?.toDouble() ?? 0.0;
    final battLevel = _resources['battery_level'] as int? ?? -1;
    final battStatus = _resources['battery_status'] as String? ?? 'unknown';
    final battTemp = (_resources['battery_temp_c'] as num?)?.toDouble() ?? 0.0;
    final isCharging = _resources['battery_charging'] == true;

    Color pressureColor;
    String pressureLabel;
    if (pressure < 60) {
      pressureColor = AppColors.success;
      pressureLabel = 'Normal';
    } else if (pressure < 80) {
      pressureColor = AppColors.warning;
      pressureLabel = 'Moderate';
    } else {
      pressureColor = AppColors.error;
      pressureLabel = 'Critical';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Resource Monitor', Icons.monitor_heart_rounded, const Color(0xFF6C5CE7)),
        _buildCard(children: [
          // Memory pressure bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Memory Pressure',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13.5)),
                    Text('$pressureLabel (${pressure.toStringAsFixed(0)}%)',
                        style: TextStyle(
                            color: pressureColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (pressure / 100).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppColors.divider,
                    valueColor: AlwaysStoppedAnimation<Color>(pressureColor),
                  ),
                ),
              ],
            ),
          ),
          _divider(),
          _buildRow('App Memory (RSS)', '${appMem.toStringAsFixed(0)} MB'),
          _divider(),
          _buildRow('Available RAM', '${availMem.toStringAsFixed(0)} MB'),
          _divider(),
          _buildRow(
            'Battery',
            battLevel >= 0
                ? '${battLevel}% ${isCharging ? "⚡" : ""} (${battTemp.toStringAsFixed(1)}°C)'
                : 'N/A',
            valueColor: battLevel > 20
                ? AppColors.success
                : (battLevel >= 0 ? AppColors.error : AppColors.textDim),
          ),
          _divider(),
          _buildRow('Battery Status', _capitalize(battStatus)),
        ]),
      ],
    );
  }

  // ---- Adaptive Profile ----

  Widget _buildAdaptiveProfileSection() {
    final profile = _resources['profile_name'] as String? ?? 'Unknown';
    final totalRam = (_resources['total_ram_gb'] as num?)?.toDouble() ?? 0.0;
    final ctx = _resources['context_window'] as int? ?? 0;
    final maxTok = _resources['max_tokens'] as int? ?? 0;
    final threads = _resources['threads'] as int? ?? 0;
    final kvCache = _resources['kv_cache_type'] as String? ?? 'unknown';
    final nomicCtx = _resources['nomic_ctx'] as int? ?? 0;
    final nomicLazy = _resources['nomic_lazy'] == true;
    final nomicRunning = _resources['nomic_running'] == true;
    final embedLimit = _resources['embed_chunk_limit'] as int? ?? 0;
    final cpuCores = _resources['cpu_cores'] as int? ?? 0;
    final useMmap = _resources['use_mmap'] == true;

    Color profileColor;
    switch (profile) {
      case 'ULTRA_LOW':
        profileColor = AppColors.error;
        break;
      case 'LOW':
        profileColor = AppColors.warning;
        break;
      case 'MEDIUM':
        profileColor = const Color(0xFF00B894);
        break;
      case 'HIGH':
        profileColor = AppColors.success;
        break;
      default:
        profileColor = AppColors.textDim;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'Adaptive Profile', Icons.tune_rounded, const Color(0xFF00B894)),
        _buildCard(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: profileColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: profileColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    profile,
                    style: TextStyle(
                      color: profileColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${totalRam.toStringAsFixed(1)} GB RAM · $cpuCores cores',
                  style: const TextStyle(
                      color: AppColors.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
          _divider(),
          _buildRow('Context Window', '$ctx tokens'),
          _divider(),
          _buildRow('Max Output', '$maxTok tokens'),
          _divider(),
          _buildRow('Threads', '$threads'),
          _divider(),
          _buildRow('KV Cache', kvCache.toUpperCase()),
          _divider(),
          _buildRow('Memory Map', useMmap ? 'On (page-in)' : 'Off (full load)'),
          _divider(),
          _buildRow('Nomic Ctx', '$nomicCtx tokens'),
          _divider(),
          _buildRow('Nomic Mode', nomicLazy ? 'Lazy (on demand)' : 'Eager (at init)'),
          _divider(),
          _buildRow('Nomic Status', '',
              trailing: _statusDot(nomicRunning)),
          _divider(),
          _buildRow('Embed Limit', '$embedLimit chunks'),
        ]),
      ],
    );
  }

  // ---- About ----

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
            'About', Icons.info_outline_rounded, AppColors.textSecondary),
        _buildCard(children: [
          _buildRow('App', 'O-RAG'),
          _divider(),
          _buildRow('Version', '1.0.0'),
          _divider(),
          _buildRow('Engine', 'LLM + Embeddings'),
          _divider(),
          _buildRow('Platform', 'On-device (offline)'),
        ]),
      ],
    );
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }
}
