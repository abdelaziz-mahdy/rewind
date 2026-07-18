import 'dart:convert';

/// An audio INPUT device (microphone), as reported by
/// `rewind_list_audio_inputs_json`.
class AudioInputInfo {
  /// Stable per-device identifier (a CoreAudio device UID on macOS); pass
  /// this back to [CaptureEngine.setMicDevice].
  final String uid;

  /// Human-readable display name, for UI presentation.
  final String name;

  /// Whether this is the OS's current default input device.
  final bool isDefault;

  const AudioInputInfo({
    required this.uid,
    required this.name,
    this.isDefault = false,
  });

  factory AudioInputInfo.fromJson(Map<String, dynamic> j) => AudioInputInfo(
        uid: j['uid'] as String,
        name: j['name'] as String,
        isDefault: j['default'] as bool? ?? false,
      );

  /// Parses the compact JSON array emitted by
  /// `rewind_list_audio_inputs_json`.
  static List<AudioInputInfo> listFromJson(String json) => (jsonDecode(json)
          as List)
      .map((e) => AudioInputInfo.fromJson((e as Map).cast<String, dynamic>()))
      .toList();

  @override
  String toString() =>
      'AudioInputInfo($uid, $name${isDefault ? ', default' : ''})';
}
