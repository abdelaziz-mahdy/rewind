import 'package:flutter/material.dart';

import '../../events/game_event.dart';
import '../game_directory.dart';
import '../theme.dart';
import 'clip_tile.dart' show eventBadge;

/// League's `enabledEvents` matrix groups (§3.4): `manual` is excluded (the
/// hotkey always saves, regardless of this config) and `other` has no group
/// (it's a generic fallback no source currently emits for League). Shared by
/// [GameHubScreen]'s capture-settings disclosure and each MY GAMES per-game
/// settings page (`settings_screen.dart`) — one grouping, drawn once.
const List<GameEventKind> combatEvents = [
  GameEventKind.kill,
  GameEventKind.doubleKill,
  GameEventKind.tripleKill,
  GameEventKind.quadraKill,
  GameEventKind.pentaKill,
  GameEventKind.ace,
];
const List<GameEventKind> objectiveEvents = [
  GameEventKind.dragonKill,
  GameEventKind.dragonSteal,
  GameEventKind.baronKill,
  GameEventKind.baronSteal,
  GameEventKind.turretKill,
  GameEventKind.inhibitorKill,
];
const List<GameEventKind> matchEvents = [
  GameEventKind.victory,
  GameEventKind.defeat,
];

/// One labeled event group: [combatEvents]/[objectiveEvents]/[matchEvents].
typedef EventGroupSpec = ({String label, List<GameEventKind> kinds});

/// The event groups a game's auto-clip UI should offer. Only League's vendor
/// integration ever emits `GameEvent`s (see `docs/COMPLIANCE.md` —
/// process-watched catalog games have no sanctioned event API), so every
/// other game gets no groups at all — callers hide the whole event matrix
/// when this returns empty rather than show an auto-clip picker with
/// nothing to pick.
List<EventGroupSpec> eventGroupsFor(GameEntry entry) =>
    entry.detection.contains(DetectionMethod.liveClientApi)
        ? const [
            (label: 'COMBAT', kinds: combatEvents),
            (label: 'OBJECTIVES', kinds: objectiveEvents),
            (label: 'MATCH', kinds: matchEvents),
          ]
        : const [];

/// One group's micro-label header + a wrapping row of [EventToggleChip]s.
class EventGroup extends StatelessWidget {
  final String label;
  final List<GameEventKind> kinds;
  final Set<GameEventKind> selected;
  final void Function(GameEventKind kind, bool value) onChanged;

  const EventGroup({
    required this.label,
    required this.kinds,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in kinds)
              EventToggleChip(
                key: ValueKey('eventToggle:${kind.name}'),
                kind: kind,
                selected: selected.contains(kind),
                onChanged: (value) => onChanged(kind, value),
              ),
          ],
        ),
      ],
    );
  }
}

/// A checkbox-styled chip for an auto-clip event matrix: accent fill/border
/// when enabled, hairline otherwise — same visual language as
/// `EventFilterChips`, but a boolean toggle rather than a single-select.
class EventToggleChip extends StatelessWidget {
  final GameEventKind kind;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const EventToggleChip({
    required this.kind,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final accent = tokens.accent;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(tokens.radiusChip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : tokens.surface,
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.fromBorderSide(
                selected ? BorderSide(color: accent) : hairlineBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A non-colour cue for "on". State was previously carried by hue
              // alone (green vs white), which reads as nothing to a
              // colour-blind player — and every chip is the same size and
              // shape, so hue was the ONLY signal.
              if (selected) ...[
                Icon(Icons.check, size: 13, color: accent),
                const SizedBox(width: 5),
              ],
              Text(
                eventBadge(kind),
                // OFF is muted, ON is the accent. This used to be inverted:
                // an unselected chip drew full-brightness `tokens.text` while
                // a selected one drew the dimmer accent, so a hub's LOUDEST
                // elements were the events the player had switched off.
                style: theme.textTheme.label
                    .copyWith(color: selected ? accent : tokens.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
