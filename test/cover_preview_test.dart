import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGNg2JLyH4xhDABF9AhdNoOp9gAAAABJRU5ErkJggg==',
);
final previewUri = Uri.parse(
  'https://cover_api.whzxc.com/covers.php?source=itunes&action=image&preview=1&id=test',
);

class PreviewAdapter implements HttpClientAdapter {
  PreviewAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final List<RequestOptions> requests = [];
  final List<(int, Completer<void>)> waiting = [];

  Future<void> waitForRequests(int count) {
    if (requests.length >= count) return Future.value();
    final gate = Completer<void>();
    waiting.add((count, gate));
    return gate.future.timeout(const Duration(seconds: 5));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    for (final wait in waiting.toList()) {
      if (requests.length >= wait.$1) {
        wait.$2.complete();
        waiting.remove(wait);
      }
    }
    return Future.any([
      respond(options),
      if (cancelFuture != null)
        cancelFuture.then(
          (_) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          ),
        ),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody imageResponse() => ResponseBody.fromBytes(
  png,
  200,
  headers: {
    Headers.contentTypeHeader: ['image/png'],
  },
);

void main() {
  test('关联封面的预览使用原歌曲信息，匹配说明可显示，旧接口可兼容', () {
    final rows = CoverCandidate.parse({
      'candidates': [
        {
          'id': 'd' * 64,
          'source': 'community',
          'lookup_title': 'Summer Nigh',
          'lookup_artist': '',
          'lookup_duration': 201,
          'match_label': '歌词精确匹配 · 歌曲信息有差异',
        },
        {'id': 'e' * 64, 'source': 'community'},
      ],
    });
    expect(rows.first.imageTitle('Summer Night'), 'Summer Nigh');
    expect(rows.first.imageArtist('Singer'), '');
    expect(rows.first.imageDuration(200), 201);
    expect(rows.first.matchLabel, '歌词精确匹配 · 歌曲信息有差异');
    expect(rows.last.imageTitle('Summer Night'), 'Summer Night');
    expect(rows.last.imageArtist('Singer'), 'Singer');
    expect(rows.last.imageDuration(200), 200);
    expect(rows.last.matchLabel, isEmpty);
  });
  test('其他用户封面展示人数、原始来源，保存时保留原始来源', () {
    final rows = CoverCandidate.parse({
      'candidates': [
        {
          'id': 'a' * 64,
          'source': 'community',
          'title': 'Song',
          'artist': 'Singer',
          'album': 'Album',
          'votes': 3,
          'origin_source': 'deezer',
        },
      ],
    });
    expect(rows, hasLength(1));
    expect(rows.single.details, 'Singer\nAlbum\n3 位其他用户选择 · Deezer');
    expect(rows.single.selectionSource, 'deezer');
    expect(rows.single.source, 'community');
  });
  test('历史共享封面不虚构人数，旧来源继续显示匹配分', () {
    final rows = CoverCandidate.parse({
      'candidates': [
        {'id': 'b' * 64, 'source': 'community', 'legacy': true},
        {'id': 'c' * 64, 'source': 'itunes', 'score': 200},
        {'id': 'invalid', 'source': 'community', 'votes': 99},
      ],
    });
    expect(rows, hasLength(2));
    expect(rows.first.details, '历史共享选择');
    expect(rows.first.selectionSource, 'community');
    expect(rows.last.details, 'iTunes · 匹配 200');
    expect(rows.last.selectionSource, 'itunes');
  });
  test('预览复用给定 Dio 和令牌，以二进制读取并复用缓存', () async {
    final gate = Completer<ResponseBody>();
    final adapter = PreviewAdapter((_) => gate.future);
    final dio = Dio()..httpClientAdapter = adapter;
    final loader = CoverPreviewLoader(
      dio,
      cancelToken: CancelToken(),
      headers: {'Authorization': 'Bearer test-token'},
    );
    final first = loader.load(previewUri);
    final duplicate = loader.load(previewUri);
    await adapter.waitForRequests(1);
    expect(adapter.requests, hasLength(1));
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer test-token',
    );
    expect(adapter.requests.single.responseType, ResponseType.bytes);
    expect(adapter.requests.single.uri, previewUri);
    gate.complete(imageResponse());
    expect(await first, png);
    expect(await duplicate, png);
    expect(await loader.load(previewUri), png);
    expect(adapter.requests, hasLength(1));
    dio.close();
  });

  test('预览最多三个并发，排队请求在槽位释放后开始', () async {
    final gates = List.generate(4, (_) => Completer<ResponseBody>());
    final adapter = PreviewAdapter(
      (options) => gates[int.parse(options.uri.queryParameters['n']!)].future,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final loader = CoverPreviewLoader(dio, cancelToken: CancelToken());
    final futures = List.generate(
      4,
      (n) => loader.load(previewUri.replace(queryParameters: {'n': '$n'})),
    );
    await adapter.waitForRequests(3);
    expect(adapter.requests, hasLength(3));
    gates[0].complete(imageResponse());
    await futures[0];
    await adapter.waitForRequests(4);
    expect(adapter.requests, hasLength(4));
    for (var i = 1; i < 4; i++) {
      gates[i].complete(imageResponse());
    }
    await Future.wait(futures);
    dio.close();
  });

  test('关闭窗口取消正在加载和排队的预览，不再发新请求', () async {
    final adapter = PreviewAdapter((_) => Completer<ResponseBody>().future);
    final dio = Dio()..httpClientAdapter = adapter;
    final token = CancelToken();
    final loader = CoverPreviewLoader(dio, cancelToken: token);
    final checks = List.generate(
      5,
      (n) => expectLater(
        loader.load(previewUri.replace(queryParameters: {'n': '$n'})),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      ),
    );
    await adapter.waitForRequests(3);
    expect(adapter.requests, hasLength(3));
    token.cancel('dialog closed');
    await Future.wait(checks);
    expect(adapter.requests, hasLength(3));
    dio.close();
  });

  test('拒绝 JSON 错误正文，失败不缓存，重试可成功', () async {
    var calls = 0, errors = 0;
    final adapter = PreviewAdapter(
      (_) async => calls++ == 0
          ? ResponseBody.fromString('{"error":"invalid image"}', 200)
          : imageResponse(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final loader = CoverPreviewLoader(
      dio,
      cancelToken: CancelToken(),
      onError: (_, _) => errors++,
    );
    await expectLater(loader.load(previewUri), throwsFormatException);
    expect(await loader.load(previewUri), png);
    expect(calls, 2);
    expect(errors, 1);
    dio.close();
  });

  test('预览缓存按 16 张上限淘汰，重新访问已淘汰图片会加载', () async {
    final adapter = PreviewAdapter((_) async => imageResponse());
    final dio = Dio()..httpClientAdapter = adapter;
    final loader = CoverPreviewLoader(dio, cancelToken: CancelToken());
    Uri uri(int n) => previewUri.replace(queryParameters: {'n': '$n'});
    for (var n = 0; n < 17; n++) {
      await loader.load(uri(n));
    }
    await loader.load(uri(16));
    expect(adapter.requests, hasLength(17));
    await loader.load(uri(0));
    expect(adapter.requests, hasLength(18));
    dio.close();
  });

  testWidgets('候选用内存图片显示，父组件重建不会重复下载', (tester) async {
    final adapter = PreviewAdapter((_) async => imageResponse());
    final dio = Dio()..httpClientAdapter = adapter;
    final token = CancelToken();
    final loader = CoverPreviewLoader(dio, cancelToken: token);
    Widget view() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: CoverCandidatePreview(
            loader: loader,
            uri: previewUri,
            side: 90,
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(adapter.requests, hasLength(1));
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    token.cancel();
    dio.close();
  });

  testWidgets('预览失败可点击重试，不会触发选择整张封面', (tester) async {
    var calls = 0, selections = 0;
    final adapter = PreviewAdapter(
      (_) async => calls++ == 0
          ? ResponseBody.fromString('{"error":"temporarily unavailable"}', 502)
          : imageResponse(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final token = CancelToken();
    final loader = CoverPreviewLoader(dio, cancelToken: token);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InkWell(
            onTap: () => selections++,
            child: CoverCandidatePreview(
              loader: loader,
              uri: previewUri,
              side: 90,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败\n点击重试'), findsOneWidget);
    await tester.tap(find.text('加载失败\n点击重试'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(calls, 2);
    expect(selections, 0);
    await tester.pumpWidget(const SizedBox());
    token.cancel();
    dio.close();
  });
}
