import 'app_settings.dart';

/// The named video-quality tiers (plus the Custom escape hatch) that replace
/// the raw framerate/resolution knobs as Settings' primary quality choice.
///
/// Design provenance (2026-07-18 research pass, see the settings-variants
/// artifact's Research tab): three outcome-worded tiers + Custom keeps the
/// choice inside the Hick's-law band and matches the field (Medal/Steam/Xbox
/// name tiers; OBS/Outplayed hide knobs behind Simple/Custom). The default is
/// [balanced] — NOT native res — because <5% of users ever change a default,
/// and native-by-default silently blows up disk on Retina/1440p rigs (this
/// repo's own past failure mode). Native/4K deliberately lives INSIDE Custom.
enum VideoPreset {
  performance(fps: 30, maxHeight: 1080),
  balanced(fps: 60, maxHeight: 1080),
  high(fps: 60, maxHeight: 1440),
  custom(fps: null, maxHeight: null);

  /// The tier's bundled values; null on [custom], whose values come from the
  /// Resolution/Framerate rows it reveals instead.
  final int? fps;
  final int? maxHeight;

  const VideoPreset({required this.fps, required this.maxHeight});

  /// The tier the given raw settings correspond to, or [custom] for any
  /// combination that isn't exactly a named tier (720p, native res, 1440p30…).
  /// Deriving — rather than persisting a preset name — keeps the raw settings
  /// the single source of truth the capture engine already reads.
  static VideoPreset of(int fps, int? maxHeight) {
    for (final p in const [performance, balanced, high]) {
      if (p.fps == fps && p.maxHeight == maxHeight) return p;
    }
    return custom;
  }

  /// Writes this tier's values onto [settings]. No-op for [custom]: picking
  /// the Custom card only reveals the per-axis rows, it must not clobber the
  /// values the user last set there.
  void applyTo(AppSettings settings) {
    if (this == custom) return;
    settings.captureFps = fps!;
    settings.captureMaxHeight = maxHeight;
  }
}

/// Rough hardware-encoder bitrate for a given quality, in Mbps — the basis of
/// the honest disk-cost line each preset card prints ("30 s buffer ≈ 75 MB"),
/// which no comparable app ships. Estimates, deliberately conservative:
/// 30 fps bases of 4/8/14/20 Mbps for 720p/1080p/1440p/native(4K-class),
/// ×2.5 at 60 fps (matches the researched tier costs: Balanced 20 Mbps,
/// High 35 Mbps, native60 ≈ 50 Mbps).
double _estimatedMbps({required int fps, required int? maxHeight}) {
  final h = maxHeight ?? 2160;
  final base = h <= 720
      ? 4.0
      : h <= 1080
          ? 8.0
          : h <= 1440
              ? 14.0
              : 20.0;
  return fps >= 60 ? base * 2.5 : base;
}

/// Approximate size in whole megabytes of a [seconds]-long replay buffer at
/// the given quality — `Mbps × seconds ÷ 8`.
int estimatedBufferMegabytes(int seconds, {required int fps, int? maxHeight}) {
  return (_estimatedMbps(fps: fps, maxHeight: maxHeight) * seconds / 8)
      .round();
}
