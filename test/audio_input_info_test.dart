import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/audio_input_info.dart';

void main() {
  test('parses the JSON array emitted by rewind_list_audio_inputs_json', () {
    const json = '[{"uid":"mic-1","name":"Built-in Microphone",'
        '"default":true}]';
    final inputs = AudioInputInfo.listFromJson(json);
    expect(inputs, hasLength(1));
    expect(inputs.single.uid, 'mic-1');
    expect(inputs.single.name, 'Built-in Microphone');
    expect(inputs.single.isDefault, isTrue);
  });

  test('parses multiple devices, preserving order', () {
    const json = '['
        '{"uid":"a","name":"Mic A","default":false},'
        '{"uid":"b","name":"Mic B","default":true}'
        ']';
    final inputs = AudioInputInfo.listFromJson(json);
    expect(inputs, hasLength(2));
    expect(inputs[0].uid, 'a');
    expect(inputs[0].isDefault, isFalse);
    expect(inputs[1].uid, 'b');
    expect(inputs[1].isDefault, isTrue);
  });

  test('empty array parses to an empty list', () {
    expect(AudioInputInfo.listFromJson('[]'), isEmpty);
  });

  test('"default" absent falls back to false', () {
    final input = AudioInputInfo.fromJson(const {'uid': 'x', 'name': 'Mic X'});
    expect(input.isDefault, isFalse);
  });

  test('single-object fromJson round-trips the expected fields', () {
    final input = AudioInputInfo.fromJson(const {
      'uid': 'x',
      'name': 'Mic X',
      'default': false,
    });
    expect(input.uid, 'x');
    expect(input.name, 'Mic X');
    expect(input.isDefault, isFalse);
  });
}
