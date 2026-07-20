import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/clip_markers.dart';
import '../clip/clip_trimmer.dart';
import '../clip/match_stats.dart';
import '../events/game_catalog.dart';
import 'format_duration.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart';
import 'widgets/timeline_markers.dart';

export 'format_duration.dart' show formatDuration;

/// Route name used when pushing [PlayerScreen] — lets tests assert a push
/// happened (via a [NavigatorObserver]) without ever building the screen,
/// which would construct a real media_kit [Player] and require the native
/// libmpv libraries that aren't loaded in the widget-test host process.
const playerScreenRouteName = '/player';

/// Which speaker glyph represents a media_kit [volume] (0-100, see
/// `Player.state.volume`): muted at zero, a lower glyph below the halfway
/// mark, full above it. Pure so the branch is testable without a real
/// media_kit [Player] (player_screen_test.dart cannot build [PlayerScreen]
/// itself — see that file's header comment).
IconData volumeIcon(double volume) {
  if (volume <= 0) return Icons.volume_off_rounded;
  if (volume < 50) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

/// In-app playback view for a single clip. Owns a media_kit [Player] /
/// [VideoController] pair for the lifetime of the screen and disposes them
/// on pop. Trimming/clipping is out of scope here — this is playback only;
/// the OS default player is still reachable from the clip tile's overflow
/// menu for anyone who wants an external app.
///
/// Takes the whole [Clip] (rather than a bare path/title pair) so the header
/// can show [displayNameFor]'s game name, the clip's event badge, and its
/// relative age (§3.7) instead of the raw gameId string.
class PlayerScreen extends StatefulWidget {
  final Clip clip;

  /// The match's recorded events (see `MatchStats.events`), from which
  /// [computeClipMarkers] derives this clip's timeline markers once the
  /// player reports a real duration (see [_PlayerScreenState.build]).
  /// Default empty — a caller with no `MatchStats` for this clip (an older
  /// session, a game with no event API, or a pusher that simply has no
  /// store handy) just gets a plain seek bar; that's not an error (see
  /// CLAUDE.md/this feature's honesty note).
  final List<MatchEventStamp> events;

  /// The clip library, for indexing a trimmed copy (see [trimmer]). Null
  /// (tests, embeddings without a library) hides the Trim button.
  final ClipLibrary? library;

  /// The platform trim exporter. Null or unsupported (Windows/Linux for
  /// now) hides the Trim button — no dead affordance.
  final ClipTrimmer? trimmer;

  const PlayerScreen({
    required this.clip,
    this.events = const [],
    this.library,
    this.trimmer,
    super.key,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  final FocusNode _focusNode = FocusNode();

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // media_kit's PlayerState defaults volume to 100.0 (full); mirrored here
  // so the mute toggle has a sane starting point before the first stream
  // event arrives.
  double _volume = 100;

  /// Remembers the pre-mute volume so unmuting restores it rather than
  /// jumping to a fixed value. Only ever holds a positive volume.
  double _previousVolume = 100;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<double>? _volumeSub;
  StreamSubscription<String>? _errorSub;

  /// The first playback error mpv reported, or null while playback is
  /// healthy. A missing/corrupt clip file otherwise plays as an indefinite
  /// black frame with a dead seek bar — this swaps the video area for an
  /// explanation and a fallback.
  String? _playbackError;

  /// Trim mode: while true the controls grow a range selector and a save
  /// row. [_trimRange] is in milliseconds within the clip; null until the
  /// user first enters trim mode after the duration is known.
  bool _trimming = false;
  RangeValues? _trimRange;

  /// True while a trim export runs — disables the save button so a slow
  /// export can't be double-fired.
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // Subscribe to every property stream BEFORE calling open() — mpv's
    // property observers are registered at Player() construction, and a
    // late subscription can miss the first emissions (see CLAUDE.md's
    // media_kit headless-Player gotchas).
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    _positionSub = _player.stream.position.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _durationSub = _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _volumeSub = _player.stream.volume.listen((volume) {
      if (mounted) setState(() => _volume = volume);
      if (volume > 0) _previousVolume = volume;
    });
    _errorSub = _player.stream.error.listen((message) {
      // First error wins — mpv often follows one root failure with a
      // cascade of secondary messages, and the first names the real cause.
      if (mounted && _playbackError == null) {
        setState(() => _playbackError = message);
      }
    });
    _player.open(Media(widget.clip.path));
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _volumeSub?.cancel();
    _errorSub?.cancel();
    _focusNode.dispose();
    // Fire-and-forget: Player.dispose() is async (it tears down the native
    // player) but State.dispose() must be synchronous.
    unawaited(_player.dispose());
    super.dispose();
  }

  void _togglePlay() => _player.playOrPause();

  void _toggleMute() {
    _player.setVolume(_volume > 0 ? 0 : _previousVolume);
  }

  bool get _trimAvailable =>
      widget.library != null &&
      (widget.trimmer?.isSupported ?? false) &&
      _playbackError == null;

  void _toggleTrimming() {
    if (_duration <= Duration.zero) return;
    setState(() {
      _trimming = !_trimming;
      if (_trimming) {
        _trimRange ??=
            RangeValues(0, _duration.inMilliseconds.toDouble());
      }
    });
  }

  Future<void> _saveTrim() async {
    final library = widget.library;
    final trimmer = widget.trimmer;
    final range = _trimRange;
    if (library == null || trimmer == null || range == null) return;
    final start = Duration(milliseconds: range.start.round());
    final end = Duration(milliseconds: range.end.round());
    if (end - start < const Duration(seconds: 1)) {
      _toast('Trims need to be at least a second long.');
      return;
    }

    setState(() => _exporting = true);
    final outPath =
        trimOutPath(widget.clip.path, library.all.map((c) => c.path));
    final ok = await trimmer.trim(
        srcPath: widget.clip.path, start: start, end: end, outPath: outPath);
    if (!mounted) return;
    if (!ok) {
      setState(() => _exporting = false);
      _toast("Couldn't save the trim — the original clip is untouched.");
      return;
    }

    // Same gameId/session/event as the source so the trim files next to it
    // in every grouping; fresh size from the real exported file.
    var size = 0;
    try {
      size = await File(outPath).length();
    } on FileSystemException {
      // Indexed with size 0 rather than dropped — the file exists (the
      // exporter said so); a transient stat failure shouldn't lose it.
    }
    library.add(Clip(
      path: outPath,
      gameId: widget.clip.gameId,
      event: widget.clip.event,
      createdAt: widget.clip.createdAt,
      sizeBytes: size,
      sessionAt: widget.clip.sessionAt,
      killCount: widget.clip.killCount,
      eventLabel: 'Trimmed',
    ));
    await library.save();
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _trimming = false;
    });
    _toast('Trimmed clip saved.');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(message),
    ));
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlay();
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only meaningful once the real duration is known (see
    // computeClipMarkers's doc) — before then this is always empty, so the
    // seek bar renders plain until the player reports one.
    final markers = _duration > Duration.zero
        ? computeClipMarkers(
            clip: widget.clip, duration: _duration, events: widget.events)
        : const <ClipMarker>[];
    return Scaffold(
      // No hard-coded background: inherit rewindTheme's scaffoldBackgroundColor
      // (RewindTokens.dark.bg) so this stays in step with the shared palette.
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          children: [
            _Header(clip: widget.clip),
            Expanded(
              child: Center(
                child: _playbackError != null
                    ? _PlaybackErrorPanel(
                        message: _playbackError!,
                        clip: widget.clip,
                      )
                    : Video(
                        controller: _controller,
                        // media_kit's own control overlay would render
                        // alongside ours otherwise (maintainer: "both
                        // render, ours win") — NoVideoControls is
                        // media_kit_video's documented way to opt out of it
                        // entirely (it's literally `null` under the hood,
                        // not a special-cased builder).
                        controls: NoVideoControls,
                      ),
              ),
            ),
            _Controls(
              playing: _playing,
              position: _position,
              duration: _duration,
              volume: _volume,
              markers: markers,
              onTogglePlay: _togglePlay,
              onSeek: (d) => _player.seek(d),
              onToggleMute: _toggleMute,
              trimming: _trimming,
              onToggleTrim: _trimAvailable && _duration > Duration.zero
                  ? _toggleTrimming
                  : null,
            ),
            if (_trimming && _trimRange != null)
              _TrimBar(
                range: _trimRange!,
                duration: _duration,
                exporting: _exporting,
                onChanged: (r) => setState(() => _trimRange = r),
                onPreview: (d) => _player.seek(d),
                onSave: _saveTrim,
                onCancel: () => setState(() => _trimming = false),
              ),
          ],
        ),
      ),
    );
  }
}

/// Close button, event badge, game name, and relative age (§3.7) — replaces
/// the raw gameId string the header used to show.
class _Header extends StatelessWidget {
  final Clip clip;

  const _Header({required this.clip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: hairlineBorder())),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          EventBadge(kind: clip.event),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              displayNameFor(clip.gameId),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.title,
            ),
          ),
          const SizedBox(width: 8),
          Text(relativeAge(clip.createdAt), style: theme.textTheme.bodyMuted),
        ],
      ),
    );
  }
}

/// Play/pause, seek bar, elapsed/total readout, and a mute/volume toggle —
/// the app's own control bar, replacing media_kit's built-in overlay (see
/// the `Video(controls: NoVideoControls)` call site above).
class _Controls extends StatelessWidget {
  final bool playing;
  final Duration position;
  final Duration duration;
  final double volume;

  /// This clip's event markers (empty when there's nothing to show — see
  /// [PlayerScreen.events]'s doc). Rendered as a [TimelineMarkers] strip
  /// directly above the seek bar, sharing its width.
  final List<ClipMarker> markers;

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onToggleMute;

  /// Trim-mode toggle. Null hides the button entirely (no library, no
  /// platform support, playback failed) — an affordance that can't work
  /// shouldn't render.
  final VoidCallback? onToggleTrim;
  final bool trimming;

  const _Controls({
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.markers,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onToggleMute,
    required this.trimming,
    this.onToggleTrim,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Tabular figures so the elapsed/total readout doesn't jitter width as
    // its digits change every second (§2's numeral treatment for durations).
    final durationStyle = theme.textTheme.bodyMuted
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final totalMs = duration.inMilliseconds;
    final positionMs =
        position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);
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
          Text(formatDuration(position), style: durationStyle),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (markers.isNotEmpty)
                  TimelineMarkers(
                      markers: markers, duration: duration, onSeek: onSeek),
                Slider(
                  value: positionMs.toDouble(),
                  max: totalMs > 0 ? totalMs.toDouble() : 1.0,
                  onChanged: totalMs > 0
                      ? (v) => onSeek(Duration(milliseconds: v.round()))
                      : null,
                ),
              ],
            ),
          ),
          Text(formatDuration(duration), style: durationStyle),
          if (onToggleTrim != null)
            IconButton(
              key: const ValueKey('trimButton'),
              icon: const Icon(Icons.content_cut),
              tooltip: trimming ? 'Close trim' : 'Trim clip',
              color: trimming ? context.rewindTokens.accent : null,
              onPressed: onToggleTrim,
            ),
          IconButton(
            icon: Icon(volumeIcon(volume)),
            tooltip: volume <= 0 ? 'Unmute' : 'Mute',
            onPressed: onToggleMute,
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the video when mpv reports a playback error (missing,
/// moved, or corrupt clip file): names the problem instead of the previous
/// behavior — an indefinite black frame with a dead seek bar and no message.
class _PlaybackErrorPanel extends StatelessWidget {
  final String message;
  final Clip clip;

  const _PlaybackErrorPanel({required this.message, required this.clip});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.broken_image_outlined, size: 48, color: tokens.textMuted),
        const SizedBox(height: 16),
        Text("Couldn't play this clip", style: textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'The file may have been moved, deleted, or damaged.',
          style: textTheme.bodyMuted,
        ),
        const SizedBox(height: 4),
        // The raw mpv line, for a bug report — muted so it reads as detail,
        // not the headline.
        SelectableText(message,
            style: textTheme.bodyMuted, textAlign: TextAlign.center),
      ],
    );
  }
}


/// The trim row shown under the controls in trim mode: a range selector
/// over the clip with live in/out timecodes, and Save/Cancel. Dragging a
/// handle seeks the player to that edge so the user sees the exact frame
/// they're cutting on.
class _TrimBar extends StatelessWidget {
  final RangeValues range;
  final Duration duration;
  final bool exporting;
  final ValueChanged<RangeValues> onChanged;
  final ValueChanged<Duration> onPreview;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _TrimBar({
    required this.range,
    required this.duration,
    required this.exporting,
    required this.onChanged,
    required this.onPreview,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStyle = theme.textTheme.bodyMuted
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final totalMs = duration.inMilliseconds.toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(border: Border(top: hairlineBorder())),
      child: Row(
        children: [
          Text(formatDuration(Duration(milliseconds: range.start.round())),
              style: timeStyle),
          Expanded(
            child: RangeSlider(
              key: const ValueKey('trimRange'),
              values: range,
              max: totalMs > 0 ? totalMs : 1.0,
              onChanged: exporting
                  ? null
                  : (r) {
                      // Seek to whichever edge moved so the cut frame is
                      // visible while dragging.
                      final startMoved = r.start != range.start;
                      onPreview(Duration(
                          milliseconds:
                              (startMoved ? r.start : r.end).round()));
                      onChanged(r);
                    },
            ),
          ),
          Text(formatDuration(Duration(milliseconds: range.end.round())),
              style: timeStyle),
          const SizedBox(width: 16),
          TextButton(
            onPressed: exporting ? null : onCancel,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('saveTrimButton'),
            onPressed: exporting ? null : onSave,
            child: Text(exporting ? 'Saving…' : 'Save trimmed clip'),
          ),
        ],
      ),
    );
  }
}
