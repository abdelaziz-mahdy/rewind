import 'package:flutter/material.dart';

import '../theme.dart';

/// Rewind's ONE row grammar for a setting: a label (+ optional muted [hint]
/// beneath it) on the LEFT in an [Expanded], the control sized to its own
/// content on the RIGHT.
///
/// Shared, not private to one screen, on purpose. The same settings appear in
/// two places — the Settings screen and a game hub's per-game capture panel —
/// and when the grammar lived inside `settings_screen.dart` the hub couldn't
/// reach it, so it kept drawing label-ABOVE-control while Settings drew
/// label-left/control-right. One setting, two shapes, same app: nothing reads
/// as settled when the eye can't learn a single rule.
///
/// [footnote], when given, is a full-width caption below the row (e.g.
/// "Applies on next launch") — kept INSIDE the row rather than as a sibling,
/// because it explains this row's control specifically.
class SettingRow extends StatelessWidget {
  final String label;
  final Widget? hint;
  final Widget control;
  final String? footnote;

  const SettingRow({
    required this.label,
    this.hint,
    required this.control,
    this.footnote,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ONE Expanded filler per row: several loose Flexible(flex: 1)
              // children would each take an equal SHARE of the free space and
              // strand the control mid-row (CLAUDE.md's flex-allocation trap).
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.body),
                    if (hint case final h?) ...[
                      const SizedBox(height: 4),
                      h,
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 24),
              control,
            ],
          ),
          if (footnote != null) ...[
            const SizedBox(height: 8),
            Text(footnote!, style: theme.textTheme.bodyMuted),
          ],
        ],
      ),
    );
  }
}

/// Lays out [SettingRow]s with ONE hairline between each pair — never before
/// the first or after the last.
///
/// The hairline is load-bearing, not decoration: it's what binds a label to
/// the control across the row, which is what lets the column be wide enough
/// to fill its pane instead of staying narrow to keep the two near each other.
class SettingRows extends StatelessWidget {
  final List<Widget> rows;

  const SettingRows(this.rows, {super.key});

  @override
  Widget build(BuildContext context) {
    final hairline = context.rewindTokens.hairline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: hairline),
          rows[i],
        ],
      ],
    );
  }
}
