import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'theme.dart';

/// Route name used when pushing [PlayerScreen] — lets tests assert a push
/// happened (via a [NavigatorObserver]) without ever building the screen,
/// which would construct a real media_kit [Player] and require the native
/// libmpv libraries that aren't loaded in the widget-test host process.
const playerScreenRouteName = '/player';

/// Formats a [Duration] as `M:SS`, or `H:MM:SS` once past an hour. Used for
/// the elapsed/total readout next to the seek bar.
String formatDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// In-app playback view for a single clip. Owns a media_kit [Player] /
/// [VideoController] pair for the lifetime of the screen and disposes them
/// on pop. Trimming/clipping is out of scope here — this is playback only;
/// the OS default player is still reachable from the clip tile's overflow
/// menu for anyone who wants an external app.
class PlayerScreen extends StatefulWidget {
  final String path;
  final String title;

  const PlayerScreen({required this.path, required this.title, super.key});

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

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    _positionSub = _player.stream.position.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _durationSub = _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _focusNode.dispose();
    // Fire-and-forget: Player.dispose() is async (it tears down the native
    // player) but State.dispose() must be synchronous.
    unawaited(_player.dispose());
    super.dispose();
  }

  void _togglePlay() => _player.playOrPause();

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
    return Scaffold(
      // No hard-coded background: inherit rewindTheme's scaffoldBackgroundColor
      // (RewindTokens.dark.bg) so this stays in step with the shared palette.
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          children: [
            _Header(title: widget.title),
            Expanded(
              child: Center(child: Video(controller: _controller)),
            ),
            _Controls(
              playing: _playing,
              position: _position,
              duration: _duration,
              onTogglePlay: _togglePlay,
              onSeek: (d) => _player.seek(d),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;

  const _Header({required this.title});

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
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Play/pause, seek bar, and elapsed/total readout.
class _Controls extends StatelessWidget {
  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;

  const _Controls({
    required this.playing,
    required this.position,
    required this.duration,
    required this.onTogglePlay,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          Text(formatDuration(position), style: theme.textTheme.bodySmall),
          Expanded(
            child: Slider(
              value: positionMs.toDouble(),
              max: totalMs > 0 ? totalMs.toDouble() : 1.0,
              onChanged: totalMs > 0
                  ? (v) => onSeek(Duration(milliseconds: v.round()))
                  : null,
            ),
          ),
          Text(formatDuration(duration), style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
