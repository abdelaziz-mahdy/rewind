import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/app_info.dart';

void main() {
  test('parses the JSON array emitted by rewind_list_capturable_apps', () {
    const json = '[{"bundle_id":"com.rewind.stub.one","name":"Stub App One",'
        '"pid":1001}]';
    final apps = AppInfo.listFromJson(json);
    expect(apps, hasLength(1));
    expect(apps.single.bundleId, 'com.rewind.stub.one');
    expect(apps.single.name, 'Stub App One');
    expect(apps.single.pid, 1001);
  });

  test('parses multiple apps, preserving order', () {
    const json = '['
        '{"bundle_id":"com.apple.Safari","name":"Safari","pid":100},'
        '{"bundle_id":"com.apple.Terminal","name":"Terminal","pid":200}'
        ']';
    final apps = AppInfo.listFromJson(json);
    expect(apps, hasLength(2));
    expect(apps[0].bundleId, 'com.apple.Safari');
    expect(apps[0].pid, 100);
    expect(apps[1].bundleId, 'com.apple.Terminal');
    expect(apps[1].pid, 200);
  });

  test('empty array parses to an empty list', () {
    expect(AppInfo.listFromJson('[]'), isEmpty);
  });

  test('single-object fromJson round-trips the expected fields', () {
    final a = AppInfo.fromJson(const {
      'bundle_id': 'com.example.app',
      'name': 'Example',
      'pid': 42,
    });
    expect(a.bundleId, 'com.example.app');
    expect(a.name, 'Example');
    expect(a.pid, 42);
  });

  test('parses a name containing escaped quotes/backslashes', () {
    const json = r'[{"bundle_id":"com.example.app",'
        r'"name":"Weird \"Name\" \\ App","pid":7}]';
    final apps = AppInfo.listFromJson(json);
    expect(apps.single.name, r'Weird "Name" \ App');
  });
}
