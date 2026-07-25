import 'package:flutter/material.dart';

import '../../clip/clip_markers.dart';
import '../format_duration.dart';
import '../theme.dart';
import 'clip_tile.dart' show eventBadge, eventColor;

/// Tick size (see class doc's "2x8-ish").
const double timelineMarkerWidth = 3;
const double timelineMarkerHeight = 11;

/// How far before a marker's own offset a tap seeks to, so the viewer lands
/// on the lead-up to the moment rather than the moment itself.
const Duration timelineMarkerSeekLeadIn = Duration(seconds: 2);

/// A strip of colored ticks over/around a clip player's seek bar, one per
/// [ClipMarker] — proportionally positioned by `offset / duration` along the
/// available width. Tapping a tick seeks (via [onSeek]) to
/// `max(0, offset - timelineMarkerSeekLeadIn)`, so the viewer sees the
/// lead-up to the moment, not just its start. A plain, dependency-free
/// widget (no media_kit) deliberately — `PlayerScreen` can't be built in
/// widget tests (see its own doc), so this strip has to be independently
/// testable.
class TimelineMarkers extends StatelessWidget {
  final List<ClipMarker> markers;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  const TimelineMarkers({
    required this.markers,
    required this.duration,
    required this.onSeek,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0 || markers.isEmpty) {
      return const SizedBox(height: timelineMarkerHeight);
    }
    return SizedBox(
      height: timelineMarkerHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            children: [
              for (var i = 0; i < markers.length; i++)
                _Tick(
                  key: ValueKey('timelineMarker-$i'),
                  marker: markers[i],
                  // Centered on its proportional position, clamped so a
                  // marker at offset 0 (or duration) doesn't render half
                  // off the edge of the strip.
                  left: ((markers[i].offset.inMilliseconds / totalMs) * width -
                          timelineMarkerWidth / 2)
                      .clamp(0.0, width - timelineMarkerWidth),
                  onSeek: onSeek,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Tick extends StatelessWidget {
  final ClipMarker marker;
  final double left;
  final ValueChanged<Duration> onSeek;

  const _Tick(
      {required this.marker,
      required this.left,
      required this.onSeek,
      super.key});

  @override
  Widget build(BuildContext context) {
    final color = eventColor(context, marker.kind);
    final leadIn = marker.offset - timelineMarkerSeekLeadIn;
    final target = leadIn.isNegative ? Duration.zero : leadIn;
    return Positioned(
      left: left,
      top: 0,
      child: Tooltip(
        message:
            '${eventBadge(marker.kind)} · ${formatDuration(marker.offset)}',
        child: Semantics(
          label: '${eventBadge(marker.kind)} at '
              '${formatDuration(marker.offset)}',
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSeek(target),
            child: Container(
              width: timelineMarkerWidth,
              height: timelineMarkerHeight,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(timelineMarkerWidth / 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled key for the ticks above, rendered beneath the seek bar.
///
/// The ticks alone are 3px of pure colour: their meaning is reachable only by
/// hovering each one, and not at all by a screen reader. The legend states
/// what happened and when in text, which is also simply faster to read than
/// hunting along a bar.
class TimelineMarkerLegend extends StatelessWidget {
  final List<ClipMarker> markers;
  final ValueChanged<Duration> onSeek;

  /// Beyond this many, the legend would be longer than the clip is
  /// interesting; the ticks still show every marker.
  static const int maxShown = 6;

  const TimelineMarkerLegend(
      {required this.markers, required this.onSeek, super.key});

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final m in markers.take(maxShown))
          _LegendEntry(marker: m, onSeek: onSeek, style: theme.textTheme.micro),
        if (markers.length > maxShown)
          Text('+${markers.length - maxShown} more',
              style: theme.textTheme.micro
                  .copyWith(color: context.rewindTokens.textDim)),
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  final ClipMarker marker;
  final ValueChanged<Duration> onSeek;
  final TextStyle style;

  const _LegendEntry(
      {required this.marker, required this.onSeek, required this.style});

  @override
  Widget build(BuildContext context) {
    final color = eventColor(context, marker.kind);
    final leadIn = marker.offset - timelineMarkerSeekLeadIn;
    final target = leadIn.isNegative ? Duration.zero : leadIn;
    return InkWell(
      onTap: () => onSeek(target),
      child: Text(
        '▲ ${eventBadge(marker.kind)} ${formatDuration(marker.offset)}',
        style: style.copyWith(color: color),
      ),
    );
  }
}
