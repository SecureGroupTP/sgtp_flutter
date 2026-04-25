import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_cubit.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_view_state.dart';

/// Full-screen log viewer accessible from Settings → Logs.
///
/// Features:
///   • Live-updating list (new entries appear without reopening the screen).
///   • Level badge colour coding: DEBUG=grey, INFO=blue, WARNING=orange, ERROR=red.
///   • Filter bar — filter by level, logger name, time range, or free-text search.
///   • "Copy visible" / "Copy all" buttons copy log text to the clipboard.
///   • "Clear" button wipes the log file and in-memory buffer.
///   • Auto-scrolls to the newest entry when already at the bottom.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  static const String _allNamesValue = '__all_names__';

  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      context.read<LogsCubit>().setSearchText(_searchCtrl.text);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Color _levelColor(LogLevel l) => switch (l) {
        LogLevel.debug => const Color(0xFF636366),
        LogLevel.info => const Color(0xFF0A84FF),
        LogLevel.warning => const Color(0xFFFF9F0A),
        LogLevel.error => const Color(0xFFFF3B30),
      };

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<LogsCubit, LogsViewState>(
      listener: (context, state) {
        if (_searchCtrl.text != state.searchText) {
          _searchCtrl.value = TextEditingValue(
            text: state.searchText,
            selection: TextSelection.collapsed(offset: state.searchText.length),
          );
        }
        // Auto-scroll to bottom when new entries arrive and already near bottom.
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
      },
      builder: (context, state) {
        final entries = state.entries;
        final totalCount = state.totalCount;

        return Scaffold(
          backgroundColor: AppColors.bgMain,
          appBar: _buildAppBar(context, totalCount, entries.length),
          body: Column(
            children: [
              _buildFilterBar(state),
              const Divider(height: 1, color: Color(0xFF2C2C30)),
              Expanded(child: _buildLogList(entries, totalCount)),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, int total, int shown) {
    final cubit = context.read<LogsCubit>();
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
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                // Copy visible
                IconButton(
                  icon: const Icon(Icons.content_copy_outlined,
                      color: AppColors.textSecondary),
                  tooltip: 'Copy visible logs',
                  onPressed: shown == 0
                      ? null
                      : () {
                          Clipboard.setData(
                              ClipboardData(text: cubit.visibleLogText));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Visible logs copied'),
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
                          final ok = await showAppConfirmSheet(
                            context,
                            title: 'Clear logs?',
                            body: 'All log entries will be deleted from memory '
                                'and the log file.',
                            confirmLabel: 'Clear',
                            danger: true,
                          );
                          if (ok) cubit.clearLogs();
                        },
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar(LogsViewState state) {
    final cubit = context.read<LogsCubit>();
    return Container(
      color: AppColors.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              // Level filter
              for (final level in [null, ...LogLevel.values])
                _LevelChip(
                  label: level == null ? 'All' : level.name.toUpperCase(),
                  color: level == null
                      ? const Color(0xFF8E8E93)
                      : _levelColor(level),
                  selected: state.filterLevel == level,
                  onTap: () => cubit.setFilterLevel(level),
                ),
              // Name (logger class) filter
              _PopupFilterChip<String>(
                label: state.filterName == null
                    ? 'Logger: All'
                    : 'Logger: ${state.filterName}',
                selected: state.filterName != null,
                items: [
                  const PopupMenuItem<String>(
                    value: _allNamesValue,
                    child: Text('All loggers'),
                  ),
                  for (final name in state.availableNames)
                    PopupMenuItem<String>(
                      value: name,
                      child: Text(name),
                    ),
                ],
                onSelected: (value) {
                  cubit.setFilterName(value == _allNamesValue ? null : value);
                },
              ),
              // Time range filter
              _PopupFilterChip<LogsTimeRange>(
                label: 'Time: ${state.timeRange.label}',
                selected: state.timeRange != LogsTimeRange.all,
                items: [
                  for (final range in LogsTimeRange.values)
                    PopupMenuItem<LogsTimeRange>(
                      value: range,
                      child: Text(range.label),
                    ),
                ],
                onSelected: cubit.setTimeRange,
              ),
              _ActionChip(
                label: 'Reset',
                icon: Icons.restart_alt,
                onTap: () {
                  _searchCtrl.clear();
                  cubit.resetFilters();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Free-text search
          SizedBox(
            height: 32,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.bgMain,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: _searchCtrl,
                style:
                    const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search message or logger name…',
                  hintStyle: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  suffixIcon: state.searchText.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchCtrl.clear();
                            cubit.setSearchText('');
                          },
                          child: const Icon(Icons.close,
                              size: 16, color: AppColors.textSecondary),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList(List<LogEntry> entries, int totalCount) {
    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.receipt_long_outlined,
              size: 56, color: Color(0xFF636366)),
          const SizedBox(height: 12),
          Text(
            totalCount == 0
                ? 'No log entries yet'
                : 'No entries match the filter',
            style:
                const TextStyle(fontSize: 15, color: AppColors.textSecondary),
          ),
        ]),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: entries.length,
      itemBuilder: (_, i) => _LogRow(
        key: ValueKey(
          '${entries[i].time.microsecondsSinceEpoch}-${entries[i].level.index}-${entries[i].name}-${entries[i].message.hashCode}',
        ),
        entry: entries[i],
      ),
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

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F24),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2C2C30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: const Color(0xFF8E8E93)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8E8E93),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PopupFilterChip<T> extends StatelessWidget {
  final String label;
  final bool selected;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  const _PopupFilterChip({
    required this.label,
    required this.selected,
    required this.items,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF0A84FF) : const Color(0xFF8E8E93);
    return PopupMenuButton<T>(
      onSelected: onSelected,
      itemBuilder: (_) => items,
      color: const Color(0xFF1F1F24),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(40) : const Color(0xFF1F1F24),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : const Color(0xFF2C2C30),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? color : const Color(0xFF8E8E93),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.expand_more,
              size: 14,
              color: selected ? color : const Color(0xFF8E8E93),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Single log entry row ─────────────────────────────────────────────────────

class _LogRow extends StatefulWidget {
  final LogEntry entry;
  const _LogRow({super.key, required this.entry});

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  static const int _previewLength = 120;

  bool _expanded = false;

  LogEntry get entry => widget.entry;

  Color get _levelColor => switch (entry.level) {
        LogLevel.debug => const Color(0xFF636366),
        LogLevel.info => const Color(0xFF0A84FF),
        LogLevel.warning => const Color(0xFFFF9F0A),
        LogLevel.error => const Color(0xFFFF3B30),
      };

  Color get _rowBg => switch (entry.level) {
        LogLevel.error => const Color(0x12FF3B30),
        LogLevel.warning => const Color(0x10FF9F0A),
        _ => Colors.transparent,
      };

  bool get _canExpand {
    final compact = entry.message.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length > _previewLength ||
        entry.message.contains('\n') ||
        entry.error != null;
  }

  String get _collapsedMessage {
    final compact = entry.message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= _previewLength) return compact;
    return '${compact.substring(0, _previewLength)}…';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _canExpand ? () => setState(() => _expanded = !_expanded) : null,
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
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
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
                width: 44,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
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
              // Message + name badge
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MetaBadge(label: entry.name, color: _levelColor),
                    const SizedBox(height: 2),
                    Text(
                      _expanded ? entry.message : _collapsedMessage,
                      maxLines: _expanded ? null : 1,
                      style: TextStyle(
                        fontFamily:
                            entry.level == LogLevel.error ||
                                    entry.level == LogLevel.warning
                                ? null
                                : 'monospace',
                        fontSize: 12,
                        color: entry.level == LogLevel.error
                            ? const Color(0xFFFF6B63)
                            : entry.level == LogLevel.warning
                                ? const Color(0xFFFFBF3B)
                                : const Color(0xFFF5F5F5),
                        height: 1.4,
                      ),
                    ),
                    if (_expanded && entry.error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.error!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Color(0xFFFF6B63),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_canExpand) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF636366),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _MetaBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.25,
        ),
      ),
    );
  }
}
