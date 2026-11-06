import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  test('custom opaque colors survive settings validation including black', () {
    expect(isDesktopLyricColor(0), isTrue);
    expect(isDesktopLyricColor(0xFF1768AB), isTrue);
    expect(isDesktopLyricColor(0xFF000000), isTrue);
    expect(isDesktopLyricColor(0xFFFFFFFF), isTrue);
    expect(isDesktopLyricColor(null), isFalse);
    expect(isDesktopLyricColor(-1), isFalse);
    expect(isDesktopLyricColor(0x7F1768AB), isFalse);
    expect(isDesktopLyricColor(0x1FFFFFFFF), isFalse);
  });
  test('lyrics carry the sampled current playback clock unchanged', () {
    final clock = {
      'positionMs': 6500,
      'sampledAtMs': 12000,
      'speed': 1.0,
      'advancing': true,
    };
    final payload = desktopLyricsPayload(
      title: 'new',
      artist: 'artist',
      lyrics: [],
      ready: true,
      clock: clock,
    );
    expect(payload['clock'], clock);
  });
  Future<void> openPicker(
    WidgetTester tester,
    void Function(int?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onResult(
                await showDialog<int>(
                  context: context,
                  builder: (_) => const DesktopLyricColorPicker(
                    initialColor: 0xFFFFFFFF,
                    followColor: Colors.green,
                    presets: {0: '跟随大屏', 0xFFFFFFFF: '白色'},
                    scale: 1,
                  ),
                ),
              ),
              child: const Text('选择'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
  }

  testWidgets('color wheel and brightness save a custom opaque color', (
    tester,
  ) async {
    int? result;
    await openPicker(tester, (value) => result = value);
    final wheel = find.byKey(const ValueKey('desktop-color-wheel'));
    final bounds = tester.getRect(wheel);
    await tester.tapAt(Offset(bounds.right - 8, bounds.center.dy));
    await tester.pump();
    final brightness = find.byKey(const ValueKey('desktop-color-brightness'));
    await tester.tapAt(tester.getRect(brightness).center);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(isDesktopLyricColor(result), isTrue);
    expect(Color(result!).r, greaterThan(Color(result!).g));
    expect(Color(result!).r, lessThan(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('follow-color selection and cancel remain distinct', (
    tester,
  ) async {
    int? result = -1;
    await openPicker(tester, (value) => result = value);
    await tester.tap(find.text('跟随大屏'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, 0);
    await openPicker(tester, (value) => result = value);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
  final lyrics = <Map<String, dynamic>>[
    {'time': const Duration(milliseconds: 100), 'text': 'First\n第一句'},
    {'time': const Duration(seconds: 3), 'text': 'Second\n第二句'},
  ];
  test(
    'desktop lyrics preserve original/translation and advance both by offset',
    () {
      final payload = desktopLyricsPayload(
        title: 'Song',
        artist: 'Singer',
        lyrics: lyrics,
        ready: true,
        offsetSeconds: .5,
      );
      expect(payload['title'], 'Song');
      expect(payload['artist'], 'Singer');
      expect(payload['lines'], [
        {'timeMs': -400, 'text': 'First\n第一句'},
        {'timeMs': 2500, 'text': 'Second\n第二句'},
      ]);
      expect(lyrics.first['time'], const Duration(milliseconds: 100));
    },
  );
  test(
    'source transition clears old lyrics even if playback is still playing',
    () {
      final payload = desktopLyricsPayload(
        title: 'Next',
        artist: 'Singer',
        lyrics: lyrics,
        ready: false,
      );
      expect(payload['ready'], false);
      expect(payload['lines'], isEmpty);
    },
  );
  test('negative offset delays all lines and empty lyrics remain empty', () {
    final payload = desktopLyricsPayload(
      title: 'Song',
      artist: 'Singer',
      lyrics: lyrics,
      ready: true,
      offsetSeconds: -.75,
    );
    expect((payload['lines'] as List).first['timeMs'], 850);
    expect(
      desktopLyricsPayload(
        title: '',
        artist: '',
        lyrics: [],
        ready: true,
      )['lines'],
      isEmpty,
    );
  });
}
