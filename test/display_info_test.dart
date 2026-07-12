import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/display_info.dart';

void main() {
  test('parses the JSON array emitted by rewind_list_displays', () {
    const json = '[{"uuid":"stub-display","width":1920,"height":1080,'
        '"main":true}]';
    final displays = DisplayInfo.listFromJson(json);
    expect(displays, hasLength(1));
    expect(displays.single.uuid, 'stub-display');
    expect(displays.single.width, 1920);
    expect(displays.single.height, 1080);
    expect(displays.single.isMain, isTrue);
  });

  test('parses multiple displays, preserving order', () {
    const json = '['
        '{"uuid":"a","width":2560,"height":1440,"main":false},'
        '{"uuid":"b","width":3840,"height":2160,"main":true}'
        ']';
    final displays = DisplayInfo.listFromJson(json);
    expect(displays, hasLength(2));
    expect(displays[0].uuid, 'a');
    expect(displays[0].isMain, isFalse);
    expect(displays[1].uuid, 'b');
    expect(displays[1].isMain, isTrue);
  });

  test('empty array parses to an empty list', () {
    expect(DisplayInfo.listFromJson('[]'), isEmpty);
  });

  test('single-object fromJson round-trips the expected fields', () {
    final d = DisplayInfo.fromJson(const {
      'uuid': 'x',
      'width': 1024,
      'height': 768,
      'main': false,
    });
    expect(d.uuid, 'x');
    expect(d.width, 1024);
    expect(d.height, 768);
    expect(d.isMain, isFalse);
  });
}
