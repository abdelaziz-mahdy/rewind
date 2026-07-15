import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// talker_flutter re-exports talker's TalkerData/LogLevel — no separate dep.
import 'package:talker_flutter/talker_flutter.dart';

import '../log/file_log.dart';
import '../log/log.dart';
import 'theme.dart';

/// Rewind's own logs viewer — a plain, on-brand list of what the app has
/// been doing (detections, saves, cleanup, errors), replacing the
/// third-party `TalkerScreen` (whose developer-tool look confused users).
/// It reads the same [talker] history/stream; the raw trail also lives in a
/// per-session file (see `file_log.dart`).
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

enum _Filter { all, info, warnings, errors }

class _LogsScreenState extends State<LogsScreen> {
  late final List<TalkerData> _entries;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _entries = talker.history.toList();
    talker.stream.listen((e) {
      if (mounted) setState(() => _entries.add(e));
    });
  }

  bool _isError(TalkerData e) =>
      e.logLevel == LogLevel.error ||
      e.logLevel == LogLevel.critical ||
      e.exception != null ||
      e.error != null;

  bool _isWarning(TalkerData e) => e.logLevel == LogLevel.warning;

  bool _passesFilter(TalkerData e) => switch (_filter) {
        _Filter.all => true,
        _Filter.errors => _isError(e),
        _Filter.warnings => _isWarning(e),
        _Filter.info => !_isError(e) && !_isWarning(e),
      };

  Color _color(BuildContext context, TalkerData e) {
    final scheme = Theme.of(context).colorScheme;
    if (_isError(e)) return scheme.error;
    if (_isWarning(e)) return context.rewindTokens.accent; // amber-ish accent
    return context.rewindTokens.textMuted;
  }

  String _label(TalkerData e) {
    if (_isError(e)) return 'ERROR';
    if (_isWarning(e)) return 'WARN';
    return 'INFO';
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
      ':${t.second.toString().padLeft(2, '0')}';

  Future<void> _copyAll() async {
    final text = _entries.map((e) => e.generateTextMessage()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logs copied to clipboard')));
    }
  }

  Future<void> _openLogFile() async {
    final f = activeLogFile;
    if (f == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', f.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,${f.path}']);
      }
    } catch (_) {}
  }

  void _clear() {
    talker.cleanHistory();
    setState(_entries.clear);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    // Newest first.
    final visible = _entries.where(_passesFilter).toList().reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _entries.isEmpty ? null : _copyAll,
          ),
          if (activeLogFile != null)
            IconButton(
              tooltip: 'Show log file',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _openLogFile,
            ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: _entries.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                for (final f in _Filter.values) ...[
                  ChoiceChip(
                    label: Text(switch (f) {
                      _Filter.all => 'All',
                      _Filter.info => 'Info',
                      _Filter.warnings => 'Warnings',
                      _Filter.errors => 'Errors',
                    }),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text('Nothing logged yet.',
                        style: theme.textTheme.bodyMuted),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: tokens.hairline),
                    itemBuilder: (context, i) => _LogRow(
                        entry: visible[i],
                        color: _color(context, visible[i]),
                        label: _label(visible[i]),
                        time: _time(visible[i].time)),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One log line: a level chip + time, then the message; tapping expands any
/// exception/stack trace.
class _LogRow extends StatefulWidget {
  final TalkerData entry;
  final Color color;
  final String label;
  final String time;

  const _LogRow({
    required this.entry,
    required this.color,
    required this.label,
    required this.time,
  });

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final e = widget.entry;
    final hasDetail =
        e.stackTrace != null || e.exception != null || e.error != null;

    return InkWell(
      onTap: hasDetail ? () => setState(() => _expanded = !_expanded) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(tokens.radiusChip),
                    border:
                        Border.all(color: widget.color.withValues(alpha: 0.5)),
                  ),
                  child: Text(widget.label,
                      textAlign: TextAlign.center,
                      style:
                          theme.textTheme.micro.copyWith(color: widget.color)),
                ),
                const SizedBox(width: 10),
                Text(widget.time,
                    style: theme.textTheme.micro.copyWith(
                        color: tokens.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(e.message ?? e.displayMessage,
                      style: theme.textTheme.body),
                ),
                if (hasDetail)
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: tokens.textMuted),
              ],
            ),
            if (_expanded && hasDetail) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(tokens.radiusControl),
                ),
                child: SelectableText(
                  [
                    if (e.exception != null) e.displayException,
                    if (e.error != null) e.displayError,
                    if (e.stackTrace != null) e.displayStackTrace,
                  ].where((s) => s.trim().isNotEmpty).join('\n\n'),
                  style:
                      theme.textTheme.micro.copyWith(color: tokens.textMuted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
