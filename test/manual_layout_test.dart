import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('旧版侧栏使用保存的手动倍率，小屏仍可打开缩放设置', (tester) async {
    SharedPreferences.setMockInitialValues({
      'isFirstLaunch': false,
      'uiScale': 0.8,
    });
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const appChannel = MethodChannel('com.nascarplayer/app_retain');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => '${Directory.systemTemp.path}/nas-empty-layout-fixture',
    );
    messenger.setMockMethodCallHandler(appChannel, (_) async => null);
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1280, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(appChannel, null);
    });
    audioHandler = CarAudioHandler();
    await tester.pumpWidget(const MaterialApp(home: MainHomeScreen()));
    await tester.pumpAndSettle();

    final dashboardTitle = find.text('我的资源');
    final adjustment = find.byTooltip('调整界面缩放');
    final originalFontSize = tester
        .widget<Text>(dashboardTitle)
        .style!
        .fontSize;
    expect(originalFontSize, closeTo(36 * 0.8, .001));
    expect(adjustment, findsNothing);
    expect(
      tester.getRect(find.text('NAS 乐库')).right,
      lessThan(tester.getRect(dashboardTitle).left),
    );

    tester.view.devicePixelRatio = 3;
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(dashboardTitle).style!.fontSize,
      originalFontSize,
    );
    expect(adjustment.hitTestable(), findsOneWidget);

    await tester.tap(adjustment);
    await tester.pumpAndSettle();
    final sliderFinder = find.byType(Slider).hitTestable();
    expect(sliderFinder, findsOneWidget);
    expect(find.text('保存缩放').hitTestable(), findsOneWidget);
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged!(slider.min);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存缩放'));
    await tester.pumpAndSettle();

    expect(prefs.getDouble('uiScale'), 0.4);
    expect(
      tester.widget<Text>(dashboardTitle).style!.fontSize,
      closeTo(36 * 0.4, .001),
    );
    expect(find.text('系统设置 ⚙️').hitTestable(), findsOneWidget);
    expect(adjustment, findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(audioHandler.player.dispose);
  });
}
