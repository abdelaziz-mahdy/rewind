import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// One reading of the live audio levels, parsed from the shim's
/// `rewind_audio_levels_json` (see `CaptureEngine.audioLevelsJson`). All
/// values are dBFS; -120.0 is the shim's silence floor.
class AudioLevels {
  final double micPeakDb;
  final double micMagDb;
  final double gamePeakDb;
  final double gameMagDb;

  const AudioLevels({
    required this.micPeakDb,
    required this.micMagDb,
    required this.gamePeakDb,
    required this.gameMagDb,
  });

  /// Parses the shim's JSON, or returns null on any malformed/missing input
  /// (engine not running, stub mode, truncated buffer) — the meter shows
  /// its idle state rather than crashing on a bad poll.
  static AudioLevels? parse(String? json) {
    if (json == null) return null;
    try {
      final m = jsonDecode(json);
      if (m is! Map<String, dynamic>) return null;
      double? d(String key) => (m[key] as num?)?.toDouble();
      final micPeak = d('mic_peak_db');
      final micMag = d('mic_mag_db');
      final gamePeak = d('game_peak_db');
      final gameMag = d('game_mag_db');
      if (micPeak == null ||
          micMag == null ||
          gamePeak == null ||
          gameMag == null) {
        return null;
      }
      return AudioLevels(
        micPeakDb: micPeak,
        micMagDb: micMag,
        gamePeakDb: gamePeak,
        gameMagDb: gameMag,
      );
    } on FormatException {
      return null;
    }
  }

  /// Whether meaningful game/desktop audio is currently flowing — gates the
  /// second meter bar and the voice-vs-game comparison hint. -50 dB rather
  /// than the -120 floor: a "silent" desktop still ticks over with faint UI
  /// sounds that shouldn't count as "the game is playing".
  bool get gameActive => gamePeakDb > -50;
}

/// What the mic test concludes about the current (peak-held) mic level.
enum MicTestVerdict { waiting, tooQuiet, good, tooLoud, clipping }

/// Classifies a peak-held mic level (dBFS) for the test hints.
///
/// The target window (-22..-5 dB) is where speech peaks land when the mic
/// slider is set so voice sits clearly over a typical game mix without
/// hitting the converter ceiling. With auto-leveling on, the limiter caps
/// peaks at -6 dB at a 100% slider, so `good` is exactly where a sane
/// configuration settles; `tooLoud`/`clipping` are only reachable by
/// pushing the slider past 100% or turning leveling off — both worth
/// warning about.
MicTestVerdict micTestVerdict(double peakHoldDb) {
  if (peakHoldDb <= -55) return MicTestVerdict.waiting;
  if (peakHoldDb >= -2) return MicTestVerdict.clipping;
  if (peakHoldDb > -5) return MicTestVerdict.tooLoud;
  if (peakHoldDb < -22) return MicTestVerdict.tooQuiet;
  return MicTestVerdict.good;
}

/// The user-facing hint for a verdict (plus an optional voice-vs-game
/// comparison when game audio is flowing). Pure so tests cover the exact
/// strings without pumping the widget.
String micTestHint(MicTestVerdict verdict, {double? voiceOverGameDb}) {
  final base = switch (verdict) {
    MicTestVerdict.waiting => 'Speak normally for a few seconds…',
    MicTestVerdict.tooQuiet =>
      'Too quiet — raise Mic volume, or move the mic closer.',
    MicTestVerdict.good => 'Level looks good.',
    MicTestVerdict.tooLoud => 'A little hot — lower Mic volume slightly.',
    MicTestVerdict.clipping =>
      'Clipping — lower Mic volume before your voice distorts.',
  };
  if (verdict == MicTestVerdict.waiting || voiceOverGameDb == null) {
    return base;
  }
  final delta = voiceOverGameDb.round();
  if (delta < 3) {
    return '$base Voice is buried under the game — raise Mic volume or '
        'lower Game audio.';
  }
  return '$base Voice sits ${delta}dB above the game.';
}

/// Live mic-test meter for the Settings audio section: polls the engine's
/// audio levels while open, shows a mic bar (plus a game bar when game
/// audio is flowing), and tells the user in words whether their mic slider
/// is right — instead of making them record a clip and guess.
///
/// Polls [pollLevels] every 100 ms only while testing (opened via its
/// button); fully idle otherwise. Peak-hold over the last 1.5 s keeps the
/// verdict stable between syllables.
class MicTestMeter extends StatefulWidget {
  /// Returns the shim's current levels JSON (see
  /// `CaptureEngine.audioLevelsJson`), or null when unavailable. Optional
  /// so existing callers/tests that don't wire it still render the button
  /// (which then reports levels as unavailable).
  final String? Function()? pollLevels;

  const MicTestMeter({this.pollLevels, super.key});

  @override
  State<MicTestMeter> createState() => _MicTestMeterState();
}

class _MicTestMeterState extends State<MicTestMeter> {
  Timer? _poll;
  AudioLevels? _levels;

  /// Recent mic peaks with their arrival times, for the 1.5 s peak hold.
  final List<(DateTime, double)> _recentMicPeaks = [];
  final List<(DateTime, double)> _recentGamePeaks = [];

  bool get _testing => _poll != null;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _toggleTesting() {
    if (_testing) {
      _poll?.cancel();
      setState(() {
        _poll = null;
        _levels = null;
        _recentMicPeaks.clear();
        _recentGamePeaks.clear();
      });
      return;
    }
    setState(() {
      _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    });
    _tick();
  }

  void _tick() {
    final levels = AudioLevels.parse(widget.pollLevels?.call());
    if (!mounted) return;
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(milliseconds: 1500));
    _recentMicPeaks.removeWhere((e) => e.$1.isBefore(cutoff));
    _recentGamePeaks.removeWhere((e) => e.$1.isBefore(cutoff));
    if (levels != null) {
      _recentMicPeaks.add((now, levels.micPeakDb));
      _recentGamePeaks.add((now, levels.gamePeakDb));
    }
    setState(() => _levels = levels);
  }

  double get _micPeakHold => _recentMicPeaks.isEmpty
      ? -120.0
      : _recentMicPeaks.map((e) => e.$2).reduce(math.max);

  double get _gamePeakHold => _recentGamePeaks.isEmpty
      ? -120.0
      : _recentGamePeaks.map((e) => e.$2).reduce(math.max);

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('micTestButton'),
              onPressed: _toggleTesting,
              icon: Icon(_testing ? Icons.stop : Icons.graphic_eq, size: 18),
              label: Text(_testing ? 'Stop test' : 'Test my mic'),
            ),
          ],
        ),
        if (_testing) ...[
          const SizedBox(height: 12),
          if (_levels == null)
            Text(
              'Levels unavailable — is capture running?',
              style: textTheme.bodyMuted,
            )
          else ...[
            _LevelBar(
              label: 'Voice',
              db: _levels!.micPeakDb,
              holdDb: _micPeakHold,
              // The good-verdict window (see micTestVerdict) drawn ON the
              // bar: without it "Too quiet" beside a half-full bar reads
              // as a contradiction — dB is not linear loudness, so the
              // target zone must be visible, not implied.
              targetMinDb: -22,
              targetMaxDb: -5,
              color: switch (micTestVerdict(_micPeakHold)) {
                MicTestVerdict.clipping => tokens.rec,
                MicTestVerdict.tooLoud || MicTestVerdict.tooQuiet =>
                  tokens.warn,
                _ => tokens.accent,
              },
            ),
            if (_levels!.gameActive) ...[
              const SizedBox(height: 8),
              _LevelBar(
                label: 'Game',
                db: _levels!.gamePeakDb,
                holdDb: _gamePeakHold,
                color: tokens.textMuted,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              key: const ValueKey('micTestHint'),
              micTestHint(
                micTestVerdict(_micPeakHold),
                voiceOverGameDb: _levels!.gameActive
                    ? _micPeakHold - _gamePeakHold
                    : null,
              ),
              style: textTheme.bodyMuted.copyWith(
                color: switch (micTestVerdict(_micPeakHold)) {
                  MicTestVerdict.good => tokens.accent,
                  MicTestVerdict.clipping => tokens.rec,
                  MicTestVerdict.waiting => tokens.textMuted,
                  _ => tokens.warn,
                },
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// One horizontal level bar: a hairline track with a colored fill mapping
/// -60..0 dBFS to 0..100% width, plus a thin peak-hold tick and (when
/// [targetMinDb]/[targetMaxDb] are set) a visible target zone the user is
/// asked to land the bar inside.
class _LevelBar extends StatelessWidget {
  final String label;
  final double db;
  final double holdDb;
  final Color color;
  final double? targetMinDb;
  final double? targetMaxDb;

  const _LevelBar({
    required this.label,
    required this.db,
    required this.holdDb,
    required this.color,
    this.targetMinDb,
    this.targetMaxDb,
  });

  static double _fraction(double db) => ((db + 60) / 60).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: Theme.of(context).textTheme.bodyMuted),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return SizedBox(
                height: 10,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: tokens.surfaceRaised,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: tokens.hairline),
                      ),
                    ),
                    if (targetMinDb != null && targetMaxDb != null)
                      Positioned(
                        left: w * _fraction(targetMinDb!),
                        width: w * (_fraction(targetMaxDb!) -
                            _fraction(targetMinDb!)),
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.accent.withValues(alpha: 0.18),
                            border: Border.symmetric(
                              vertical: BorderSide(
                                  color:
                                      tokens.accent.withValues(alpha: 0.5)),
                            ),
                          ),
                        ),
                      ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: w * _fraction(db),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Positioned(
                      left: (w * _fraction(holdDb) - 1).clamp(0.0, w - 2),
                      top: 0,
                      bottom: 0,
                      child: Container(width: 2, color: tokens.text),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
