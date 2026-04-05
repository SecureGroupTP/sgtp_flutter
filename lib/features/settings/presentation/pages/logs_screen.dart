import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/app_theme.dart';

/// Full-screen log viewer accessible from Settings → Logs.
///
/// Features:
///   • Live-updating list (new entries appear without reopening the screen).
///   • Level badge colour coding: DEBUG=grey, INFO=blue, WARN=orange, ERROR=red.
///   • Filter bar — filter by level or free-text search.
///   • "Copy all" button copies the full log text to the clipboard.
///   • "Clear" button wipes the ring buffer.
///   • Auto-scrolls to the newest entry when already at the bottom.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  LogLevel? _filterLevel;   // null = show all
  String    _searchText = '';

  @override
  void initState() {
    super.initState();
    AppLogger.addListener(_onNewLog);
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _searchText) {
        setState(() => _searchText = _searchCtrl.text);
      }
    });
  }

  @override
  void dispose() {
    AppLogger.removeListener(_onNewLog);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onNewLog(LogEntry _) {
    if (!mounted) return;
    setState(() {});
    // Auto-scroll to bottom only if already near the bottom.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        final pos = _scrollCtrl.position;
        if (pos.maxScrollExtent - pos.pixels < 120) {
          _scrollCtrl.animateTo(
            pos.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  List<LogEntry> get _filtered {
    var list = AppLogger.entries;
    if (_filterLevel != null) {
      list = list.where((e) => e.level == _filterLevel).toList();
    }
    final q = _searchText.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) => e.message.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  Color _levelColor(LogLevel l) => switch (l) {
    LogLevel.debug => const Color(0xFF636366),
    LogLevel.info  => const Color(0xFF0A84FF),
    LogLevel.warn  => const Color(0xFFFF9F0A),
    LogLevel.error => const Color(0xFFFF3B30),
  };

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    final totalCount = AppLogger.entries.length;

    return Scaffold(
      backgroundColor: AppColors.bgMain,
      appBar: _buildAppBar(context, totalCount, entries.length),
      body: Column(
        children: [
          _buildFilterBar(),
          const Divider(height: 1, color: Color(0xFF2C2C30)),
          Expanded(child: _buildLogList(entries)),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
      BuildContext context, int total, int shown) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bgMain,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back,
                      color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Logs',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      Text(
                        shown == total
                            ? '$total entries'
                            : '$shown / $total shown',
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                // Copy all
                IconButton(
                  icon: const Icon(Icons.copy_all_outlined,
                      color: AppColors.textSecondary),
                  tooltip: 'Copy all logs',
                  onPressed: total == 0
                      ? null
                      : () {
                          Clipboard.setData(
                              ClipboardData(text: AppLogger.fullText));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Logs copied to clipboard'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                ),
                // Scroll to bottom
                IconButton(
                  icon: const Icon(Icons.arrow_downward,
                      color: AppColors.textSecondary),
                  tooltip: 'Scroll to latest',
                  onPressed: () {
                    if (_scrollCtrl.hasClients) {
                      _scrollCtrl.animateTo(
                        _scrollCtrl.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                ),
                // Clear
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined,
                      color: Color(0xFFFF3B30)),
                  tooltip: 'Clear logs',
                  onPressed: total == 0
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Clear logs?'),
                              content: const Text(
                                  'All in-memory log entries will be deleted. '
                                  'This cannot be undone.'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, true),
                                  style: TextButton.styleFrom(
                                      foregroundColor:
                                          const Color(0xFFFF3B30)),
                                  child: const Text('Clear'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) AppLogger.clear();
                        },
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      color: AppColors.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        // Level filter chips
        for (final level in [null, ...LogLevel.values])
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _LevelChip(
              label: level == null ? 'All' : level.name.toUpperCase(),
              color: level == null
                  ? const Color(0xFF8E8E93)
                  : _levelColor(level),
              selected: _filterLevel == level,
              onTap: () => setState(() => _filterLevel = level),
            ),
          ),
        const SizedBox(width: 4),
        // Free-text search
        Expanded(
          child: Container(
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.bgMain,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search…',
                hintStyle: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 7),
                suffixIcon: _searchText.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                          setState(() => _searchText = '');
                        },
                        child: const Icon(Icons.close,
                            size: 16, color: AppColors.textSecondary),
                      )
                    : null,
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildLogList(List<LogEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.receipt_long_outlined,
              size: 56, color: Color(0xFF636366)),
          const SizedBox(height: 12),
          Text(
            AppLogger.entries.isEmpty
                ? 'No log entries yet'
                : 'No entries match the filter',
            style: const TextStyle(
                fontSize: 15, color: AppColors.textSecondary),
          ),
        ]),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: entries.length,
      itemBuilder: (_, i) => _LogRow(entry: entries[i]),
    );
  }
}

// ─── Compact level filter chip ────────────────────────────────────────────────

class _LevelChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _LevelChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(40) : const Color(0xFF1F1F24),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : const Color(0xFF2C2C30),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? color : const Color(0xFF8E8E93),
          ),
        ),
      ),
    );
  }
}

// ─── Single log entry row ─────────────────────────────────────────────────────

class _LogRow extends StatelessWidget {
  final LogEntry entry;
  const _LogRow({required this.entry});

  Color get _levelColor => switch (entry.level) {
    LogLevel.debug => const Color(0xFF636366),
    LogLevel.info  => const Color(0xFF0A84FF),
    LogLevel.warn  => const Color(0xFFFF9F0A),
    LogLevel.error => const Color(0xFFFF3B30),
  };

  Color get _rowBg => switch (entry.level) {
    LogLevel.error => const Color(0x12FF3B30),
    LogLevel.warn  => const Color(0x10FF9F0A),
    _              => Colors.transparent,
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: entry.toString()));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Entry copied'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Container(
        color: _rowBg,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Timestamp
            Text(
              entry.timeLabel,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFF636366),
              ),
            ),
            const SizedBox(width: 8),
            // Level badge
            Container(
              width: 40,
              padding: const EdgeInsets.symmetric(
                  horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: _levelColor.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                entry.level.name.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: _levelColor,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Message
            Expanded(
              child: Text(
                entry.message,
                style: TextStyle(
                  fontFamily: entry.level == LogLevel.error ||
                          entry.level == LogLevel.warn
                      ? null
                      : 'monospace',
                  fontSize: 12,
                  color: entry.level == LogLevel.error
                      ? const Color(0xFFFF6B63)
                      : entry.level == LogLevel.warn
                          ? const Color(0xFFFFBF3B)
                          : const Color(0xFFF5F5F5),
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
