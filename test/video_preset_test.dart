import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/video_preset.dart';

void main() {
  group('VideoPreset.of', () {
    test('recognises the three named tiers from fps + maxHeight', () {
      expect(VideoPreset.of(30, 1080), VideoPreset.performance);
      expect(VideoPreset.of(60, 1080), VideoPreset.balanced);
      expect(VideoPreset.of(60, 1440), VideoPreset.high);
    });

    test('anything else is custom — including native res and 720p', () {
      expect(VideoPreset.of(60, null), VideoPreset.custom);
      expect(VideoPreset.of(30, null), VideoPreset.custom);
      expect(VideoPreset.of(30, 720), VideoPreset.custom);
      expect(VideoPreset.of(30, 1440), VideoPreset.custom);
    });
  });

  group('applyTo', () {
    test('writes the tier values onto settings', () {
      final s = AppSettings(captureFps: 30, captureMaxHeight: null);
      VideoPreset.high.applyTo(s);
      expect(s.captureFps, 60);
      expect(s.captureMaxHeight, 1440);
    });

    test('custom leaves settings untouched (its values come from the '
        'Resolution/Framerate rows, not the card)', () {
      final s = AppSettings(captureFps: 30, captureMaxHeight: 720);
      VideoPreset.custom.applyTo(s);
      expect(s.captureFps, 30);
      expect(s.captureMaxHeight, 720);
    });
  });

  group('disk-cost estimate', () {
    test('matches the researched tier costs for a 30 s buffer', () {
      // Balanced ≈ 20 Mbps → 20 * 30 / 8 = 75 MB, the number printed on the
      // preset card; Performance ≈ 30 MB; High ≈ 131 MB.
      expect(estimatedBufferMegabytes(30, fps: 60, maxHeight: 1080), 75);
      expect(estimatedBufferMegabytes(30, fps: 30, maxHeight: 1080), 30);
      expect(estimatedBufferMegabytes(30, fps: 60, maxHeight: 1440), 131);
    });

    test('scales with buffer length', () {
      expect(estimatedBufferMegabytes(60, fps: 60, maxHeight: 1080), 150);
      expect(estimatedBufferMegabytes(15, fps: 60, maxHeight: 1080), 38);
    });

    test('native/Source estimates high (worst-case 4K-class), never zero', () {
      final native60 = estimatedBufferMegabytes(30, fps: 60, maxHeight: null);
      final high60 = estimatedBufferMegabytes(30, fps: 60, maxHeight: 1440);
      expect(native60, greaterThan(high60));
      expect(estimatedBufferMegabytes(30, fps: 30, maxHeight: 720),
          greaterThan(0));
    });
  });

  test('fresh settings default to the Balanced tier (research: the default '
      'must be universally safe, not native res)', () {
    final s = AppSettings();
    expect(VideoPreset.of(s.captureFps, s.captureMaxHeight),
        VideoPreset.balanced);
  });
}
