import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  test('cover decode buckets follow physical size and bound image memory', () {
    expect(coverDecodeSize(128, 2), 256);
    expect(coverDecodeSize(129, 2), 512);
    expect(coverDecodeSize(240, 2), 512);
    expect(coverDecodeSize(240, 3), 1024);
    expect(coverDecodeSize(1800, 3), 1024);
  });

  testWidgets('100 lyric changes rebuild only the old and new rows', (
    tester,
  ) async {
    final active = ValueNotifier<int>(0);
    final builds = List<int>.filled(200, 0);
    final highlights = List<bool>.filled(200, false);
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var index = 0; index < builds.length; index++)
              LyricHighlightBuilder(
                activeIndex: active,
                index: index,
                builder: (_, highlighted) {
                  builds[index]++;
                  highlights[index] = highlighted;
                  return const SizedBox(height: 1);
                },
              ),
          ],
        ),
      ),
    );
    expect(builds.reduce((a, b) => a + b), 200);
    for (var index = 1; index <= 100; index++) {
      final before = builds.reduce((a, b) => a + b);
      active.value = index;
      await tester.pump();
      expect(builds.reduce((a, b) => a + b) - before, 2);
      expect(highlights.where((value) => value).length, 1);
      expect(highlights[index], isTrue);
    }
    active.value = -1; // A new song has not reached its first lyric yet.
    await tester.pump();
    expect(highlights.any((value) => value), isFalse);
    await tester.pumpWidget(const SizedBox());
    active.value = 0;
    await tester.pump();
    expect(tester.takeException(), isNull);
    active.dispose();
  });

  testWidgets('reused rows switch notifier and index without stale listeners', (
    tester,
  ) async {
    final oldActive = ValueNotifier<int>(1);
    final newActive = ValueNotifier<int>(2);
    var builds = 0;
    Widget row(ValueNotifier<int> active, int index) => MaterialApp(
      home: LyricHighlightBuilder(
        activeIndex: active,
        index: index,
        builder: (_, highlighted) {
          builds++;
          return Text(highlighted ? 'current' : 'other');
        },
      ),
    );
    await tester.pumpWidget(row(oldActive, 1));
    expect(find.text('current'), findsOneWidget);
    await tester.pumpWidget(row(newActive, 3));
    expect(find.text('other'), findsOneWidget);
    final before = builds;
    oldActive.value = 3;
    await tester.pump();
    expect(builds, before);
    newActive.value = 3;
    await tester.pump();
    expect(find.text('current'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    oldActive.dispose();
    newActive.dispose();
  });
}
