import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../clip/clip_markers.dart';
import '../clip/duration_prober.dart';
import '../clip/match_stats.dart';
import '../clip/match_timeline.dart';
import 'clip_sessions.dart';
import 'format_duration.dart';
import 'theme.dart';
import 'widgets/timeline_markers.dart';

/// Route name for the match timeline viewer, so navigation can be asserted
/// in widget tests without building the screen (media_kit needs native
/// libmpv — same pattern as `playerScreenRouteName`).
const String matchTimelineScreenRouteName = 'matchTimeline';

/// Watches a whole match in-app: every clip of the session laid on the REAL
/// match timeline — recorded spans as bright segments, unrecorded spans as
/// visible gaps, the match's events (kills, achievements…) marked at their
/// true times — with playback running clip-to-clip chronologically and
/// auto-jumping across the gaps. Tapping anywhere on the timeline seeks:
/// into a segment plays that moment; into a gap jumps to the next recorded
/// span.
class MatchTimelineScreen extends StatefulWidget {
  final ClipSession session;
  final String matchLabel;
  final MatchStats? stats;
  final DurationProber prober;

  const MatchTimelineScreen({
    required this.session,
    required this.matchLabel,
    required this.stats,
    required this.prober,
    super.key,
  });

  @override
  State<MatchTimelineScreen> createState() => _MatchTimelineScreenState();
}

class _MatchTimelineScreenState extends State<MatchTimelineScreen> {
  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;

  MatchTimelineLayout? _layout;

  /// Index into [_layout.segments] of the clip currently loaded, or -1
  /// before the first open.
  int _segmentIndex = -1;
  bool _playing = false;
  Duration _positionInClip = Duration.zero;

  /// True while ffprobe runs over the session's clips on open.
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // Subscribe before any open() — see CLAUDE.md's media_kit gotchas.
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    _positionSub = _player.stream.position.listen((position) {
      if (mounted) setState(() => _positionInClip = position);
    });
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _advance();
    });
    _prepare();
  }

  Future<void> _prepare() async {
    final clips = widget.session.clips;
    final durations = <String, Duration>{};
    for (final c in clips) {
      final d = await widget.prober.probe(c.path);
      if (d != null) durations[c.path] = d;
    }
    if (!mounted) return;
    final layout = computeMatchTimeline(
        clips, durations, widget.stats?.events ?? const []);
    setState(() {
      _layout = layout;
      _probing = false;
    });
    if (layout.segments.isNotEmpty) {
      unawaited(_openSegment(0, play: true));
    }
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _positionSub?.cancel();
    _completedSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  /// The playhead's position on the MATCH timeline.
  Duration get _matchPosition {
    final layout = _layout;
    if (layout == null || _segmentIndex < 0) return Duration.zero;
    if (_segmentIndex >= layout.segments.length) return layout.span;
    return layout.segments[_segmentIndex].start + _positionInClip;
  }

  Future<void> _openSegment(int index,
      {Duration offset = Duration.zero, bool play = true}) async {
    final layout = _layout;
    if (layout == null || index < 0 || index >= layout.segments.length) {
      return;
    }
    final changed = index != _segmentIndex;
    setState(() => _segmentIndex = index);
    if (changed) {
      await _player.open(
          Media(layout.segments[index].clip.path), play: play);
    }
    if (offset > Duration.zero) await _player.seek(offset);
    if (play && !changed) await _player.play();
  }

  void _advance() {
    final layout = _layout;
    if (layout == null) return;
    final next = _segmentIndex + 1;
    if (next < layout.segments.length) {
      unawaited(_openSegment(next, play: true));
    } else if (mounted) {
      // End of the match — leave the last frame up, paused.
      setState(() {});
    }
  }

  /// Seeks the MATCH position: inside a segment plays that exact moment; in
  /// a gap, jumps to the next recorded span (that's what a viewer wants —
  /// there is nothing to show in a gap).
  void _seekMatch(Duration at) {
    final layout = _layout;
    if (layout == null) return;
    final direct = layout.segmentAt(at);
    final target = direct ?? layout.nextSegmentFrom(at);
    if (target == null) return;
    final index = layout.segments.indexOf(target);
    final offset = direct == null ? Duration.zero : at - target.start;
    unawaited(_openSegment(index, offset: offset, play: true));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = _layout;

    return Scaffold(
      appBar: AppBar(title: Text('${widget.matchLabel} — full match')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _probing
                  ? const CircularProgressIndicator()
                  : (layout == null || layout.segments.isEmpty)
                      ? Text(
                          "Couldn't read this match's clips — they may have "
                          'been moved or deleted.',
                          style: theme.textTheme.bodyMuted,
                        )
                      : Video(controller: _controller,
                          controls: NoVideoControls),
            ),
          ),
          if (layout != null && layout.segments.isNotEmpty)
            _MatchTimelineBar(
              layout: layout,
              matchPosition: _matchPosition,
              currentSegment: _segmentIndex,
              playing: _playing,
              onTogglePlay: () => _player.playOrPause(),
              onSeek: _seekMatch,
            ),
        ],
      ),
    );
  }
}

/// The full-match strip: play/pause + match-position readout above a bar
/// where recorded spans render bright (the playing one brightest), gaps
/// stay dark, an event-marker row sits on top, and a playhead tracks
/// playback. All hit-testing is fraction-of-span → [onSeek].
class _MatchTimelineBar extends StatelessWidget {
  final MatchTimelineLayout layout;
  final Duration matchPosition;
  final int currentSegment;
  final bool playing;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;

  const _MatchTimelineBar({
    required this.layout,
    required this.matchPosition,
    required this.currentSegment,
    required this.playing,
    required this.onTogglePlay,
    required this.onSeek,
  });

  static const double _barHeight = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final timeStyle = theme.textTheme.bodyMuted
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final markers = [
      for (final e in layout.events)
        ClipMarker(kind: e.stamp.kind, offset: e.at),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 12),
      decoration: BoxDecoration(border: Border(top: hairlineBorder())),
      child: Row(
        children: [
          IconButton(
            icon:
                Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            tooltip: playing ? 'Pause' : 'Play',
            onPressed: onTogglePlay,
          ),
          Text(formatDuration(matchPosition), style: timeStyle),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (markers.isNotEmpty)
                  TimelineMarkers(
                    markers: markers,
                    duration: layout.span,
                    onSeek: onSeek,
                  ),
                LayoutBuilder(builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => onSeek(Duration(
                        milliseconds: (layout.span.inMilliseconds *
                                (d.localPosition.dx / w))
                            .round())),
                    child: SizedBox(
                      height: _barHeight,
                      child: Stack(
                        children: [
                          // Gap-colored base track.
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: tokens.surfaceRaised,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          // Recorded spans.
                          for (var i = 0; i < layout.segments.length; i++)
                            Positioned(
                              left: w *
                                  layout
                                      .fractionOf(layout.segments[i].start),
                              width: (w *
                                      (layout.fractionOf(
                                              layout.segments[i].end) -
                                          layout.fractionOf(
                                              layout.segments[i].start)))
                                  .clamp(2.0, w),
                              top: 0,
                              bottom: 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: i == currentSegment
                                      ? tokens.accent
                                      : tokens.accent
                                          .withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          // Playhead.
                          Positioned(
                            left: (w * layout.fractionOf(matchPosition) - 1)
                                .clamp(0.0, w - 2),
                            width: 2,
                            top: -2,
                            bottom: -2,
                            child: ColoredBox(color: tokens.text),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(formatDuration(layout.span), style: timeStyle),
        ],
      ),
    );
  }
}
