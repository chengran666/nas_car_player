import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:nas_car_player/main.dart';
import 'cover_preview_test.dart' show PreviewAdapter, png;

ResponseBody jsonResponse(Map<String, dynamic> data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = {'title': 'Song', 'artist': 'Singer', 'duration': 200.0};
  const deviceA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const deviceB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  SongSelectionClient client(
    Dio dio, {
    Future<Directory> Function()? directory,
    String deviceId = deviceA,
  }) => SongSelectionClient(
    dio,
    prefs,
    Uri.parse('https://example.test/'),
    {'Authorization': 'Bearer test-token'},
    (_) {},
    outboxDirectory: directory,
    deviceId: deviceId,
  );

  test('系统标识生成稳定设备码，缺失或异常标识不会误用公共偏好', () async {
    const channel = MethodChannel('com.nascarplayer/app_retain');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getAndroidId');
          return '0123456789abcdef';
        });
    try {
      final first = await readSongSelectionDeviceId();
      expect(first, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await readSongSelectionDeviceId(), first);
      expect(songSelectionDeviceId('0123456789ABCDEF'), first);
      expect(songSelectionDeviceId('1123456789abcdef'), isNot(first));
      for (final invalid in [
        null,
        '',
        '0000000000000000',
        '9774d56d682e549c',
        'bad-id',
      ]) {
        expect(songSelectionDeviceId(invalid), isNull);
      }
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('按元数据读取最新选择并携带令牌，旧查询结果不拦截下一次读取', () async {
    var text = '[00:01]Chosen';
    final adapter = PreviewAdapter(
      (_) async => jsonResponse({
        'success': true,
        'selection': {
          'lyrics': {'text': text},
        },
      }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final service = client(dio);
    expect((await service.lookup(song))!['lyrics']['text'], '[00:01]Chosen');
    text = '[00:01]New choice from another client';
    expect((await service.lookup({...song}))!['lyrics']['text'], text);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.uri.queryParameters['duration'], '200.0');
    expect(adapter.requests.first.uri.queryParameters['device_id'], deviceA);
    expect(
      adapter.requests.first.headers['Authorization'],
      'Bearer test-token',
    );
    final image = service.imageUri(song, 'revision');
    expect(image.queryParameters['action'], 'image');
    expect(image.queryParameters['revision'], 'revision');
    expect(image.queryParameters['device_id'], deviceA);
    dio.close();
  });

  test('断网保存完整歌词、重启后重试成功才清理待同步记录', () async {
    final offline = Dio()
      ..httpClientAdapter = PreviewAdapter(
        (_) async => jsonResponse({'success': false}, status: 503),
      );
    final first = client(offline);
    await first.enqueue(song, 'lyrics', {'text': '[00:01]Chosen'});
    await first.flush();
    expect(first.hasPending(song, 'lyrics'), isTrue);
    expect(prefs.getString('songSelectionOutboxV1'), contains('[00:01]Chosen'));
    final adapter = PreviewAdapter(
      (_) async => jsonResponse({'success': true}),
    );
    final online = Dio()..httpClientAdapter = adapter;
    final restarted = client(online);
    await restarted.flush();
    expect(restarted.hasPending(song, 'lyrics'), isFalse);
    expect(adapter.requests.single.data['choice']['text'], '[00:01]Chosen');
    expect(adapter.requests.single.data['device_id'], deviceA);
    expect(prefs.getString('songSelectionOutboxV1'), '{}');
    offline.close();
    online.close();
  });

  test('复制应用数据到另一设备不会上传原设备待提交的选择', () async {
    final offline = Dio()
      ..httpClientAdapter = PreviewAdapter(
        (_) async => jsonResponse({'success': false}, status: 503),
      );
    final first = client(offline);
    await first.enqueue(song, 'lyrics', {'text': 'Device A choice'});
    await first.flush();
    final adapter = PreviewAdapter(
      (_) async => jsonResponse({'success': true}),
    );
    final online = Dio()..httpClientAdapter = adapter;
    final otherDevice = client(online, deviceId: deviceB);
    await otherDevice.flush();
    expect(otherDevice.hasPending(song, 'lyrics'), isFalse);
    expect(adapter.requests, isEmpty);
    offline.close();
    online.close();
  });

  test('升级前未带设备码的手选待提交记录归属当前设备', () async {
    await prefs.setString(
      'songSelectionOutboxV1',
      jsonEncode({
        'legacy-key': {
          ...song,
          'kind': 'lyrics',
          'choice': {'text': 'Pending before upgrade'},
        },
      }),
    );
    final adapter = PreviewAdapter(
      (_) async => jsonResponse({'success': true}),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    await client(dio).flush();
    expect(adapter.requests.single.data['device_id'], deviceA);
    expect(
      adapter.requests.single.data['choice']['text'],
      'Pending before upgrade',
    );
    dio.close();
  });

  test('旧保存请求结束后不会删除快速切换的新歌词选择', () async {
    final gate = Completer<ResponseBody>();
    final adapter = PreviewAdapter(
      (options) => options.data['choice']['text'] == 'Old'
          ? gate.future
          : Future.value(jsonResponse({'success': true})),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final service = client(dio);
    await service.enqueue(song, 'lyrics', {'text': 'Old'});
    await adapter.waitForRequests(1);
    await service.enqueue(song, 'lyrics', {'text': 'New'});
    gate.complete(jsonResponse({'success': true}));
    await service.flush();
    expect(adapter.requests.map((r) => r.data['choice']['text']), [
      'Old',
      'New',
    ]);
    expect(service.hasPending(song, 'lyrics'), isFalse);
    dio.close();
  });

  test('封面待同步使用独立副本，清缓存不会丢失或上传后来的图片', () async {
    final root = await Directory.systemTemp.createTemp('nas-selection-test-');
    final file = File('${root.path}/cover.png');
    await file.writeAsBytes(png);
    final offline = Dio()
      ..httpClientAdapter = PreviewAdapter(
        (_) async => jsonResponse({'success': false}, status: 503),
      );
    final first = client(offline, directory: () async => root);
    await first.enqueue(song, 'cover', {
      'id': 'chosen',
      'image_path': file.path,
    });
    await first.flush();
    await file.delete();
    final adapter = PreviewAdapter(
      (_) async => jsonResponse({'success': true}),
    );
    final online = Dio()..httpClientAdapter = adapter;
    await client(online, directory: () async => root).flush();
    expect(
      base64Decode(adapter.requests.single.data['choice']['image_base64']),
      png,
    );
    expect(
      adapter.requests.single.data['choice'].containsKey('image_path'),
      isFalse,
    );
    expect(
      await Directory('${root.path}/song_selection_outbox').list().toList(),
      isEmpty,
    );
    offline.close();
    online.close();
    await root.delete(recursive: true);
  });

  test('之前未命中，提交成功后的下一次读取可恢复', () async {
    var hasSelection = false;
    final adapter = PreviewAdapter((options) async {
      if (options.method == 'POST') hasSelection = true;
      return jsonResponse({
        'success': true,
        'selection': hasSelection
            ? {
                'lyrics': {'text': 'Chosen'},
              }
            : null,
      });
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final service = client(dio);
    expect(await service.lookup(song), isNull);
    await service.enqueue(song, 'lyrics', {'text': 'Chosen'});
    await service.flush();
    expect((await service.lookup(song))!['lyrics']['text'], 'Chosen');
    expect(adapter.requests, hasLength(3));
    dio.close();
  });

  test('重装后的空客户端恢复最后提交的歌词和封面，读取不会反向提交', () async {
    final saved = <String, Map<String, dynamic>>{};
    final adapter = PreviewAdapter((options) async {
      final deviceId = options.method == 'POST'
          ? options.data['device_id'] as String
          : options.uri.queryParameters['device_id']!;
      if (options.method == 'POST') {
        final data = options.data as Map;
        (saved[deviceId] ??= {})[data['kind']] = Map<String, dynamic>.from(
          data['choice'],
        );
      }
      return jsonResponse({
        'success': true,
        'selection': {...?saved[deviceId]},
      });
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final first = client(dio);
    await first.enqueue(song, 'lyrics', {
      'text': '[00:01]Old',
      'candidate_id': 1,
    });
    await first.flush();
    await first.enqueue(song, 'cover', {'id': 'old-cover', 'revision': 'old'});
    await first.flush();
    await first.enqueue(song, 'lyrics', {
      'text': '[00:02]Latest',
      'candidate_id': 2,
    });
    await first.flush();
    await first.enqueue(song, 'cover', {
      'id': 'latest-cover',
      'revision': 'latest',
    });
    await first.flush();

    final secondDevice = client(dio, deviceId: deviceB);
    await secondDevice.enqueue(song, 'lyrics', {'text': 'Device B lyrics'});
    await secondDevice.flush();
    await secondDevice.enqueue(song, 'cover', {'id': 'device-b-cover'});
    await secondDevice.flush();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final postsBeforeRestore = adapter.requests
        .where((r) => r.method == 'POST')
        .length;
    final restored = await client(dio).lookup(song);
    expect(restored!['lyrics']['text'], '[00:02]Latest');
    expect(restored['cover']['id'], 'latest-cover');
    final restoredB = await client(dio, deviceId: deviceB).lookup(song);
    expect(restoredB!['lyrics']['text'], 'Device B lyrics');
    expect(restoredB['cover']['id'], 'device-b-cover');
    expect(prefs.getKeys(), isEmpty);
    expect(
      adapter.requests.where((r) => r.method == 'POST').length,
      postsBeforeRestore,
    );
    dio.close();
  });

  test('读取失败不缓存，下次联网可以恢复', () async {
    var count = 0;
    final adapter = PreviewAdapter(
      (_) async => ++count == 1
          ? jsonResponse({'success': false}, status: 503)
          : jsonResponse({
              'success': true,
              'selection': {
                'lyrics': {'text': 'Chosen'},
              },
            }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final service = client(dio);
    expect(await service.lookup(song), isNull);
    expect((await service.lookup(song))!['lyrics']['text'], 'Chosen');
    expect(adapter.requests, hasLength(2));
    dio.close();
  });

  test('保存期间返回的旧读取结果不会覆盖最新选择或留下旧缓存', () async {
    final gate = Completer<ResponseBody>();
    var gets = 0;
    final adapter = PreviewAdapter((options) {
      if (options.method == 'GET' && ++gets == 1) return gate.future;
      return Future.value(
        jsonResponse({
          'success': true,
          'selection': {
            'lyrics': {'text': 'New'},
          },
        }),
      );
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final service = client(dio);
    final stale = service.lookup(song);
    await adapter.waitForRequests(1);
    await service.enqueue(song, 'lyrics', {'text': 'New'});
    await service.flush();
    gate.complete(
      jsonResponse({
        'success': true,
        'selection': {
          'lyrics': {'text': 'Old'},
        },
      }),
    );
    expect(await stale, isNull);
    expect((await service.lookup(song))!['lyrics']['text'], 'New');
    dio.close();
  });
}
