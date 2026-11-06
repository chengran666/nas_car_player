import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('窄屏、横屏和旋转时保留播放页与大屏歌词可用空间', (tester) async {
    SharedPreferences.setMockInitialValues({
      'isFirstLaunch': false,
      'uiScale': 2.5,
      'largeUiScale': 2.0,
    });
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final mock =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    mock.setMockMethodCallHandler(
      pathChannel,
      (_) async => '${Directory.systemTemp.path}/nas-empty-layout-fixture',
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      mock.setMockMethodCallHandler(pathChannel, null);
    });
    audioHandler = CarAudioHandler();
    await tester.pumpWidget(const MaterialApp(home: MainHomeScreen()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-playback-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-playback-sidebar')), findsNothing);
    await tester.tap(find.text('等待播放'));
    await tester.pumpAndSettle();
    final lyrics = find.byKey(const ValueKey('stage-lyrics-pane'));
    await tester.tap(find.byTooltip('大屏歌词'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示调整'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出大屏'), findsOneWidget);
    expect(find.byTooltip('收起显示调整'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('收起显示调整'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出大屏'));
    await tester.pumpAndSettle();
    for (final (pixels, density, wide) in const [
      (Size(320, 568), 1.0, false),
      (Size(568, 320), 1.0, false),
      (Size(800, 360), 1.0, true),
      (Size(1024, 600), 1.0, true),
      (Size(1280, 980), 1.0, true),
      (Size(1280, 980), 2.0, false),
      (Size(1920, 720), 1.0, true),
      (Size(2560, 720), 1.0, true),
      (Size(2560, 1440), 1.0, true),
      (Size(3840, 2160), 1.0, true),
      (Size(3840, 2160), 2.0, true),
      (Size(3840, 2160), 3.0, true),
      (Size(640, 240), 1.0, false),
      (Size(360, 800), 1.0, false),
    ]) {
      tester.view.physicalSize = pixels;
      tester.view.devicePixelRatio = density;
      final size = pixels / density;
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'ordinary player at $size',
      );
      final ordinary = tester.getRect(lyrics);
      expect(
        find.byKey(const ValueKey('wide-playback-sidebar')),
        wide ? findsOneWidget : findsNothing,
      );
      expect(ordinary.height, greaterThan(size.height * .30));
      expect(ordinary.right, lessThanOrEqualTo(size.width));
      expect(find.byTooltip('播放'), findsWidgets);
      await tester.tap(find.byTooltip('大屏歌词'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'large lyrics at $size');
      expect(find.byKey(const ValueKey('wide-playback-sidebar')), findsNothing);
      expect(tester.getSize(lyrics).height, greaterThan(ordinary.height));
      await tester.tap(find.byTooltip('退出大屏'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('返回歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统设置 ⚙️'));
    await tester.pumpAndSettle();
    for (final size in const [
      Size(320, 568),
      Size(640, 240),
      Size(1024, 600),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.text('系统设置'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'settings at $size');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(audioHandler.player.dispose);
  });

  testWidgets('长歌名歌单在窄屏和键盘弹出后仍可搜索', (tester) async {
    const account = {
      'url': 'https://layout-fixture.invalid/',
      'user': 'test',
      'pwd': '',
      'name': '一个有很长名字的车机音乐资源库',
    };
    const song = '歌手 - 这是一首名称非常长而且不会在一行放下的测试歌曲.mp3';
    final key = base64UrlEncode(
      utf8.encode('${account['url']}|${account['user']}'),
    ).replaceAll('=', '');
    final root = Directory.systemTemp.createTempSync('nas-adaptive-');
    SharedPreferences.setMockInitialValues({
      'isFirstLaunch': false,
      'scopedCacheV2': true,
      'uiScale': 2.5,
      'webdavAccounts': jsonEncode([
        account,
        for (var i = 2; i <= 4; i++)
          {
            ...account,
            'url': 'https://layout-fixture-$i.invalid/',
            'name': '资源库 $i',
          },
      ]),
      'lastAccount': jsonEncode(account),
      'lastFileName': song,
      'cachedSongList_$key': [song, '歌手 - 另一首歌.mp3'],
    });
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final mock =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    mock.setMockMethodCallHandler(pathChannel, (_) async => root.path);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      mock.setMockMethodCallHandler(pathChannel, null);
      final resolved = Directory(root.resolveSymbolicLinksSync());
      if (resolved.parent.path ==
              Directory.systemTemp.resolveSymbolicLinksSync() &&
          resolved.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last
              .startsWith('nas-adaptive-')) {
        resolved.deleteSync(recursive: true);
      }
    });
    audioHandler = CarAudioHandler();
    await tester.pumpWidget(const MaterialApp(home: MainHomeScreen()));
    for (var i = 0; i < 20 && find.text('等待播放').evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    for (final (size, density) in const [
      (Size(360, 320), 1.0),
      (Size(568, 320), 1.0),
      (Size(640, 240), 1.0),
      (Size(800, 180), 1.0),
      (Size(1280, 980), 1.0),
      (Size(1280, 980), 2.0),
      (Size(1280, 980), 3.0),
      (Size(1920, 720), 1.0),
      (Size(2560, 720), 1.0),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = density;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wide-playback-sidebar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('compact-playback-bar')), findsNothing);
      for (final label in [
        '${account['name']} ☁️',
        for (var i = 2; i <= 4; i++) '资源库 $i ☁️',
        '系统设置 ⚙️',
      ]) {
        expect(
          find.text(label).hitTestable(),
          findsOneWidget,
          reason: '$label at $size',
        );
      }
      final grid = tester.getRect(find.byType(GridView));
      final settings = tester.getRect(find.text('系统设置 ⚙️'));
      expect(settings.bottom, lessThanOrEqualTo(grid.bottom));
      for (final label in ['系统设置 ⚙️', '添加云盘与偏好设置']) {
        final richText = find.descendant(
          of: find.text(label),
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(richText);
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '$label at $size, DPR $density',
        );
      }
      for (final tooltip in ['播放模式', '上一首', '播放', '下一首']) {
        expect(
          find.byTooltip(tooltip).hitTestable(),
          findsOneWidget,
          reason: '$tooltip at $size',
        );
      }
      expect(tester.takeException(), isNull, reason: 'home at $size');
    }
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('compact-playback-bar'));
    await tester.tap(
      find.descendant(of: bar, matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回歌单'));
    await tester.pumpAndSettle();
    expect(find.text(song.replaceAll('.mp3', '')), findsOneWidget);
    final search = find.byType(TextFormField);
    await tester.enterText(search, '另一首');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('歌手 - 另一首歌'), findsOneWidget);
    tester.view.physicalSize = const Size(568, 320);
    tester.view.viewInsets = const FakeViewPadding(bottom: 150);
    await tester.pumpAndSettle();
    expect(find.text('另一首'), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-playback-bar')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the deferred NAS refresh after disposal; it is guarded by mounted.
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(audioHandler.player.dispose);
  });
}
