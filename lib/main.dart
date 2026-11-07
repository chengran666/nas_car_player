import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_open_chinese_convert/flutter_open_chinese_convert.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:xml/xml.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' show min, max, pi, atan2, cos, sin, Random;
import 'package:flutter/foundation.dart'
    show compute, ValueListenable, listEquals;

// The library remains in NAS order; this copy is the actual transport queue.
// Refreshes retain the shuffled order and append only newly discovered songs.
List<String> buildPlaybackOrder(
  Iterable<String> songs, {
  required bool shuffled,
  List<String> previousOrder = const [],
  String currentSong = '',
  Random? random,
}) {
  final library = songs.toSet().toList();
  if (!shuffled) return library;
  final available = library.toSet();
  final retained = previousOrder.where(available.contains).toSet().toList();
  final retainedSet = retained.toSet();
  final added = library.where((song) => !retainedSet.contains(song)).toList();
  if (retained.isEmpty && added.remove(currentSong)) retained.add(currentSong);
  added.shuffle(random);
  return [...retained, ...added];
}

String? playbackQueueNeighbor(
  List<String> order,
  String currentSong,
  int direction, {
  bool repeatCurrent = false,
}) {
  if (order.isEmpty) return null;
  final index = order.indexOf(currentSong);
  if (index < 0) return order.first;
  if (repeatCurrent) return currentSong;
  return order[(index + direction) % order.length];
}

// Bucket decode sizes so changing display scale reuses a small number of images.
int coverDecodeSize(double diameter, double devicePixelRatio) {
  final pixels = (diameter * devicePixelRatio).ceil();
  if (pixels <= 256) return 256;
  if (pixels <= 512) return 512;
  return 1024;
}

// Only the previously highlighted row and the new row need rebuilding.
class LyricHighlightBuilder extends StatefulWidget {
  final ValueListenable<int> activeIndex;
  final int index;
  final Widget Function(BuildContext context, bool highlighted) builder;

  const LyricHighlightBuilder({
    super.key,
    required this.activeIndex,
    required this.index,
    required this.builder,
  });

  @override
  State<LyricHighlightBuilder> createState() => _LyricHighlightBuilderState();
}

class _LyricHighlightBuilderState extends State<LyricHighlightBuilder> {
  late bool _highlighted;

  @override
  void initState() {
    super.initState();
    _highlighted = widget.index == widget.activeIndex.value;
    widget.activeIndex.addListener(_updateHighlight);
  }

  void _updateHighlight() {
    final highlighted = widget.index == widget.activeIndex.value;
    if (highlighted != _highlighted) {
      setState(() => _highlighted = highlighted);
    }
  }

  @override
  void didUpdateWidget(LyricHighlightBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      oldWidget.activeIndex.removeListener(_updateHighlight);
      widget.activeIndex.addListener(_updateHighlight);
    }
    _highlighted = widget.index == widget.activeIndex.value;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _highlighted);

  @override
  void dispose() {
    widget.activeIndex.removeListener(_updateHighlight);
    super.dispose();
  }
}

String encodeSelectionImage(List<int> bytes) => base64Encode(bytes);
String selectionImageRevision(List<int> bytes) =>
    sha256.convert(bytes).toString();

String updateInstallFailureMessage(
  Object error, {
  bool requestingPermission = false,
}) {
  final message = error is PlatformException
      ? error.message ?? ''
      : error.toString();
  if (message.contains('No Activity found') ||
      message.contains('ActivityNotFoundException')) {
    return requestingPermission
        ? '车机无法打开安装授权页面。请手动进入系统设置，找到“安装未知应用”，允许车机NAS播放器安装应用。'
        : '车机无法打开系统安装程序，请检查安装程序是否被禁用，或通过浏览器、文件管理器手动安装。';
  }
  if (message.contains('SecurityException') ||
      message.contains('Permission Denial')) {
    return '车机系统限制了安装操作。请在系统设置中检查是否允许本播放器安装未知应用。';
  }
  // Preserve actionable validation errors (signature/version/package) and
  // native Chinese guidance, without showing a Java exception dump in the UI.
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(message)) return message;
  return requestingPermission
      ? '无法打开安装授权页面，请在车机系统设置中手动允许本播放器安装未知应用。'
      : '无法打开更新安装，请检查安装权限和系统安装程序；详细原因已记录在应用日志中。';
}

class AppRelease {
  final int code;
  final String name;
  final Uri url;
  final String digest;
  final int size;
  final String notes;
  final String abi;
  String get packageLabel => switch (abi) {
    'arm64-v8a' => 'ARM 64 位小包',
    'armeabi-v7a' => 'ARM 32 位小包',
    'x86_64' => 'x86_64 小包',
    _ => '通用包',
  };
  AppRelease(
    this.code,
    this.name,
    this.url,
    this.digest,
    this.size,
    this.notes, {
    this.abi = 'universal',
  });

  static AppRelease? parse(
    dynamic response,
    Uri endpoint, {
    List<String> supportedAbis = const [],
  }) {
    if (response is! Map || response['success'] != true) {
      throw const FormatException('升级服务响应无效');
    }
    final data = response['release'];
    if (data == null) return null;
    if (data is! Map) throw const FormatException('版本信息无效');
    final code = data['version_code'];
    final name = data['version_name'];
    if (code is! int || code <= 0 || name is! String || name.isEmpty) {
      throw const FormatException('版本信息不完整');
    }
    final notes = (data['notes'] is String ? data['notes'] as String : '')
        .trim();
    AppRelease readPackage(Map package, String abi) {
      final size = package['size'];
      final hash = package['sha256'];
      final path = package['apk_url'];
      if (size is! int ||
          size <= 0 ||
          size > 512 * 1024 * 1024 ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          path is! String) {
        throw const FormatException('版本信息不完整');
      }
      final url = endpoint.resolve(path);
      if (url.scheme != 'https' ||
          url.origin != endpoint.origin ||
          !url.path.endsWith('.apk') ||
          url.userInfo.isNotEmpty ||
          !url.path.startsWith(endpoint.resolve('updates/').path)) {
        throw const FormatException('升级包地址无效');
      }
      return AppRelease(code, name, url, hash, size, notes, abi: abi);
    }

    final fallback = readPackage(data, 'universal');
    final downloads = data['downloads'];
    if (downloads is Map) {
      // Android orders SUPPORTED_ABIS by preference. A 64-bit CPU running a
      // 32-bit Android system lists only the ABIs it can actually install.
      for (final abi in supportedAbis) {
        if (!const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi))
          continue;
        final package = downloads[abi];
        if (package is! Map) continue;
        try {
          return readPackage(package, abi);
        } on FormatException {
          // An absent/invalid split must not block a valid universal update.
          continue;
        }
      }
    }
    return fallback;
  }
}

Map<String, dynamic> desktopLyricsPayload({
  required String title,
  required String artist,
  required List<Map<String, dynamic>> lyrics,
  required bool ready,
  double offsetSeconds = 0,
  Map<String, dynamic>? clock,
}) => {
  'title': title,
  'artist': artist,
  'ready': ready,
  if (clock != null) 'clock': clock,
  // Same convention as lyricIndexAtPosition: positive offset advances lyrics.
  'lines': ready
      ? lyrics
            .map(
              (line) => {
                'timeMs':
                    (line['time'] as Duration).inMilliseconds -
                    (offsetSeconds * 1000).round(),
                'text': line['text'] as String,
              },
            )
            .toList(growable: false)
      : <Map<String, dynamic>>[],
};

bool isDesktopLyricColor(int? value) =>
    value != null &&
    (value == 0 || (value >= 0xFF000000 && value <= 0xFFFFFFFF));

/// Created only while the settings dialog is open; no player-frame work.
class DesktopLyricColorPicker extends StatefulWidget {
  final int initialColor;
  final Color followColor;
  final Map<int, String> presets;
  final double scale;
  const DesktopLyricColorPicker({
    super.key,
    required this.initialColor,
    required this.followColor,
    required this.presets,
    required this.scale,
  });

  @override
  State<DesktopLyricColorPicker> createState() =>
      _DesktopLyricColorPickerState();
}

class _DesktopLyricColorPickerState extends State<DesktopLyricColorPicker> {
  late HSVColor _color;
  late bool _follow;
  double s(double value) => value * widget.scale;
  @override
  void initState() {
    super.initState();
    _follow = widget.initialColor == 0;
    _color = HSVColor.fromColor(
      _follow ? widget.followColor : Color(widget.initialColor),
    );
  }

  void _pick(Offset point, double diameter) {
    final delta = point - Offset(diameter / 2, diameter / 2);
    setState(() {
      _follow = false;
      _color = _color
          .withHue((atan2(delta.dy, delta.dx) * 180 / pi + 360) % 360)
          .withSaturation((delta.distance / (diameter / 2)).clamp(0.0, 1.0));
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _follow ? 0 : _color.toColor().toARGB32();
    final preview = _follow ? widget.followColor : _color.toColor();
    final diameter = min(s(210), MediaQuery.sizeOf(context).height * .30);
    return AlertDialog(
      title: Text('桌面歌词颜色', style: TextStyle(fontSize: s(24))),
      content: SizedBox(
        width: s(460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(s(12)),
                color: Colors.black87,
                child: Text(
                  '桌面歌词预览',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: preview,
                    fontSize: s(24),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(height: s(12)),
              Semantics(
                label: '颜色盘，拖动选择色相和饱和度',
                child: GestureDetector(
                  key: const ValueKey('desktop-color-wheel'),
                  onPanDown: (details) =>
                      _pick(details.localPosition, diameter),
                  onPanUpdate: (details) =>
                      _pick(details.localPosition, diameter),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.square(diameter),
                      painter: _DesktopColorWheelPainter(_color),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Text('亮度', style: TextStyle(fontSize: s(18))),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('desktop-color-brightness'),
                      value: _color.value,
                      min: 0,
                      max: 1,
                      onChanged: (value) => setState(() {
                        _follow = false;
                        _color = _color.withValue(value);
                      }),
                    ),
                  ),
                  Text(
                    '${(_color.value * 100).round()}%',
                    style: TextStyle(fontSize: s(18)),
                  ),
                ],
              ),
              Text(
                _follow
                    ? '跟随大屏歌词颜色'
                    : '#${selected.toRadixString(16).substring(2).toUpperCase()}',
                key: const ValueKey('desktop-color-value'),
                style: TextStyle(fontSize: s(18)),
              ),
              SizedBox(height: s(8)),
              Wrap(
                spacing: s(8),
                runSpacing: s(6),
                children: widget.presets.entries
                    .map(
                      (entry) => ChoiceChip(
                        avatar: Container(
                          width: s(18),
                          height: s(18),
                          decoration: BoxDecoration(
                            color: entry.key == 0
                                ? widget.followColor
                                : Color(entry.key),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black26),
                          ),
                        ),
                        label: Text(
                          entry.value,
                          style: TextStyle(fontSize: s(18)),
                        ),
                        selected: selected == entry.key,
                        onSelected: (_) => setState(() {
                          _follow = entry.key == 0;
                          _color = HSVColor.fromColor(
                            _follow ? widget.followColor : Color(entry.key),
                          );
                        }),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(fontSize: s(20))),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, selected),
          child: Text('保存', style: TextStyle(fontSize: s(20))),
        ),
      ],
    );
  }
}

class _DesktopColorWheelPainter extends CustomPainter {
  final HSVColor color;
  _DesktopColorWheelPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 1 - color.value),
    );
    final angle = color.hue * pi / 180;
    final cursor =
        center + Offset(cos(angle), sin(angle)) * (radius * color.saturation);
    canvas.drawCircle(
      cursor,
      radius * .045,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * .028,
    );
    canvas.drawCircle(
      cursor,
      radius * .045,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * .014,
    );
  }

  @override
  bool shouldRepaint(_DesktopColorWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}

String? songSelectionDeviceId(String? androidId) {
  final value = androidId?.trim().toLowerCase() ?? '';
  if (!RegExp(r'^[0-9a-f]{1,16}$').hasMatch(value) ||
      RegExp(r'^0+$').hasMatch(value) ||
      value == '9774d56d682e549c') {
    return null;
  }
  // App-specific identifier only; do not send the raw Android ID to the server.
  return sha256
      .convert(utf8.encode('nas_car_player:device:v1|$value'))
      .toString();
}

Future<String?> readSongSelectionDeviceId() async => songSelectionDeviceId(
  await const MethodChannel(
    'com.nascarplayer/app_retain',
  ).invokeMethod<String>('getAndroidId'),
);

// Small durable outbox: network work never blocks playback or local selection.
class SongSelectionClient {
  SongSelectionClient(
    this.dio,
    this.prefs,
    this.baseUri,
    this.log, {
    required this.deviceId,
    this.outboxDirectory,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(deviceId)) {
      throw ArgumentError('设备识别码无效');
    }
    try {
      final saved = jsonDecode(
        prefs.getString('songSelectionOutboxV1') ?? '{}',
      );
      if (saved is Map) {
        for (final entry in saved.entries) {
          if (entry.key is String && entry.value is Map) {
            final payload = Map<String, dynamic>.from(entry.value);
            // Backed-up outboxes must not submit another device's choices.
            if (payload['device_id'] != null &&
                payload['device_id'] != deviceId) {
              continue;
            }
            payload['device_id'] = deviceId;
            _pending[_key(payload, kind: payload['kind'] as String?)] = payload;
          }
        }
      }
    } catch (_) {
      log('歌曲选择待同步记录读取失败');
    }
  }

  final Dio dio;
  final SharedPreferences prefs;
  final Uri baseUri;
  final void Function(String) log;
  final Future<Directory> Function()? outboxDirectory;
  final String deviceId;
  final _pending = <String, Map<String, dynamic>>{};
  Future<void> _writeTail = Future.value();
  Future<void>? _flushTask;
  int _selectionEpoch = 0;

  String _key(Map<String, dynamic> song, {String? kind}) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            deviceId,
            song['title'],
            song['artist'],
            song['duration'],
            if (kind != null) kind,
          ]),
        ),
      )
      .toString();

  bool hasPending(Map<String, dynamic> song, String kind) =>
      _pending.containsKey(_key(song, kind: kind));

  Future<void> _persist() {
    final task = _writeTail.then<void>((_) async {
      final ok = await prefs.setString(
        'songSelectionOutboxV1',
        jsonEncode(_pending),
      );
      if (!ok) throw StateError('无法保存歌曲选择待同步记录');
    });
    _writeTail = task.catchError((Object error) => log('待同步记录保存失败: $error'));
    return task;
  }

  Future<String?> enqueue(
    Map<String, dynamic> song,
    String kind,
    Map<String, dynamic> choice,
  ) async {
    choice = Map<String, dynamic>.from(choice);
    String? revision;
    if (kind == 'cover' && choice['image_path'] is String) {
      final bytes = await File(choice['image_path']).readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) throw StateError('封面图片过大');
      revision = await compute(selectionImageRevision, bytes);
      final root =
          await (outboxDirectory?.call() ?? getApplicationSupportDirectory());
      final snapshot = File('${root.path}/song_selection_outbox/$revision.img');
      await snapshot.parent.create(recursive: true);
      if (!await snapshot.exists())
        await snapshot.writeAsBytes(bytes, flush: true);
      choice['image_path'] = snapshot.path;
    } else if (kind == 'lyrics' && choice['text'] is String) {
      revision = sha256.convert(utf8.encode(choice['text'])).toString();
    }
    _pending[_key(song, kind: kind)] = {
      ...song,
      'device_id': deviceId,
      'kind': kind,
      'choice': choice,
    };
    _selectionEpoch++;
    await _persist();
    unawaited(flush());
    return revision;
  }

  Future<void> flush() =>
      _flushTask ??= _drain().whenComplete(() => _flushTask = null);

  Future<void> _drain() async {
    final attempted = <Map<String, dynamic>>{};
    while (true) {
      final entries = _pending.entries.where(
        (e) => !attempted.contains(e.value),
      );
      if (entries.isEmpty) return;
      final entry = entries.first;
      final payload = entry.value;
      attempted.add(payload);
      try {
        final choice = Map<String, dynamic>.from(payload['choice'] as Map);
        final path = choice.remove('image_path');
        if (path is String) {
          final file = File(path);
          if (!await file.exists()) {
            if (identical(_pending[entry.key], payload))
              _pending.remove(entry.key);
            await _persist();
            log('待同步封面本地文件已删除，跳过该记录');
            continue;
          }
          if (await file.length() > 8 * 1024 * 1024) throw StateError('封面图片过大');
          choice['image_base64'] = await compute(
            encodeSelectionImage,
            await file.readAsBytes(),
          );
        }
        // A newer local choice may arrive while the old image is being read.
        if (!identical(_pending[entry.key], payload)) continue;
        final response = await dio.postUri(
          baseUri.resolve('selections.php'),
          data: {...payload, 'choice': choice},
          options: Options(
            sendTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        final data = response.data is String
            ? jsonDecode(response.data)
            : response.data;
        if (data is! Map || data['success'] != true)
          throw StateError('服务端未确认保存');
        if (identical(_pending[entry.key], payload)) _pending.remove(entry.key);
        _selectionEpoch++;
        await _persist();
        if (path is String &&
            !_pending.values.any(
              (item) => (item['choice'] as Map)['image_path'] == path,
            )) {
          final snapshot = File(path);
          if (await snapshot.exists()) await snapshot.delete();
        }
        log(
          '${payload['kind'] == 'lyrics' ? '歌词' : '封面'}选择已保存到服务端: ${payload['title']}',
        );
      } catch (error) {
        log('歌曲选择暂未同步，已保留待重试记录: $error');
        return;
      }
    }
  }

  Future<Map<String, dynamic>?> lookup(Map<String, dynamic> song) async {
    final epoch = _selectionEpoch;
    // Read the last server submission on each playback, without polling.
    try {
      final response = await dio.getUri(
        baseUri
            .resolve('selections.php')
            .replace(
              queryParameters: {
                ...song,
                'device_id': deviceId,
              }.map((key, value) => MapEntry(key, value.toString())),
            ),
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      final data = response.data is String
          ? jsonDecode(response.data)
          : response.data;
      if (epoch != _selectionEpoch) return null;
      if (data is! Map || data['success'] != true)
        throw StateError('服务端选择响应无效');
      final selection = data['selection'] is Map
          ? Map<String, dynamic>.from(data['selection'])
          : null;
      return selection;
    } catch (error) {
      log('读取服务端歌曲选择失败，继续使用本地/自动结果: $error');
      return null;
    }
  }

  Uri imageUri(Map<String, dynamic> song, String revision) => baseUri
      .resolve('selections.php')
      .replace(
        queryParameters: {
          ...song.map((key, value) => MapEntry(key, value.toString())),
          'device_id': deviceId,
          'action': 'image',
          'revision': revision,
        },
      );
}

bool isSupportedCoverImageHeader(List<int> bytes) {
  bool startsWith(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => i,
      ).every((i) => bytes[i] == signature[i]);
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return true;
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return true;
  }
  if (startsWith('GIF87a'.codeUnits) || startsWith('GIF89a'.codeUnits)) {
    return true;
  }
  return bytes.length >= 12 &&
      startsWith('RIFF'.codeUnits) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

class VersionedFileImage extends FileImage {
  const VersionedFileImage(super.file, this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is VersionedFileImage &&
      other.file.path == file.path &&
      other.scale == scale &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(file.path, scale, revision);
}

const String appBuildTime = String.fromEnvironment(
  'BUILD_TIME',
  defaultValue: '终极后台保活版',
);
const String appAuthor = "NAS Car Player";
const String coverProxyBaseUrl = String.fromEnvironment(
  'COVER_PROXY_URL',
  defaultValue: 'https://mp3.whzxc.com/',
);
const String defaultLyricTranslationApiUrl = String.fromEnvironment(
  'LYRIC_TRANSLATION_API_URL',
  defaultValue: 'https://mp3.whzxc.com/lyrics.php',
);

String migrateLyricServiceUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri?.host != 'cover_api.whzxc.com') return value;
  return uri!
      .replace(scheme: 'https', host: 'mp3.whzxc.com', port: 443)
      .toString();
}

Uri parseLyricTranslationApiUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw const FormatException('接口地址不能为空');
  final uri = Uri.parse(trimmed);
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('请输入完整的 HTTP 或 HTTPS 地址');
  }
  if (uri.path.isEmpty || uri.path.endsWith('/')) {
    return uri.replace(path: '${uri.path}lyrics.php');
  }
  return uri;
}

late CarAudioHandler audioHandler;

final StreamController<String> _logStream =
    StreamController<String>.broadcast();
void addLog(String message) {
  final time = DateTime.now().toString().substring(11, 19);
  _logStream.add('[$time] $message');
  debugPrint('[$time] $message');
}

typedef CoverColorSample = ({Color color, int population});

Color selectRepresentativeCoverColor(
  Iterable<CoverColorSample> samples, {
  Color fallback = const Color(0xFF1ED760),
}) {
  final usable = samples.where((sample) {
    if (sample.population <= 0) return false;
    final hsl = HSLColor.fromColor(sample.color);
    return hsl.lightness >= 0.06 && hsl.lightness <= 0.94;
  }).toList();
  if (usable.isEmpty) return fallback;

  final largestPopulation = usable
      .map((sample) => sample.population)
      .reduce((left, right) => left > right ? left : right);
  CoverColorSample? best;
  var bestScore = double.negativeInfinity;
  for (final sample in usable) {
    final hsl = HSLColor.fromColor(sample.color);
    final populationScore = sample.population / largestPopulation;
    final usefulLightness = (1 - ((hsl.lightness - 0.42).abs() / 0.52)).clamp(
      0.0,
      1.0,
    );
    final nearNeutralPenalty = hsl.saturation < 0.10 ? 0.25 : 0.0;
    final score =
        populationScore * 0.70 +
        hsl.saturation * 0.20 +
        usefulLightness * 0.10 -
        nearNeutralPenalty;
    if (score > bestScore) {
      best = sample;
      bestScore = score;
    }
  }
  if (best == null || HSLColor.fromColor(best.color).saturation < 0.08) {
    return fallback;
  }
  return best.color;
}

({Color accent, Color glow}) buildCoverThemeColors(Color seed) {
  const pageBackground = Color(0xFFF2F6F9);
  final hsl = HSLColor.fromColor(seed);
  final saturation = hsl.saturation.clamp(0.42, 0.82);
  var accentLightness = (hsl.lightness + 0.08).clamp(0.28, 0.40);
  var accent = HSLColor.fromAHSL(
    1,
    hsl.hue,
    saturation,
    accentLightness,
  ).toColor();

  double contrastRatio(Color first, Color second) {
    final firstLuminance = first.computeLuminance();
    final secondLuminance = second.computeLuminance();
    final lighter = firstLuminance > secondLuminance
        ? firstLuminance
        : secondLuminance;
    final darker = firstLuminance > secondLuminance
        ? secondLuminance
        : firstLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  while (contrastRatio(accent, pageBackground) < 4.5 &&
      accentLightness > 0.16) {
    accentLightness -= 0.02;
    accent = HSLColor.fromAHSL(
      1,
      hsl.hue,
      saturation,
      accentLightness,
    ).toColor();
  }

  final glow = HSLColor.fromAHSL(
    1,
    hsl.hue,
    saturation.clamp(0.24, 0.52),
    0.88,
  ).toColor();
  return (accent: accent, glow: glow);
}

({String title, String artist}) parseSongFileName(String songName) {
  final cleanName = songName
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .replaceAll(RegExp(r'\[.*?\]|【.*?】'), '')
      .trim();
  if (!cleanName.contains('-')) return (title: cleanName, artist: '私人乐库');

  final spacedSeparator = RegExp(r'\s+-\s+').firstMatch(cleanName);
  if (spacedSeparator != null) {
    final artist = cleanName.substring(0, spacedSeparator.start).trim();
    final title = cleanName.substring(spacedSeparator.end).trim();
    if (artist.isNotEmpty && title.isNotEmpty)
      return (title: title, artist: artist);
  }

  final separator = cleanName.lastIndexOf('-');
  final left = cleanName.substring(0, separator).trim();
  final right = cleanName.substring(separator + 1).trim();
  if (left.isEmpty || right.isEmpty) return (title: cleanName, artist: '私人乐库');

  final artistListPattern = RegExp(
    r'[、,，/&]|feat\.?|ft\.?',
    caseSensitive: false,
  );
  if (artistListPattern.hasMatch(left) && !artistListPattern.hasMatch(right))
    return (title: right, artist: left);
  if (artistListPattern.hasMatch(right) && !artistListPattern.hasMatch(left))
    return (title: left, artist: right);
  return (title: left, artist: right);
}

String buildMusicBrainzRecordingQuery(String title, String artist) {
  String escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').trim();
  final query = <String>['recording:"${escape(title)}"'];
  final artists = splitArtistNames(artist);
  if (artists.length == 1 && artists.first != '私人乐库') {
    query.add('artist:"${escape(artists.first)}"');
  } else if (artists.length > 1) {
    query.add(
      '(${artists.map((name) => 'artist:"${escape(name)}"').join(' OR ')})',
    );
  }
  return query.join(' AND ');
}

bool isLikelySameSongText(String expected, String actual) {
  String normalize(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[\s\-_.,，。·、/&＆+＋\\()\[\]【】（）]'),
    '',
  );
  final a = normalize(expected);
  final b = normalize(actual);
  if (a.isEmpty || b.isEmpty) return false;
  if (a.contains(b) || b.contains(a)) return true;
  if (a.length != b.length) return false;
  var differences = 0;
  for (var i = 0; i < a.length; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) differences++;
  }
  final allowedDifferences = a.length >= 8 ? 2 : 1;
  return differences <= allowedDifferences;
}

List<String> splitArtistNames(String artist) {
  final trimmed = artist.trim();
  if (trimmed.isEmpty || trimmed == '私人乐库') return [];
  final parts = trimmed
      .split(
        RegExp(
          r'\s*(?:、|&|＆|/|,|，|;|；|\+|＋|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)\s*',
          caseSensitive: false,
        ),
      )
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty);
  final unique = <String>[];
  for (final part in parts) {
    if (!unique.any((value) => value.toLowerCase() == part.toLowerCase())) {
      unique.add(part);
    }
  }
  return unique;
}

List<String> buildArtistSearchVariants(String artist) {
  final variants = <String>[];
  void add(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && !variants.contains(trimmed))
      variants.add(trimmed);
  }

  add(artist);
  for (final part in splitArtistNames(artist)) {
    add(part);
  }
  return variants;
}

bool isLikelySameArtistCredit(String expected, String actual) {
  if (isLikelySameSongText(expected, actual)) return true;
  final expectedParts = splitArtistNames(expected);
  final actualParts = splitArtistNames(actual);
  return expectedParts.any(
    (left) => actualParts.any((right) => isLikelySameSongText(left, right)),
  );
}

bool _isEnglishLyricPart(String text) {
  final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
  final chineseCount = RegExp(r'[\u3400-\u9FFF]').allMatches(text).length;
  return latinCount >= 2 && chineseCount == 0;
}

bool _isChineseLyricPart(String text) {
  final chineseCount = RegExp(r'[\u3400-\u9FFF]').allMatches(text).length;
  final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
  return chineseCount >= 2 && chineseCount >= latinCount;
}

List<({Duration time, String text})> normalizeBilingualLyricLines(
  List<({Duration time, String text})> lines,
) {
  if (lines.length < 3) return lines;
  final normalized = lines
      .map((line) => (time: line.time, text: line.text))
      .toList();

  bool isEnglishOnly(int index) {
    final parts = normalized[index].text
        .split('\n')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.length == 1 && _isEnglishLyricPart(parts.single);
  }

  bool isShiftedPair(int index) {
    final parts = normalized[index].text
        .split('\n')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.length == 2 &&
        _isChineseLyricPart(parts.first) &&
        _isEnglishLyricPart(parts.last);
  }

  var index = 1;
  while (index < normalized.length) {
    if (!isEnglishOnly(index - 1) || !isShiftedPair(index)) {
      index++;
      continue;
    }
    var runEnd = index;
    while (runEnd + 1 < normalized.length && isShiftedPair(runEnd + 1)) {
      runEnd++;
    }
    // 至少连续两组才判断为“译文使用了下一句时间戳”，避免误改偶发的
    // 中文在前、英文在后的正常双语歌词。
    if (runEnd - index + 1 < 2) {
      index++;
      continue;
    }
    for (var pairIndex = index; pairIndex <= runEnd; pairIndex++) {
      final pair = normalized[pairIndex].text
          .split('\n')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      final translation = pair.first;
      final original = pair.last;
      final previous = normalized[pairIndex - 1];
      normalized[pairIndex - 1] = (
        time: previous.time,
        text: '${previous.text.trim()}\n$translation',
      );
      normalized[pairIndex] = (
        time: normalized[pairIndex].time,
        text: original,
      );
    }
    index = runEnd + 1;
  }

  // 对没有发生时间错位、但把中文写在英文前面的双语行统一调整显示顺序。
  for (var lineIndex = 0; lineIndex < normalized.length; lineIndex++) {
    final parts = normalized[lineIndex].text
        .split('\n')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length == 2 &&
        _isChineseLyricPart(parts.first) &&
        _isEnglishLyricPart(parts.last)) {
      normalized[lineIndex] = (
        time: normalized[lineIndex].time,
        text: '${parts.last}\n${parts.first}',
      );
    }
  }
  return normalized;
}

List<({Duration time, String text})> parseLrcText(String text) {
  final cleanText = text
      .replaceAll(r'\n', '\n')
      .replaceAll('\r', '')
      .replaceAll('\uFEFF', '');
  final fileOffsetMilliseconds =
      int.tryParse(
        RegExp(
              r'^\[offset:([+-]?\d+)\]\s*$',
              caseSensitive: false,
              multiLine: true,
            ).firstMatch(cleanText)?.group(1) ??
            '',
      ) ??
      0;
  // 同时兼容标准 [mm:ss.xx] 和备用词库的 [开始时间,结束时间] 格式。
  // 区间标签只使用开始时间，结束时间不应再生成一条重复歌词。
  final timeTagRegExp = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?(?:,\d{1,3}:\d{2}(?:[.:]\d{1,3})?)?\]',
  );
  final timedLines = <int, List<String>>{};
  for (final line in cleanText.split('\n')) {
    final matches = timeTagRegExp.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final pureLyric = line
        .replaceAll(timeTagRegExp, '')
        .replaceAll(RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>'), '')
        .trim();
    if (pureLyric.isEmpty) continue;
    int? previousTimestampInLine;
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3) ?? '';
      final milliseconds = fraction.isEmpty
          ? 0
          : int.parse(fraction.padRight(3, '0').substring(0, 3));
      final shiftedTimestamp =
          Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: milliseconds,
          ).inMilliseconds +
          fileOffsetMilliseconds;
      final timestamp = shiftedTimestamp < 0 ? 0 : shiftedTimestamp;
      // 同一物理行的密集时间标签通常是接口重复输出；不同物理行的
      // 相同歌词则可能是正常重复唱法，必须保留各自的时间点。
      if (previousTimestampInLine != null &&
          timestamp >= previousTimestampInLine &&
          timestamp - previousTimestampInLine <= 8000) {
        continue;
      }
      previousTimestampInLine = timestamp;
      final linesAtTime = timedLines.putIfAbsent(timestamp, () => []);
      if (!linesAtTime.contains(pureLyric)) linesAtTime.add(pureLyric);
    }
  }

  if (timedLines.isEmpty) {
    final plainLines = cleanText
        .split('\n')
        .map(
          (line) => line
              .replaceAll(RegExp(r'^\[[a-z]+:.*?\]$', caseSensitive: false), '')
              .trim(),
        )
        .where((line) => line.isNotEmpty)
        .toList();
    return [
      (
        time: Duration.zero,
        text: plainLines.isEmpty ? '纯音乐 / 暂无滚动歌词' : plainLines.join('\n'),
      ),
    ];
  }

  var result = timedLines.entries
      .map(
        (entry) => (
          time: Duration(milliseconds: entry.key),
          text: entry.value.join('\n'),
        ),
      )
      .toList();
  result.sort((a, b) => a.time.compareTo(b.time));
  return normalizeBilingualLyricLines(result);
}

// 调整缓存文件里的时间标签。正数让歌词延后，负数让歌词提前。
({String text, int tagCount}) shiftLrcTimestamps(
  String source,
  int milliseconds,
) {
  final tagPattern = RegExp(
    r'(\[|<)(\d{1,3}:\d{2}(?:[.:]\d{1,3})?(?:,\d{1,3}:\d{2}(?:[.:]\d{1,3})?)?)(\]|>)',
  );
  final timestampPattern = RegExp(r'^(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?$');
  var tagCount = 0;

  String shiftTimestamp(String value) {
    final match = timestampPattern.firstMatch(value)!;
    final fraction = match.group(3) ?? '';
    final original =
        (int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!)) * 1000 +
        (fraction.isEmpty ? 0 : int.parse(fraction.padRight(3, '0')));
    final shifted = (original + milliseconds).clamp(0, 59999999);
    final minutes = shifted ~/ 60000;
    final seconds = (shifted ~/ 1000) % 60;
    final millis = shifted % 1000;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  final text = source.replaceAllMapped(tagPattern, (match) {
    final opening = match.group(1)!;
    final closing = match.group(3)!;
    if ((opening == '[' && closing != ']') ||
        (opening == '<' && closing != '>')) {
      return match.group(0)!;
    }
    tagCount++;
    return '$opening${match.group(2)!.split(',').map(shiftTimestamp).join(',')}$closing';
  });
  return (text: text, tagCount: tagCount);
}

int lyricIndexAtPosition(
  List<Duration> lyricTimes,
  Duration playbackPosition,
  double offsetSeconds,
) {
  if (lyricTimes.isEmpty) return -1;
  final adjustedMilliseconds =
      playbackPosition.inMilliseconds + (offsetSeconds * 1000).round();
  var low = 0;
  var high = lyricTimes.length - 1;
  var result = -1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (lyricTimes[middle].inMilliseconds <= adjustedMilliseconds) {
      result = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return result;
}

bool isPredominantlyEnglishLyrics(String lyrics) {
  final text = parseLrcText(lyrics).map((line) => line.text).join(' ');
  final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
  final chineseCount = RegExp(r'[\u3400-\u9FFF]').allMatches(text).length;
  return latinCount >= 40 && chineseCount <= 2;
}

String buildBilingualLrc(
  List<({Duration time, String text})> originalLines,
  List<String> translations,
) {
  if (originalLines.length != translations.length) return '';
  String timestamp(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final milliseconds = duration.inMilliseconds.remainder(1000);
    return '[${totalMinutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${milliseconds.toString().padLeft(3, '0')}]';
  }

  final output = <String>[];
  for (var index = 0; index < originalLines.length; index++) {
    final original = originalLines[index];
    final translated = translations[index].trim();
    final timeTag = timestamp(original.time);
    for (final part in original.text.split('\n')) {
      output.add('$timeTag$part');
    }
    if (translated.isNotEmpty && translated != original.text.trim()) {
      output.add('$timeTag$translated');
    }
  }
  return output.join('\n');
}

String normalizeLyricTranslationLine(String line) =>
    line.replaceAll(RegExp(r'\s+'), ' ').trim();

String lyricTranslationLineId(String line) =>
    sha256.convert(utf8.encode(normalizeLyricTranslationLine(line))).toString();

Map<String, String> missingLyricTranslationLines(
  String lyrics,
  Map<String, String> cached,
) {
  final result = <String, String>{};
  for (final line in parseLrcText(lyrics)) {
    final parts = line.text.split('\n');
    final source = normalizeLyricTranslationLine(parts.first);
    if (RegExp(r'[\u3400-\u9FFF]').hasMatch(line.text) ||
        RegExp(r'[A-Za-z]').allMatches(source).length < 2 ||
        RegExp(r'^\s*[\[(].*[\])]\s*$').hasMatch(source))
      continue;
    final id = lyricTranslationLineId(source);
    if (!cached.containsKey(id)) result[id] = source;
  }
  return result;
}

Map<String, String> validateLyricLineTranslations(
  dynamic data,
  Map<String, String> requested,
) {
  if (data is! Map || data['schema_version'] != 3 || data['lines'] is! List) {
    throw const FormatException('服务端未返回新版逐行翻译');
  }
  final result = <String, String>{};
  for (final row in data['lines'] as List) {
    if (row is! Map ||
        row['id'] is! String ||
        row['source'] is! String ||
        row['translation'] is! String) {
      throw const FormatException('逐行翻译格式错误');
    }
    final id = row['id'] as String;
    final source = normalizeLyricTranslationLine(row['source']);
    final translated = (row['translation'] as String).trim();
    if (requested[id] != source ||
        lyricTranslationLineId(source) != id ||
        result.containsKey(id) ||
        !RegExp(r'[\u3400-\u9FFF]').hasMatch(translated)) {
      throw const FormatException('译文与原文不匹配');
    }
    result[id] = translated;
  }
  if (result.length != requested.length)
    throw const FormatException('翻译缺少对应歌词行');
  return result;
}

String composeLineTranslatedLrc(String lyrics, Map<String, String> cached) {
  final lines = parseLrcText(lyrics);
  final translations = lines.map((line) {
    if (RegExp(r'[\u3400-\u9FFF]').hasMatch(line.text)) return '';
    return cached[lyricTranslationLineId(line.text.split('\n').first)] ?? '';
  }).toList();
  if (translations.every((line) => line.isEmpty)) return lyrics;
  return buildBilingualLrc(lines, translations);
}

List<({Duration time, String text})> mergeLyricTranslations(
  List<({Duration time, String text})> lines,
  Map<String, String> cached,
) => lines
    .map((line) {
      if (RegExp(r'[\u3400-\u9FFF]').hasMatch(line.text)) return line;
      final translation =
          cached[lyricTranslationLineId(line.text.split('\n').first)]?.trim() ??
          '';
      return translation.isEmpty || translation == line.text.trim()
          ? line
          : (time: line.time, text: '${line.text}\n$translation');
    })
    .toList(growable: false);

const coverSourceLabels = <String, String>{
  'community': '其他用户选择',
  'itunes': 'iTunes',
  'lastfm': 'Last.fm',
  'deezer': 'Deezer',
  'musicbrainz': 'MusicBrainz',
};

class CoverCandidate {
  const CoverCandidate({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    required this.album,
    required this.score,
    this.artistMatches = true,
    this.votes = 0,
    this.legacyShared = false,
    this.originSource = '',
    this.matchLabel = '',
    this.lookupTitle = '',
    this.lookupArtist = '',
    this.lookupDuration,
  });
  final String id, source, title, artist, album;
  final int score;
  final bool artistMatches;
  final int votes;
  final bool legacyShared;
  final String originSource;
  final String matchLabel, lookupTitle, lookupArtist;
  final double? lookupDuration;
  String imageTitle(String title) => lookupTitle.isEmpty ? title : lookupTitle;
  String imageArtist(String artist) =>
      lookupTitle.isEmpty ? artist : lookupArtist;
  double imageDuration(double duration) => lookupDuration ?? duration;
  String get selectionSource => source == 'community'
      ? (originSource.isEmpty ? 'community' : originSource)
      : source;
  String get details => [
    if (artist.isNotEmpty) artist,
    if (album.isNotEmpty) album,
    if (source == 'community')
      '${legacyShared ? '历史共享选择' : '$votes 位其他用户选择'}'
          '${originSource.isEmpty ? '' : ' · ${coverSourceLabels[originSource] ?? originSource}'}'
    else
      '${coverSourceLabels[source]} · 匹配 $score${artistMatches ? '' : ' · 歌手不匹配'}',
  ].join('\n');
  static List<CoverCandidate> parse(dynamic data) {
    if (data is! Map || data['candidates'] is! List)
      throw const FormatException('封面候选格式错误');
    return (data['candidates'] as List)
        .whereType<Map>()
        .where(
          (row) =>
              row['id'] is String &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(row['id']) &&
              coverSourceLabels.containsKey(row['source']),
        )
        .map(
          (row) => CoverCandidate(
            id: row['id'],
            source: row['source'],
            title: row['title']?.toString() ?? '',
            artist: row['artist']?.toString() ?? '',
            album: row['album']?.toString() ?? '',
            score: (row['score'] as num?)?.toInt() ?? 0,
            artistMatches: row['artist_match'] != false,
            votes: max(0, (row['votes'] as num?)?.toInt() ?? 0),
            legacyShared: row['legacy'] == true,
            originSource: row['origin_source']?.toString() ?? '',
            matchLabel: row['match_label']?.toString() ?? '',
            lookupTitle: row['source'] == 'community'
                ? row['lookup_title']?.toString() ?? ''
                : '',
            lookupArtist: row['lookup_artist']?.toString() ?? '',
            lookupDuration: row['lookup_duration'] is num
                ? (row['lookup_duration'] as num).toDouble()
                : null,
          ),
        )
        .toList();
  }
}

// 候选预览复用 API 的 Dio，避免图片组件另建 HTTP/TLS 链路。
class CoverPreviewLoader {
  CoverPreviewLoader(this.dio, {required this.cancelToken, this.onError}) {
    unawaited(
      cancelToken.whenCancel.then((_) {
        for (final waiter in _waiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
        _waiters.clear();
        _cache.clear();
        _cachedBytes = 0;
      }),
    );
  }

  final Dio dio;
  final CancelToken cancelToken;
  final void Function(Uri uri, Object error)? onError;
  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List>> _pending = {};
  final List<Completer<void>> _waiters = [];
  int _active = 0, _cachedBytes = 0;

  Future<Uint8List> load(Uri uri) {
    if (cancelToken.isCancelled) return Future.error(cancelToken.cancelError!);
    final key = uri.toString();
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(key, () {
      return _download(uri).whenComplete(() {
        _pending.remove(key);
      });
    });
  }

  void evict(Uri uri) {
    final removed = _cache.remove(uri.toString());
    if (removed != null) _cachedBytes -= removed.length;
  }

  Future<Uint8List> _download(Uri uri) async {
    while (_active >= 3) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    _active++;
    try {
      final response = await dio.getUri<List<int>>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final bytes = Uint8List.fromList(response.data ?? []);
      if (!isSupportedCoverImageHeader(bytes)) {
        throw const FormatException('预览接口未返回有效图片');
      }
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('预览图片过大，请选择其他候选');
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      // 只保留小预览；并发最多三个，内存缓存最多 2MB / 16 张。
      while (_cache.isNotEmpty &&
          (_cache.length >= 16 ||
              _cachedBytes + bytes.length > 2 * 1024 * 1024)) {
        evict(Uri.parse(_cache.keys.first));
      }
      _cache[uri.toString()] = bytes;
      _cachedBytes += bytes.length;
      return bytes;
    } catch (error) {
      if (!cancelToken.isCancelled) onError?.call(uri, error);
      rethrow;
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        final waiter = _waiters.removeAt(0);
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }
}

class CoverCandidatePreview extends StatefulWidget {
  const CoverCandidatePreview({
    super.key,
    required this.loader,
    required this.uri,
    required this.side,
  });
  final CoverPreviewLoader loader;
  final Uri uri;
  final double side;

  @override
  State<CoverCandidatePreview> createState() => _CoverCandidatePreviewState();
}

class _CoverCandidatePreviewState extends State<CoverCandidatePreview> {
  late Future<Uint8List> _image;
  bool _decodeErrorLogged = false;
  Uint8List? _shownBytes;

  void _evictDecodedPreview() {
    final bytes = _shownBytes;
    _shownBytes = null;
    if (bytes != null) {
      unawaited(
        ResizeImage.resizeIfNeeded(160, 160, MemoryImage(bytes)).evict(),
      );
    }
  }

  @override
  void dispose() {
    _evictDecodedPreview();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _image = widget.loader.load(widget.uri);
  }

  @override
  void didUpdateWidget(CoverCandidatePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.loader != widget.loader) {
      _evictDecodedPreview();
      _decodeErrorLogged = false;
      _image = widget.loader.load(widget.uri);
    }
  }

  Widget _retry() => TextButton(
    onPressed: () {
      _evictDecodedPreview();
      widget.loader.evict(widget.uri);
      setState(() {
        _decodeErrorLogged = false;
        _image = widget.loader.load(widget.uri);
      });
    },
    child: Text(
      '加载失败\n点击重试',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: widget.side / 6.5),
    ),
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.side,
    height: widget.side,
    child: FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: widget.side * 0.25,
              height: widget.side * 0.25,
              child: CircularProgressIndicator(strokeWidth: widget.side / 45),
            ),
          );
        }
        if (snapshot.hasError || snapshot.data == null) return _retry();
        _shownBytes = snapshot.data;
        return Image.memory(
          snapshot.data!,
          cacheWidth: 160,
          cacheHeight: 160,
          fit: BoxFit.cover,
          errorBuilder: (_, error, _) {
            if (!_decodeErrorLogged) {
              _decodeErrorLogged = true;
              widget.loader.onError?.call(widget.uri, error);
            }
            return _retry();
          },
        );
      },
    ),
  );
}

class LyricCandidate {
  const LyricCandidate({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    required this.lyrics,
    required this.hasSyncedLyrics,
    required this.score,
  });

  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double durationSeconds;
  final String lyrics;
  final bool hasSyncedLyrics;
  final int score;

  String get identity =>
      id > 0 ? 'lrclib:$id' : '$trackName|$artistName|$durationSeconds';
}

int scoreLyricCandidate({
  required String expectedTitle,
  required String expectedArtist,
  required Duration expectedDuration,
  required String actualTitle,
  required String actualArtist,
  required double actualDurationSeconds,
  required bool hasSyncedLyrics,
}) {
  var score = 0;
  if (isLikelySameSongText(expectedTitle, actualTitle)) score += 55;
  if (expectedArtist.trim().isEmpty) {
    score += 15;
  } else if (isLikelySameSongText(expectedArtist, actualArtist)) {
    score += 30;
  }
  if (expectedDuration.inSeconds > 0 && actualDurationSeconds > 0) {
    final difference =
        (expectedDuration.inMilliseconds / 1000 - actualDurationSeconds).abs();
    if (difference <= 2) {
      score += 30;
    } else if (difference <= 5) {
      score += 22;
    } else if (difference <= 10) {
      score += 12;
    } else if (difference <= 20) {
      score += 4;
    }
  }
  if (hasSyncedLyrics) score += 8;
  return score;
}

typedef SongListSyncResult = ({
  int total,
  int added,
  int removed,
  int cleanupFailed,
});

const _libraryTaskZone = #nasPlayerLibrary;
const _coverTaskZone = #nasPlayerCoverChoice;

Map<String, dynamic>? get currentLibraryTask =>
    Zone.current[_libraryTaskZone] as Map<String, dynamic>?;

Directory libraryCacheDirectory(Directory root, Map<String, dynamic> account) =>
    Directory('${root.path}/libraries/${libraryCacheId(account)}');

Future<String?> prepareCachedOrRemote({
  required String preferred,
  required String remote,
  required Future<bool> Function(String path) prepare,
  required Future<void> Function(String path, Object error) onCachedFailure,
  required bool Function() isCurrent,
}) async {
  try {
    return await prepare(preferred) && isCurrent() ? preferred : null;
  } catch (error) {
    if (!isCurrent()) return null;
    if (preferred == remote) rethrow;
    await onCachedFailure(preferred, error);
    if (!isCurrent()) return null;
    return await prepare(remote) && isCurrent() ? remote : null;
  }
}

String libraryCacheId(Map<String, dynamic> account) => sha256
    .convert(utf8.encode('${account['url'] ?? ''}|${account['user'] ?? ''}'))
    .toString();

// Keep the song, library and its position in a single preference. A power cut
// between independent writes must not pair one recording with another's clock.
class PlaybackResumePoint {
  const PlaybackResumePoint(this.libraryId, this.song, this.positionMs);

  static const preferenceKey = 'playbackResumeV2';
  final String libraryId, song;
  final int positionMs;

  String encode() => jsonEncode([libraryId, song, positionMs]);

  static PlaybackResumePoint? decode(String? value) {
    if (value == null) return null;
    try {
      final data = jsonDecode(value);
      if (data is List &&
          data.length == 3 &&
          data[0] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(data[0]) &&
          data[1] is String &&
          (data[1] as String).trim().isNotEmpty &&
          data[2] is int &&
          data[2] >= 0) {
        return PlaybackResumePoint(data[0], data[1], data[2]);
      }
    } on FormatException {
      // A corrupt checkpoint is not a valid resume target.
    }
    return null;
  }
}

// just_audio extrapolates with DateTime.now(). Cars can correct wall time long
// after startup. Use the engine's sampled position and monotonic elapsed time.
class PlaybackPositionClock {
  PlaybackPositionClock({Duration Function()? elapsed})
    : _elapsed = elapsed ?? _startClock();

  static Duration Function() _startClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final Duration Function() _elapsed;
  (DateTime, Duration, int?, bool, double)? _anchor;
  Duration _anchorTime = Duration.zero;

  Duration read({
    required PlaybackEvent event,
    required bool advancing,
    required double speed,
  }) {
    final now = _elapsed();
    final anchor = (
      event.updateTime,
      event.updatePosition,
      event.currentIndex,
      advancing,
      speed,
    );
    if (_anchor != anchor) {
      _anchor = anchor;
      _anchorTime = now;
    }
    final position =
        event.updatePosition +
        (advancing ? (now - _anchorTime) * speed : Duration.zero);
    if (position < Duration.zero) return Duration.zero;
    final duration = event.duration;
    return duration != null && position > duration ? duration : position;
  }
}

List<String> filterSongList(
  Iterable<String> songs, {
  String query = '',
  Set<String> cachedSongs = const {},
  bool onlyCached = false,
  bool descending = false,
}) {
  final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
  final filtered = songs.where((song) {
    if (onlyCached && !cachedSongs.contains(song)) return false;
    final name = song.toLowerCase();
    return terms.every(name.contains);
  }).toList();
  filtered.sort(
    (a, b) => descending
        ? b.toLowerCase().compareTo(a.toLowerCase())
        : a.toLowerCase().compareTo(b.toLowerCase()),
  );
  return filtered;
}

// 异步任务固定使用发起时的乐库，切换页面或播放歌曲不会改变其缓存归属。
T runInLibrary<T>(Map<String, dynamic> account, T Function() action) =>
    runZoned(
      action,
      zoneValues: {_libraryTaskZone: Map<String, dynamic>.from(account)},
    );

class RemoteSongVersion {
  const RemoteSongVersion({this.etag = '', this.modified = '', this.size = 0});
  final String etag;
  final String modified;
  final int size;

  Map<String, dynamic> toJson() => {
    'etag': etag,
    'modified': modified,
    'size': size,
  };
  factory RemoteSongVersion.fromJson(Map<String, dynamic> value) =>
      RemoteSongVersion(
        etag: value['etag']?.toString() ?? '',
        modified: value['modified']?.toString() ?? '',
        size: (value['size'] as num?)?.toInt() ?? 0,
      );

  bool differsFrom(RemoteSongVersion previous) =>
      (etag.isNotEmpty && previous.etag.isNotEmpty && etag != previous.etag) ||
      (modified.isNotEmpty &&
          previous.modified.isNotEmpty &&
          modified != previous.modified) ||
      (size > 0 && previous.size > 0 && size != previous.size);
}

Map<String, RemoteSongVersion> parseWebDavVersions(String body, Uri directory) {
  final result = <String, RemoteSongVersion>{};
  for (final entry in XmlDocument.parse(
    body,
  ).rootElement.findElements('response', namespaceUri: 'DAV:')) {
    final href = entry
        .getElement('href', namespaceUri: 'DAV:')
        ?.innerText
        .trim();
    if (href == null || href.isEmpty) continue;
    final parts = directory.resolve(href).pathSegments;
    if (parts.isEmpty || !isSafeSongCacheName(parts.last)) continue;
    String property(String name) {
      for (final propstat in entry.findElements(
        'propstat',
        namespaceUri: 'DAV:',
      )) {
        final status =
            propstat.getElement('status', namespaceUri: 'DAV:')?.innerText ??
            '';
        if (!RegExp(r'^HTTP/\S+\s+2\d\d\b').hasMatch(status.trim())) continue;
        final value = propstat
            .getElement('prop', namespaceUri: 'DAV:')
            ?.getElement(name, namespaceUri: 'DAV:');
        if (value != null) return value.innerText.trim();
      }
      return '';
    }

    result[parts.last] = RemoteSongVersion(
      etag: property('getetag'),
      modified: property('getlastmodified'),
      size: int.tryParse(property('getcontentlength')) ?? 0,
    );
  }
  return result;
}

bool isSafeSongCacheName(String name) =>
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('\u0000') &&
    RegExp(r'\.(mp3|flac|wav|m4a|aac)$', caseSensitive: false).hasMatch(name);

// 删除同步必须基于完整的 DAV 响应，不能把 HTML 错误页或解析失败当成空目录。
List<String> parseWebDavSongList(String body, Uri directory) {
  const dav = 'DAV:';
  final root = XmlDocument.parse(body).rootElement;
  if (root.name.local != 'multistatus' || root.name.namespaceUri != dav) {
    throw const FormatException('服务器未返回 WebDAV 目录');
  }
  final base = directory.replace(
    path: directory.path.endsWith('/') ? directory.path : '${directory.path}/',
  );
  final baseParts = base.pathSegments.where((part) => part.isNotEmpty).toList();
  var directoryConfirmed = false;
  final songs = <String>{};
  for (final entry in root.findElements('response', namespaceUri: dav)) {
    final href = entry.getElement('href', namespaceUri: dav)?.innerText.trim();
    if (href == null || href.isEmpty) {
      throw const FormatException('WebDAV 目录缺少文件地址');
    }
    final location = base.resolve(href);
    final parts = location.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    if (location.host != base.host ||
        location.port != base.port ||
        parts.length < baseParts.length ||
        !List.generate(
          baseParts.length,
          (i) => parts[i] == baseParts[i],
        ).every((v) => v)) {
      throw const FormatException('WebDAV 返回了其他目录的内容');
    }
    if (parts.length > baseParts.length + 1) {
      throw const FormatException('WebDAV 未按 Depth: 1 返回目录');
    }
    final directStatus = entry.getElement('status', namespaceUri: dav);
    bool isSuccess(String value) =>
        RegExp(r'^HTTP/\S+\s+2\d\d\b').hasMatch(value.trim());
    if (directStatus != null && !isSuccess(directStatus.innerText)) {
      throw const FormatException('WebDAV 目录包含无法读取的项目');
    }
    XmlElement? resourceType;
    for (final propstat in entry.findElements('propstat', namespaceUri: dav)) {
      final status =
          propstat.getElement('status', namespaceUri: dav)?.innerText ?? '';
      if (!isSuccess(status)) continue;
      resourceType ??= propstat
          .getElement('prop', namespaceUri: dav)
          ?.getElement('resourcetype', namespaceUri: dav);
    }
    if (resourceType == null) {
      throw const FormatException('WebDAV 文件属性读取不完整');
    }
    final isDirectory =
        resourceType.getElement('collection', namespaceUri: dav) != null;
    if (parts.length == baseParts.length) {
      if (!isDirectory) throw const FormatException('WebDAV 地址不是目录');
      directoryConfirmed = true;
    } else if (!isDirectory && isSafeSongCacheName(parts.last)) {
      songs.add(parts.last);
    }
  }
  if (!directoryConfirmed) throw const FormatException('WebDAV 未确认当前目录');
  return songs.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

Set<String> songCachesToRemove({
  required Iterable<String> knownSongs,
  required Iterable<String> remoteSongs,
  Iterable<String> otherLibrarySongs = const [],
}) => knownSongs
    .where(isSafeSongCacheName)
    .toSet()
    .difference(remoteSongs.toSet())
    .difference(otherLibrarySongs.toSet());

Future<Set<String>> readSongAssetCacheNames(Directory cacheDirectory) async {
  final songs = <String>{};
  if (!await cacheDirectory.exists()) return songs;
  await for (final item in cacheDirectory.list()) {
    if (item is! File) continue;
    final name = item.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.(meta\.json|invalid|part)$'),
      '',
    );
    if (isSafeSongCacheName(name)) songs.add(name);
  }
  // 有些歌只缓存了歌词/封面，尚未下载音频，也要纳入删除同步。
  for (final folder in ['lyrics', 'covers']) {
    final directory = Directory('${cacheDirectory.path}/$folder');
    if (!await directory.exists()) continue;
    await for (final item in directory.list()) {
      if (item is! File) continue;
      final key = item.uri.pathSegments.last.split('.').first;
      try {
        final song = utf8.decode(base64Url.decode(base64Url.normalize(key)));
        if (isSafeSongCacheName(song)) songs.add(song);
      } on FormatException {
        // 其他文件不属于播放器管理的缓存。
      }
    }
  }
  return songs;
}

class SongCacheGroup {
  SongCacheGroup(this.directory, this.libraryId, this.song);
  final String directory;
  final String libraryId;
  final String song;
  final List<File> files = [];
  int bytes = 0;
  DateTime touched = DateTime.fromMillisecondsSinceEpoch(0);
  String get audioPath => File('$directory/$song').absolute.path;
}

bool canEvictSongCache(
  SongCacheGroup group, {
  required String playingLibraryId,
  required String currentSong,
  required Iterable<String> activeDownloads,
}) =>
    !(group.libraryId == playingLibraryId && group.song == currentSong) &&
    !activeDownloads.contains('${group.libraryId}:${group.song}');

Future<({int bytes, List<SongCacheGroup> groups})> readCacheInventory(
  Directory root,
) async {
  var bytes = 0;
  final groups = <String, SongCacheGroup>{};
  if (!await root.exists()) return (bytes: 0, groups: <SongCacheGroup>[]);
  await for (final item in root.list(recursive: true, followLinks: false)) {
    if (item is! File) continue;
    final stat = await item.stat();
    bytes += stat.size;
    final relative = item.path
        .substring(root.path.length + 1)
        .replaceAll('\\', '/')
        .split('/');
    final scoped = relative.length >= 3 && relative.first == 'libraries';
    final id = scoped ? relative[1] : '';
    final base = scoped ? '${root.path}/libraries/$id' : root.path;
    final parts = scoped ? relative.sublist(2) : relative;
    var song = '';
    if (parts.length == 1) {
      song = parts.single.replaceFirst(
        RegExp(r'\.(meta\.json|invalid|part)$'),
        '',
      );
    } else if (parts.length == 2 &&
        (parts.first == 'lyrics' || parts.first == 'covers')) {
      try {
        song = utf8.decode(
          base64Url.decode(base64Url.normalize(parts.last.split('.').first)),
        );
      } on FormatException {
        continue;
      }
    }
    if (!isSafeSongCacheName(song)) continue;
    final group = groups.putIfAbsent(
      '$id:$song',
      () => SongCacheGroup(base, id, song),
    );
    group.files.add(item);
    group.bytes += stat.size;
    if (stat.modified.isAfter(group.touched)) group.touched = stat.modified;
  }
  return (
    bytes: bytes,
    groups: groups.values.toList()
      ..sort((a, b) => a.touched.compareTo(b.touched)),
  );
}

Dio _createHttpClient({
  required Duration connectTimeout,
  required Duration receiveTimeout,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: connectTimeout,
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () =>
        HttpClient()..badCertificateCallback = (_, __, ___) => true,
  );
  return dio;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    audioHandler = await AudioService.init(
      builder: () => CarAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.nascarplayer.channel.audio',
        androidNotificationChannelName: 'NAS Car Player',
        androidNotificationOngoing: true,
      ),
    );
    addLog("音频服务初始化成功");
  } catch (e) {
    addLog("音频服务初始化失败: $e");
    audioHandler = CarAudioHandler();
  }

  runApp(const NasCarPlayerApp());
}

class NasCarPlayerApp extends StatelessWidget {
  const NasCarPlayerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NAS Car Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(primaryColor: const Color(0xFF1ED760)),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});
  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _hasOverlayPermission = false;
  bool _desktopLyricsEnabled = true;
  bool _desktopLyricsPrefsLoaded = false;
  bool _desktopLyricsLocked = false;
  bool _desktopLyricsStaggered = false;
  String? _lastDesktopClockEvent;
  double _desktopLyricFontSize = 28;
  double _desktopLyricOpacity = .55;
  double _desktopLyricWidth = .85;
  int _desktopLyricColor = 0xFFFFFFFF;
  static const _desktopLyricColors = <int, String>{
    0: '跟随大屏',
    0xFFFFFFFF: '白色',
    0xFFFFD166: '暖黄',
    0xFFFFA857: '橙色',
    0xFF8FE3B0: '浅绿',
    0xFF70DCE8: '青色',
    0xFF8FC7FF: '天蓝',
    0xFFD1B3FF: '淡紫',
    0xFFFFA8C5: '粉色',
  };
  int get _effectiveDesktopLyricColor => _desktopLyricColor == 0
      ? _lyricHighlightColor.toARGB32()
      : _desktopLyricColor;
  final Dio _updateDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  bool _checkingUpdate = false;
  bool _updateDialogOpen = false;
  CancelToken? _updateCancelToken;
  AppRelease? _availableRelease;
  String _installedVersion = '';
  Timer? _updateCheckTimer;
  bool _awaitingInstallPermission = false;
  String _installPermissionRoute = 'app_source';
  int? _downloadedUpdateCode;
  bool _savingUpdateToDownloads = false;
  int currentLeftScreen = 0;
  bool isLoading = false;
  List<String> realNasSongs = [];
  Set<String> _cachedFiles = {};
  bool _showingCachedSongsOnly = false;
  String? _slidingSongName; // 当前正在滑动的歌曲名称

  String currentPlayingSong = "等待播放",
      currentArtist = "私人乐库",
      _currentFileName = "";
  bool isPlaying = false;
  int _loopMode = 0;
  List<String> _playbackLibrarySongs = [];
  List<String> _playbackQueue = [];

  static const String defaultCoverUrl = '';
  late String currentCoverUrl;

  String _currentTimeString = "12:00";
  Duration _currentPosition = Duration.zero, _totalDuration = Duration.zero;
  double? _draggingSeekMs;
  Timer? _clockTimer,
      _screenSaverTimer,
      _playbackSaveTimer,
      _lyricAutoScrollResumeTimer;
  bool _isLargeMode = false;
  bool _showLargeDisplayControls = false;
  bool _lyricsManuallyScrolled = false;
  bool _isAppForeground = true;
  int _lyricSessionId = 0;
  DateTime _lastPositionUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  List<Map<String, dynamic>> parsedLyrics = [];
  List<Duration> _lyricTimes = [];
  List<LyricCandidate> _lyricCandidates = [];
  String _currentLyricSource = '';
  String? _displayedLyricRaw;
  bool _isRefreshingLyrics = false;
  final _activeLyricIndex = ValueNotifier<int>(0);
  int get _currentLyricIndex => _activeLyricIndex.value;
  set _currentLyricIndex(int value) => _activeLyricIndex.value = value;
  List<GlobalKey> _lyricKeys = [], _miniLyricKeys = [];

  final ScrollController _lyricScrollController = ScrollController();
  final ScrollController _miniLyricScrollController = ScrollController();
  final ScrollController _playlistScrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController();
  final List<String> _logs = [];
  final _progressTick = ValueNotifier<int>(0);
  final _clockText = ValueNotifier<String>('');
  final _logTick = ValueNotifier<int>(0);
  Future<void>? _cacheLimitTask;
  Timer? _cacheLimitDebounce;
  String _songSearch = '';
  bool _onlyCached = false;
  bool _reverseSongSort = false;
  Timer? _songSearchDebounce;
  List<String>? _filteredSource;
  Set<String>? _filteredCachedSource;
  String _filteredCriteria = '';
  List<String> _filteredSongs = [];
  DateTime? _lastLibrarySync;
  final Map<String, Map<String, RemoteSongVersion>> _libraryVersions = {};

  late AnimationController _spinController;
  Timer? _positionPollTimer;
  late StreamSubscription _playingSub,
      _positionSub,
      _durationSub,
      _completedSub,
      _logSub;
  late final bool Function(KeyEvent) _hardwareKeyHandler;
  Color _lyricHighlightColor = const Color(0xFF1ED760),
      _bottomGlowColor = const Color(0xFFE2EFE9);
  final Map<String, ({Color accent, Color glow})> _coverThemeCache = {};
  final Set<String> _paletteUpdatesInFlight = {};
  final Map<String, int> _coverImageRevisions = {};
  final Map<String, Future<String?>> _coverWriteTasks = {};
  final Set<String> _reportedCoverImageErrors = {};

  late SharedPreferences _prefs;
  List<Map<String, dynamic>> webdavAccounts = [];
  Map<String, dynamic>? activeAccount;
  Map<String, dynamic>? playingAccount;
  late final Dio _webDavDio = _createHttpClient(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  );
  late final Dio _externalDio = _createHttpClient(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 8),
  );
  final Map<String, CancelToken> _downloadCancelTokens = {};
  final Map<String, int> _songAssetGenerations = {};
  Future<Directory>? _audioCacheDirectoryFuture;
  Timer? _cacheDownloadTimer;
  int _playRequestId = 0;
  int _songListRequestId = 0;
  CancelToken? _songListCancelToken;
  Future<void> _songListSyncGate = Future.value();
  int _lyricChoiceRevision = 0;
  int _coverChoiceRevision = 0;
  int? _positionUpdatesForRequestId;
  bool _prefsReady = false;
  SongSelectionClient? _songSelections;
  late final Future<void> _initializationFuture;
  bool _isStartingPlayback = false;
  int _preparingPlaybackCount = 0;
  int _rememberedPositionMs = 0;
  Future<void> _musicBrainzRequestGate = Future.value();
  DateTime _lastMusicBrainzRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, Future<void>> _lyricTranslationTasks = {};
  final Map<String, Future<bool>> _lyricWriteTasks = {};
  final Map<String, String> _latestLyricsForTranslation = {};
  String _lyricTranslationApiUrl = defaultLyricTranslationApiUrl;

  double _uiScale = 1.3, _btnScale = 1.0, _lyricOffset = 0.0;
  static const platform = MethodChannel('com.nascarplayer/app_retain');
  static const mediaChannel = MethodChannel('com.nascarplayer/media_control');
  double s(double value) => value * _uiScale;

  double _lyricFontSize = 50.0, _maxCacheGB = 2.0;
  double _largeLyricFontSize = 34.0, _largeUiScale = 1.5;
  double _largeClockFontSize = 70.0;

  double _stageSize(double value) =>
      s(value) * (_isLargeMode ? _largeUiScale / _uiScale : 1.0);
  int _screenSaverTimeout = 8, _bootDelay = 5;
  bool _autoPlay = false,
      _showStatusBar = false,
      _startOnBoot = false,
      _startOtherAppOnBoot = false;
  String _bootOtherAppPackage = '', _bootOtherAppLabel = '';
  int _bootOtherAppDelay = 10;

  DateTime _lastEventTime = DateTime.now();
  String? _playingLocalPath;
  bool _recoveringAudio = false;

  Map<String, dynamic>? get _cacheAccount =>
      currentLibraryTask ?? playingAccount ?? activeAccount;

  String _songPreferenceKey(String prefix, String song) =>
      '${prefix}_${libraryCacheId(_cacheAccount!)}:$song';

  String _songTaskKey(String song) => '${libraryCacheId(_cacheAccount!)}:$song';

  Map<String, RemoteSongVersion> _loadLibraryVersions(
    Map<String, dynamic> account,
  ) {
    final id = libraryCacheId(account);
    return _libraryVersions.putIfAbsent(id, () {
      try {
        final data =
            jsonDecode(
                  _prefs.getString(
                        '${_accountSongListKey(account)}_versions',
                      ) ??
                      '{}',
                )
                as Map;
        return {
          for (final entry in data.entries)
            entry.key.toString(): RemoteSongVersion.fromJson(
              Map<String, dynamic>.from(entry.value),
            ),
        };
      } catch (_) {
        return {};
      }
    });
  }

  Future<Directory> _cacheRoot() => _audioCacheDirectoryFuture ??= () async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/nas_cache');
  }();

  Future<void> _migrateLegacyCaches() async {
    if (_prefs.getBool('scopedCacheV2') == true || webdavAccounts.isEmpty)
      return;
    final root = await _cacheRoot();
    final legacySongs = await readSongAssetCacheNames(root);
    for (final song in legacySongs) {
      final owners = webdavAccounts
          .where(
            (account) =>
                webdavAccounts.length == 1 ||
                (_prefs.getStringList(_accountSongListKey(account)) ?? [])
                    .contains(song),
          )
          .toList();
      if (owners.length != 1) continue;
      final account = owners.single;
      await runInLibrary(account, () async {
        final target = await _audioCacheDirectory();
        if (target == null) return;
        final key = _cacheAssetKey(song);
        for (final relative in [
          song,
          'lyrics/$key.lrc',
          'lyrics/$key.lrc.original',
          'covers/$key.jpg',
        ]) {
          final source = File('${root.path}/$relative');
          final destination = File('${target.path}/$relative');
          if (await source.exists() && !await destination.exists()) {
            await destination.parent.create(recursive: true);
            await source.rename(destination.path);
          }
        }
        for (final prefix in [
          'songMetadata',
          'lyricSource',
          'manualLyric',
          'lyricCandidateId',
          'lyricFileShift',
          'lyricOffset',
        ]) {
          final oldKey = '${prefix}_$song';
          final newKey = _songPreferenceKey(prefix, song);
          final value = _prefs.get(oldKey);
          if (!_prefs.containsKey(newKey)) {
            if (value is String) await _prefs.setString(newKey, value);
            if (value is double) await _prefs.setDouble(newKey, value);
            if (value is int) await _prefs.setInt(newKey, value);
            if (value is bool) await _prefs.setBool(newKey, value);
          }
          await _prefs.remove(oldKey);
        }
      });
    }
    await _prefs.setBool('scopedCacheV2', true);
    addLog('旧缓存迁移完成，缓存已按乐库隔离');
  }

  Future<void> _recoverCachedAudio(Object error) async {
    final path = _playingLocalPath;
    final account = playingAccount;
    if (!mounted || _recoveringAudio || path == null || account == null) {
      if (mounted && !_recoveringAudio) _showPlaybackMessage('播放异常，请检查网络或切换歌曲');
      return;
    }
    _recoveringAudio = true;
    final song = _currentFileName;
    final position = audioHandler.playbackPosition;
    final request = _playRequestId;
    try {
      await _markAudioCacheInvalid(path, error);
      if (!mounted || request != _playRequestId) return;
      _playingLocalPath = null;
      addLog('缓存播放异常，使用网络音源恢复: $song / $error');
      await runInLibrary(
        account,
        () => _playNasSong(song, initialPosition: position, forceRemote: true),
      );
    } catch (failure) {
      addLog('缓存播放恢复失败: $failure');
    } finally {
      _recoveringAudio = false;
    }
  }

  Future<void> _markAudioCacheInvalid(String path, Object error) async {
    try {
      await File('$path.invalid').writeAsString(error.toString());
    } catch (failure) {
      addLog('记录无效缓存失败: $failure');
    }
  }

  Future<void> _enforceCacheLimit() {
    _cacheLimitDebounce?.cancel();
    return _cacheLimitTask ??= _trimCacheToLimit().whenComplete(
      () => _cacheLimitTask = null,
    );
  }

  void _scheduleCacheLimitCheck() {
    if (!mounted) return;
    _cacheLimitDebounce?.cancel();
    _cacheLimitDebounce = Timer(const Duration(seconds: 30), () {
      if (mounted) unawaited(_enforceCacheLimit());
    });
  }

  Future<void> _trimCacheToLimit() async {
    try {
      final inventory = await readCacheInventory(await _cacheRoot());
      var bytes = inventory.bytes;
      for (final group in inventory.groups) {
        if (bytes <= (_maxCacheGB * 1024 * 1024 * 1024).round()) break;
        final playingId = playingAccount == null
            ? ''
            : libraryCacheId(playingAccount!);
        if (!canEvictSongCache(
          group,
          playingLibraryId: playingId,
          currentSong: _currentFileName,
          activeDownloads: _downloadCancelTokens.keys,
        ))
          continue;
        Map<String, dynamic>? owner;
        for (final account in webdavAccounts) {
          if (libraryCacheId(account) == group.libraryId) {
            owner = account;
            break;
          }
        }
        var deleted = false;
        if (owner != null) {
          deleted = await _deleteCacheFile(
            group.song,
            account: owner,
            refreshFiles: false,
            updatePresentation: false,
          );
        } else {
          for (final file in group.files) {
            if (await file.exists()) await file.delete();
          }
          deleted = true;
        }
        if (deleted) bytes -= group.bytes;
      }
      await _updateCachedFilesList();
    } catch (e) {
      addLog('缓存容量清理失败: $e');
    }
  }

  Future<void> _showCacheOverview() async {
    final inventory = await readCacheInventory(await _cacheRoot());
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('离线缓存'),
        content: Text(
          '占用 ${(inventory.bytes / 1024 / 1024).toStringAsFixed(1)} MB\n'
          '歌曲资源 ${inventory.groups.length} 组\n上限 ${_maxCacheGB.toStringAsFixed(1)} GB\n'
          '容量包含音频、歌词、封面和备份。清理时保留当前歌曲。',
          style: TextStyle(fontSize: s(20)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _enforceCacheLimit();
              _showPlaybackMessage('超额缓存清理完成，当前歌曲已保留');
            },
            child: const Text('清理超额缓存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onDesktopLyricsLockChanged' &&
          call.arguments is bool) {
        _applyDesktopLyricsLock(call.arguments as bool);
      } else if (call.method == 'onDesktopLyricsEnabledChanged' &&
          call.arguments is bool) {
        _applyDesktopLyricsEnabled(call.arguments as bool);
      } else if (call.method == 'onDesktopLyricsWidthChanged' &&
          call.arguments is num) {
        _applyDesktopLyricWidth((call.arguments as num).toDouble());
      }
    });
    _checkOverlayPermission();
    currentCoverUrl = defaultCoverUrl;
    _initClock();
    _initializationFuture = _initPrefsAndState();

    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _spinController.stop();

    // 设置 MediaSession 切歌回调
    audioHandler.onNextCallback = () {
      addLog(
        "\u2705 [MediaSession] \u89e6\u53d1: \u4e0b\u4e00\u66f2 (\u65b9\u5411\u76d8 Next)",
      );
      if (_checkDebounce()) return;
      _playNextSong(manual: true);
      _resetScreenSaverTimer();
    };
    audioHandler.onPrevCallback = () {
      addLog(
        "\u2705 [MediaSession] \u89e6\u53d1: \u4e0a\u4e00\u66f2 (\u65b9\u5411\u76d8 Prev)",
      );
      if (_checkDebounce()) return;
      _playPrevSong();
      _resetScreenSaverTimer();
    };
    audioHandler.onErrorCallback = (error) {
      if (_preparingPlaybackCount == 0) {
        unawaited(_recoverCachedAudio(error));
      } else {
        final request = _playRequestId;
        // play() 的错误可能早于 playSong() 返回；等音源准备结果落定再恢复。
        Future<void>.delayed(Duration.zero, () {
          if (mounted &&
              request == _playRequestId &&
              _preparingPlaybackCount == 0 &&
              _playingLocalPath != null) {
            unawaited(_recoverCachedAudio(error));
          }
        });
      }
    };

    // 监听 just_audio 的播放状态
    _playingSub = audioHandler.player.playingStream.listen((p) {
      if (mounted) {
        setState(() => isPlaying = p);
        _syncDiscAnimation();
        _syncPositionPolling();
      }
      if (!p) unawaited(_savePlaybackState());
      _syncDesktopPlaybackClock();
    });

    _positionSub = audioHandler.player.playbackEventStream.listen(
      (_) {
        if (!mounted) return;
        _syncDesktopPlaybackClock();
        if (!_isAppForeground) return;
        // setAudioSource 时旧音源仍可能补发最后一个位置事件。切歌开始后先
        // 禁用位置同步，等新音源真正准备好再恢复，避免新歌词跳到上一首末尾。
        // 使用播放器当前时钟，避免后台积压的 Stream 事件把页面退回旧位置。
        _syncPlaybackPosition();
      },
      onError: (Object _, StackTrace _) {
        // CarAudioHandler owns playback error reporting and cache recovery.
      },
    );
    _durationSub = audioHandler.player.durationStream.listen((dur) {
      if (mounted &&
          _positionUpdatesForRequestId == _playRequestId &&
          dur != null &&
          dur != _totalDuration) {
        _totalDuration = dur;
        _progressTick.value++;
      }
    });
    _completedSub = audioHandler.player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed &&
          mounted &&
          _positionUpdatesForRequestId == _playRequestId &&
          audioHandler.player.processingState == ProcessingState.completed) {
        _playNextSong(manual: false);
      }
    });

    // 日志流订阅
    _logSub = _logStream.stream.listen((log) {
      if (!mounted) return;
      _logs.add(log);
      if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
      if (currentLeftScreen != 3 || !_isAppForeground) return;
      _logTick.value++;
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && _logScrollController.hasClients) {
          _logScrollController.animateTo(
            _logScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
    addLog("APP 启动，等待接收车机方向盘指令...");
    addLog("监听通道: MediaSession + HardwareKey + Native广播");

    // HardwareKey 监听（接收 adb keyevent 和部分车机方向盘按键）
    _hardwareKeyHandler = (KeyEvent event) {
      if (event is KeyDownEvent) {
        String keyName = event.logicalKey.debugName ?? "未知";
        if (event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
          addLog("✅ [HardwareKey] 下一曲: $keyName");
          if (_checkDebounce()) return true;
          _playNextSong(manual: true);
          _resetScreenSaverTimer();
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
          addLog("✅ [HardwareKey] 上一曲: $keyName");
          if (_checkDebounce()) return true;
          _playPrevSong();
          _resetScreenSaverTimer();
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
          addLog("✅ [HardwareKey] 播放/暂停: $keyName");
          _togglePlayPause();
          return true;
        } else {
          addLog("🔵 [HardwareKey] 其他: $keyName");
        }
      }
      return false;
    };
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);

    // Native MethodChannel 监听（接收 MainActivity.kt 转发的按键）- 仅切歌兜底
    mediaChannel.setMethodCallHandler((call) async {
      if (call.method == 'onMediaButton') {
        String key = call.arguments;
        addLog("🔵 [Native广播] 捕获: $key");
        if (key == 'NEXT') {
          if (_checkDebounce()) return;
          _playNextSong(manual: true);
          _resetScreenSaverTimer();
        } else if (key == 'PREVIOUS') {
          if (_checkDebounce()) return;
          _playPrevSong();
          _resetScreenSaverTimer();
        }
      }
    });
  }

  @override
  void dispose() {
    unawaited(_savePlaybackState());
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    mediaChannel.setMethodCallHandler(null);
    platform.setMethodCallHandler(null);
    audioHandler.onNextCallback = null;
    audioHandler.onPrevCallback = null;
    audioHandler.onErrorCallback = null;
    _songSearchDebounce?.cancel();
    _cacheLimitDebounce?.cancel();
    _updateCheckTimer?.cancel();
    _updateCancelToken?.cancel('播放器已关闭');
    _updateDio.close(force: true);
    _clockTimer?.cancel();
    _screenSaverTimer?.cancel();
    _playbackSaveTimer?.cancel();
    _cacheDownloadTimer?.cancel();
    _lyricAutoScrollResumeTimer?.cancel();
    for (final token in _downloadCancelTokens.values) {
      token.cancel('播放器已关闭');
    }
    _downloadCancelTokens.clear();
    _songListCancelToken?.cancel('播放器已关闭');
    _playingSub.cancel();
    _positionSub.cancel();
    _positionPollTimer?.cancel();
    _durationSub.cancel();
    _completedSub.cancel();
    _logSub.cancel();
    _lyricScrollController.dispose();
    _miniLyricScrollController.dispose();
    _playlistScrollController.dispose();
    _logScrollController.dispose();
    _spinController.dispose();
    _progressTick.dispose();
    _activeLyricIndex.dispose();
    _clockText.dispose();
    _logTick.dispose();
    _webDavDio.close(force: true);
    _externalDio.close(force: true);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isAppForeground = true;
      _syncPositionPolling();
      if (_awaitingInstallPermission) unawaited(_resumeUpdateInstall());
      if (_availableRelease != null && !_updateDialogOpen && !_checkingUpdate) {
        unawaited(_offerUpdate(_availableRelease!));
      }
      _syncDiscAnimation();
      _checkOverlayPermission();
      _draggingSeekMs = null;
      _recenterLyricsForLayout();
      if (_positionUpdatesForRequestId == _playRequestId) {
        addLog('返回前台，歌词已校准到 ${_printDuration(_currentPosition)}');
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _isAppForeground = false;
      _syncPositionPolling();
      _spinController.stop();
      unawaited(_savePlaybackState());
    }
  }

  void _syncPositionPolling() {
    if (!mounted || !_isAppForeground || !isPlaying) {
      _positionPollTimer?.cancel();
      _positionPollTimer = null;
      return;
    }
    // just_audio's positionStream keeps its timer until player disposal, even
    // with no listeners. Own the foreground timer so it really stops in back.
    _positionPollTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _syncPlaybackPosition(),
    );
  }

  void _syncDiscAnimation() {
    // The sidebar disc stays visible outside large mode too. Both discs share
    // one controller; keep it running while playing in the foreground.
    final shouldRotate = isPlaying && _isAppForeground;
    if (shouldRotate == _spinController.isAnimating) return;
    if (shouldRotate) {
      _spinController.repeat();
    } else {
      _spinController.stop();
    }
  }

  void _cancelLyricScrollAnimations() {
    for (final controller in [
      _lyricScrollController,
      _miniLyricScrollController,
    ]) {
      if (controller.hasClients) controller.jumpTo(controller.offset);
    }
  }

  void _recenterLyricsForLayout() {
    _lyricSessionId++;
    _lyricAutoScrollResumeTimer?.cancel();
    _lyricsManuallyScrolled = false;
    _cancelLyricScrollAnimations();
    if (_positionUpdatesForRequestId == _playRequestId) {
      _syncPlaybackPosition(forceLyricRecenter: true);
    } else {
      _scheduleLyricRecenter(immediate: true);
    }
  }

  void _syncPlaybackPosition({bool forceLyricRecenter = false}) {
    if (!mounted || _positionUpdatesForRequestId != _playRequestId) return;
    final player = audioHandler.player;
    final position = audioHandler.playbackPosition;
    _currentPosition = position;
    final duration = player.duration;
    final durationChanged = duration != null && duration != _totalDuration;
    if (durationChanged) _totalDuration = duration;
    if (_draggingSeekMs != null) return;

    _updateLyricScroll(position, force: forceLyricRecenter);
    final now = DateTime.now();
    if (forceLyricRecenter ||
        durationChanged ||
        (currentLeftScreen == 2 &&
            !_isLargeMode &&
            now.difference(_lastPositionUiUpdate) >=
                const Duration(milliseconds: 250))) {
      _lastPositionUiUpdate = now;
      _progressTick.value++;
    }
  }

  Future<void> _checkOverlayPermission() async {
    try {
      final bool result = await platform.invokeMethod('checkOverlayPermission');
      if (mounted) {
        final changed = _hasOverlayPermission != result;
        setState(() => _hasOverlayPermission = result);
        if (changed && _prefsReady) unawaited(_configureDesktopLyrics());
      }
    } catch (_) {}
  }

  void _applyDesktopLyricsLock(bool value) {
    if (!mounted) return;
    if (_desktopLyricsLocked != value) {
      setState(() => _desktopLyricsLocked = value);
    }
    if (_prefsReady) unawaited(_prefs.setBool('desktopLyricsLocked', value));
  }

  void _applyDesktopLyricsEnabled(bool value) {
    if (!mounted) return;
    if (_desktopLyricsEnabled != value) {
      setState(() => _desktopLyricsEnabled = value);
    }
    if (_prefsReady) unawaited(_prefs.setBool('desktopLyricsEnabled', value));
  }

  Future<void> _configureDesktopLyrics({
    bool setLock = false,
    bool setEnabled = false,
    bool syncLyrics = true,
    bool setWidth = false,
  }) async {
    // Permission callbacks can arrive before saved settings finish loading.
    // Do not initialize native persistence from the temporary default values.
    if (!Platform.isAndroid || !_desktopLyricsPrefsLoaded) return;
    try {
      final state = await platform.invokeMapMethod<String, dynamic>(
        'configureDesktopLyrics',
        {
          'enabled': _desktopLyricsEnabled,
          'fontSize': s(_desktopLyricFontSize),
          'opacity': _desktopLyricOpacity,
          'color': _effectiveDesktopLyricColor,
          'scale': _uiScale,
          'locked': _desktopLyricsLocked,
          'staggered': _desktopLyricsStaggered,
          'widthFraction': _desktopLyricWidth,
          'widthOverride': setWidth,
          // Native button is authoritative unless the settings switch was changed.
          'lockOverride': setLock,
          'enabledOverride': setEnabled,
        },
      );
      if (state?['locked'] is bool) _applyDesktopLyricsLock(state!['locked']);
      if (state?['enabled'] is bool)
        _applyDesktopLyricsEnabled(state!['enabled']);
      if (!setWidth && state?['widthFraction'] is num) {
        _applyDesktopLyricWidth((state!['widthFraction'] as num).toDouble());
      }
      if (mounted && syncLyrics) _syncDesktopLyrics();
    } catch (error) {
      addLog('桌面歌词设置失败: $error');
    }
  }

  void _applyDesktopLyricWidth(double value) {
    if (!mounted) return;
    final width = value.clamp(.3, 1.0);
    if ((_desktopLyricWidth - width).abs() > .0001) {
      setState(() => _desktopLyricWidth = width);
    }
    if (_prefsReady &&
        ((_prefs.getDouble('desktopLyricWidth') ?? -1) - width).abs() > .0001) {
      unawaited(_prefs.setDouble('desktopLyricWidth', width));
    }
  }

  void _syncDesktopLyrics() {
    if (!Platform.isAndroid || !_desktopLyricsEnabled || !_prefsReady) return;
    // Only called when lyrics/translation/source/offset change, never per position tick.
    unawaited(
      platform
          .invokeMethod(
            'setDesktopLyrics',
            desktopLyricsPayload(
              title: currentPlayingSong,
              artist: currentArtist,
              lyrics: parsedLyrics,
              ready:
                  _currentFileName.isNotEmpty &&
                  _positionUpdatesForRequestId == _playRequestId,
              offsetSeconds: _lyricOffset,
              clock: _desktopPlaybackSnapshot(),
            ),
          )
          .catchError((Object error) {
            addLog('桌面歌词更新失败: $error');
          }),
    );
  }

  Map<String, dynamic> _desktopPlaybackSnapshot() {
    final player = audioHandler.player;
    return {
      'title': currentPlayingSong,
      'artist': currentArtist,
      'positionMs': audioHandler.playbackPosition.inMilliseconds,
      'sampledAtMs': DateTime.now().millisecondsSinceEpoch,
      'speed': player.speed,
      'advancing':
          player.playing && player.processingState == ProcessingState.ready,
    };
  }

  void _syncDesktopPlaybackClock() {
    if (!mounted ||
        !Platform.isAndroid ||
        !_desktopLyricsPrefsLoaded ||
        !_desktopLyricsEnabled ||
        _positionUpdatesForRequestId != _playRequestId)
      return;
    final player = audioHandler.player;
    final event = player.playbackEvent;
    // Ignore buffered-byte/duration-only updates. No position polling in background.
    final signature =
        '$_playRequestId|${event.updateTime.microsecondsSinceEpoch}|'
        '${event.updatePosition.inMilliseconds}|${player.speed}|${player.playing}|${player.processingState}';
    if (_lastDesktopClockEvent == signature) return;
    _lastDesktopClockEvent = signature;
    unawaited(
      platform
          .invokeMethod('setDesktopPlaybackClock', _desktopPlaybackSnapshot())
          .catchError((Object error) {
            addLog('桌面歌词时间同步失败: $error');
          }),
    );
  }

  Future<void> _chooseDesktopLyricColor() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => DesktopLyricColorPicker(
        initialColor: _desktopLyricColor,
        followColor: _lyricHighlightColor,
        presets: _desktopLyricColors,
        scale: _uiScale,
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _desktopLyricColor = selected);
    unawaited(_prefs.setInt('desktopLyricColor', selected));
    unawaited(_configureDesktopLyrics());
  }

  void _syncDesktopLyricColor() {
    if (!Platform.isAndroid ||
        !_desktopLyricsEnabled ||
        _desktopLyricColor != 0)
      return;
    unawaited(
      platform
          .invokeMethod('setDesktopLyricsColor', {
            'color': _effectiveDesktopLyricColor,
          })
          .catchError((Object error) {
            addLog('桌面歌词颜色更新失败: $error');
          }),
    );
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    if (!Platform.isAndroid ||
        _checkingUpdate ||
        _updateDialogOpen ||
        _updateCancelToken != null)
      return;
    setState(() => _checkingUpdate = true);
    try {
      final info = await platform.invokeMapMethod<String, dynamic>(
        'getAppVersion',
      );
      if (info == null || info['code'] is! int) throw StateError('无法读取应用版本');
      if (!mounted) return;
      setState(() => _installedVersion = '${info['name']} (${info['code']})');
      final base = Uri.parse(coverProxyBaseUrl);
      final endpoint = base.resolve('updates.php');
      if (endpoint.scheme != 'https') throw StateError('升级接口必须使用 HTTPS');
      final response = await _updateDio.getUri(
        endpoint,
        options: Options(
          followRedirects: false,
          responseType: ResponseType.json,
        ),
      );
      final supportedAbis = (info['abis'] is List)
          ? (info['abis'] as List).whereType<String>().toList(growable: false)
          : const <String>[];
      final release = AppRelease.parse(
        response.data,
        endpoint,
        supportedAbis: supportedAbis,
      );
      if (release != null) {
        addLog(
          '升级包选择：${supportedAbis.join(', ')} → ${release.packageLabel} '
          '${(release.size / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      }
      if (!mounted) return;
      if (release == null || release.code <= (info['code'] as int)) {
        _availableRelease = null;
        if (manual) _showPlaybackMessage('当前已是最新版本');
        return;
      }
      if (!manual && _prefs.getInt('dismissedUpdateCode') == release.code)
        return;
      _availableRelease = release;
      if (_isAppForeground) await _offerUpdate(release);
    } catch (error) {
      addLog('检查升级失败: $error');
      if (manual && mounted) _showPlaybackMessage('检查升级失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _offerUpdate(AppRelease release) async {
    if (!mounted ||
        !_isAppForeground ||
        _updateDialogOpen ||
        _savingUpdateToDownloads)
      return;
    _updateDialogOpen = true;
    try {
      final download = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            '发现新版本 ${release.name}',
            style: TextStyle(fontSize: s(24)),
          ),
          content: SingleChildScrollView(
            child: Text(
              '${release.packageLabel} · ${(release.size / 1024 / 1024).toStringAsFixed(1)} MB\n'
              '覆盖安装会保留设置和缓存。\n\n${release.notes}',
              style: TextStyle(fontSize: s(20)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('稍后', style: TextStyle(fontSize: s(20))),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text('下载更新', style: TextStyle(fontSize: s(20))),
            ),
          ],
        ),
      );
      _availableRelease = null;
      if (!mounted) return;
      if (download == true) {
        await _downloadUpdate(release);
      } else {
        await _prefs.setInt('dismissedUpdateCode', release.code);
      }
    } finally {
      _updateDialogOpen = false;
    }
  }

  Future<void> _downloadUpdate(AppRelease release) async {
    final token = CancelToken();
    _updateCancelToken = token;
    final progress = ValueNotifier<int>(0);
    var verifying = false;
    BuildContext? progressContext;
    final dialogReady = Completer<void>();
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressContext = dialogContext;
        if (!dialogReady.isCompleted) dialogReady.complete();
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text('下载更新', style: TextStyle(fontSize: s(24))),
            content: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (_, percent, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: verifying ? null : percent / 100,
                  ),
                  SizedBox(height: s(16)),
                  Text(
                    verifying ? '正在校验安装包…' : '$percent%',
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => token.cancel('用户取消下载'),
                child: Text('取消', style: TextStyle(fontSize: s(20))),
              ),
            ],
          ),
        );
      },
    );
    File? partial;
    var verified = false;
    try {
      await dialogReady.future;
      final path = await platform.invokeMethod<String>('getUpdateDownloadPath');
      if (path == null) throw StateError('无法获取下载目录');
      partial = File('$path.part');
      await _updateDio.downloadUri(
        release.url,
        partial.path,
        cancelToken: token,
        options: Options(
          followRedirects: false,
          receiveTimeout: const Duration(seconds: 30),
        ),
        onReceiveProgress: (received, total) {
          if (received > release.size) {
            token.cancel('升级包大小超出版本信息');
            return;
          }
          final percent = (received * 100 ~/ release.size).clamp(0, 100);
          if (progress.value != percent) progress.value = percent;
        },
      );
      if (token.isCancelled) throw StateError('下载已取消');
      verifying = true;
      progress.value = 101;
      if (await partial.length() != release.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.digest) {
        throw StateError('安装包校验失败，请重新下载');
      }
      if (token.isCancelled) throw StateError('下载已取消');
      final target = File(path);
      if (await target.exists()) await target.delete();
      await partial.rename(path);
      if (mounted) setState(() => _downloadedUpdateCode = release.code);
      verified = true;
    } catch (error) {
      if (!token.isCancelled || token.cancelError?.error != '用户取消下载') {
        addLog('下载更新失败: $error');
        if (mounted) _showPlaybackMessage('下载或校验失败，请重试');
      }
    } finally {
      if (partial != null && await partial.exists()) await partial.delete();
      _updateCancelToken = null;
      if (progressContext?.mounted == true) Navigator.pop(progressContext!);
      await dialog;
      progress.dispose();
    }
    if (verified && mounted && _isAppForeground) {
      await _offerDownloadedUpdateActions();
    }
  }

  Future<void> _offerDownloadedUpdateActions() async {
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('更新已下载', style: TextStyle(fontSize: s(24))),
        content: Text(
          '可以直接安装，或保存到下载文件夹，再用车机文件管理器打开 APK。',
          style: TextStyle(fontSize: s(20)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('稍后', style: TextStyle(fontSize: s(20))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('保存到下载文件夹', style: TextStyle(fontSize: s(20))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('安装更新', style: TextStyle(fontSize: s(20))),
          ),
        ],
      ),
    );
    if (!mounted || save == null) return;
    if (save) {
      await _saveDownloadedUpdate();
    } else {
      await _installDownloadedUpdate();
    }
  }

  Future<void> _saveDownloadedUpdate() async {
    final code = _downloadedUpdateCode;
    if (code == null ||
        !_isAppForeground ||
        _savingUpdateToDownloads ||
        _updateCancelToken != null)
      return;
    setState(() => _savingUpdateToDownloads = true);
    try {
      final saved = await platform.invokeMethod<String>(
        'saveUpdateToDownloads',
        {'code': code},
      );
      if (mounted && saved != null) {
        _showPlaybackMessage('已保存：$saved。请用车机文件管理器打开安装。');
      }
    } catch (error) {
      addLog('保存更新安装包失败: $error');
      if (mounted) {
        final reason = error is PlatformException ? error.message : null;
        _showPlaybackMessage(reason ?? '无法保存安装包，请重试');
      }
    } finally {
      if (mounted) setState(() => _savingUpdateToDownloads = false);
    }
  }

  Future<void> _installDownloadedUpdate() async {
    if (_downloadedUpdateCode == null ||
        !_isAppForeground ||
        _savingUpdateToDownloads ||
        _updateCancelToken != null)
      return;
    var requestingPermission = false;
    try {
      final allowed =
          await platform.invokeMethod<bool>('canInstallUpdates') ?? false;
      if (!mounted) return;
      if (!allowed) {
        final action = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('允许安装更新', style: TextStyle(fontSize: s(24))),
            content: Text(
              '可以允许播放器安装未知应用。如果车机没有该权限入口，可以保存 APK，再用文件管理器手动安装。',
              style: TextStyle(fontSize: s(20)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('稍后', style: TextStyle(fontSize: s(20))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'save'),
                child: Text('保存到下载文件夹', style: TextStyle(fontSize: s(20))),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'permission'),
                child: Text('去授权', style: TextStyle(fontSize: s(20))),
              ),
            ],
          ),
        );
        if (!mounted || action == null) return;
        if (action == 'save') {
          await _saveDownloadedUpdate();
          return;
        }
        requestingPermission = true;
        _awaitingInstallPermission = true;
        final route = await platform.invokeMethod<String>(
          'requestInstallPermission',
        );
        _installPermissionRoute = route ?? 'app_source';
        addLog('更新安装授权入口: $_installPermissionRoute');
        if (route == 'not_required') {
          _awaitingInstallPermission = false;
          if (mounted) await _installDownloadedUpdate();
        }
        return;
      }
      await platform.invokeMethod('installUpdate', {
        'code': _downloadedUpdateCode,
      });
    } catch (error) {
      _awaitingInstallPermission = false;
      addLog('更新${requestingPermission ? '授权' : '安装'}失败: $error');
      if (mounted) {
        final save = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('暂时无法安装更新', style: TextStyle(fontSize: s(24))),
            content: SingleChildScrollView(
              child: SelectableText(
                '${updateInstallFailureMessage(error, requestingPermission: requestingPermission)}\n\n'
                '可保存已下载的 APK，再用文件管理器手动安装。',
                style: TextStyle(fontSize: s(20)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('知道了', style: TextStyle(fontSize: s(20))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text('保存到下载文件夹', style: TextStyle(fontSize: s(20))),
              ),
            ],
          ),
        );
        if (save == true && mounted) await _saveDownloadedUpdate();
      }
    }
  }

  Future<void> _resumeUpdateInstall() async {
    _awaitingInstallPermission = false;
    try {
      if (await platform.invokeMethod<bool>('canInstallUpdates') == true) {
        if (mounted) await _installDownloadedUpdate();
      } else if (mounted) {
        _showPlaybackMessage(
          _installPermissionRoute == 'app_source'
              ? '尚未允许安装更新，也可在播放器设置中保存 APK 后手动安装'
              : '若车机没有安装授权入口，请在播放器设置中保存 APK 后手动安装',
        );
      }
    } catch (error) {
      addLog('读取安装更新权限失败: $error');
    }
  }

  bool _checkDebounce() {
    final now = DateTime.now();
    if (now.difference(_lastEventTime).inMilliseconds < 250) return true;
    _lastEventTime = now;
    return false;
  }

  Future<void> _togglePlayPause() async {
    _resetScreenSaverTimer();
    await _initializationFuture;
    if (!mounted) return;
    if (audioHandler.player.playing) {
      await audioHandler.player.pause();
      await _savePlaybackState();
      return;
    }

    final state = audioHandler.player.processingState;
    if (state != ProcessingState.idle) {
      if (state == ProcessingState.completed) {
        await audioHandler.player.seek(Duration.zero);
      }
      unawaited(audioHandler.play());
      return;
    }

    await _startRememberedOrFirstSong();
  }

  Future<void> _startRememberedOrFirstSong() async {
    if (_isStartingPlayback) return;
    _isStartingPlayback = true;
    try {
      if (activeAccount == null && webdavAccounts.isNotEmpty) {
        activeAccount = webdavAccounts.first;
        await _restoreRememberedPlaylist(activeAccount!);
      }

      if (activeAccount == null) {
        _showPlaybackMessage('请先在系统设置中添加 WebDAV 乐库');
        return;
      }

      final canResumeRememberedSong =
          _currentFileName.isNotEmpty &&
          realNasSongs.contains(_currentFileName) &&
          _sameAccount(activeAccount, playingAccount);
      var targetSong = canResumeRememberedSong ? _currentFileName : '';
      if (targetSong.isEmpty) {
        if (realNasSongs.isEmpty) await fetchSongsFromWebDav(silent: true);
        if (realNasSongs.isNotEmpty) {
          final changedAccount = !_sameAccount(activeAccount, playingAccount);
          playingAccount = Map.from(activeAccount!);
          _setPlaybackLibrary(
            realNasSongs,
            restoreOrder: changedAccount,
            anchor: '',
          );
          targetSong = _playbackQueue.first;
        }
      }

      if (targetSong.isEmpty) {
        _showPlaybackMessage(
          _showingCachedSongsOnly ? '离线状态下没有可播放的缓存歌曲' : '当前乐库没有可播放的歌曲',
        );
        return;
      }

      await playNasSong(
        targetSong,
        initialPosition: canResumeRememberedSong
            ? Duration(milliseconds: _rememberedPositionMs)
            : Duration.zero,
      );
    } finally {
      _isStartingPlayback = false;
    }
  }

  void _showPlaybackMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggleLoopMode() {
    setState(() {
      _loopMode = (_loopMode + 1) % 3;
      _setPlaybackLibrary(_playbackLibrarySongs, resetOrder: true);
    });
    _prefs.setInt('loopMode', _loopMode);
    _resetScreenSaverTimer();
  }

  Future<void> _initPrefsAndState() async {
    _prefs = await SharedPreferences.getInstance();
    _prefsReady = true;
    if (!mounted) return;
    if (coverProxyBaseUrl.trim().isNotEmpty) {
      try {
        final deviceId = await readSongSelectionDeviceId();
        if (!mounted) return;
        if (deviceId != null) {
          _songSelections = SongSelectionClient(
            _externalDio,
            _prefs,
            Uri.parse(coverProxyBaseUrl),
            addLog,
            deviceId: deviceId,
          );
          addLog('设备偏好已启用: ${deviceId.substring(0, 8)}');
          unawaited(_songSelections!.flush());
        } else {
          addLog('设备标识不可用，歌词/封面选择暂仅保存到本地');
        }
      } catch (error) {
        addLog('读取设备标识失败，歌词/封面选择暂仅保存到本地: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _uiScale = _prefs.getDouble('uiScale') ?? 1.5;
      _btnScale = _prefs.getDouble('btnScale') ?? 1.0;
      _desktopLyricsEnabled = _prefs.getBool('desktopLyricsEnabled') ?? true;
      _desktopLyricsLocked = _prefs.getBool('desktopLyricsLocked') ?? false;
      _desktopLyricsStaggered =
          _prefs.getBool('desktopLyricsStaggered') ?? false;
      _desktopLyricsPrefsLoaded = true;
      _desktopLyricFontSize = (_prefs.getDouble('desktopLyricFontSize') ?? 28)
          .clamp(18.0, 48.0);
      _desktopLyricOpacity = (_prefs.getDouble('desktopLyricOpacity') ?? .55)
          .clamp(.0, .85);
      _desktopLyricWidth = (_prefs.getDouble('desktopLyricWidth') ?? .85).clamp(
        .3,
        1.0,
      );
      final savedLyricColor = _prefs.getInt('desktopLyricColor');
      _desktopLyricColor = isDesktopLyricColor(savedLyricColor)
          ? savedLyricColor!
          : 0xFFFFFFFF;
      _lyricFontSize = _prefs.getDouble('lyricFontSize') ?? 50.0;
      _largeUiScale = (_prefs.getDouble('largeUiScale') ?? _uiScale).clamp(
        0.8,
        2.0,
      );
      // 首次迁移保持旧版大屏的实际歌词大小，之后与普通播放页独立。
      _largeLyricFontSize =
          (_prefs.getDouble('largeLyricFontSize') ??
                  _lyricFontSize / _largeUiScale)
              .clamp(20.0, 100.0);
      _largeClockFontSize = (_prefs.getDouble('largeClockFontSize') ?? 70.0)
          .clamp(30.0, 120.0);
      _screenSaverTimeout = _prefs.getInt('screenSaverTimeout') ?? 8;
      _autoPlay = _prefs.getBool('autoPlay') ?? false;
      _showStatusBar = _prefs.getBool('showStatusBar') ?? false;
      _maxCacheGB = _prefs.getDouble('maxCacheGB') ?? 2.0;
      _startOnBoot = _prefs.getBool('startOnBoot') ?? false;
      _startOtherAppOnBoot = _prefs.getBool('startOtherAppOnBoot') ?? false;
      _bootOtherAppPackage = _prefs.getString('bootOtherAppPackage') ?? '';
      _bootOtherAppLabel = _prefs.getString('bootOtherAppLabel') ?? '';
      _bootOtherAppDelay = _prefs.getInt('bootOtherAppDelay') ?? 10;
      _bootDelay = _prefs.getInt('bootDelay') ?? 5;
      _loopMode = _prefs.getInt('loopMode') ?? 0;
      _lyricTranslationApiUrl = migrateLyricServiceUrl(
        _prefs.getString('lyricTranslationApiUrl') ??
            defaultLyricTranslationApiUrl,
      );

      String? accJson = _prefs.getString('webdavAccounts');
      if (accJson != null)
        webdavAccounts = jsonDecode(accJson).cast<Map<String, dynamic>>();
    });

    _applyStatusBar();
    if (_prefs.getString('lyricTranslationApiUrl') != _lyricTranslationApiUrl) {
      unawaited(
        _prefs.setString('lyricTranslationApiUrl', _lyricTranslationApiUrl),
      );
    }
    unawaited(_configureDesktopLyrics());
    if (Platform.isAndroid) {
      // Delay until startup playback has settled; never block audio preparation.
      _updateCheckTimer = Timer(const Duration(seconds: 20), () {
        if (mounted) unawaited(_checkForUpdates());
      });
    }
    await _cleanupPartialCacheFiles();
    try {
      await _migrateLegacyCaches();
    } catch (error) {
      addLog('旧缓存迁移未完成，下次启动继续: $error');
    }
    await _updateCachedFilesList();

    _playbackSaveTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (isPlaying) unawaited(_savePlaybackState());
    });

    bool isFirstLaunch = _prefs.getBool('isFirstLaunch') ?? true;
    if (isFirstLaunch)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUiScaleDialog(firstLaunch: true);
      });

    // 启动其他应用：放在 autoPlay 之前，避免网络请求阻塞导致永远不执行
    if (_startOtherAppOnBoot && _bootOtherAppPackage.isNotEmpty) {
      addLog("📱 计划启动其他应用: $_bootOtherAppPackage (延迟 ${_bootOtherAppDelay}s)");
      Future.delayed(Duration(seconds: _bootOtherAppDelay), () {
        _launchAppByPackage(_bootOtherAppPackage);
      });
    }

    await _restoreLastSession();
    if (mounted) _scheduleCacheLimitCheck();
  }

  Map<String, dynamic>? _configuredAccountFromJson(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final saved = Map<String, dynamic>.from(jsonDecode(encoded));
      for (final account in webdavAccounts) {
        if (_sameAccount(account, saved)) return account;
      }
    } catch (e) {
      addLog('读取上次乐库失败: $e');
    }
    return null;
  }

  Future<void> _restoreRememberedPlaylist(Map<String, dynamic> account) async {
    final savedSongs =
        _prefs.getStringList(_accountSongListKey(account)) ?? <String>[];
    final cachedSongs = await _readCachedSongsForAccount(account);
    final rememberedSongs = <String>[...savedSongs];
    for (final song in cachedSongs) {
      if (!rememberedSongs.contains(song)) rememberedSongs.add(song);
    }
    if (!mounted || !_sameAccount(activeAccount, account)) return;
    setState(() {
      realNasSongs = rememberedSongs;
      _cachedFiles = cachedSongs.toSet();
      final syncTime = _prefs.getInt(
        '${_accountSongListKey(account)}_syncedAt',
      );
      _lastLibrarySync = syncTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(syncTime);
      _showingCachedSongsOnly = savedSongs.isEmpty && cachedSongs.isNotEmpty;
      if (_sameAccount(playingAccount, account) && _playbackQueue.isEmpty) {
        _setPlaybackLibrary(
          rememberedSongs,
          restoreOrder: true,
          anchor: _readPlaybackResume()?.song ?? '',
        );
      }
    });
  }

  PlaybackResumePoint? _readPlaybackResume() {
    final encoded = _prefs.getString(PlaybackResumePoint.preferenceKey);
    if (encoded != null) return PlaybackResumePoint.decode(encoded);
    final account = _configuredAccountFromJson(_prefs.getString('lastAccount'));
    final song = _prefs.getString('lastFileName');
    if (account == null || song == null || song.trim().isEmpty) return null;
    return PlaybackResumePoint(
      libraryCacheId(account),
      song,
      max(0, _prefs.getInt('lastPosition') ?? 0),
    );
  }

  Future<void> _restoreLastSession() async {
    final request = _playRequestId;
    final resume = _readPlaybackResume();
    Map<String, dynamic>? lastPlayingAccount;
    if (resume != null) {
      for (final library in webdavAccounts) {
        if (libraryCacheId(library) == resume.libraryId) {
          lastPlayingAccount = library;
          break;
        }
      }
    }
    final account =
        lastPlayingAccount ??
        _configuredAccountFromJson(_prefs.getString('lastActiveAccount')) ??
        (webdavAccounts.isEmpty ? null : webdavAccounts.first);
    if (account == null) return;

    activeAccount = account;
    playingAccount = account;
    bool isRestoring() =>
        mounted &&
        request == _playRequestId &&
        _sameAccount(activeAccount, account);
    await _restoreRememberedPlaylist(account);
    if (!isRestoring()) return;

    final lastSong = lastPlayingAccount == null ? null : resume;
    if (lastSong != null && !realNasSongs.contains(lastSong.song)) {
      setState(() => realNasSongs.insert(0, lastSong.song));
    }
    _setPlaybackLibrary(
      realNasSongs,
      restoreOrder: true,
      anchor: lastSong?.song,
    );
    if (lastSong != null) {
      final position = Duration(milliseconds: lastSong.positionMs);
      if (_autoPlay) {
        // Auto-play has one preparation path. Do not first display and
        // translate lyrics against a remembered position from disk.
        await playNasSong(
          lastSong.song,
          account: account,
          fromQueue: true,
          initialPosition: position,
        );
      } else {
        final song = lastSong.song;
        final metadata = _metadataForSong(song);
        final coverFuture = _readCachedCoverPath(song);
        final cachedLyric = await _readCachedLyric(song);
        final cachedCover = await coverFuture;
        if (!isRestoring()) return;
        setState(() {
          _rememberedPositionMs = lastSong.positionMs;
          _currentFileName = song;
          _currentPosition = position;
          currentPlayingSong = metadata.title;
          currentArtist = metadata.artist;
          currentCoverUrl = cachedCover ?? defaultCoverUrl;
          _currentLyricSource = cachedLyric == null
              ? ''
              : _savedLyricSource(song);
          _lyricOffset =
              _prefs.getDouble(_songPreferenceKey('lyricOffset', song)) ?? 0;
          _parseRawLrcText(cachedLyric ?? '[00:00.00]点击播放，继续上次的歌曲');
        });
        audioHandler.updateCurrentSong(
          currentPlayingSong,
          currentArtist,
          currentCoverUrl,
        );
        if (cachedCover != null) unawaited(_updatePalette(cachedCover));
      }
    }
    if (!mounted || !_sameAccount(activeAccount, account)) return;
    // 有历史列表时先保证起播，再刷新 WebDAV。
    if (realNasSongs.isEmpty) {
      unawaited(fetchSongsFromWebDav(silent: true));
    } else {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _sameAccount(activeAccount, account)) {
          unawaited(fetchSongsFromWebDav(silent: true));
        }
      });
    }
  }

  Future<void> _savePlaybackState() async {
    if (!_prefsReady ||
        _currentFileName.isEmpty ||
        _positionUpdatesForRequestId != _playRequestId) {
      return;
    }
    final account = playingAccount;
    if (account == null) return;
    // 已被同步删除的歌曲可以播完，但不能写回“上次播放”。
    final knownSongs = _prefs.getStringList(_accountSongListKey(account));
    if (knownSongs != null && !knownSongs.contains(_currentFileName)) return;
    _rememberedPositionMs = audioHandler.playbackPosition.inMilliseconds;
    final snapshot = PlaybackResumePoint(
      libraryCacheId(account),
      _currentFileName,
      _rememberedPositionMs,
    ).encode();
    if (_prefs.getString(PlaybackResumePoint.preferenceKey) != snapshot) {
      await _prefs.setString(PlaybackResumePoint.preferenceKey, snapshot);
    }
  }

  Future<void> _launchAppByPackage(String packageName) async {
    try {
      final result = await platform.invokeMethod('launchAppByPackage', {
        'packageName': packageName,
      });
      addLog("✅ 启动其他应用: $packageName (结果: $result)");
    } catch (e) {
      addLog("❌ 启动其他应用失败: $packageName ($e)");
    }
  }

  Future<void> _showAppPickerDialog() async {
    List<Map<String, dynamic>> apps = [];
    try {
      final List<dynamic> result = await platform.invokeMethod(
        'listInstalledApps',
      );
      apps = result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {}
    if (!mounted || apps.isEmpty) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.95),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(s(24)),
          ),
          title: Text(
            '\u9009\u62e9\u8981\u542f\u52a8\u7684\u5e94\u7528',
            style: TextStyle(fontSize: s(26), fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.6,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: apps.length,
              itemBuilder: (context, index) {
                final app = apps[index];
                final bool isSelected =
                    app['packageName'] == _bootOtherAppPackage;
                return ListTile(
                  leading: Icon(
                    Icons.android,
                    color: isSelected ? Colors.blueAccent : Colors.black54,
                    size: s(36),
                  ),
                  title: Text(
                    app['label'],
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  subtitle: Text(
                    app['packageName'],
                    style: TextStyle(fontSize: s(18)),
                  ),
                  selected: isSelected,
                  selectedTileColor: Colors.blueAccent.withOpacity(0.1),
                  trailing: isSelected
                      ? Icon(
                          Icons.check_circle,
                          color: Colors.blueAccent,
                          size: s(32),
                        )
                      : null,
                  onTap: () {
                    setState(() {
                      _bootOtherAppPackage = app['packageName'];
                      _bootOtherAppLabel = app['label'];
                    });
                    _prefs.setString(
                      'bootOtherAppPackage',
                      _bootOtherAppPackage,
                    );
                    _prefs.setString('bootOtherAppLabel', _bootOtherAppLabel);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _bootOtherAppPackage = '';
                  _bootOtherAppLabel = '';
                });
                _prefs.setString('bootOtherAppPackage', '');
                _prefs.setString('bootOtherAppLabel', '');
                Navigator.pop(context);
              },
              child: Text(
                '\u6e05\u9664\u9009\u62e9',
                style: TextStyle(fontSize: s(22), color: Colors.redAccent),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('\u5173\u95ed', style: TextStyle(fontSize: s(22))),
            ),
          ],
        );
      },
    );
  }

  void _showUiScaleDialog({required bool firstLaunch}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white.withOpacity(0.95),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  firstLaunch ? '🎉 欢迎使用 NAS Car Player' : '调整界面缩放',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '拖动滑块，界面会实时缩放。',
                      style: TextStyle(fontSize: 16, color: Colors.black87),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        children: [
                          Text(
                            "全局缩放: ",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 22,
                              color: Colors.black87,
                            ),
                          ),
                          SizedBox(
                            width: 250,
                            child: Slider(
                              value: _uiScale,
                              min: 0.4,
                              max: 2.5,
                              divisions: 21,
                              activeColor: Colors.blueAccent,
                              onChanged: (val) {
                                setDialogState(() {
                                  _uiScale = val;
                                });
                                setState(() {
                                  _uiScale = val;
                                });
                              },
                            ),
                          ),
                          SizedBox(
                            width: 65,
                            child: Text(
                              "${_uiScale.toStringAsFixed(1)}x",
                              style: TextStyle(
                                fontSize: 20,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 10,
                        ),
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        _prefs.setDouble('uiScale', _uiScale);
                        if (firstLaunch) _prefs.setBool('isFirstLaunch', false);
                        unawaited(_configureDesktopLyrics());
                        Navigator.pop(context);
                      },
                      child: Text(
                        firstLaunch ? '调整好了，进入车机！' : '保存缩放',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _applyStatusBar() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: _showStatusBar
          ? SystemUiOverlay.values
          : [SystemUiOverlay.bottom],
    );
  }

  void _initClock() {
    void updateClock() {
      final now = DateTime.now();
      final value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
      if (!mounted || value == _currentTimeString) return;
      _currentTimeString = value;
      _clockText.value = value;
    }

    updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      updateClock();
      if (_isAppForeground) _syncPlaybackPosition();
    });
  }

  void _resetScreenSaverTimer() {
    _screenSaverTimer?.cancel();
    if (currentLeftScreen != 2 || _isLargeMode || _screenSaverTimeout == 0) {
      addLog(
        "⏱️ 屏保定时器跳过: screen=$currentLeftScreen, large=$_isLargeMode, timeout=$_screenSaverTimeout",
      );
      return;
    }
    addLog("⏱️ 屏保定时器启动: ${_screenSaverTimeout}s后进入大屏");
    _screenSaverTimer = Timer(Duration(seconds: _screenSaverTimeout), () {
      if (mounted && currentLeftScreen == 2) {
        addLog("⏱️ 屏保定时器触发: 进入大屏模式");
        setState(() => _isLargeMode = true);
        _recenterLyricsForLayout();
      }
    });
  }

  bool _isAudioFileName(String fileName) => RegExp(
    r'\.(mp3|flac|wav|m4a|aac)$',
    caseSensitive: false,
  ).hasMatch(fileName);

  String _buildWebDavFileUrl(String baseUrl, String fileName) {
    final normalizedBase = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return '$normalizedBase${Uri.encodeComponent(fileName)}';
  }

  ({String title, String artist}) _parseSongMetadata(String songName) {
    return parseSongFileName(songName);
  }

  ({String title, String artist}) _metadataForSong(String songName) {
    final saved = _prefs.getString(
      _songPreferenceKey('songMetadata', songName),
    );
    if (saved != null) {
      try {
        final data = jsonDecode(saved);
        final title = data['title']?.toString().trim() ?? '';
        final artist = data['artist']?.toString().trim() ?? '';
        if (title.isNotEmpty && artist.isNotEmpty)
          return (title: title, artist: artist);
      } catch (_) {}
    }
    return _parseSongMetadata(songName);
  }

  String _cacheAssetKey(String songName) =>
      base64UrlEncode(utf8.encode(songName)).replaceAll('=', '');

  String _accountSongListKey(Map<String, dynamic> account) {
    final identity = '${account['url'] ?? ''}|${account['user'] ?? ''}';
    return 'cachedSongList_${_cacheAssetKey(identity)}';
  }

  bool _sameAccount(Map<String, dynamic>? a, Map<String, dynamic>? b) =>
      a != null && b != null && a['url'] == b['url'] && a['user'] == b['user'];

  Future<List<String>> _readCachedSongsForAccount(
    Map<String, dynamic> account,
  ) async {
    final allCachedSongs = await runInLibrary(account, _readCachedSongNames);
    final saved = _prefs.getStringList(_accountSongListKey(account));
    if (saved == null) return allCachedSongs;
    final knownSongs = saved.toSet();
    return allCachedSongs.where(knownSongs.contains).toList();
  }

  Future<void> _cleanupPartialCacheFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/nas_cache');
      if (!await cacheDir.exists()) return;
      await for (final entity in cacheDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.part'))
          await entity.delete();
      }
    } catch (e) {
      addLog('清理未完成缓存失败: $e');
    }
  }

  int _songAssetGeneration(String songName) =>
      _songAssetGenerations[_songTaskKey(songName)] ?? 0;

  bool _isCurrentAssetGeneration(String songName, int generation) =>
      _songAssetGeneration(songName) == generation;

  void _invalidateSongAssets(String songName) {
    _songAssetGenerations[_songTaskKey(songName)] =
        _songAssetGeneration(songName) + 1;
  }

  Future<File> _lyricCacheFile(
    String songName, {
    bool createDirectory = true,
  }) async {
    final dir = await _audioCacheDirectory(create: createDirectory);
    if (dir == null) throw const FileSystemException('未选择乐库');
    final lyricDir = Directory('${dir.path}/lyrics');
    if (createDirectory && !await lyricDir.exists()) {
      await lyricDir.create(recursive: true);
    }
    return File('${lyricDir.path}/${_cacheAssetKey(songName)}.lrc');
  }

  Future<String> _convertLyricToSimplified(String lyric) async {
    if (lyric.trim().isEmpty) return lyric;
    try {
      return await ChineseConverter.convert(lyric, T2S(), inBackground: true);
    } catch (e) {
      addLog('歌词繁体转简体失败，保留原文: $e');
      return lyric;
    }
  }

  final Map<String, Map<String, String>> _lyricLineCache = {};

  Future<Map<String, String>> _loadLyricLineCache(String songName) async {
    final key = _songTaskKey(songName);
    if (_lyricLineCache.containsKey(key)) return _lyricLineCache[key]!;
    final result = <String, String>{};
    try {
      final lyricFile = await _lyricCacheFile(songName, createDirectory: false);
      final file = File('${lyricFile.path}.translations.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map &&
            data['schema_version'] == 3 &&
            data['lines'] is Map) {
          for (final entry in (data['lines'] as Map).entries) {
            if (entry.key is String &&
                entry.value is String &&
                RegExp(r'[\u3400-\u9FFF]').hasMatch(entry.value)) {
              result[entry.key as String] = entry.value as String;
            }
          }
        }
      }
    } catch (error) {
      addLog('读取逐行翻译缓存失败: $error');
    }
    _lyricLineCache[key] = result;
    if (_lyricLineCache.length > 16)
      _lyricLineCache.remove(_lyricLineCache.keys.first);
    return result;
  }

  final Map<String, Future<void>> _lyricLineWriteTasks = {};

  Future<void> _saveLyricLineCache(
    String songName,
    Map<String, String> lines,
    bool Function() isCurrent,
  ) async {
    final key = _songTaskKey(songName);
    final previous = _lyricLineWriteTasks[key];
    final task = Future<void>(() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      if (!isCurrent()) return;
      final lyricFile = await _lyricCacheFile(songName);
      if (!isCurrent()) return;
      final file = File('${lyricFile.path}.translations.json');
      final temp = File('${file.path}.part');
      try {
        await temp.writeAsString(
          jsonEncode({'schema_version': 3, 'lines': lines}),
          flush: true,
        );
        if (!isCurrent()) return;
        if (await file.exists()) await file.delete();
        if (!isCurrent()) return;
        await temp.rename(file.path);
        _scheduleCacheLimitCheck();
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    });
    _lyricLineWriteTasks[key] = task;
    try {
      await task;
    } finally {
      if (identical(_lyricLineWriteTasks[key], task))
        _lyricLineWriteTasks.remove(key);
    }
  }

  Future<void> _translateEnglishLyrics(
    String songName,
    String lyrics, {
    required bool Function() isCurrent,
    required Future<void> Function() onProgress,
    bool reportDetection = false,
  }) async {
    final cached = await _loadLyricLineCache(songName);
    if (!isCurrent()) return;
    final missing = missingLyricTranslationLines(
      lyrics,
      cached,
    ).entries.toList();
    if (missing.isEmpty) {
      if (reportDetection) {
        addLog('新歌词已自动检查：译文已齐全，或没有需要翻译的英文行');
      }
      return;
    }
    if (_lyricTranslationApiUrl.trim().isEmpty) return;
    if (reportDetection) {
      addLog('新歌词已识别到 ${missing.length} 行缺失译文，开始自动翻译');
    }
    final metadata = _metadataForSong(songName);
    String? deviceId = _songSelections?.deviceId;
    if (deviceId == null && Platform.isAndroid) {
      try {
        deviceId = await readSongSelectionDeviceId();
      } catch (_) {
        // Legacy fallback is still subject to the server's daily IP limit.
      }
    }
    for (var start = 0; start < missing.length; start += 24) {
      if (!isCurrent()) return;
      final batch = Map<String, String>.fromEntries(
        missing.skip(start).take(24),
      );
      try {
        final response = await _externalDio.postUri(
          parseLyricTranslationApiUrl(_lyricTranslationApiUrl),
          data: {
            'title': metadata.title,
            'artist': metadata.artist == '私人乐库' ? '' : metadata.artist,
            if (deviceId != null) 'device_id': deviceId,
            'lyrics': batch.values.toList(),
          },
          options: Options(
            contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 90),
          ),
        );
        final data = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        final translated = validateLyricLineTranslations(data, batch);
        if (!isCurrent()) return;
        cached.addAll(translated);
        await _saveLyricLineCache(songName, cached, isCurrent);
        if (!isCurrent()) return;
        await onProgress();
        addLog('逐行歌词翻译已保存: ${translated.length} 行 / $songName');
      } catch (error) {
        if (isCurrent()) {
          final reason = _externalErrorText(error);
          addLog('部分歌词翻译暂不可用，保留已有译文: $reason');
          _showPlaybackMessage(
            error is DioException && error.response?.statusCode == 429
                ? reason
                : reason.contains('not available in your region')
                ? '翻译模型受地区限制，请配置服务端中转或代理'
                : '部分歌词翻译失败，可在歌词选择中重试翻译',
          );
        }
        return;
      }
    }
  }

  String _externalErrorText(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      var data = error.response?.data;
      if (data is List<int>) {
        data = utf8.decode(data.take(4096).toList(), allowMalformed: true);
      }
      String? message;
      if (data is Map && data['error'] != null) {
        message = data['error'].toString();
      } else if (data is String && data.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map && decoded['error'] != null) {
            message = decoded['error'].toString();
          }
        } catch (_) {
          message = data.trim();
        }
      }
      if (message != null && message.isNotEmpty) {
        return '${status == null ? '' : 'HTTP $status: '}$message';
      }
      return status == null
          ? (error.message ?? error.toString())
          : 'HTTP $status: ${error.message ?? '请求失败'}';
    }
    return error.toString();
  }

  void _scheduleEnglishLyricTranslation(
    String songName,
    String lyrics, {
    int? expectedGeneration,
    int? expectedLyricRevision,
    bool reportDetection = false,
  }) {
    final revision = expectedLyricRevision ?? _lyricChoiceRevision;
    if (revision != _lyricChoiceRevision) return;
    final request = _playRequestId;
    final key = _songTaskKey(songName);
    final taskKey = '$key:$revision:${sha256.convert(utf8.encode(lyrics))}';
    _latestLyricsForTranslation[key] = taskKey;
    if (_lyricTranslationTasks.containsKey(taskKey)) return;
    bool isCurrent() =>
        mounted &&
        _currentFileName == songName &&
        request == _playRequestId &&
        revision == _lyricChoiceRevision &&
        _latestLyricsForTranslation[key] == taskKey &&
        (expectedGeneration == null ||
            _isCurrentAssetGeneration(songName, expectedGeneration));
    // 下一事件循环再开始，先完成原歌词显示，缓存命中也不会抢先覆盖歌词来源。
    final task = Future<void>(() async {
      if (!isCurrent()) return;
      await _translateEnglishLyrics(
        songName,
        lyrics,
        isCurrent: isCurrent,
        reportDetection: reportDetection,
        onProgress: () async {
          if (isCurrent())
            _showLyricsForSong(
              songName,
              lyrics,
              expectedGeneration: expectedGeneration,
            );
        },
      );
    });
    _lyricTranslationTasks[taskKey] = task;
    unawaited(
      task
          .catchError((Object error) {
            addLog('逐行歌词翻译失败: $error');
          })
          .whenComplete(() {
            _lyricTranslationTasks.remove(taskKey);
          }),
    );
  }

  Future<bool> _writeCachedLyric(
    String songName,
    String lyric, {
    int? expectedGeneration,
    int? expectedLyricRevision,
  }) async {
    if (lyric.trim().isEmpty) return false;
    bool isCurrentWrite() =>
        (expectedGeneration == null ||
            _isCurrentAssetGeneration(songName, expectedGeneration)) &&
        (expectedLyricRevision == null ||
            expectedLyricRevision == _lyricChoiceRevision);
    final previousWrite = _lyricWriteTasks[_songTaskKey(songName)];
    final task = () async {
      if (previousWrite != null) await previousWrite;
      if (!isCurrentWrite()) return false;
      File? tempFile;
      try {
        final file = await _lyricCacheFile(songName);
        tempFile = File('${file.path}.part');
        if (await tempFile.exists()) await tempFile.delete();
        await tempFile.writeAsString(lyric, flush: true);
        if (!isCurrentWrite()) {
          await tempFile.delete();
          return false;
        }
        await tempFile.rename(file.path);
        _scheduleCacheLimitCheck();
        return true;
      } catch (e) {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
        addLog('保存歌词缓存失败: $e');
        return false;
      }
    }();
    _lyricWriteTasks[_songTaskKey(songName)] = task;
    try {
      return await task;
    } finally {
      if (identical(_lyricWriteTasks[_songTaskKey(songName)], task)) {
        _lyricWriteTasks.remove(_songTaskKey(songName));
      }
    }
  }

  Future<String?> _readCachedLyric(
    String songName, {
    int? expectedGeneration,
  }) async {
    final lyricRevision = _lyricChoiceRevision;
    try {
      final file = await _lyricCacheFile(songName);
      if (await file.exists() && await file.length() > 0) {
        final original = await file.readAsString();
        final simplified = await _convertLyricToSimplified(original);
        if (simplified != original &&
            (expectedGeneration == null ||
                _isCurrentAssetGeneration(songName, expectedGeneration))) {
          await _writeCachedLyric(
            songName,
            simplified,
            expectedGeneration: expectedGeneration,
            expectedLyricRevision: lyricRevision,
          );
          addLog('已更新旧歌词缓存格式: $songName');
        }
        _scheduleEnglishLyricTranslation(
          songName,
          simplified,
          expectedGeneration: expectedGeneration,
          expectedLyricRevision: lyricRevision,
        );
        final cached = await _loadLyricLineCache(songName);
        return composeLineTranslatedLrc(simplified, cached);
      }
    } catch (e) {
      addLog('读取歌词缓存失败: $e');
    }
    return null;
  }

  Future<String> _saveCachedLyric(
    String songName,
    String lyric, {
    int? expectedGeneration,
    int? expectedLyricRevision,
    bool scheduleTranslation = true,
  }) async {
    final simplified = await _convertLyricToSimplified(lyric);
    final saved = await _writeCachedLyric(
      songName,
      simplified,
      expectedGeneration: expectedGeneration,
      expectedLyricRevision: expectedLyricRevision,
    );
    if (saved &&
        (expectedLyricRevision == null ||
            expectedLyricRevision == _lyricChoiceRevision)) {
      // 换了歌词来源后，旧来源的微调基准不再适用。
      final file = await _lyricCacheFile(songName);
      final originalFile = File('${file.path}.original');
      if (await originalFile.exists()) await originalFile.delete();
      await _prefs.remove(_songPreferenceKey('lyricFileShift', songName));
      if (scheduleTranslation) {
        _scheduleEnglishLyricTranslation(
          songName,
          simplified,
          expectedGeneration: expectedGeneration,
          expectedLyricRevision: expectedLyricRevision,
        );
      }
    }
    final cached = await _loadLyricLineCache(songName);
    return composeLineTranslatedLrc(simplified, cached);
  }

  String _savedLyricSource(String songName) =>
      _prefs.getString(_songPreferenceKey('lyricSource', songName)) ?? '本地歌词缓存';

  Map<String, dynamic> _selectionSong(String songName, {Duration? duration}) {
    final metadata = _metadataForSong(songName);
    return {
      'title': metadata.title,
      'artist': metadata.artist == '私人乐库' ? '' : metadata.artist,
      'duration': (duration ?? _totalDuration).inMilliseconds / 1000.0,
    };
  }

  Future<void> _queueSongSelection(
    String songName,
    Map<String, dynamic> song,
    String kind,
    Map<String, dynamic> choice,
  ) async {
    final client = _songSelections;
    if (client == null) return;
    try {
      final revision = await client.enqueue(song, kind, choice);
      if (revision != null &&
          kind == 'lyrics' &&
          (_prefs.getInt(_songPreferenceKey('lyricCandidateId', songName)) ??
                  0) ==
              (choice['candidate_id'] ?? 0)) {
        await _prefs.setString(
          _songPreferenceKey('serverLyricRevision', songName),
          revision,
        );
      } else if (revision != null && kind == 'cover') {
        final key = _songPreferenceKey('coverSelection', songName);
        final saved = jsonDecode(_prefs.getString(key) ?? '{}');
        if (saved is Map && saved['id'] == choice['id']) {
          await _prefs.setString(
            key,
            jsonEncode({
              ...Map<String, dynamic>.from(saved),
              'server_revision': revision,
            }),
          );
        }
      }
    } catch (error) {
      addLog('歌曲选择待同步保存失败: $error');
    }
  }

  Future<({bool lyrics, String? cover})> _restoreServerSelections(
    String songName,
    Map<String, dynamic> song,
    bool hasLyrics,
    String? coverPath,
    int generation,
    int lyricRevision,
    int coverRevision,
    bool Function() isCurrent,
  ) async {
    final client = _songSelections;
    if (client == null) return (lyrics: hasLyrics, cover: coverPath);
    try {
      // Retry explicit manual submissions only; cached assets are never uploaded.
      unawaited(client.flush());
      if (!isCurrent()) return (lyrics: hasLyrics, cover: coverPath);
      final selected = await client.lookup(song);
      if (selected == null || !isCurrent())
        return (lyrics: hasLyrics, cover: coverPath);
      final lyric = selected['lyrics'];
      final localTimeAdjusted =
          hasLyrics &&
          (_lyricOffset != 0 ||
              (_prefs.getDouble(
                        _songPreferenceKey('lyricFileShift', songName),
                      ) ??
                      0) !=
                  0);
      if (lyric is Map &&
          lyric['text'] is String &&
          lyric['revision'] is String &&
          !(localTimeAdjusted && lyric['selection_scope'] == 'community') &&
          !client.hasPending(song, 'lyrics') &&
          lyricRevision == _lyricChoiceRevision &&
          (!hasLyrics ||
              _prefs.getString(
                    _songPreferenceKey('serverLyricRevision', songName),
                  ) !=
                  lyric['revision'])) {
        // Invalidate cache reads/translation jobs started against the old text.
        final appliedRevision = ++_lyricChoiceRevision;
        final text = await _saveCachedLyric(
          songName,
          lyric['text'],
          expectedGeneration: generation,
          expectedLyricRevision: appliedRevision,
          scheduleTranslation: false,
        );
        if (!isCurrent() || appliedRevision != _lyricChoiceRevision) {
          return (lyrics: hasLyrics, cover: coverPath);
        }
        await _rememberLyricSource(
          songName,
          '服务端已选歌词',
          manuallySelected: true,
          candidateId: lyric['candidate_id'] is int
              ? lyric['candidate_id']
              : null,
          expectedGeneration: generation,
          expectedLyricRevision: appliedRevision,
        );
        if (!isCurrent() || appliedRevision != _lyricChoiceRevision) {
          return (lyrics: hasLyrics, cover: coverPath);
        }
        await _prefs.setString(
          _songPreferenceKey('serverLyricRevision', songName),
          lyric['revision'],
        );
        if (!isCurrent() || appliedRevision != _lyricChoiceRevision) {
          return (lyrics: hasLyrics, cover: coverPath);
        }
        setState(() => _currentLyricSource = '服务端已选歌词');
        _showLyricsForSong(songName, text, expectedGeneration: generation);
        _scheduleEnglishLyricTranslation(
          songName,
          text,
          expectedGeneration: generation,
          expectedLyricRevision: appliedRevision,
        );
        hasLyrics = true;
        addLog('已复用服务端所选歌词: $songName');
      }
      final cover = selected['cover'];
      final localCover = jsonDecode(
        _prefs.getString(_songPreferenceKey('coverSelection', songName)) ??
            '{}',
      );
      if (cover is Map &&
          cover['revision'] is String &&
          !client.hasPending(song, 'cover') &&
          isCurrent() &&
          coverRevision == _coverChoiceRevision &&
          (coverPath == null ||
              localCover is! Map ||
              localCover['server_revision'] != cover['revision'])) {
        final path = await _downloadAndCacheCover(
          songName,
          client.imageUri(song, cover['revision']).toString(),
          _externalDio,
          expectedGeneration: generation,
          expectedCoverRevision: coverRevision,
        );
        if (path != null &&
            isCurrent() &&
            coverRevision == _coverChoiceRevision) {
          await _prefs.setString(
            _songPreferenceKey('coverSelection', songName),
            jsonEncode({
              ...Map<String, dynamic>.from(cover),
              'server_revision': cover['revision'],
            }),
          );
          if (isCurrent() && coverRevision == _coverChoiceRevision) {
            coverPath = path;
            setState(() => currentCoverUrl = path);
            audioHandler.updateCurrentSong(
              currentPlayingSong,
              currentArtist,
              path,
            );
            unawaited(_updatePalette(path));
            addLog('已复用服务端所选封面: $songName');
          }
        }
      }
    } catch (error) {
      addLog('恢复服务端选择失败，继续原缓存流程: $error');
    }
    return (lyrics: hasLyrics, cover: coverPath);
  }

  Future<void> _rememberLyricSource(
    String songName,
    String source, {
    required bool manuallySelected,
    int? candidateId,
    int? expectedGeneration,
    int? expectedLyricRevision,
  }) async {
    bool isCurrentSource() =>
        (expectedGeneration == null ||
            _isCurrentAssetGeneration(songName, expectedGeneration)) &&
        (expectedLyricRevision == null ||
            expectedLyricRevision == _lyricChoiceRevision);
    if (!isCurrentSource()) return;
    await _prefs.setString(_songPreferenceKey('lyricSource', songName), source);
    if (!isCurrentSource()) return;
    await _prefs.setBool(
      _songPreferenceKey('manualLyric', songName),
      manuallySelected,
    );
    if (!isCurrentSource()) return;
    if (candidateId != null && candidateId > 0) {
      await _prefs.setInt(
        _songPreferenceKey('lyricCandidateId', songName),
        candidateId,
      );
    } else {
      await _prefs.remove(_songPreferenceKey('lyricCandidateId', songName));
    }
  }

  Future<File> _coverCacheFile(
    String songName, {
    bool createDirectory = true,
  }) async {
    final dir = await _audioCacheDirectory(create: createDirectory);
    if (dir == null) throw const FileSystemException('未选择乐库');
    final coverDir = Directory('${dir.path}/covers');
    if (createDirectory && !await coverDir.exists()) {
      await coverDir.create(recursive: true);
    }
    return File('${coverDir.path}/${_cacheAssetKey(songName)}.jpg');
  }

  Future<String?> _readCachedCoverPath(String songName) async {
    try {
      final file = await _coverCacheFile(songName);
      if (!await file.exists()) return null;
      if (await _isSupportedCoverFile(file)) return file.path;
      await _coverImageProvider(file.path).evict();
      await file.delete();
      _bumpCoverImageRevision(file.path);
      addLog('发现无效封面缓存，准备重新获取: $songName');
    } catch (e) {
      addLog('读取封面缓存失败: $e');
    }
    return null;
  }

  Future<bool> _isSupportedCoverFile(File file) async {
    if (await file.length() < 12) return false;
    final header = await file.openRead(0, 16).first;
    return isSupportedCoverImageHeader(header);
  }

  void _bumpCoverImageRevision(String path) {
    _coverImageRevisions[path] = (_coverImageRevisions[path] ?? 0) + 1;
    _reportedCoverImageErrors.removeWhere((key) => key.startsWith('$path:'));
  }

  void _reportCoverImageError(
    String source,
    Object error, {
    required int revision,
  }) {
    if ((_coverImageRevisions[source] ?? 0) != revision) return;
    final key = '$source:$revision';
    if (_reportedCoverImageErrors.add(key)) {
      addLog('封面图片解码失败: $error');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && currentCoverUrl == source) setState(() {});
      });
    }
  }

  Future<String?> _downloadAndCacheCover(
    String songName,
    String coverUrl,
    Dio dio, {
    bool logFailure = true,
    int? expectedGeneration,
    int? expectedCoverRevision,
  }) async {
    final revision =
        expectedCoverRevision ??
        Zone.current[_coverTaskZone] as int? ??
        _coverChoiceRevision;
    bool isCurrentCover() =>
        mounted &&
        revision == _coverChoiceRevision &&
        (expectedGeneration == null ||
            _isCurrentAssetGeneration(songName, expectedGeneration));
    if (!isCurrentCover()) {
      return null;
    }
    final file = await _coverCacheFile(songName);
    final tempFile = File(
      '${file.path}.$revision.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      if (await tempFile.exists()) await tempFile.delete();
      await dio.download(coverUrl, tempFile.path);
      if (!await _isSupportedCoverFile(tempFile)) {
        throw const FileSystemException('下载内容不是受支持的图片');
      }
      if (!isCurrentCover()) {
        await tempFile.delete();
        return null;
      }
      final previous = _coverWriteTasks[file.path];
      final commit = Future<String?>(() async {
        if (previous != null) {
          try {
            await previous;
          } catch (_) {}
        }
        if (!isCurrentCover()) return null;
        if (await file.exists()) {
          await _coverImageProvider(file.path).evict();
          if (!isCurrentCover()) return null;
          await file.delete();
        }
        if (!isCurrentCover()) return null;
        await tempFile.rename(file.path);
        if (!isCurrentCover()) {
          if (await file.exists()) await file.delete();
          return null;
        }
        _bumpCoverImageRevision(file.path);
        _coverThemeCache.remove(file.path);
        if (_prefsReady)
          await _prefs.remove(_coverThemePreferenceKey(file.path));
        _scheduleCacheLimitCheck();
        return file.path;
      });
      _coverWriteTasks[file.path] = commit;
      try {
        return await commit;
      } finally {
        if (identical(_coverWriteTasks[file.path], commit))
          _coverWriteTasks.remove(file.path);
        if (await tempFile.exists()) await tempFile.delete();
      }
    } catch (e) {
      if (await tempFile.exists()) await tempFile.delete();
      if (logFailure) addLog('封面缓存失败: $e');
      return null;
    }
  }

  ImageProvider _coverImageProvider(String source) => source.startsWith('http')
      ? NetworkImage(source)
      : VersionedFileImage(File(source), _coverImageRevisions[source] ?? 0);

  Widget _buildSongDisc({
    required double diameter,
    required double holeDiameter,
    required bool rotateWithPlayback,
  }) {
    final coverSource = currentCoverUrl;
    final coverRevision = _coverImageRevisions[coverSource] ?? 0;
    final coverErrorKey = '$coverSource:$coverRevision';
    final showTextCover =
        coverSource.isEmpty ||
        _reportedCoverImageErrors.contains(coverErrorKey);
    final identity = '$currentPlayingSong|$currentArtist';
    var colorSeed = 2166136261;
    for (final codeUnit in identity.codeUnits) {
      colorSeed = ((colorSeed ^ codeUnit) * 16777619) & 0xFFFFFFFF;
    }
    final hue = (colorSeed % 360).toDouble();
    final darkColor = HSLColor.fromAHSL(1, hue, 0.50, 0.18).toColor();
    final lightColor = HSLColor.fromAHSL(
      1,
      (hue + 28) % 360,
      0.58,
      0.28,
    ).toColor();

    return GestureDetector(
      onLongPress: _showCoverSelectionDialog,
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          children: [
            RotationTransition(
              turns: rotateWithPlayback
                  ? _spinController
                  : const AlwaysStoppedAnimation<double>(0),
              child: RepaintBoundary(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 450),
                  width: diameter,
                  height: diameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [darkColor, lightColor],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: s(22),
                        offset: Offset(0, s(9)),
                      ),
                    ],
                    image: showTextCover
                        ? null
                        : DecorationImage(
                            image: ResizeImage(
                              _coverImageProvider(coverSource),
                              width: coverDecodeSize(
                                diameter,
                                MediaQuery.devicePixelRatioOf(context),
                              ),
                              height: coverDecodeSize(
                                diameter,
                                MediaQuery.devicePixelRatioOf(context),
                              ),
                              policy: ResizeImagePolicy.fit,
                            ),
                            fit: BoxFit.cover,
                            onError: (error, _) => _reportCoverImageError(
                              coverSource,
                              error,
                              revision: coverRevision,
                            ),
                          ),
                  ),
                  child: Center(
                    child: Container(
                      width: holeDiameter,
                      height: holeDiameter,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.82),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (showTextCover && _currentFileName.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: Stack(
                      children: [
                        Positioned(
                          top: diameter * 0.10,
                          left: diameter * 0.15,
                          right: diameter * 0.15,
                          height: diameter * 0.27,
                          child: Center(
                            child: Text(
                              currentPlayingSong,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: diameter * 0.105,
                                fontWeight: FontWeight.bold,
                                height: 1.1,
                                shadows: const [
                                  Shadow(color: Colors.black38, blurRadius: 4),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: diameter * 0.10,
                          left: diameter * 0.18,
                          right: diameter * 0.18,
                          height: diameter * 0.17,
                          child: Center(
                            child: Text(
                              currentArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: diameter * 0.075,
                                fontWeight: FontWeight.w500,
                                shadows: const [
                                  Shadow(color: Colors.black38, blurRadius: 3),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showLyricsForSong(
    String songName,
    String lyric, {
    int? expectedGeneration,
  }) {
    if (!mounted ||
        _currentFileName != songName ||
        (expectedGeneration != null &&
            !_isCurrentAssetGeneration(songName, expectedGeneration))) {
      return;
    }
    final lines = mergeLyricTranslations(
      parseLrcText(lyric),
      _lyricLineCache[_songTaskKey(songName)] ?? {},
    );
    // Compose only for change detection/desktop payload, never parse the
    // generated bilingual text again to decide its original timestamps.
    final displayed = buildBilingualLrc(lines, List.filled(lines.length, ''));
    setState(() => _parseRawLrcText(displayed, timeline: lines));
  }

  Future<List<String>> _readCachedSongNames() async {
    final cacheDir = await _audioCacheDirectory(create: false);
    if (cacheDir == null || !await cacheDir.exists()) return [];

    final songs = <String>[];
    await for (final entity in cacheDir.list()) {
      if (entity is! File) continue;
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (_isAudioFileName(fileName) &&
          await entity.length() > 0 &&
          !await File('${entity.path}.invalid').exists())
        songs.add(fileName);
    }
    songs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return songs;
  }

  Future<void> _updateCachedFilesList() async {
    try {
      final account = activeAccount;
      if (account == null) return;
      final cachedSongs = await runInLibrary(account, _readCachedSongNames);
      if (mounted && _sameAccount(activeAccount, account)) {
        setState(() => _cachedFiles = cachedSongs.toSet());
      }
    } catch (_) {}
  }

  Future<bool> _deleteCacheFile(
    String fileName, {
    bool refreshFiles = true,
    bool updatePresentation = true,
    Map<String, dynamic>? account,
  }) {
    final owner =
        account ?? currentLibraryTask ?? activeAccount ?? playingAccount;
    if (owner == null) return Future.value(false);
    return runInLibrary(
      owner,
      () => _deleteCacheFileInternal(
        fileName,
        refreshFiles: refreshFiles,
        updatePresentation: updatePresentation,
      ),
    );
  }

  Future<bool> _deleteCacheFileInternal(
    String fileName, {
    bool refreshFiles = true,
    bool updatePresentation = true,
  }) async {
    if (!isSafeSongCacheName(fileName)) return false;
    _invalidateSongAssets(fileName);
    final isCurrentSong =
        _currentFileName == fileName &&
        _sameAccount(playingAccount, _cacheAccount);
    if (isCurrentSong) {
      _coverChoiceRevision++;
      _lyricChoiceRevision++;
      _latestLyricsForTranslation.remove(_songTaskKey(fileName));
      _cacheDownloadTimer?.cancel();
      _cacheDownloadTimer = null;
    }
    _downloadCancelTokens[_songTaskKey(fileName)]?.cancel('用户清除了歌曲缓存');

    try {
      final cacheDir = await _audioCacheDirectory(create: false);
      if (cacheDir != null) {
        final file = File('${cacheDir.path}/$fileName');
        final partialFile = File('${file.path}.part');
        if (await file.exists()) await file.delete();
        if (await partialFile.exists()) await partialFile.delete();
        for (final suffix in ['.meta.json', '.invalid']) {
          final companion = File('${file.path}$suffix');
          if (await companion.exists()) await companion.delete();
        }
      }
      await _deleteCompanionCache(fileName);
      if (refreshFiles) await _updateCachedFilesList();
      if (mounted && updatePresentation) {
        setState(() {
          if (_showingCachedSongsOnly &&
              _sameAccount(activeAccount, _cacheAccount)) {
            realNasSongs = realNasSongs
                .where((song) => song != fileName)
                .toList();
          }
          if (isCurrentSong) {
            currentCoverUrl = defaultCoverUrl;
            _currentLyricSource = '';
            _lyricCandidates = [];
            _isRefreshingLyrics = false;
            _parseRawLrcText('[00:00.00]歌词缓存已清除，重新播放后将重新获取');
          }
        });
        if (isCurrentSong) {
          unawaited(_updatePalette(defaultCoverUrl));
          audioHandler.updateCurrentSong(
            currentPlayingSong,
            currentArtist,
            defaultCoverUrl,
          );
        }
      }
      addLog('已清除音频、歌词和封面缓存: $fileName');
      return true;
    } catch (e) {
      addLog('清除歌曲缓存失败: $fileName ($e)');
      return false;
    }
  }

  Future<void> _deleteCompanionCache(String fileName) async {
    _latestLyricsForTranslation.remove(_songTaskKey(fileName));
    _lyricLineCache.remove(_songTaskKey(fileName));
    final pendingLineWrite = _lyricLineWriteTasks[_songTaskKey(fileName)];
    if (pendingLineWrite != null) {
      try {
        await pendingLineWrite;
      } catch (_) {}
    }
    final pendingLyricWrite = _lyricWriteTasks[_songTaskKey(fileName)];
    if (pendingLyricWrite != null) await pendingLyricWrite;
    final lyricFile = await _lyricCacheFile(fileName, createDirectory: false);
    final partialLyricFile = File('${lyricFile.path}.part');
    final translationFile = File('${lyricFile.path}.translations.json');
    final translationPart = File('${translationFile.path}.part');
    if (await translationFile.exists()) await translationFile.delete();
    if (await translationPart.exists()) await translationPart.delete();
    final originalLyricFile = File('${lyricFile.path}.original');
    if (await lyricFile.exists()) await lyricFile.delete();
    if (await partialLyricFile.exists()) await partialLyricFile.delete();
    if (await originalLyricFile.exists()) await originalLyricFile.delete();
    final coverFile = await _coverCacheFile(fileName, createDirectory: false);
    final pendingCoverWrite = _coverWriteTasks[coverFile.path];
    if (pendingCoverWrite != null) {
      try {
        await pendingCoverWrite;
      } catch (_) {}
    }
    final partialCoverFile = File('${coverFile.path}.part');
    _coverThemeCache.remove(coverFile.path);
    if (_prefsReady) {
      await _prefs.remove(_coverThemePreferenceKey(coverFile.path));
    }
    if (await coverFile.exists()) {
      await _coverImageProvider(coverFile.path).evict();
      await coverFile.delete();
      _bumpCoverImageRevision(coverFile.path);
    }
    if (await partialCoverFile.exists()) await partialCoverFile.delete();
    if (await coverFile.parent.exists()) {
      final basename = coverFile.uri.pathSegments.last;
      await for (final item in coverFile.parent.list()) {
        if (item is File &&
            item.uri.pathSegments.last.startsWith('$basename.') &&
            item.path.endsWith('.part')) {
          await item.delete();
        }
      }
    }
    if (_prefsReady) {
      await _prefs.remove(_songPreferenceKey('coverSelection', fileName));
      await _prefs.remove(_songPreferenceKey('songMetadata', fileName));
      await _prefs.remove(_songPreferenceKey('lyricSource', fileName));
      await _prefs.remove(_songPreferenceKey('manualLyric', fileName));
      await _prefs.remove(_songPreferenceKey('lyricCandidateId', fileName));
      await _prefs.remove(_songPreferenceKey('lyricFileShift', fileName));
      await _prefs.remove(_songPreferenceKey('lyricOffset', fileName));
      for (final prefix in [
        'serverLyricRevision',
        'serverSelectionQueued_lyrics',
        'serverSelectionQueued_cover',
      ]) {
        await _prefs.remove(_songPreferenceKey(prefix, fileName));
      }
    }
  }

  Future<String> _getPlayableUrl(String songName, String remoteUrl) async {
    try {
      final cacheDir = await _audioCacheDirectory();
      if (cacheDir == null) return remoteUrl;
      final localFile = File('${cacheDir.path}/$songName');
      final version = _loadLibraryVersions(_cacheAccount!)[songName];
      final invalid = File('${localFile.path}.invalid');
      if (await localFile.exists() &&
          !await invalid.exists() &&
          await localFile.length() > 0) {
        if (version != null &&
            version.size > 0 &&
            await localFile.length() != version.size) {
          await invalid.writeAsString('length mismatch');
          return remoteUrl;
        }
        final metadata = File('${localFile.path}.meta.json');
        if (version != null && await metadata.exists()) {
          final cachedVersion = RemoteSongVersion.fromJson(
            jsonDecode(await metadata.readAsString()),
          );
          if (version.differsFrom(cachedVersion)) return remoteUrl;
        }
        await localFile.setLastModified(DateTime.now());
        return localFile.path;
      }
      return remoteUrl;
    } catch (e) {
      addLog('检查播放缓存失败: $songName ($e)');
      return remoteUrl;
    }
  }

  Future<Directory?> _audioCacheDirectory({bool create = true}) async {
    final account = _cacheAccount;
    if (account == null) return null;
    final root = await _cacheRoot();
    final directory = libraryCacheDirectory(root, account);
    if (create && !await directory.exists())
      await directory.create(recursive: true);
    return directory;
  }

  void _scheduleBackgroundCache(
    String songName,
    String remoteUrl,
    String auth,
    Directory cacheDir,
    File localFile,
    int assetGeneration,
  ) {
    _cacheDownloadTimer?.cancel();
    var playbackChecks = 0;
    _cacheDownloadTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_currentFileName != songName) {
        timer.cancel();
        return;
      }
      if (!audioHandler.player.playing) return;
      playbackChecks++;
      final bufferedAhead =
          audioHandler.player.bufferedPosition - audioHandler.playbackPosition;
      final bufferIsStable = bufferedAhead >= const Duration(seconds: 15);
      // 最迟约 24 秒开始缓存，避免部分服务器不报告准确的缓冲位置。
      if (!bufferIsStable && playbackChecks < 12) return;
      timer.cancel();
      unawaited(
        _backgroundDownloadAndLimit(
          songName,
          remoteUrl,
          auth,
          cacheDir,
          localFile,
          assetGeneration,
        ),
      );
    });
  }

  void _cancelBackgroundDownloads() {
    for (final token in _downloadCancelTokens.values.toList()) {
      token.cancel('新的播放请求优先');
    }
  }

  Future<void> _backgroundDownloadAndLimit(
    String songName,
    String remoteUrl,
    String auth,
    Directory cacheDir,
    File localFile,
    int assetGeneration,
  ) async {
    if (_downloadCancelTokens.containsKey(_songTaskKey(songName))) return;
    final cancelToken = CancelToken();
    _downloadCancelTokens[_songTaskKey(songName)] = cancelToken;
    final tempFile = File('${localFile.path}.part');
    final version = _loadLibraryVersions(_cacheAccount!)[songName];
    try {
      if (await tempFile.exists()) await tempFile.delete();
      final response = await _webDavDio.download(
        remoteUrl,
        tempFile.path,
        options: Options(headers: {'Authorization': auth}),
        cancelToken: cancelToken,
      );
      if (await tempFile.length() == 0)
        throw const FileSystemException('下载的缓存文件为空');
      final contentType = response.headers.value('content-type') ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          (version != null &&
              version.size > 0 &&
              await tempFile.length() != version.size)) {
        throw const FileSystemException('音频缓存内容或长度与 NAS 不一致');
      }
      if (!_isCurrentAssetGeneration(songName, assetGeneration)) {
        await tempFile.delete();
        return;
      }
      if (await localFile.exists()) await localFile.delete();
      await tempFile.rename(localFile.path);
      if (!_isCurrentAssetGeneration(songName, assetGeneration)) {
        if (await localFile.exists()) await localFile.delete();
        return;
      }
      if (version != null) {
        await File(
          '${localFile.path}.meta.json',
        ).writeAsString(jsonEncode(version.toJson()));
      }
      final invalid = File('${localFile.path}.invalid');
      if (await invalid.exists()) await invalid.delete();
      await _updateCachedFilesList();

      await _enforceCacheLimit();
    } catch (e) {
      if (await tempFile.exists()) await tempFile.delete();
      if (e is! DioException || !CancelToken.isCancel(e)) {
        addLog('缓存下载失败: $songName ($e)');
      }
    } finally {
      if (identical(
        _downloadCancelTokens[_songTaskKey(songName)],
        cancelToken,
      )) {
        _downloadCancelTokens.remove(_songTaskKey(songName));
      }
    }
  }

  void _setPlaybackLibrary(
    Iterable<String> songs, {
    bool resetOrder = false,
    bool restoreOrder = false,
    String? anchor,
  }) {
    final library = songs.toSet().toList();
    final account = playingAccount ?? activeAccount;
    final key = account == null
        ? null
        : '${_accountSongListKey(account)}_playbackOrder';
    final queueMode = _loopMode == 2 ? 2 : 0;
    var previous = resetOrder ? <String>[] : _playbackQueue;
    if (restoreOrder) {
      previous =
          key != null &&
              _prefsReady &&
              _prefs.getInt('${key}_mode') == queueMode
          ? _prefs.getStringList(key) ?? <String>[]
          : <String>[];
    }
    final order = buildPlaybackOrder(
      library,
      shuffled: _loopMode == 2,
      previousOrder: previous,
      currentSong: anchor ?? _currentFileName,
    );
    _playbackLibrarySongs = library;
    if (!listEquals(order, _playbackQueue)) {
      _playbackQueue = order;
      addLog('播放队列已更新：${_loopMode == 2 ? '随机' : '顺序'} / ${order.length} 首');
    }
    if (key != null && _prefsReady) {
      if (!listEquals(_prefs.getStringList(key), order)) {
        unawaited(_prefs.setStringList(key, order));
      }
      if (_prefs.getInt('${key}_mode') != queueMode) {
        unawaited(_prefs.setInt('${key}_mode', queueMode));
      }
    }
  }

  void _playNextSong({bool manual = false}) {
    final song = playbackQueueNeighbor(
      _playbackQueue,
      _currentFileName,
      1,
      repeatCurrent: _loopMode == 1 && !manual,
    );
    if (song != null) {
      unawaited(playNasSong(song, account: playingAccount, fromQueue: true));
    }
  }

  void _playPrevSong() {
    final song = playbackQueueNeighbor(_playbackQueue, _currentFileName, -1);
    if (song != null) {
      unawaited(playNasSong(song, account: playingAccount, fromQueue: true));
    }
  }

  void _scrollToCurrentSong() {
    if (_currentFileName.isEmpty ||
        !_sameAccount(activeAccount, playingAccount))
      return;
    int index = _visibleSongs.indexOf(_currentFileName);
    if (index != -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_playlistScrollController.hasClients) {
          double itemHeight = s(114.0);
          double viewportHeight =
              _playlistScrollController.position.viewportDimension;
          double targetOffset =
              (index * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);
          _playlistScrollController.animateTo(
            targetOffset.clamp(
              0.0,
              _playlistScrollController.position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  String _coverThemePreferenceKey(String imageUrl) =>
      'coverTheme_${_cacheAssetKey(imageUrl)}';

  Future<String> _coverFingerprint(String imageUrl) async {
    if (imageUrl.startsWith('http')) return imageUrl;
    final stat = await File(imageUrl).stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      throw const FileSystemException('封面缓存不存在或为空');
    }
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  ({Color accent, Color glow})? _readSavedCoverTheme(
    String imageUrl,
    String fingerprint,
  ) {
    if (!_prefsReady) return null;
    final saved = _prefs.getString(_coverThemePreferenceKey(imageUrl));
    if (saved == null) return null;
    try {
      final data = jsonDecode(saved);
      if (data is! Map || data['fingerprint'] != fingerprint) return null;
      final accent = data['accent'];
      final glow = data['glow'];
      if (accent is! int || glow is! int) return null;
      return (accent: Color(accent), glow: Color(glow));
    } catch (_) {
      return null;
    }
  }

  void _applyCoverTheme(String imageUrl, ({Color accent, Color glow}) theme) {
    if (!mounted || currentCoverUrl != imageUrl) return;
    if (_lyricHighlightColor == theme.accent &&
        _bottomGlowColor == theme.glow) {
      return;
    }
    setState(() {
      _lyricHighlightColor = theme.accent;
      _bottomGlowColor = theme.glow;
    });
    _syncDesktopLyricColor();
  }

  Future<void> _updatePalette(String imageUrl) async {
    void rememberTheme(({Color accent, Color glow}) theme) {
      _coverThemeCache[imageUrl] = theme;
      if (_coverThemeCache.length > 64) {
        _coverThemeCache.remove(_coverThemeCache.keys.first);
      }
    }

    void useDefaultPalette() {
      final colors = buildCoverThemeColors(const Color(0xFF1ED760));
      _lyricHighlightColor = colors.accent;
      _bottomGlowColor = colors.glow;
    }

    if (imageUrl.isEmpty) {
      if (mounted) setState(useDefaultPalette);
      _syncDesktopLyricColor();
      return;
    }
    final cachedTheme = _coverThemeCache[imageUrl];
    if (cachedTheme != null) {
      _applyCoverTheme(imageUrl, cachedTheme);
      return;
    }
    if (!_paletteUpdatesInFlight.add(imageUrl)) return;
    final timer = Stopwatch()..start();
    try {
      final fingerprint = await _coverFingerprint(imageUrl);
      final savedTheme = _readSavedCoverTheme(imageUrl, fingerprint);
      if (savedTheme != null) {
        rememberTheme(savedTheme);
        _applyCoverTheme(imageUrl, savedTheme);
        addLog('封面主题色读取缓存: ${timer.elapsedMilliseconds}ms');
        return;
      }
      if (!mounted || currentCoverUrl != imageUrl) return;
      final palette = await PaletteGenerator.fromImageProvider(
        ResizeImage(_coverImageProvider(imageUrl), width: 64, height: 64),
        maximumColorCount: 16,
      );
      if (!mounted || currentCoverUrl != imageUrl) return;
      final samples = palette.paletteColors
          .map((sample) => (color: sample.color, population: sample.population))
          .toList();
      if (samples.isEmpty && palette.dominantColor != null) {
        samples.add((
          color: palette.dominantColor!.color,
          population: palette.dominantColor!.population,
        ));
      }
      final targetColor = selectRepresentativeCoverColor(samples);
      final theme = buildCoverThemeColors(targetColor);
      if (await _coverFingerprint(imageUrl) != fingerprint ||
          !mounted ||
          currentCoverUrl != imageUrl) {
        return;
      }
      rememberTheme(theme);
      _applyCoverTheme(imageUrl, theme);
      if (_prefsReady) {
        await _prefs.setString(
          _coverThemePreferenceKey(imageUrl),
          jsonEncode({
            'fingerprint': fingerprint,
            'accent': theme.accent.toARGB32(),
            'glow': theme.glow.toARGB32(),
          }),
        );
      }
      addLog('封面主题色计算完成: ${timer.elapsedMilliseconds}ms');
    } catch (_) {
      if (mounted && currentCoverUrl == imageUrl) {
        setState(useDefaultPalette);
        _syncDesktopLyricColor();
      }
    } finally {
      _paletteUpdatesInFlight.remove(imageUrl);
    }
  }

  void _parseRawLrcText(
    String text, {
    List<({Duration time, String text})>? timeline,
  }) {
    if (_displayedLyricRaw == text) return;
    // A translation can change row heights while an old ensureVisible or
    // deferred refinement is still running. Invalidate that layout first.
    _lyricSessionId++;
    _cancelLyricScrollAnimations();
    if (_lyricsManuallyScrolled) _holdLyricAutoScroll();
    final lines = timeline ?? parseLrcText(text);
    final times = lines.map((line) => line.time).toList(growable: false);
    final timingChanged = !listEquals(_lyricTimes, times);
    _displayedLyricRaw = text;
    parsedLyrics = lines
        .map((line) => {'time': line.time, 'text': line.text})
        .toList();
    _lyricTimes = times;
    // Fetches and translations complete asynchronously, including while the
    // Flutter position timer is suspended. Never highlight using a stale tick.
    if (_positionUpdatesForRequestId == _playRequestId) {
      _currentPosition = audioHandler.playbackPosition;
    }
    _currentLyricIndex =
        _positionUpdatesForRequestId == _playRequestId || _playRequestId == 0
        ? _lyricIndexAt(_currentPosition)
        : -1;
    if (timingChanged || _lyricKeys.length != lines.length) {
      _lyricKeys = List.generate(parsedLyrics.length, (i) => GlobalKey());
      _miniLyricKeys = List.generate(parsedLyrics.length, (i) => GlobalKey());
    }
    _scheduleLyricRecenter(immediate: timingChanged);
    _syncDesktopLyrics();
  }

  int _lyricIndexAt(Duration currentPos) {
    return lyricIndexAtPosition(_lyricTimes, currentPos, _lyricOffset);
  }

  void _updateLyricScroll(Duration currentPos, {bool force = false}) {
    final newIndex = _lyricIndexAt(currentPos);
    if (newIndex < 0) {
      if (_currentLyricIndex != -1 && mounted) {
        _currentLyricIndex = -1;
      }
      if (force) {
        final lyricSessionId = _lyricSessionId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              lyricSessionId != _lyricSessionId ||
              _lyricsManuallyScrolled) {
            return;
          }
          for (final controller in [
            _lyricScrollController,
            _miniLyricScrollController,
          ]) {
            if (controller.hasClients) controller.jumpTo(0);
          }
        });
      }
      return;
    }
    if (!force && newIndex == _currentLyricIndex) return;
    if (newIndex != _currentLyricIndex && mounted) {
      _currentLyricIndex = newIndex;
    }
    _scheduleLyricRecenter(expectedIndex: newIndex, immediate: force);
  }

  void _scheduleLyricRecenter({int? expectedIndex, bool immediate = false}) {
    final lyricSessionId = _lyricSessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_isAppForeground ||
          lyricSessionId != _lyricSessionId ||
          _lyricsManuallyScrolled) {
        return;
      }
      final index = expectedIndex ?? _currentLyricIndex;
      if (index < 0 || index != _currentLyricIndex) return;
      _scrollLyricsToIndex(index, lyricSessionId, immediate: immediate);
    });
  }

  void _scrollLyricsToIndex(
    int index,
    int lyricSessionId, {
    bool immediate = false,
  }) {
    void animateToKey(
      List<GlobalKey> keys,
      ScrollController controller,
      double estimatedLineHeight,
      double alignment,
    ) {
      if (lyricSessionId != _lyricSessionId || !controller.hasClients) return;
      bool isCurrentTarget() =>
          mounted &&
          _isAppForeground &&
          lyricSessionId == _lyricSessionId &&
          !_lyricsManuallyScrolled &&
          index == _currentLyricIndex &&
          controller.hasClients;

      void alignOrRefine(int attemptsLeft) {
        if (!isCurrentTarget()) return;
        final lineContext = keys[index].currentContext;
        if (lineContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              lineContext,
              alignment: alignment,
              duration: immediate
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            ),
          );
          return;
        }
        if (attemptsLeft == 0) return;

        // 可变行高（双语、换行）会让固定行高的远距离跳转误差越来越大。
        // 用当前已渲染歌词的实际位置估算下一跳，直到目标行被构建。
        int? firstVisible;
        RenderBox? firstBox;
        int? lastVisible;
        double? firstTop;
        double? lastTop;
        for (var visibleIndex = 0; visibleIndex < keys.length; visibleIndex++) {
          final renderObject = keys[visibleIndex].currentContext
              ?.findRenderObject();
          if (renderObject is! RenderBox ||
              !renderObject.attached ||
              !renderObject.hasSize) {
            continue;
          }
          final top = renderObject.localToGlobal(Offset.zero).dy;
          firstVisible ??= visibleIndex;
          firstBox ??= renderObject;
          firstTop ??= top;
          lastVisible = visibleIndex;
          lastTop = top;
        }
        final averageHeight =
            firstVisible != null &&
                lastVisible != null &&
                lastVisible > firstVisible &&
                firstTop != null &&
                lastTop != null
            ? (lastTop - firstTop) / (lastVisible - firstVisible)
            : estimatedLineHeight;
        final viewport = firstBox == null
            ? null
            : RenderAbstractViewport.maybeOf(firstBox);
        final targetOffset =
            viewport == null || firstBox == null || firstVisible == null
            ? controller.position.maxScrollExtent *
                  index /
                  (keys.length - 1).clamp(1, keys.length)
            : viewport.getOffsetToReveal(firstBox, alignment).offset +
                  (index - firstVisible) * averageHeight;
        final clampedOffset = targetOffset.clamp(
          0.0,
          controller.position.maxScrollExtent,
        );
        if ((clampedOffset - controller.offset).abs() < 1) return;
        controller.jumpTo(clampedOffset);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          alignOrRefine(attemptsLeft - 1);
        });
      }

      alignOrRefine(8);
    }

    final largeEstimatedHeight =
        (_isLargeMode ? _stageSize(_largeLyricFontSize) : _lyricFontSize) *
            1.5 +
        _stageSize(36.0);
    final miniEstimatedHeight = s(22.0) * 1.5 + s(18.0);
    if (currentLeftScreen == 2 && index < _lyricKeys.length) {
      animateToKey(
        _lyricKeys,
        _lyricScrollController,
        largeEstimatedHeight,
        _isLargeMode ? 0.25 : 0.5,
      );
    }
    if (!_isLargeMode && index < _miniLyricKeys.length) {
      animateToKey(
        _miniLyricKeys,
        _miniLyricScrollController,
        miniEstimatedHeight,
        0.5,
      );
    }
  }

  void _holdLyricAutoScroll() {
    _lyricsManuallyScrolled = true;
    _lyricAutoScrollResumeTimer?.cancel();
    final lyricSessionId = _lyricSessionId;
    _lyricAutoScrollResumeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || lyricSessionId != _lyricSessionId) return;
      _lyricsManuallyScrolled = false;
      _scheduleLyricRecenter();
    });
  }

  void _beginLyricSession() {
    final lyricSessionId = ++_lyricSessionId;
    _lyricAutoScrollResumeTimer?.cancel();
    _lyricAutoScrollResumeTimer = null;
    _lyricsManuallyScrolled = false;
    _draggingSeekMs = null;
    _currentLyricIndex = -1;

    void resetController(ScrollController controller) {
      if (controller.hasClients) controller.jumpTo(0);
    }

    // jumpTo 会终止上一首仍在进行的 ensureVisible 动画。下一帧再执行一次，
    // 覆盖切换布局过程中刚挂载的新歌词列表。
    resetController(_lyricScrollController);
    resetController(_miniLyricScrollController);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || lyricSessionId != _lyricSessionId) return;
      resetController(_lyricScrollController);
      resetController(_miniLyricScrollController);
    });
  }

  LyricCandidate? _parseLrclibCandidate(
    dynamic raw,
    String title,
    String artist,
    Duration duration,
  ) {
    if (raw is! Map) return null;
    final syncedLyrics = raw['syncedLyrics']?.toString().trim() ?? '';
    final plainLyrics = raw['plainLyrics']?.toString().trim() ?? '';
    final lyrics = syncedLyrics.isNotEmpty ? syncedLyrics : plainLyrics;
    if (lyrics.isEmpty) return null;
    final actualTitle = raw['trackName']?.toString().trim() ?? '';
    final actualArtist = raw['artistName']?.toString().trim() ?? '';
    final actualDuration =
        double.tryParse(raw['duration']?.toString() ?? '') ?? 0;
    return LyricCandidate(
      id: int.tryParse(raw['id']?.toString() ?? '') ?? 0,
      trackName: actualTitle.isEmpty ? title : actualTitle,
      artistName: actualArtist,
      albumName: raw['albumName']?.toString().trim() ?? '',
      durationSeconds: actualDuration,
      lyrics: lyrics,
      hasSyncedLyrics: syncedLyrics.isNotEmpty,
      score: scoreLyricCandidate(
        expectedTitle: title,
        expectedArtist: artist,
        expectedDuration: duration,
        actualTitle: actualTitle,
        actualArtist: actualArtist,
        actualDurationSeconds: actualDuration,
        hasSyncedLyrics: syncedLyrics.isNotEmpty,
      ),
    );
  }

  Future<List<LyricCandidate>> _fetchLrclibCandidates(
    String title,
    String artist,
    Duration duration,
  ) async {
    final results = <LyricCandidate>[];
    final seen = <String>{};
    void addCandidate(dynamic raw) {
      final candidate = _parseLrclibCandidate(raw, title, artist, duration);
      if (candidate != null && seen.add(candidate.identity)) {
        results.add(candidate);
      }
    }

    Future<Response<dynamic>?> request(
      String path,
      Map<String, dynamic> query,
    ) async {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final response = await _externalDio.get(
            path,
            queryParameters: query,
            options: Options(
              headers: {
                'User-Agent': 'NasPlayer/1.0 (lyrics for personal playback)',
              },
              validateStatus: (status) =>
                  status == 200 ||
                  status == 404 ||
                  status == 429 ||
                  status == 503,
            ),
          );
          if ((response.statusCode == 429 || response.statusCode == 503) &&
              attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 900));
            continue;
          }
          return response;
        } catch (e) {
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
            continue;
          }
          addLog('LRCLIB 请求失败: $e');
        }
      }
      return null;
    }

    if (duration.inSeconds > 0 && artist.isNotEmpty) {
      final exact = await request('https://lrclib.net/api/get', {
        'track_name': title,
        'artist_name': artist,
        'duration': duration.inSeconds,
      });
      if (exact != null && exact.statusCode == 200) {
        addCandidate(
          exact.data is String ? jsonDecode(exact.data) : exact.data,
        );
      }
    }

    final search = await request('https://lrclib.net/api/search', {
      'track_name': title,
      if (artist.isNotEmpty) 'artist_name': artist,
    });
    if (search != null && search.statusCode == 200) {
      final data = search.data is String
          ? jsonDecode(search.data)
          : search.data;
      if (data is List) {
        for (final item in data) {
          addCandidate(item);
        }
      }
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(20).toList();
  }

  Future<void> _applyLyricCandidate(
    String songName,
    LyricCandidate candidate, {
    required bool manuallySelected,
    int? expectedGeneration,
    int? expectedPlayRequestId,
    int? expectedLyricRevision,
  }) async {
    bool isCurrentSong() =>
        mounted &&
        _currentFileName == songName &&
        (expectedPlayRequestId == null ||
            expectedPlayRequestId == _playRequestId) &&
        (expectedGeneration == null ||
            _isCurrentAssetGeneration(songName, expectedGeneration));
    if (!isCurrentSong() ||
        (expectedLyricRevision != null &&
            expectedLyricRevision != _lyricChoiceRevision)) {
      return;
    }
    final lyricRevision = manuallySelected
        ? ++_lyricChoiceRevision
        : (expectedLyricRevision ?? _lyricChoiceRevision);
    if (manuallySelected) {
      _latestLyricsForTranslation.remove(_songTaskKey(songName));
      await _prefs.remove(_songPreferenceKey('serverLyricRevision', songName));
    }
    final source = manuallySelected ? 'LRCLIB 手动选择' : 'LRCLIB 自动匹配';
    final simplifiedLyrics = await _saveCachedLyric(
      songName,
      candidate.lyrics,
      expectedGeneration: expectedGeneration,
      expectedLyricRevision: lyricRevision,
      scheduleTranslation: false,
    );
    if (!isCurrentSong() || lyricRevision != _lyricChoiceRevision) return;
    await _rememberLyricSource(
      songName,
      source,
      manuallySelected: manuallySelected,
      candidateId: candidate.id,
      expectedGeneration: expectedGeneration,
      expectedLyricRevision: lyricRevision,
    );
    if (!isCurrentSong() || lyricRevision != _lyricChoiceRevision) return;
    setState(() => _currentLyricSource = source);
    _showLyricsForSong(
      songName,
      simplifiedLyrics,
      expectedGeneration: expectedGeneration,
    );
    addLog('$source: ${candidate.artistName} - ${candidate.trackName}');
    // 先完成来源切换和原文/缓存译文显示，再检查新来源缺失的英文行。
    _scheduleEnglishLyricTranslation(
      songName,
      simplifiedLyrics,
      expectedGeneration: expectedGeneration,
      expectedLyricRevision: lyricRevision,
      reportDetection: manuallySelected,
    );
    if (manuallySelected &&
        isCurrentSong() &&
        lyricRevision == _lyricChoiceRevision) {
      unawaited(
        _queueSongSelection(songName, _selectionSong(songName), 'lyrics', {
          'text': candidate.lyrics,
          'source': 'LRCLIB',
          'candidate_id': candidate.id,
        }),
      );
    }
  }

  Future<String?> _fetchLegacyApiLrc(
    Dio dio,
    String title,
    String artist,
  ) async {
    try {
      var res = await dio.get(
        "https://tools.rangotec.com/api/anon/lrc",
        queryParameters: {"title": title, "artist": artist, "od": "asc"},
      );
      var data = res.data is String ? jsonDecode(res.data) : res.data;
      if (data['code'] == 200 &&
          data['data'] != null &&
          data['data'].isNotEmpty)
        return data['data'][0]['lrc'];
    } catch (_) {}
    return null;
  }

  Future<Map<String, String>?> _fetchApiSongInfo(
    Dio dio,
    String title,
    String artist, {
    required String country,
  }) async {
    final artistVariants = buildArtistSearchVariants(artist);
    final terms = <String>[
      ...artistVariants.map((name) => '$name $title'.trim()),
      title,
    ];
    for (final term in terms.toSet()) {
      try {
        final res = await dio.get(
          "https://itunes.apple.com/search",
          queryParameters: {
            "term": term,
            "limit": 5,
            "entity": "song",
            "country": country,
          },
        );
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        final results = data is Map ? data['results'] : null;
        if (results is! List) continue;
        for (final result in results) {
          if (result is! Map) continue;
          final resultTitle = result['trackName']?.toString() ?? '';
          final resultArtist = result['artistName']?.toString() ?? '';
          if (!isLikelySameSongText(title, resultTitle) ||
              (artist.isNotEmpty &&
                  !isLikelySameArtistCredit(artist, resultArtist))) {
            continue;
          }
          final cover =
              result['artworkUrl100']?.toString().replaceAll(
                '100x100bb.jpg',
                '600x600bb.jpg',
              ) ??
              '';
          if (!cover.startsWith('http')) continue;
          return {
            'title': resultTitle.isEmpty ? title : resultTitle,
            'artist': resultArtist.isEmpty ? artist : resultArtist,
            'cover': cover,
          };
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<String>> _fetchMusicBrainzCoverCandidates(
    Dio dio,
    String title,
    String artist,
  ) async {
    final turn = Completer<void>();
    final previousTurn = _musicBrainzRequestGate;
    _musicBrainzRequestGate = turn.future;
    await previousTurn;
    try {
      final elapsed = DateTime.now().difference(_lastMusicBrainzRequestAt);
      const minimumInterval = Duration(milliseconds: 1100);
      if (elapsed < minimumInterval)
        await Future.delayed(minimumInterval - elapsed);
      Response<dynamic>? response;
      for (var attempt = 0; attempt < 2; attempt++) {
        _lastMusicBrainzRequestAt = DateTime.now();
        try {
          response = await dio.get(
            'https://musicbrainz.org/ws/2/recording/',
            queryParameters: {
              'query': buildMusicBrainzRecordingQuery(title, artist),
              'fmt': 'json',
              'limit': 5,
            },
            options: Options(
              headers: {
                'Accept': 'application/json',
                'User-Agent':
                    'NASCarPlayer/1.0 (Android; com.example.nas_car_player)',
              },
            ),
          );
          break;
        } on DioException catch (e) {
          if (attempt == 0 && e.response?.statusCode == 503) {
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          rethrow;
        }
      }
      if (response == null) return [];
      final data = response.data is String
          ? jsonDecode(response.data)
          : response.data;
      final recordings = data is Map ? data['recordings'] : null;
      if (recordings is! List) return [];

      final releaseGroupUrls = <String>{};
      final releaseUrls = <String>{};
      for (final recording in recordings) {
        if (recording is! Map) continue;
        final score = int.tryParse(recording['score']?.toString() ?? '') ?? 0;
        if (score < 80) continue;
        final recordingTitle = recording['title']?.toString() ?? '';
        if (!isLikelySameSongText(title, recordingTitle)) continue;
        final artistCredits = recording['artist-credit'];
        final creditNames = <String>[];
        if (artistCredits is List) {
          for (final credit in artistCredits) {
            if (credit is! Map) continue;
            final nestedArtist = credit['artist'];
            final name =
                credit['name']?.toString() ??
                (nestedArtist is Map
                    ? nestedArtist['name']?.toString() ?? ''
                    : '');
            if (name.trim().isNotEmpty) creditNames.add(name.trim());
          }
        }
        if (artist.isNotEmpty &&
            !isLikelySameArtistCredit(artist, creditNames.join('、'))) {
          continue;
        }
        final releases = recording['releases'];
        if (releases is! List) continue;
        for (final release in releases) {
          if (release is! Map) continue;
          final releaseGroup = release['release-group'];
          final releaseGroupId = releaseGroup is Map
              ? releaseGroup['id']?.toString()
              : null;
          final releaseId = release['id']?.toString();
          if (releaseGroupId != null && releaseGroupId.isNotEmpty) {
            releaseGroupUrls.add(
              'https://coverartarchive.org/release-group/$releaseGroupId/front-500',
            );
          }
          if (releaseId != null && releaseId.isNotEmpty) {
            releaseUrls.add(
              'https://coverartarchive.org/release/$releaseId/front-500',
            );
          }
        }
      }
      return [...releaseGroupUrls, ...releaseUrls];
    } catch (e) {
      addLog('MusicBrainz 封面搜索失败: $e');
      return [];
    } finally {
      turn.complete();
    }
  }

  Future<String?> _downloadMusicBrainzCover(
    String songName,
    String title,
    String artist,
    int expectedGeneration,
  ) async {
    final candidates = await _fetchMusicBrainzCoverCandidates(
      _externalDio,
      title,
      artist,
    );
    for (final coverUrl in candidates.take(3)) {
      if (_currentFileName != songName ||
          !_isCurrentAssetGeneration(songName, expectedGeneration)) {
        return null;
      }
      final cachedPath = await _downloadAndCacheCover(
        songName,
        coverUrl,
        _externalDio,
        logFailure: false,
        expectedGeneration: expectedGeneration,
      );
      if (cachedPath != null) {
        addLog('已从 MusicBrainz 缓存封面: $songName');
        return cachedPath;
      }
    }
    return null;
  }

  Future<String?> _downloadCoverFromProxy(
    String songName,
    String title,
    String artist,
    int expectedGeneration,
  ) async {
    if (coverProxyBaseUrl.trim().isEmpty) return null;
    try {
      final baseUri = Uri.parse(coverProxyBaseUrl.trim());
      final uri = baseUri.replace(
        queryParameters: {
          ...baseUri.queryParameters,
          'title': title,
          'artist': artist,
          'duration': (_totalDuration.inMilliseconds / 1000.0).toString(),
          if (_songSelections != null) 'device_id': _songSelections!.deviceId,
        },
      );
      addLog(
        '封面中转请求参数: title="$title", '
        'artist="${artist.isEmpty ? '(空)' : artist}", url=$uri',
      );
      final cachedPath = await _downloadAndCacheCover(
        songName,
        uri.toString(),
        _externalDio,
        logFailure: false,
        expectedGeneration: expectedGeneration,
      );
      if (cachedPath != null) addLog('已从封面中转服务缓存封面: $songName');
      return cachedPath;
    } catch (e) {
      addLog('封面中转服务请求失败: $e');
      return null;
    }
  }

  Future<void> fetchLyricAndCover(
    String songName,
    Map<String, dynamic> account,
    int expectedGeneration,
    int expectedPlayRequestId,
  ) => runZoned(
    () => _fetchLyricAndCover(
      songName,
      account,
      expectedGeneration,
      expectedPlayRequestId,
    ),
    zoneValues: {_coverTaskZone: _coverChoiceRevision},
  );

  Future<void> _fetchLyricAndCover(
    String songName,
    Map<String, dynamic> account,
    int expectedGeneration,
    int expectedPlayRequestId,
  ) async {
    final coverRevision = _coverChoiceRevision;

    bool isCurrentSong() =>
        mounted &&
        _currentFileName == songName &&
        expectedPlayRequestId == _playRequestId &&
        _isCurrentAssetGeneration(songName, expectedGeneration);
    if (!isCurrentSong()) return;
    final lyricRevision = _lyricChoiceRevision;
    bool isCurrentLyricRequest() =>
        isCurrentSong() && lyricRevision == _lyricChoiceRevision;
    String pureName = songName.replaceAll(RegExp(r'\.[^.]+$'), '');
    String auth =
        "Basic ${base64Encode(utf8.encode("${account['user']}:${account['pwd']}"))}";
    final cachedLrc = await _readCachedLyric(
      songName,
      expectedGeneration: expectedGeneration,
    );
    var cachedCoverPath = await _readCachedCoverPath(songName);
    if (!isCurrentSong()) return;
    var hasCachedLyrics = cachedLrc != null && cachedLrc.trim().isNotEmpty;
    if (hasCachedLyrics && isCurrentLyricRequest()) {
      setState(() => _currentLyricSource = _savedLyricSource(songName));
      _showLyricsForSong(
        songName,
        cachedLrc,
        expectedGeneration: expectedGeneration,
      );
    }

    final metadata = _metadataForSong(songName);
    String cleanName = pureName
        .replaceAll(RegExp(r'\[.*?\]|\(.*?\)|【.*?】|（.*?）'), '')
        .trim();
    final queryArtist = metadata.artist == '私人乐库' ? '' : metadata.artist;
    final restored = await _restoreServerSelections(
      songName,
      _selectionSong(songName),
      hasCachedLyrics,
      cachedCoverPath,
      expectedGeneration,
      lyricRevision,
      coverRevision,
      isCurrentSong,
    );
    hasCachedLyrics = restored.lyrics;
    cachedCoverPath = restored.cover;
    if (!isCurrentSong()) return;
    if (!hasCachedLyrics && isCurrentLyricRequest()) {
      String? finalLrc;
      try {
        final response = await _webDavDio.get(
          _buildWebDavFileUrl(account['url'].toString(), '$pureName.lrc'),
          options: Options(headers: {'Authorization': auth}),
        );
        finalLrc = response.data.toString();
      } catch (_) {}
      if (isCurrentLyricRequest() &&
          finalLrc != null &&
          finalLrc.trim().isNotEmpty) {
        finalLrc = await _saveCachedLyric(
          songName,
          finalLrc,
          expectedGeneration: expectedGeneration,
          expectedLyricRevision: lyricRevision,
        );
        if (isCurrentLyricRequest()) {
          await _rememberLyricSource(
            songName,
            'NAS 同名歌词',
            manuallySelected: false,
            expectedGeneration: expectedGeneration,
            expectedLyricRevision: lyricRevision,
          );
        }
        if (isCurrentLyricRequest()) {
          setState(() {
            _currentLyricSource = 'NAS 同名歌词';
            _lyricCandidates = [];
          });
          _showLyricsForSong(
            songName,
            finalLrc,
            expectedGeneration: expectedGeneration,
          );
        }
      } else if (isCurrentLyricRequest()) {
        final candidates = await _fetchLrclibCandidates(
          metadata.title,
          queryArtist,
          _totalDuration,
        );
        if (isCurrentLyricRequest()) {
          setState(() => _lyricCandidates = candidates);
          final bestSynced = candidates.where((item) => item.hasSyncedLyrics);
          final selected = bestSynced.isEmpty ? null : bestSynced.first;
          if (selected != null && selected.score >= 70) {
            await _applyLyricCandidate(
              songName,
              selected,
              manuallySelected: false,
              expectedGeneration: expectedGeneration,
              expectedPlayRequestId: expectedPlayRequestId,
              expectedLyricRevision: lyricRevision,
            );
            finalLrc = selected.lyrics;
          } else {
            finalLrc = await _fetchLegacyApiLrc(
              _externalDio,
              metadata.title,
              queryArtist,
            );
            if (isCurrentLyricRequest() &&
                (finalLrc == null || finalLrc.isEmpty)) {
              finalLrc = await _fetchLegacyApiLrc(
                _externalDio,
                queryArtist,
                metadata.title,
              );
            }
            if (isCurrentLyricRequest() &&
                (finalLrc == null || finalLrc.isEmpty)) {
              finalLrc = await _fetchLegacyApiLrc(_externalDio, cleanName, '');
            }
            if (isCurrentLyricRequest() &&
                finalLrc != null &&
                finalLrc.isNotEmpty) {
              finalLrc = await _saveCachedLyric(
                songName,
                finalLrc,
                expectedGeneration: expectedGeneration,
                expectedLyricRevision: lyricRevision,
              );
              if (isCurrentLyricRequest()) {
                await _rememberLyricSource(
                  songName,
                  '备用网络词库',
                  manuallySelected: false,
                  expectedGeneration: expectedGeneration,
                  expectedLyricRevision: lyricRevision,
                );
              }
              if (isCurrentLyricRequest()) {
                setState(() => _currentLyricSource = '备用网络词库');
                _showLyricsForSong(
                  songName,
                  finalLrc,
                  expectedGeneration: expectedGeneration,
                );
              }
            }
          }
        }
      }
      if (isCurrentLyricRequest() && (finalLrc == null || finalLrc.isEmpty)) {
        _showLyricsForSong(
          songName,
          '[00:01.00]暂无本地歌词，且未匹配到网络词库',
          expectedGeneration: expectedGeneration,
        );
      }
    }

    if (!isCurrentSong()) return;
    String? resolvedCover = cachedCoverPath;
    String? remoteCoverFallback;
    if (isCurrentSong() &&
        resolvedCover == null &&
        coverProxyBaseUrl.trim().isNotEmpty) {
      resolvedCover = await _downloadCoverFromProxy(
        songName,
        metadata.title,
        queryArtist,
        expectedGeneration,
      );
    }

    if (isCurrentSong() && resolvedCover == null) {
      Map<String, String>? songInfo;
      for (final country in const ['cn', 'tw', 'hk']) {
        songInfo = await _fetchApiSongInfo(
          _externalDio,
          metadata.title,
          queryArtist,
          country: country,
        );
        if (songInfo != null) break;
      }
      if (!isCurrentSong()) return;
      final finalCover = songInfo?['cover'];
      if (finalCover != null && finalCover.startsWith("http")) {
        resolvedCover = await _downloadAndCacheCover(
          songName,
          finalCover,
          _externalDio,
          expectedGeneration: expectedGeneration,
        );
        remoteCoverFallback = finalCover;
      }
    }
    if (isCurrentSong() && resolvedCover == null) {
      resolvedCover = await _downloadMusicBrainzCover(
        songName,
        metadata.title,
        queryArtist,
        expectedGeneration,
      );
    }
    resolvedCover ??= remoteCoverFallback;
    if (!isCurrentSong() || coverRevision != _coverChoiceRevision) return;
    setState(() {
      currentCoverUrl = resolvedCover ?? defaultCoverUrl;
    });
    _updatePalette(currentCoverUrl);
    audioHandler.updateCurrentSong(
      currentPlayingSong,
      currentArtist,
      currentCoverUrl,
    );
  }

  Future<SongListSyncResult?> _synchronizeSongList(
    Map<String, dynamic> account,
    List<String> remoteSongs,
    int requestId,
    Map<String, RemoteSongVersion> versions,
  ) async {
    final previousSync = _songListSyncGate;
    final done = Completer<void>();
    _songListSyncGate = done.future;
    bool isCurrent() =>
        mounted &&
        requestId == _songListRequestId &&
        _sameAccount(activeAccount, account);
    try {
      await previousSync;
      if (!isCurrent()) return null;
      final listKey = _accountSongListKey(account);
      final pendingKey = '${listKey}_pendingRemoval';
      final previousSongs = _prefs.getStringList(listKey) ?? <String>[];
      final previousVersions = _loadLibraryVersions(account);
      final changedSongs = <String>{
        for (final song in remoteSongs)
          if (versions[song] != null &&
              previousVersions[song] != null &&
              versions[song]!.differsFrom(previousVersions[song]!))
            song,
      };
      final cacheDirectory = await _audioCacheDirectory(create: false);
      final knownSongs = <String>{
        ...previousSongs,
        ...?_prefs.getStringList(pendingKey),
        // 包含仅有歌词/封面、没有音频的本乐库缓存。
        if (cacheDirectory != null)
          ...await readSongAssetCacheNames(cacheDirectory),
      };
      final pending = songCachesToRemove(
        knownSongs: knownSongs,
        remoteSongs: remoteSongs,
      )..addAll(changedSongs);
      if (!isCurrent()) return null;
      // 先记录待清理项；中断或文件删除失败后，下次成功同步会继续清理。
      if (!await _prefs.setStringList(pendingKey, pending.toList()) ||
          !await _prefs.setStringList(listKey, remoteSongs)) {
        throw const FileSystemException('保存同步歌单失败');
      }
      if (!isCurrent()) return null;
      setState(() {
        realNasSongs = remoteSongs;
        _showingCachedSongsOnly = false;
        _slidingSongName = null;
        if (_sameAccount(playingAccount, account)) {
          _setPlaybackLibrary(remoteSongs);
        }
      });
      final removedNames = knownSongs.difference(remoteSongs.toSet());
      final remembered = _readPlaybackResume();
      if (remembered != null &&
          remembered.libraryId == libraryCacheId(account) &&
          removedNames.contains(remembered.song)) {
        final encoded = _prefs.getString(PlaybackResumePoint.preferenceKey);
        await _prefs.remove('lastFileName');
        await _prefs.remove('lastPosition');
        await _prefs.remove('lastAccount');
        if (encoded != null &&
            _prefs.getString(PlaybackResumePoint.preferenceKey) == encoded) {
          await _prefs.remove(PlaybackResumePoint.preferenceKey);
        }
      }
      for (final song in pending.toList()) {
        if (!isCurrent()) break;
        if (await _deleteCacheFile(
          song,
          refreshFiles: false,
          updatePresentation: false,
        )) {
          pending.remove(song);
        }
      }
      await _prefs.setStringList(pendingKey, pending.toList());
      final savedVersions = Map<String, RemoteSongVersion>.from(versions);
      for (final failed in changedSongs.intersection(pending)) {
        savedVersions[failed] = previousVersions[failed]!;
      }
      _libraryVersions[libraryCacheId(account)] = savedVersions;
      await _prefs.setString(
        '${listKey}_versions',
        jsonEncode({
          for (final entry in savedVersions.entries)
            entry.key: entry.value.toJson(),
        }),
      );
      final syncedAt = DateTime.now();
      await _prefs.setInt(
        '${listKey}_syncedAt',
        syncedAt.millisecondsSinceEpoch,
      );
      if (isCurrent()) _lastLibrarySync = syncedAt;
      await _updateCachedFilesList();
      if (!isCurrent()) return null;
      return (
        total: remoteSongs.length,
        added: remoteSongs.toSet().difference(previousSongs.toSet()).length,
        removed: removedNames.length,
        cleanupFailed: pending.length,
      );
    } finally {
      done.complete();
    }
  }

  Future<SongListSyncResult?> fetchSongsFromWebDav({
    bool silent = false,
    bool forceRefresh = false,
  }) {
    final account = activeAccount;
    if (account == null) return Future.value(null);
    return runInLibrary(
      account,
      () => _fetchSongsFromWebDav(silent: silent, forceRefresh: forceRefresh),
    );
  }

  Future<SongListSyncResult?> _fetchSongsFromWebDav({
    bool silent = false,
    bool forceRefresh = false,
  }) async {
    if (activeAccount == null) return null;
    final account = Map<String, dynamic>.from(activeAccount!);
    final previousSongs = List<String>.from(realNasSongs);
    final requestId = ++_songListRequestId;
    _songListCancelToken?.cancel('新的歌单刷新请求');
    final cancelToken = CancelToken();
    _songListCancelToken = cancelToken;
    bool isCurrentAccount() =>
        mounted &&
        requestId == _songListRequestId &&
        _sameAccount(activeAccount, account);
    if (mounted) setState(() => isLoading = true);
    String auth =
        "Basic ${base64Encode(utf8.encode("${account['user']}:${account['pwd']}"))}";
    try {
      await _prefs.setString('lastActiveAccount', jsonEncode(account));
      final requestUri = Uri.parse(account['url'].toString());
      if (forceRefresh) addLog('正在强制刷新 WebDAV 歌单: ${account['name']}');
      final response = await _webDavDio.requestUri<String>(
        requestUri,
        data:
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>',
        cancelToken: cancelToken,
        options: Options(
          method: 'PROPFIND',
          contentType: 'application/xml; charset=utf-8',
          responseType: ResponseType.plain,
          validateStatus: (status) => status == 207,
          headers: {
            'Authorization': auth,
            'Depth': '1',
            'Cache-Control': 'no-cache, no-store, max-age=0',
            'Pragma': 'no-cache',
          },
        ),
      );
      final songs = parseWebDavSongList(response.data ?? '', response.realUri);
      final versions = parseWebDavVersions(
        response.data ?? '',
        response.realUri,
      );
      if (!isCurrentAccount()) return null;
      final result = await _synchronizeSongList(
        account,
        songs,
        requestId,
        versions,
      );
      if (result != null) {
        addLog(
          'WebDAV 歌单同步完成: ${result.total} 首，新增 ${result.added} 首，移除 ${result.removed} 首，待清理 ${result.cleanupFailed} 首',
        );
      }
      return result;
    } catch (e) {
      if (!isCurrentAccount() ||
          (e is DioException && CancelToken.isCancel(e))) {
        return null;
      }
      if (forceRefresh && previousSongs.isNotEmpty) {
        addLog('WebDAV 歌单强制刷新失败，已保留当前列表: $e');
        return null;
      }
      List<String> cachedSongs = [];
      try {
        cachedSongs = await _readCachedSongsForAccount(account);
      } catch (cacheError) {
        addLog('读取本地缓存失败: $cacheError');
      }
      if (isCurrentAccount()) {
        setState(() {
          realNasSongs = cachedSongs;
          _cachedFiles = cachedSongs.toSet();
          isLoading = false;
          _showingCachedSongsOnly = true;
          if (_sameAccount(playingAccount, account) && _playbackQueue.isEmpty) {
            _setPlaybackLibrary(cachedSongs, restoreOrder: true);
          }
        });
      }
      addLog('WebDAV 连接失败，已切换到离线缓存（${cachedSongs.length} 首）: $e');
      return null;
    } finally {
      if (isCurrentAccount()) setState(() => isLoading = false);
      if (identical(_songListCancelToken, cancelToken)) {
        _songListCancelToken = null;
      }
    }
  }

  Future<void> _forceRefreshSongList() async {
    if (activeAccount == null || isLoading) return;
    final account = activeAccount;
    final requestId = _songListRequestId + 1;
    final result = await fetchSongsFromWebDav(forceRefresh: true);
    if (!mounted ||
        requestId != _songListRequestId ||
        !_sameAccount(activeAccount, account)) {
      return;
    }
    if (result == null) {
      _showPlaybackMessage('刷新失败，已保留当前歌曲列表');
      return;
    }
    _showPlaybackMessage(
      '同步完成：共 ${result.total} 首，新增 ${result.added} 首，移除 ${result.removed} 首'
      '${result.cleanupFailed > 0 ? '；${result.cleanupFailed} 首缓存待下次清理' : ''}',
    );
  }

  Future<void> playNasSong(
    String songName, {
    Duration initialPosition = Duration.zero,
    Map<String, dynamic>? account,
    bool fromQueue = false,
  }) {
    final owner = account ?? activeAccount;
    if (owner == null) return Future.value();
    if (!fromQueue) {
      final changedAccount = !_sameAccount(playingAccount, owner);
      playingAccount = Map.from(owner);
      final songs = _sameAccount(activeAccount, owner)
          ? realNasSongs
          : _playbackLibrarySongs;
      _setPlaybackLibrary(
        [...songs, songName],
        restoreOrder: changedAccount,
        anchor: songName,
      );
    }
    return runInLibrary(
      owner,
      () => _playNasSong(songName, initialPosition: initialPosition),
    );
  }

  Future<void> _playNasSong(
    String songName, {
    Duration initialPosition = Duration.zero,
    bool forceRemote = false,
  }) async {
    if (_cacheAccount == null) return;
    final requestId = ++_playRequestId;
    _coverChoiceRevision++;
    _playingLocalPath = null;
    _lyricChoiceRevision++;
    _displayedLyricRaw = null;
    _positionUpdatesForRequestId = null;
    _beginLyricSession();
    final assetGeneration = _songAssetGeneration(songName);
    _cacheDownloadTimer?.cancel();
    _cancelBackgroundDownloads();
    final preparationTimer = Stopwatch()..start();
    final account = Map<String, dynamic>.from(_cacheAccount!);
    playingAccount = account;
    String rawAuth =
        "Basic ${base64Encode(utf8.encode("${account['user']}:${account['pwd']}"))}";
    String remoteUrl = _buildWebDavFileUrl(account['url'].toString(), songName);

    final metadata = _metadataForSong(songName);
    _rememberedPositionMs = initialPosition.inMilliseconds;
    setState(() {
      _isLargeMode = currentLeftScreen == 2 && _isLargeMode;
      currentCoverUrl = defaultCoverUrl;
      final defaultTheme = buildCoverThemeColors(const Color(0xFF1ED760));
      _lyricHighlightColor = defaultTheme.accent;
      _bottomGlowColor = defaultTheme.glow;
      _currentFileName = songName;
      _currentPosition = initialPosition;
      _totalDuration = Duration.zero;
      currentPlayingSong = metadata.title;
      currentArtist = metadata.artist;
      _currentLyricSource = '';
      _lyricCandidates = [];
      _isRefreshingLyrics = false;
      _lyricOffset =
          _prefs.getDouble(_songPreferenceKey('lyricOffset', songName)) ?? 0.0;
      _parseRawLrcText("[00:00.00]正在检索本地缓存与网络词库...");
    });
    _syncDesktopLyricColor();

    audioHandler.updateCurrentSong(
      currentPlayingSong,
      currentArtist,
      currentCoverUrl,
    );
    unawaited(_applyCachedPresentation(songName, requestId, assetGeneration));

    try {
      String? playPath = forceRemote
          ? remoteUrl
          : await _getPlayableUrl(songName, remoteUrl);
      if (requestId != _playRequestId) return;
      _preparingPlaybackCount++;
      try {
        playPath = await prepareCachedOrRemote(
          preferred: playPath,
          remote: remoteUrl,
          isCurrent: () => mounted && requestId == _playRequestId,
          prepare: (path) => audioHandler.playSong(
            path,
            rawAuth,
            initialPosition: initialPosition,
            shouldContinue: () => requestId == _playRequestId,
          ),
          onCachedFailure: (path, error) async {
            await _markAudioCacheInvalid(path, error);
            addLog('本地音频缓存不可播放，尝试网络音源: $songName');
          },
        );
      } finally {
        _preparingPlaybackCount--;
      }
      if (playPath == null || !mounted || requestId != _playRequestId) return;
      _playingLocalPath = playPath.startsWith('http') ? null : playPath;
      _positionUpdatesForRequestId = requestId;
      preparationTimer.stop();
      final sourceLabel = playPath.startsWith('http') ? '网络流' : '本地缓存';
      addLog('音源已准备: $sourceLabel / ${preparationTimer.elapsedMilliseconds}ms');
      setState(() {
        currentLeftScreen = 2;
      });
      _recenterLyricsForLayout();
      _syncDesktopLyrics();
      unawaited(_savePlaybackState());
      if (playPath.startsWith('http')) {
        final cacheDir = await _audioCacheDirectory();
        if (cacheDir != null && requestId == _playRequestId) {
          _scheduleBackgroundCache(
            songName,
            remoteUrl,
            rawAuth,
            cacheDir,
            File('${cacheDir.path}/$songName'),
            assetGeneration,
          );
        }
      }
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted &&
            requestId == _playRequestId &&
            _currentFileName == songName) {
          unawaited(
            fetchLyricAndCover(songName, account, assetGeneration, requestId),
          );
        }
      });

      _resetScreenSaverTimer();
    } catch (e) {
      addLog("播放失败: $e");
      if (requestId == _playRequestId) {
        _showPlaybackMessage('播放失败，请检查网络或歌曲缓存');
      }
    }
  }

  Future<void> _applyCachedPresentation(
    String songName,
    int requestId,
    int assetGeneration,
  ) async {
    final coverRevision = _coverChoiceRevision;
    final presentationTimer = Stopwatch()..start();
    final lyricRevision = _lyricChoiceRevision;
    bool isCurrentSong() =>
        mounted &&
        requestId == _playRequestId &&
        _currentFileName == songName &&
        _isCurrentAssetGeneration(songName, assetGeneration);

    final lyricFuture = _readCachedLyric(
      songName,
      expectedGeneration: assetGeneration,
    );
    final cachedCoverPath = await _readCachedCoverPath(songName);
    if (!isCurrentSong()) return;
    if (cachedCoverPath != null && coverRevision == _coverChoiceRevision) {
      setState(() => currentCoverUrl = cachedCoverPath);
      addLog('本地封面已显示: ${presentationTimer.elapsedMilliseconds}ms');
      audioHandler.updateCurrentSong(
        currentPlayingSong,
        currentArtist,
        cachedCoverPath,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isCurrentSong()) {
          unawaited(_updatePalette(cachedCoverPath));
        }
      });
    }
    final cachedLyric = await lyricFuture;
    if (!isCurrentSong() ||
        lyricRevision != _lyricChoiceRevision ||
        cachedLyric == null ||
        cachedLyric.trim().isEmpty) {
      return;
    }
    setState(() => _currentLyricSource = _savedLyricSource(songName));
    _showLyricsForSong(
      songName,
      cachedLyric,
      expectedGeneration: assetGeneration,
    );
    addLog('本地歌词已显示: ${presentationTimer.elapsedMilliseconds}ms');
  }

  String _printDuration(Duration d) =>
      "${d.inMinutes.remainder(60).toString().padLeft(2, "0")}:${d.inSeconds.remainder(60).toString().padLeft(2, "0")}";

  Duration get _displayedPlaybackPosition => _draggingSeekMs == null
      ? _currentPosition
      : Duration(milliseconds: _draggingSeekMs!.round());

  double get _seekSliderValue {
    if (_totalDuration.inMilliseconds <= 0) return 0.0;
    return (_draggingSeekMs ?? _currentPosition.inMilliseconds.toDouble())
        .clamp(0.0, _totalDuration.inMilliseconds.toDouble());
  }

  void _onSeekStart(double value) {
    _resetScreenSaverTimer();
    _draggingSeekMs = value;
    _progressTick.value++;
  }

  void _onSeekChanged(double value) {
    _draggingSeekMs = value;
    _progressTick.value++;
  }

  Future<void> _onSeekEnd(double value) async {
    final requestId = _playRequestId;
    final targetPosition = Duration(milliseconds: value.round());
    try {
      await audioHandler.player.seek(targetPosition);
      if (!mounted || requestId != _playRequestId) return;
      _draggingSeekMs = null;
      _syncPlaybackPosition(forceLyricRecenter: true);
      addLog('进度跳转: ${_printDuration(targetPosition)}');
    } catch (error) {
      if (!mounted || requestId != _playRequestId) return;
      _draggingSeekMs = null;
      _progressTick.value++;
      addLog('进度跳转失败: $error');
    }
    _resetScreenSaverTimer();
  }

  Widget _buildScrollingLyrics(BuildContext context, {bool isMini = false}) {
    if (isMini && _isLargeMode) return const SizedBox.shrink();
    return RepaintBoundary(child: _buildLyricList(context, isMini: isMini));
  }

  Widget _buildLyricList(BuildContext context, {bool isMini = false}) {
    return ShaderMask(
      shaderCallback: (Rect bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0.0, 0.05, 0.95, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          final isUserDrag =
              notification is ScrollStartNotification &&
                  notification.dragDetails != null ||
              notification is ScrollUpdateNotification &&
                  notification.dragDetails != null;
          if (isUserDrag) _holdLyricAutoScroll();
          return false;
        },
        child: ListView.builder(
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          controller: isMini
              ? _miniLyricScrollController
              : _lyricScrollController,
          padding: EdgeInsets.symmetric(
            vertical: isMini
                ? s(90.0)
                : MediaQuery.of(context).size.height / 3.5,
          ),
          physics: const ClampingScrollPhysics(),
          itemCount: parsedLyrics.length,
          itemBuilder: (context, index) {
            final lyricFontSize = _isLargeMode
                ? _stageSize(_largeLyricFontSize)
                : _lyricFontSize;
            final lyricParts = parsedLyrics[index]['text'].toString().split(
              '\n',
            );
            final translation = lyricParts.length > 1
                ? lyricParts.sublist(1).join('\n').trim()
                : '';
            return LyricHighlightBuilder(
              activeIndex: _activeLyricIndex,
              index: index,
              builder: (context, isCurrent) {
                final primaryFontSize = isCurrent
                    ? (isMini
                          ? s(24)
                          : (_isLargeMode
                                ? lyricFontSize + _stageSize(6)
                                : lyricFontSize))
                    : (isMini
                          ? s(20)
                          : (_isLargeMode
                                ? lyricFontSize - _stageSize(8)
                                : lyricFontSize - s(10)));
                // Animating font size re-lays out bilingual text on every frame.
                // Keep the size change immediate; scrolling still animates.
                return DefaultTextStyle(
                  style: TextStyle(
                    fontSize: primaryFontSize,
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    color: isCurrent
                        ? _lyricHighlightColor
                        : (isMini ? Colors.black45 : Colors.black87),
                    height: 1.5,
                  ),
                  child: Container(
                    key: isMini ? _miniLyricKeys[index] : _lyricKeys[index],
                    padding: EdgeInsets.symmetric(
                      vertical: isMini ? s(9.0) : _stageSize(18.0),
                    ),
                    alignment: isMini ? Alignment.center : Alignment.centerLeft,
                    child: Text.rich(
                      TextSpan(
                        text: lyricParts.first,
                        children: translation.isEmpty
                            ? const []
                            : [
                                TextSpan(
                                  text: '\n$translation',
                                  style: TextStyle(
                                    fontSize: primaryFontSize * 0.72,
                                    fontWeight: FontWeight.normal,
                                    color: isCurrent
                                        ? _lyricHighlightColor.withValues(
                                            alpha: 0.78,
                                          )
                                        : Colors.black45,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                      ),
                      textAlign: isMini ? TextAlign.center : TextAlign.left,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final large = currentLeftScreen == 2 && _isLargeMode;
    final viewport = MediaQuery.sizeOf(context);
    final layoutWidth = large ? viewport.width : max(viewport.width, s(900));
    final layoutHeight = large ? viewport.height : max(viewport.height, s(520));
    final needsManualAdjustment =
        layoutWidth > viewport.width || layoutHeight > viewport.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncDiscAnimation();
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        try {
          platform.invokeMethod('sendToBackground');
        } catch (_) {}
      },
      child: Scaffold(
        floatingActionButton: needsManualAdjustment && _prefsReady
            ? FloatingActionButton.small(
                tooltip: '调整界面缩放',
                onPressed: () => _showUiScaleDialog(firstLaunch: false),
                child: const Icon(Icons.tune),
              )
            : null,
        body: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 800),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFFF2F6F9),
                    const Color(0xFFF2F6F9),
                    _bottomGlowColor,
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
            ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                // Keep the chosen scale until the user adjusts it.
                maxWidth: needsManualAdjustment ? layoutWidth : null,
                maxHeight: needsManualAdjustment ? layoutHeight : null,
                child: Row(
                  children: [
                    if (!large)
                      Container(
                        width: s(390),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.35),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          width: s(390),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: s(36),
                              horizontal: s(24),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      currentLeftScreen = 0;
                                      _isLargeMode = false;
                                    });
                                    _screenSaverTimer?.cancel();
                                  },
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.music_note,
                                        color: Colors.blueAccent,
                                        size: s(54),
                                      ),
                                      SizedBox(width: s(12)),
                                      Text(
                                        'NAS 乐库',
                                        style: TextStyle(
                                          color: Colors.black87,
                                          fontSize: s(30),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: AnimatedAlign(
                                    duration: const Duration(milliseconds: 600),
                                    curve: Curves.easeInOut,
                                    alignment:
                                        (currentPlayingSong == "等待播放" &&
                                            !isPlaying)
                                        ? Alignment.center
                                        : Alignment.topCenter,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(height: s(15)),
                                        _buildSongDisc(
                                          diameter: s(160),
                                          holeDiameter: s(40),
                                          rotateWithPlayback: true,
                                        ),
                                        SizedBox(height: s(15)),
                                        Text(
                                          currentPlayingSong,
                                          style: TextStyle(
                                            fontSize: s(30),
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                        ),
                                        Text(
                                          currentArtist,
                                          style: TextStyle(
                                            fontSize: s(20),
                                            color: Colors.black54,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (currentPlayingSong != "等待播放")
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: () {
                                                setState(() {
                                                  currentLeftScreen = 2;
                                                  _isLargeMode = false;
                                                  _resetScreenSaverTimer();
                                                });
                                                _syncPlaybackPosition(
                                                  forceLyricRecenter: true,
                                                );
                                              },
                                              child: Container(
                                                margin: EdgeInsets.symmetric(
                                                  vertical: s(12),
                                                ),
                                                child: _buildScrollingLyrics(
                                                  context,
                                                  isMini: true,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: s(6),
                                    vertical: s(12),
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.5),
                                    borderRadius: BorderRadius.circular(s(45)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      for (final button in [
                                        IconButton(
                                          icon: Icon(
                                            _loopMode == 0
                                                ? Icons.repeat
                                                : (_loopMode == 1
                                                      ? Icons.repeat_one
                                                      : Icons.shuffle),
                                          ),
                                          iconSize: s(33) * _btnScale,
                                          color: Colors.black87,
                                          onPressed: _toggleLoopMode,
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.skip_previous),
                                          iconSize: s(45) * _btnScale,
                                          color: Colors.black87,
                                          onPressed: () {
                                            _resetScreenSaverTimer();
                                            _playPrevSong();
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            isPlaying
                                                ? Icons.pause_circle_filled
                                                : Icons.play_circle_filled,
                                          ),
                                          iconSize: s(64) * _btnScale,
                                          color: _lyricHighlightColor,
                                          onPressed: () {
                                            _resetScreenSaverTimer();
                                            _togglePlayPause();
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.skip_next),
                                          iconSize: s(45) * _btnScale,
                                          color: Colors.black87,
                                          onPressed: () {
                                            _resetScreenSaverTimer();
                                            _playNextSong(manual: true);
                                          },
                                        ),
                                      ])
                                        Flexible(child: button),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (!large) Container(width: 1, color: Colors.black12),
                    Expanded(
                      child: switch (currentLeftScreen) {
                        0 => _buildNasDashboard(),
                        1 => _buildSongListView(),
                        2 => _buildQQMusicUnifiedStage(),
                        _ => _buildSettingsScreen(),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNasDashboard() {
    return Padding(
      padding: EdgeInsets.all(s(36.0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '我的资源',
            style: TextStyle(
              fontSize: s(36),
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          SizedBox(height: s(36)),
          Expanded(
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.4,
                crossAxisSpacing: s(24),
                mainAxisSpacing: s(24),
              ),
              itemCount: webdavAccounts.length + 1,
              itemBuilder: (context, index) {
                if (index == webdavAccounts.length)
                  return _buildDashboardCard(
                    title: '系统设置 ⚙️',
                    subtitle: '添加云盘与偏好设置',
                    onTap: () {
                      setState(() {
                        currentLeftScreen = 3;
                      });
                    },
                  );
                var acc = webdavAccounts[index];
                return _buildDashboardCard(
                  title: '${acc['name']} ☁️',
                  subtitle: activeAccount == acc && realNasSongs.isNotEmpty
                      ? '已挂载 / 共 ${realNasSongs.length} 首歌'
                      : '点击连接挂载',
                  onTap: () async {
                    final switchingAccount = !_sameAccount(activeAccount, acc);
                    setState(() {
                      activeAccount = acc;
                      currentLeftScreen = 1;
                      if (switchingAccount) {
                        realNasSongs = [];
                        _slidingSongName = null;
                        _showingCachedSongsOnly = false;
                      }
                    });
                    await _restoreRememberedPlaylist(acc);
                    if (mounted && _sameAccount(activeAccount, acc)) {
                      await fetchSongsFromWebDav();
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.black87, size: s(36)),
          onPressed: () {
            setState(() {
              currentLeftScreen = 0;
            });
          },
        ),
        title: Text(
          '系统设置',
          style: TextStyle(
            color: Colors.black87,
            fontSize: s(28),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(s(48)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "已配置的 WebDAV 节点",
                  style: TextStyle(
                    fontSize: s(26),
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    padding: EdgeInsets.symmetric(
                      horizontal: s(24),
                      vertical: s(12),
                    ),
                  ),
                  icon: Icon(Icons.add, size: s(28)),
                  label: Text("添加", style: TextStyle(fontSize: s(24))),
                  onPressed: () => _showAddWebDAVDialog(),
                ),
              ],
            ),
            SizedBox(height: s(24)),
            ...webdavAccounts.asMap().entries.map((entry) {
              int idx = entry.key;
              var acc = entry.value;
              return Card(
                color: Colors.white.withOpacity(0.6),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(s(12)),
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.all(s(12)),
                  leading: Icon(
                    Icons.cloud_queue,
                    color: Colors.blueAccent,
                    size: s(36),
                  ),
                  title: Text(
                    acc['name'],
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(26),
                    ),
                  ),
                  subtitle: Text(acc['url'], style: TextStyle(fontSize: s(20))),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.edit,
                          color: Colors.black54,
                          size: s(36),
                        ),
                        onPressed: () => _showAddWebDAVDialog(editIndex: idx),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete,
                          color: Colors.redAccent,
                          size: s(36),
                        ),
                        onPressed: () {
                          setState(() {
                            if (activeAccount == webdavAccounts[idx])
                              activeAccount = null;
                            webdavAccounts.removeAt(idx);
                            _prefs.setString(
                              'webdavAccounts',
                              jsonEncode(webdavAccounts),
                            );
                          });
                        },
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
            SizedBox(height: s(48)),
            Text(
              "播放与显示偏好",
              style: TextStyle(
                fontSize: s(26),
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    "全局 UI 缩放: ",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _uiScale,
                      min: 0.4,
                      max: 2.5,
                      divisions: 21,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() {
                          _uiScale = val;
                        });
                        _prefs.setDouble('uiScale', val);
                        unawaited(_configureDesktopLyrics());
                        _updateCachedFilesList();
                      },
                    ),
                  ),
                  Text(
                    "${_uiScale.toStringAsFixed(1)}x",
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    "全局按钮缩放: ",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _btnScale,
                      min: 0.5,
                      max: 3.0,
                      divisions: 25,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() {
                          _btnScale = val;
                        });
                        _prefs.setDouble('btnScale', val);
                      },
                    ),
                  ),
                  Text(
                    "${_btnScale.toStringAsFixed(1)}x",
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: Text(
                '桌面歌词',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                _hasOverlayPermission
                    ? '后台播放时显示原文和译文；点 × 后保持关闭，可在这里重新开启'
                    : '需要悬浮窗权限，请点击下方“悬浮窗权限”授权',
                style: TextStyle(fontSize: s(20)),
              ),
              value: _desktopLyricsEnabled,
              onChanged: (value) {
                setState(() => _desktopLyricsEnabled = value);
                _prefs.setBool('desktopLyricsEnabled', value);
                unawaited(_configureDesktopLyrics(setEnabled: true));
                if (value && !_hasOverlayPermission) {
                  unawaited(platform.invokeMethod('requestOverlayPermission'));
                }
              },
            ),
            if (_desktopLyricsEnabled) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(16)),
                child: Row(
                  children: [
                    Text('桌面歌词宽度', style: TextStyle(fontSize: s(20))),
                    Expanded(
                      child: Slider(
                        value: _desktopLyricWidth,
                        min: .3,
                        max: 1,
                        divisions: 70,
                        label: '${(_desktopLyricWidth * 100).round()}%',
                        onChanged: (value) {
                          setState(() => _desktopLyricWidth = value);
                          // Resize the native window without resending the whole LRC.
                          unawaited(
                            _configureDesktopLyrics(
                              syncLyrics: false,
                              setWidth: true,
                            ),
                          );
                        },
                        onChangeEnd: (value) => unawaited(
                          _prefs.setDouble('desktopLyricWidth', value),
                        ),
                      ),
                    ),
                    Text(
                      '${(_desktopLyricWidth * 100).round()}%',
                      style: TextStyle(fontSize: s(20)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(16)),
                child: Text(
                  '桌面上先解锁，再拖动 ↔ 调整宽度；拖动歌词可移动位置',
                  style: TextStyle(fontSize: s(18), color: Colors.grey),
                ),
              ),
              SwitchListTile(
                title: Text('桌面歌词双行显示', style: TextStyle(fontSize: s(22))),
                subtitle: Text(
                  '第一行左对齐、第二行右对齐；译文随原文显示',
                  style: TextStyle(fontSize: s(18)),
                ),
                value: _desktopLyricsStaggered,
                onChanged: (value) {
                  setState(() => _desktopLyricsStaggered = value);
                  unawaited(_prefs.setBool('desktopLyricsStaggered', value));
                  unawaited(_configureDesktopLyrics());
                },
              ),
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  title: Text('桌面歌词颜色', style: TextStyle(fontSize: s(20))),
                  subtitle: Text(
                    '原文和译文使用同一色系',
                    style: TextStyle(fontSize: s(18)),
                  ),
                  trailing: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: s(12),
                      vertical: s(6),
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(s(8)),
                    ),
                    child: Text(
                      _desktopLyricColors[_desktopLyricColor] ?? '自定义',
                      style: TextStyle(
                        color: Color(_effectiveDesktopLyricColor),
                        fontSize: s(20),
                      ),
                    ),
                  ),
                  onTap: _chooseDesktopLyricColor,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(16)),
                child: Row(
                  children: [
                    Text('桌面歌词字号', style: TextStyle(fontSize: s(20))),
                    Expanded(
                      child: Slider(
                        value: _desktopLyricFontSize,
                        min: 18,
                        max: 48,
                        divisions: 30,
                        label: _desktopLyricFontSize.round().toString(),
                        onChanged: (value) {
                          setState(() => _desktopLyricFontSize = value);
                          _prefs.setDouble('desktopLyricFontSize', value);
                          unawaited(_configureDesktopLyrics());
                        },
                      ),
                    ),
                    Text(
                      '${_desktopLyricFontSize.round()}',
                      style: TextStyle(fontSize: s(20)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(16)),
                child: Row(
                  children: [
                    Text('桌面歌词底色浓度', style: TextStyle(fontSize: s(20))),
                    Expanded(
                      child: Slider(
                        value: _desktopLyricOpacity,
                        min: 0,
                        max: .85,
                        divisions: 17,
                        onChanged: (value) {
                          setState(() => _desktopLyricOpacity = value);
                          _prefs.setDouble('desktopLyricOpacity', value);
                          unawaited(_configureDesktopLyrics());
                        },
                      ),
                    ),
                    Text(
                      '${(_desktopLyricOpacity * 100).round()}%',
                      style: TextStyle(fontSize: s(20)),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                title: Text('锁定位置并允许点击穿透', style: TextStyle(fontSize: s(22))),
                subtitle: Text(
                  '开启后可操作歌词下方的应用；桌面歌词末尾的锁按钮可随时切换',
                  style: TextStyle(fontSize: s(18)),
                ),
                value: _desktopLyricsLocked,
                onChanged: (value) {
                  setState(() => _desktopLyricsLocked = value);
                  _prefs.setBool('desktopLyricsLocked', value);
                  unawaited(_configureDesktopLyrics(setLock: true));
                },
              ),
              ListTile(
                title: Text('恢复桌面歌词默认位置', style: TextStyle(fontSize: s(20))),
                trailing: Icon(Icons.open_with, size: s(24)),
                onTap: () async {
                  try {
                    await platform.invokeMethod('resetDesktopLyricsPosition');
                  } catch (error) {
                    addLog('桌面歌词位置重置失败: $error');
                  }
                },
              ),
            ],
            SwitchListTile(
              title: Text(
                "断电记忆自动播放",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                "启动时自动从上次断电位置继续播放",
                style: TextStyle(fontSize: s(20)),
              ),
              value: _autoPlay,
              onChanged: (val) {
                setState(() => _autoPlay = val);
                _prefs.setBool('autoPlay', val);
              },
            ),
            SwitchListTile(
              title: Text(
                "隐藏系统顶部状态栏",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                "开启后顶栏隐藏，但保留空调导航底栏",
                style: TextStyle(fontSize: s(20)),
              ),
              value: !_showStatusBar,
              onChanged: (val) {
                setState(() => _showStatusBar = !val);
                _prefs.setBool('showStatusBar', !val);
                _applyStatusBar();
              },
            ),

            ListTile(
              title: Text(
                "悬浮窗权限",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                _hasOverlayPermission
                    ? "✅ 已获得授权，可显示桌面歌词并支持后台唤醒"
                    : "❌ 未授权，桌面歌词无法显示，后台唤醒也可能被拦截",
                style: TextStyle(
                  fontSize: s(20),
                  color: _hasOverlayPermission
                      ? Colors.green
                      : Colors.redAccent,
                ),
              ),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _hasOverlayPermission
                      ? Colors.grey
                      : Colors.blueAccent,
                  padding: EdgeInsets.symmetric(
                    horizontal: s(24),
                    vertical: s(12),
                  ),
                ),
                onPressed: () async {
                  if (!_hasOverlayPermission) {
                    await platform.invokeMethod('requestOverlayPermission');
                  }
                },
                child: Text(
                  _hasOverlayPermission ? "已授权" : "去授权",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: s(20),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Divider(color: Colors.black12),

            SwitchListTile(
              title: Text(
                "开机自动运行",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                "通电开机后，在后台自动拉起本播放器",
                style: TextStyle(fontSize: s(20)),
              ),
              value: _startOnBoot,
              onChanged: (val) {
                setState(() => _startOnBoot = val);
                _prefs.setBool('startOnBoot', val);
              },
            ),
            if (_startOnBoot)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: s(16),
                  vertical: s(4),
                ),
                child: Row(
                  children: [
                    Text(
                      "自启延迟时间: ",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: s(24),
                        color: Colors.black54,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _bootDelay.toDouble(),
                        min: 0.0,
                        max: 60.0,
                        divisions: 60,
                        activeColor: Colors.blueAccent.withOpacity(0.7),
                        onChanged: (val) {
                          setState(() => _bootDelay = val.toInt());
                          _prefs.setInt('bootDelay', val.toInt());
                        },
                      ),
                    ),
                    SizedBox(
                      width: s(80),
                      child: Text(
                        "$_bootDelay 秒",
                        style: TextStyle(
                          fontSize: s(22),
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: s(48)),
            Text(
              '\u542f\u52a8\u5176\u4ed6\u5e94\u7528',
              style: TextStyle(
                fontSize: s(26),
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
            SwitchListTile(
              title: Text(
                '\u542f\u52a8\u65f6\u62c9\u8d77\u5176\u4ed6\u5e94\u7528',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24)),
              ),
              subtitle: Text(
                '\u5f00\u542f\u540e\uff0c\u5e94\u7528\u542f\u52a8\u540e\u81ea\u52a8\u6253\u5f00\u4e0b\u65b9\u9009\u5b9a\u7684\u5e94\u7528',
                style: TextStyle(fontSize: s(20)),
              ),
              value: _startOtherAppOnBoot,
              onChanged: (val) {
                setState(() => _startOtherAppOnBoot = val);
                _prefs.setBool('startOtherAppOnBoot', val);
              },
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    '\u76ee\u6807\u5e94\u7528: ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _bootOtherAppLabel.isNotEmpty
                          ? _bootOtherAppLabel
                          : '\u672a\u9009\u62e9',
                      style: TextStyle(
                        fontSize: s(22),
                        color: _bootOtherAppLabel.isNotEmpty
                            ? Colors.black87
                            : Colors.black38,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: s(16)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      padding: EdgeInsets.symmetric(
                        horizontal: s(20),
                        vertical: s(10),
                      ),
                    ),
                    icon: Icon(Icons.apps, size: s(28)),
                    label: Text(
                      '\u9009\u62e9\u5e94\u7528',
                      style: TextStyle(fontSize: s(22)),
                    ),
                    onPressed: () => _showAppPickerDialog(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    '\u542f\u52a8\u5ef6\u8fdf: ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _bootOtherAppDelay.toDouble(),
                      min: 1.0,
                      max: 30.0,
                      divisions: 29,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() => _bootOtherAppDelay = val.toInt());
                        _prefs.setInt('bootOtherAppDelay', val.toInt());
                      },
                    ),
                  ),
                  SizedBox(
                    width: s(80),
                    child: Text(
                      "${_bootOtherAppDelay}s",
                      style: TextStyle(
                        fontSize: s(22),
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    "自动进入大屏: ",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _screenSaverTimeout.toDouble(),
                      min: 0.0,
                      max: 60.0,
                      divisions: 60,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() {
                          _screenSaverTimeout = val.toInt();
                        });
                        _prefs.setInt('screenSaverTimeout', val.toInt());
                        _resetScreenSaverTimer();
                      },
                    ),
                  ),
                  Text(
                    _screenSaverTimeout == 0
                        ? "不自动切换"
                        : "$_screenSaverTimeout s",
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    "普通播放页歌词字号: ",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _lyricFontSize,
                      min: 30.0,
                      max: 100.0,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() => _lyricFontSize = val);
                        _prefs.setDouble('lyricFontSize', val);
                      },
                    ),
                  ),
                  Text(
                    _lyricFontSize.toInt().toString(),
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
              child: Row(
                children: [
                  Text(
                    "最大离线缓存 (GB): ",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: s(24),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _maxCacheGB,
                      min: 0.5,
                      max: 20.0,
                      divisions: 39,
                      activeColor: Colors.blueAccent,
                      onChanged: (val) {
                        setState(() => _maxCacheGB = val);
                      },
                      onChangeEnd: (val) {
                        _prefs.setDouble('maxCacheGB', val);
                        unawaited(_enforceCacheLimit());
                      },
                    ),
                  ),
                  Text(
                    _maxCacheGB.toStringAsFixed(1),
                    style: TextStyle(fontSize: s(20)),
                  ),
                ],
              ),
            ),

            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _showCacheOverview,
                icon: Icon(Icons.storage, size: s(24)),
                label: Text('查看缓存占用', style: TextStyle(fontSize: s(22))),
              ),
            ),
            SizedBox(height: s(48)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "方向盘按键调试日志",
                  style: TextStyle(
                    fontSize: s(26),
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  ),
                ),
                TextButton.icon(
                  icon: Icon(
                    Icons.delete_outline,
                    size: s(24),
                    color: Colors.redAccent,
                  ),
                  label: Text(
                    "清空",
                    style: TextStyle(fontSize: s(22), color: Colors.redAccent),
                  ),
                  onPressed: () => setState(() => _logs.clear()),
                ),
              ],
            ),
            SizedBox(height: s(12)),
            Container(
              height: s(400),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(s(12)),
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: _logTick,
                builder: (context, _, _) => _logs.isEmpty
                    ? Center(
                        child: Text(
                          "暂无日志\n按下方向盘按钮后此处会显示收到的按键",
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: s(20),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        controller: _logScrollController,
                        padding: EdgeInsets.symmetric(
                          horizontal: s(12),
                          vertical: s(8),
                        ),
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: EdgeInsets.symmetric(vertical: s(2)),
                            child: Text(
                              _logs[index],
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: s(18),
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),

            SizedBox(height: s(60)),
            Divider(color: Colors.black12, height: s(60)),
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                title: Text('检查更新', style: TextStyle(fontSize: s(24))),
                subtitle: Text(
                  _installedVersion.isEmpty
                      ? '从服务器获取最新版本'
                      : '当前版本 $_installedVersion',
                  style: TextStyle(fontSize: s(18)),
                ),
                trailing: _checkingUpdate
                    ? SizedBox(
                        width: s(24),
                        height: s(24),
                        child: const CircularProgressIndicator(),
                      )
                    : Icon(Icons.system_update, size: s(28)),
                onTap: _checkingUpdate
                    ? null
                    : () => _checkForUpdates(manual: true),
              ),
            ),
            if (_downloadedUpdateCode != null)
              TextButton.icon(
                onPressed: _installDownloadedUpdate,
                icon: Icon(Icons.install_mobile, size: s(24)),
                label: Text('继续安装已下载的更新', style: TextStyle(fontSize: s(20))),
              ),
            if (_downloadedUpdateCode != null)
              TextButton.icon(
                onPressed: _savingUpdateToDownloads
                    ? null
                    : _saveDownloadedUpdate,
                icon: Icon(Icons.save_alt, size: s(24)),
                label: Text(
                  _savingUpdateToDownloads ? '正在保存安装包…' : '保存到下载文件夹',
                  style: TextStyle(fontSize: s(20)),
                ),
              ),
            Center(
              child: Column(
                children: [
                  Text(
                    appAuthor,
                    style: TextStyle(
                      fontSize: s(22),
                      fontWeight: FontWeight.bold,
                      color: Colors.black54,
                    ),
                  ),
                  SizedBox(height: s(8)),
                  Text(
                    "Build: $appBuildTime",
                    style: TextStyle(
                      fontSize: s(18),
                      color: Colors.black38,
                      fontFamily: 'monospace',
                    ),
                  ),
                  SizedBox(height: s(40)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddWebDAVDialog({int? editIndex}) {
    var acc = editIndex != null ? webdavAccounts[editIndex] : null;
    TextEditingController nameCtrl = TextEditingController(
          text: acc?['name'] ?? "",
        ),
        urlCtrl = TextEditingController(text: acc?['url'] ?? ""),
        userCtrl = TextEditingController(text: acc?['user'] ?? ""),
        pwdCtrl = TextEditingController(text: acc?['pwd'] ?? "");
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            editIndex == null ? "添加 WebDAV" : "修改 WebDAV",
            style: TextStyle(fontSize: s(24)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: TextStyle(fontSize: s(20)),
                  decoration: const InputDecoration(
                    labelText: "显示名称 (例: 家里群晖)",
                  ),
                ),
                TextField(
                  controller: urlCtrl,
                  style: TextStyle(fontSize: s(20)),
                  decoration: const InputDecoration(
                    labelText: "URL (末尾 / 可省略)",
                  ),
                ),
                TextField(
                  controller: userCtrl,
                  style: TextStyle(fontSize: s(20)),
                  decoration: const InputDecoration(labelText: "用户名"),
                ),
                TextField(
                  controller: pwdCtrl,
                  style: TextStyle(fontSize: s(20)),
                  obscureText: true,
                  decoration: const InputDecoration(labelText: "密码"),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("取消", style: TextStyle(fontSize: s(20))),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  String normalizedUrl = urlCtrl.text.trim();
                  if (normalizedUrl.isNotEmpty && !normalizedUrl.endsWith('/'))
                    normalizedUrl = '$normalizedUrl/';
                  var newAcc = {
                    "name": nameCtrl.text,
                    "url": normalizedUrl,
                    "user": userCtrl.text,
                    "pwd": pwdCtrl.text,
                  };
                  if (editIndex != null) {
                    webdavAccounts[editIndex] = newAcc;
                    if (activeAccount == acc) activeAccount = newAcc;
                  } else {
                    webdavAccounts.add(newAcc);
                  }
                  _prefs.setString(
                    'webdavAccounts',
                    jsonEncode(webdavAccounts),
                  );
                });
                Navigator.pop(context);
              },
              child: Text("保存", style: TextStyle(fontSize: s(20))),
            ),
          ],
        );
      },
    );
  }

  List<String> get _visibleSongs {
    final criteria = '$_songSearch|$_onlyCached|$_reverseSongSort';
    if (identical(_filteredSource, realNasSongs) &&
        identical(_filteredCachedSource, _cachedFiles) &&
        _filteredCriteria == criteria)
      return _filteredSongs;
    _filteredSource = realNasSongs;
    _filteredCachedSource = _cachedFiles;
    _filteredCriteria = criteria;
    _filteredSongs = filterSongList(
      realNasSongs,
      query: _songSearch,
      cachedSongs: _cachedFiles,
      onlyCached: _onlyCached,
      descending: _reverseSongSort,
    );
    return _filteredSongs;
  }

  Widget _buildSongListView() {
    final visibleSongs = _visibleSongs;
    final lastSync = _lastLibrarySync;
    final syncLabel = lastSync == null
        ? '尚未同步'
        : '同步 ${lastSync.month}/${lastSync.day} '
              '${lastSync.hour.toString().padLeft(2, '0')}:'
              '${lastSync.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.black87, size: s(36)),
          onPressed: () {
            setState(() {
              currentLeftScreen = 0;
              _slidingSongName = null;
            });
          },
        ),
        title: Text(
          activeAccount != null
              ? '${activeAccount!['name']}${_showingCachedSongsOnly ? '（离线缓存）' : ''}'
              : '群晖歌单',
          style: TextStyle(
            color: Colors.black87,
            fontSize: s(28),
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: s(16)),
            child: TextButton.icon(
              onPressed: activeAccount == null || isLoading
                  ? null
                  : _forceRefreshSongList,
              icon: isLoading
                  ? SizedBox(
                      width: s(22),
                      height: s(22),
                      child: CircularProgressIndicator(strokeWidth: s(2)),
                    )
                  : Icon(Icons.sync, size: s(28)),
              label: Text(
                isLoading ? '同步中…' : '强制刷新',
                style: TextStyle(fontSize: s(20)),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(s(110)),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: s(16)),
            child: Column(
              children: [
                TextFormField(
                  key: ValueKey(
                    activeAccount == null ? '' : libraryCacheId(activeAccount!),
                  ),
                  initialValue: _songSearch,
                  style: TextStyle(fontSize: s(22)),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: s(26)),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: s(42),
                      minHeight: s(42),
                    ),
                    hintText: '搜索歌名或歌手',
                    contentPadding: EdgeInsets.all(s(10)),
                  ),
                  onChanged: (value) {
                    _songSearchDebounce?.cancel();
                    _songSearchDebounce = Timer(
                      const Duration(milliseconds: 180),
                      () {
                        if (mounted) setState(() => _songSearch = value);
                      },
                    );
                  },
                ),
                Row(
                  children: [
                    FilterChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: EdgeInsets.symmetric(horizontal: s(4)),
                      padding: EdgeInsets.all(s(6)),
                      label: Text('仅已缓存', style: TextStyle(fontSize: s(18))),
                      selected: _onlyCached,
                      onSelected: (value) =>
                          setState(() => _onlyCached = value),
                    ),
                    IconButton(
                      constraints: BoxConstraints(
                        minWidth: s(42),
                        minHeight: s(42),
                      ),
                      padding: EdgeInsets.all(s(8)),
                      tooltip: _reverseSongSort ? '按名称升序' : '按名称降序',
                      icon: Icon(
                        _reverseSongSort
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: s(24),
                      ),
                      onPressed: () =>
                          setState(() => _reverseSongSort = !_reverseSongSort),
                    ),
                    Expanded(
                      child: Text(
                        '${visibleSongs.length} 首 · $syncLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: s(16),
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: isLoading && realNasSongs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : (_showingCachedSongsOnly && realNasSongs.isEmpty)
          ? Center(
              child: Text(
                '网络不可用，暂无可播放的本地缓存',
                style: TextStyle(fontSize: s(24), color: Colors.black54),
              ),
            )
          : visibleSongs.isEmpty
          ? Center(
              child: Text('没有符合条件的歌曲', style: TextStyle(fontSize: s(24))),
            )
          : GestureDetector(
              onTap: () {
                // 点击空白区域关闭滑动状态
                if (_slidingSongName != null) {
                  setState(() => _slidingSongName = null);
                }
              },
              child: ListView.builder(
                controller: _playlistScrollController,
                itemCount: visibleSongs.length,
                itemBuilder: (context, index) {
                  String songName = visibleSongs[index];
                  bool isCurrent =
                      songName == _currentFileName &&
                      _sameAccount(activeAccount, playingAccount);
                  bool isCached = _cachedFiles.contains(songName);
                  bool isSliding = _slidingSongName == songName;
                  String nasName = activeAccount != null
                      ? activeAccount!['name']
                      : '未知云盘';

                  Widget songItem = Container(
                    height: s(114.0),
                    color: isCurrent
                        ? _lyricHighlightColor.withOpacity(0.12)
                        : Colors.transparent,
                    child: Center(
                      child: ListTile(
                        leading: SizedBox(
                          width: s(48),
                          child: isCurrent
                              ? Icon(
                                  Icons.equalizer,
                                  color: _lyricHighlightColor,
                                  size: s(36),
                                )
                              : Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: s(24),
                                    color: Colors.black54,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                        ),
                        title: Text(
                          songName.replaceAll(RegExp(r'\.[^.]+$'), ''),
                          style: TextStyle(
                            fontSize: s(26),
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isCurrent
                                ? _lyricHighlightColor
                                : Colors.black87,
                          ),
                        ),
                        subtitle: Text(
                          _showingCachedSongsOnly
                              ? '本地缓存 / 离线可播放'
                              : (isCached
                                    ? '来自 $nasName / 已缓存'
                                    : '来自 $nasName'),
                          style: TextStyle(
                            fontSize: s(18),
                            color: isCurrent
                                ? _lyricHighlightColor.withOpacity(0.7)
                                : Colors.black54,
                          ),
                        ),
                        trailing: Icon(
                          isCurrent
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          color: isCurrent
                              ? _lyricHighlightColor
                              : Colors.black87,
                          size: s(36),
                        ),
                        onTap: () {
                          if (isSliding) {
                            setState(() => _slidingSongName = null);
                          } else {
                            playNasSong(songName);
                          }
                        },
                      ),
                    ),
                  );

                  if (!isCached) return songItem;

                  return GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      if (details.delta.dx < -5 && !isSliding) {
                        setState(() => _slidingSongName = songName);
                      } else if (details.delta.dx > 5 && isSliding) {
                        setState(() => _slidingSongName = null);
                      }
                    },
                    child: Stack(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          margin: EdgeInsets.only(
                            right: isSliding ? s(120) : 0,
                          ),
                          child: songItem,
                        ),
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          right: isSliding ? 0 : s(-120),
                          top: 0,
                          bottom: 0,
                          width: s(120),
                          child: GestureDetector(
                            onTap: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(
                                    '清除缓存',
                                    style: TextStyle(fontSize: s(24)),
                                  ),
                                  content: Text(
                                    '确定要清除「${songName.replaceAll(RegExp(r'\.[^.]+$'), '')}」的音频、歌词和封面缓存吗？',
                                    style: TextStyle(fontSize: s(22)),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: Text(
                                        '取消',
                                        style: TextStyle(fontSize: s(20)),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: Text(
                                        '清除',
                                        style: TextStyle(
                                          fontSize: s(20),
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true || !context.mounted) return;
                              setState(() => _slidingSongName = null);
                              final cleared = await _deleteCacheFile(songName);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    cleared
                                        ? '已清除音频、歌词和封面缓存'
                                        : '缓存清除失败，请查看运行日志',
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              color: Colors.redAccent,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.delete,
                                      color: Colors.white,
                                      size: s(32),
                                    ),
                                    SizedBox(height: s(4)),
                                    Text(
                                      '清除缓存',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: s(16),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }

  Future<void> _saveLargeDisplaySettings() async {
    if (!_prefsReady) return;
    await Future.wait([
      _prefs.setDouble('largeLyricFontSize', _largeLyricFontSize),
      _prefs.setDouble('largeClockFontSize', _largeClockFontSize),
      _prefs.setDouble('largeUiScale', _largeUiScale),
    ]);
  }

  void _updateLargeDisplay({
    double? fontSize,
    double? clockFontSize,
    double? scale,
  }) {
    final nextFont = (fontSize ?? _largeLyricFontSize).clamp(20.0, 100.0);
    final nextClockFont = (clockFontSize ?? _largeClockFontSize).clamp(
      30.0,
      120.0,
    );
    final nextScale = (scale ?? _largeUiScale).clamp(0.8, 2.0);
    if (nextFont == _largeLyricFontSize &&
        nextClockFont == _largeClockFontSize &&
        nextScale == _largeUiScale) {
      return;
    }
    // 仅重新布局歌词，取消旧尺寸下的滚动定位，不重新解析歌词或请求网络。
    _lyricSessionId++;
    _lyricAutoScrollResumeTimer?.cancel();
    _lyricsManuallyScrolled = false;
    _cancelLyricScrollAnimations();
    setState(() {
      _largeLyricFontSize = nextFont;
      _largeClockFontSize = nextClockFont;
      _largeUiScale = nextScale;
    });
    _scheduleLyricRecenter(immediate: true);
  }

  Widget _buildLargeDisplayControls() {
    return Material(
      elevation: s(6),
      color: const Color(0xFFF7FAFC),
      borderRadius: BorderRadius.circular(s(18)),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(s(14)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '大屏显示',
                    style: TextStyle(
                      fontSize: s(20),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '收起显示调整',
                  icon: Icon(Icons.close, size: s(24)),
                  onPressed: () {
                    setState(() => _showLargeDisplayControls = false);
                    unawaited(_saveLargeDisplaySettings());
                  },
                ),
              ],
            ),
            Text(
              '歌词字号  ${_largeLyricFontSize.round()}',
              style: TextStyle(fontSize: s(17)),
            ),
            Slider(
              value: _largeLyricFontSize,
              min: 20,
              max: 100,
              divisions: 80,
              onChanged: (value) => _updateLargeDisplay(fontSize: value),
              onChangeEnd: (_) => unawaited(_saveLargeDisplaySettings()),
            ),
            Text(
              '时间字号  ${_largeClockFontSize.round()}',
              style: TextStyle(fontSize: s(17)),
            ),
            Slider(
              value: _largeClockFontSize,
              min: 30,
              max: 120,
              divisions: 90,
              onChanged: (value) => _updateLargeDisplay(clockFontSize: value),
              onChangeEnd: (_) => unawaited(_saveLargeDisplaySettings()),
            ),
            Text(
              '大屏缩放  ${_largeUiScale.toStringAsFixed(2)}×',
              style: TextStyle(fontSize: s(17)),
            ),
            Slider(
              value: _largeUiScale,
              min: 0.8,
              max: 2.0,
              divisions: 24,
              onChanged: (value) => _updateLargeDisplay(scale: value),
              onChangeEnd: (_) => unawaited(_saveLargeDisplaySettings()),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '实时生效 · 自动保存',
                    style: TextStyle(fontSize: s(14), color: Colors.black54),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final scale = _uiScale.clamp(0.8, 2.0);
                    _updateLargeDisplay(
                      fontSize: _lyricFontSize / scale,
                      clockFontSize: 70,
                      scale: scale,
                    );
                    unawaited(_saveLargeDisplaySettings());
                  },
                  child: Text('重置', style: TextStyle(fontSize: s(16))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQQMusicUnifiedStage() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = _isLargeMode
              ? _stageSize(75).clamp(0.0, constraints.maxWidth * 0.07)
              : _stageSize(75);
          final discSize =
              (_isLargeMode
                      ? _stageSize(240).clamp(
                          0.0,
                          min(
                            constraints.maxWidth * 0.23,
                            constraints.maxHeight * 0.38,
                          ),
                        )
                      : _stageSize(220))
                  .toDouble();
          final layoutDuration = _showLargeDisplayControls
              ? Duration.zero
              : const Duration(milliseconds: 450);
          final titlePanelWidth = (constraints.maxWidth - horizontalPadding * 2)
              .clamp(0.0, _isLargeMode ? constraints.maxWidth : _stageSize(750))
              .toDouble();
          final clockStyle = TextStyle(
            fontSize: _stageSize(_largeClockFontSize),
            height: 1,
            fontWeight: FontWeight.w200,
            color: Colors.black87,
            fontFamily: 'monospace',
          );
          final songHeading = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentPlayingSong,
                style: TextStyle(
                  fontSize: _isLargeMode ? _stageSize(40) : _stageSize(34),
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                currentArtist,
                style: TextStyle(
                  fontSize: _stageSize(18),
                  color: Colors.black54,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _isLargeMode = !_isLargeMode;
                if (!_isLargeMode) _showLargeDisplayControls = false;
                _resetScreenSaverTimer();
              });
              _recenterLyricsForLayout();
            },
            // The foreground lyric ListView covers the disc's hit-test area.
            // Keep its long-press action on the stage; vertical drags still scroll.
            onLongPressStart: _isLargeMode
                ? (details) {
                    final discBounds = Rect.fromLTWH(
                      constraints.maxWidth - horizontalPadding - discSize,
                      constraints.maxHeight - _stageSize(75) - discSize,
                      discSize,
                      discSize,
                    );
                    if (discBounds.contains(details.localPosition)) {
                      _showCoverSelectionDialog();
                    }
                  }
                : null,
            child: Stack(
              children: [
                Positioned(
                  left: _stageSize(30),
                  top: _stageSize(30),
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_back_ios,
                      color: Colors.black87,
                      size: _stageSize(36),
                    ),
                    onPressed: () {
                      setState(() {
                        currentLeftScreen = 1;
                        _screenSaverTimer?.cancel();
                        _scrollToCurrentSong();
                      });
                    },
                  ),
                ),
                // Background → rotating cover → lyrics. Rotation stays in its own layer.
                AnimatedPositioned(
                  duration: layoutDuration,
                  curve: Curves.easeInOut,
                  right: horizontalPadding,
                  bottom: _isLargeMode ? _stageSize(75) : _stageSize(225),
                  width: discSize,
                  height: discSize,
                  child: IgnorePointer(
                    ignoring: !_isLargeMode,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _isLargeMode ? 1.0 : 0.0,
                      child: _buildSongDisc(
                        diameter: discSize,
                        holeDiameter: _stageSize(45),
                        rotateWithPlayback: _isLargeMode,
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: layoutDuration,
                  curve: Curves.easeInOut,
                  left: horizontalPadding,
                  top: _isLargeMode ? _stageSize(75) : _stageSize(90),
                  bottom: _isLargeMode ? _stageSize(30) : _stageSize(240),
                  width: titlePanelWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_isLargeMode)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: songHeading),
                            SizedBox(width: _stageSize(24)),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: titlePanelWidth * 0.45,
                              ),
                              child: ValueListenableBuilder<String>(
                                valueListenable: _clockText,
                                builder: (context, time, _) => FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(time, style: clockStyle),
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        songHeading,
                      SizedBox(height: _stageSize(15)),
                      Expanded(
                        child: _buildScrollingLyrics(context, isMini: false),
                      ),
                    ],
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                  left: _stageSize(75),
                  right: _stageSize(75),
                  bottom: _isLargeMode ? _stageSize(-180) : _stageSize(30),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _isLargeMode ? 0.0 : 1.0,
                    child: Column(
                      children: [
                        ValueListenableBuilder<int>(
                          valueListenable: _progressTick,
                          builder: (context, _, _) => Row(
                            children: [
                              Text(
                                _printDuration(_displayedPlaybackPosition),
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: _stageSize(18),
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _seekSliderValue,
                                  min: 0.0,
                                  max: _totalDuration.inMilliseconds > 0
                                      ? _totalDuration.inMilliseconds.toDouble()
                                      : 1.0,
                                  activeColor: Colors.black87,
                                  inactiveColor: Colors.black12,
                                  onChangeStart: _onSeekStart,
                                  onChanged: _onSeekChanged,
                                  onChangeEnd: _onSeekEnd,
                                ),
                              ),
                              Text(
                                _printDuration(_totalDuration),
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: _stageSize(18),
                                ),
                              ),
                            ],
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: Icon(
                                  _loopMode == 0
                                      ? Icons.repeat
                                      : (_loopMode == 1
                                            ? Icons.repeat_one
                                            : Icons.shuffle),
                                ),
                                iconSize: _stageSize(42) * _btnScale,
                                color: Colors.black87,
                                onPressed: _toggleLoopMode,
                              ),
                              SizedBox(width: _stageSize(36)),
                              IconButton(
                                icon: const Icon(Icons.skip_previous),
                                iconSize: _stageSize(64) * _btnScale,
                                color: Colors.black87,
                                onPressed: () {
                                  _resetScreenSaverTimer();
                                  _playPrevSong();
                                },
                              ),
                              SizedBox(width: _stageSize(24)),
                              IconButton(
                                icon: Icon(
                                  isPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                ),
                                iconSize: _stageSize(100) * _btnScale,
                                color: _lyricHighlightColor,
                                onPressed: () {
                                  _resetScreenSaverTimer();
                                  _togglePlayPause();
                                },
                              ),
                              SizedBox(width: _stageSize(24)),
                              IconButton(
                                icon: const Icon(Icons.skip_next),
                                iconSize: _stageSize(64) * _btnScale,
                                color: Colors.black87,
                                onPressed: () {
                                  _resetScreenSaverTimer();
                                  _playNextSong(manual: true);
                                },
                              ),
                              SizedBox(width: _stageSize(30)),
                              IconButton(
                                tooltip: '歌词选择',
                                icon: _isRefreshingLyrics
                                    ? SizedBox(
                                        width: _stageSize(32),
                                        height: _stageSize(32),
                                        child: CircularProgressIndicator(
                                          strokeWidth: _stageSize(3),
                                          color: Colors.black54,
                                        ),
                                      )
                                    : Icon(
                                        Icons.lyrics_outlined,
                                        size: _stageSize(42) * _btnScale,
                                      ),
                                color: _lyricCandidates.length > 1
                                    ? _lyricHighlightColor
                                    : Colors.black87,
                                onPressed: _showLyricSelectionDialog,
                              ),
                              IconButton(
                                tooltip: '选择封面（也可长按圆盘）',
                                icon: const Icon(Icons.image_search),
                                iconSize: _stageSize(42) * _btnScale,
                                color: Colors.black87,
                                onPressed: _showCoverSelectionDialog,
                              ),
                              SizedBox(width: _stageSize(18)),
                              IconButton(
                                icon: const Icon(Icons.timer),
                                iconSize: _stageSize(42) * _btnScale,
                                color: Colors.black87,
                                onPressed: () {
                                  _resetScreenSaverTimer();
                                  _showLyricOffsetDialog();
                                },
                              ),
                              SizedBox(width: _stageSize(18)),
                              IconButton(
                                icon: const Icon(Icons.queue_music),
                                iconSize: _stageSize(42) * _btnScale,
                                color: Colors.black87,
                                onPressed: () async {
                                  if (playingAccount != null &&
                                      !_sameAccount(
                                        activeAccount,
                                        playingAccount,
                                      )) {
                                    setState(() {
                                      activeAccount = playingAccount;
                                    });
                                    await fetchSongsFromWebDav(silent: true);
                                  }
                                  if (!mounted) return;
                                  setState(() {
                                    currentLeftScreen = 1;
                                    _isLargeMode = false;
                                  });
                                  _screenSaverTimer?.cancel();
                                  Future.delayed(
                                    const Duration(milliseconds: 300),
                                    () {
                                      if (mounted) _scrollToCurrentSong();
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_isLargeMode)
                  Positioned(
                    left: _stageSize(92),
                    top: _stageSize(24),
                    child: TextButton.icon(
                      icon: Icon(Icons.text_fields, size: s(24)),
                      label: Text('显示调整', style: TextStyle(fontSize: s(17))),
                      onPressed: () {
                        setState(
                          () => _showLargeDisplayControls =
                              !_showLargeDisplayControls,
                        );
                        if (!_showLargeDisplayControls) {
                          unawaited(_saveLargeDisplaySettings());
                        }
                      },
                    ),
                  ),
                if (_isLargeMode && _showLargeDisplayControls)
                  Positioned(
                    right: s(18),
                    bottom: s(18),
                    width: min(s(380), max(0.0, constraints.maxWidth - s(36))),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.65,
                      ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: _buildLargeDisplayControls(),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<List<LyricCandidate>> _refreshLyricCandidates(
    String songName,
    String title,
    String artist,
    Duration duration,
  ) async {
    if (mounted && _currentFileName == songName)
      setState(() => _isRefreshingLyrics = true);
    final candidates = await _fetchLrclibCandidates(title, artist, duration);
    if (mounted && _currentFileName == songName) {
      setState(() {
        _lyricCandidates = candidates;
        _isRefreshingLyrics = false;
      });
    }
    return candidates;
  }

  Future<void> _retryCurrentLyricTranslation() async {
    final account = playingAccount;
    if (account == null || _currentFileName.isEmpty) return;
    final song = _currentFileName;
    final request = _playRequestId;
    await runInLibrary(account, () async {
      final revision = ++_lyricChoiceRevision;
      _latestLyricsForTranslation.remove(_songTaskKey(song));
      final generation = _songAssetGeneration(song);
      final file = await _lyricCacheFile(song, createDirectory: false);
      if (!await file.exists() || !mounted || request != _playRequestId) return;
      final lyrics = await file.readAsString();
      if (!mounted ||
          request != _playRequestId ||
          revision != _lyricChoiceRevision)
        return;
      final cache = await _loadLyricLineCache(song);
      if (!mounted ||
          request != _playRequestId ||
          revision != _lyricChoiceRevision)
        return;
      if (missingLyricTranslationLines(lyrics, cache).isEmpty) {
        _showPlaybackMessage('当前歌词的译文已齐全，或没有需要翻译的英文行');
        return;
      }
      _showPlaybackMessage('正在翻译缺失的歌词行');
      _scheduleEnglishLyricTranslation(
        song,
        lyrics,
        expectedGeneration: generation,
        expectedLyricRevision: revision,
      );
    });
  }

  Uri _coverCandidateUri(
    String title,
    String artist,
    String source, {
    bool refresh = false,
    String? id,
    bool preview = false,
    double duration = 0,
  }) => Uri.parse(coverProxyBaseUrl)
      .resolve('covers.php')
      .replace(
        queryParameters: {
          'title': title,
          'artist': artist,
          'source': source,
          if (source == 'community') 'duration': '$duration',
          if (source == 'community' && _songSelections != null)
            'device_id': _songSelections!.deviceId,
          if (refresh) 'refresh': '1',
          if (id != null) 'action': 'image',
          if (id != null) 'id': id,
          if (preview) 'preview': '1',
        },
      );

  Future<List<CoverCandidate>> _searchCoverCandidates(
    String title,
    String artist,
    String source, {
    bool refresh = false,
    CancelToken? cancelToken,
    double duration = 0,
    String lyrics = '',
  }) async {
    addLog('封面候选请求: title="$title", artist="$artist", source=$source');
    final uri = _coverCandidateUri(
      title,
      artist,
      source,
      refresh: refresh,
      duration: duration,
    );
    final options = Options(receiveTimeout: const Duration(seconds: 30));
    Response<dynamic> response;
    try {
      response = source == 'community'
          ? await _externalDio.postUri(
              uri,
              data: {...uri.queryParameters, 'lyrics': lyrics},
              cancelToken: cancelToken,
              options: options,
            )
          : await _externalDio.getUri(
              uri,
              cancelToken: cancelToken,
              options: options,
            );
    } on DioException catch (error) {
      // Keep cover selection usable before the server update is deployed.
      if (source != 'community' || error.response?.statusCode != 405) rethrow;
      response = await _externalDio.getUri(
        uri,
        cancelToken: cancelToken,
        options: options,
      );
    }
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    return CoverCandidate.parse(data);
  }

  Future<void> _showCoverSelectionDialog() {
    final account = playingAccount;
    if (account == null || _currentFileName.isEmpty) return Future.value();
    return runInLibrary(account, _showCoverSelectionDialogInternal);
  }

  Future<void> _showCoverSelectionDialogInternal() async {
    _resetScreenSaverTimer();
    final song = _currentFileName;
    final request = _playRequestId;
    final generation = _songAssetGeneration(song);
    final metadata = _metadataForSong(song);
    final artist = metadata.artist == '私人乐库' ? '' : metadata.artist;
    const sources = coverSourceLabels;
    var source = 'community';
    final duration = _positionUpdatesForRequestId == request
        ? (audioHandler.player.duration ?? _totalDuration).inMilliseconds / 1000
        : 0.0;
    // Read only the stored source lyrics. Display text may contain locally
    // generated translations and would incorrectly change its fingerprint.
    var matchLyrics = '';
    final lyricRevision = _lyricChoiceRevision;
    try {
      final file = await _lyricCacheFile(song, createDirectory: false);
      if (await file.exists() && await file.length() <= 262144) {
        matchLyrics = await file.readAsString();
      }
    } catch (_) {}
    if (!mounted || request != _playRequestId) return;
    if (lyricRevision != _lyricChoiceRevision) matchLyrics = '';
    var selectedId = '';
    var selectedImageRevision = '';
    try {
      final saved = jsonDecode(
        _prefs.getString(_songPreferenceKey('coverSelection', song)) ?? '{}',
      );
      if (saved is Map) {
        selectedId = saved['id']?.toString() ?? '';
        selectedImageRevision = saved['server_revision']?.toString() ?? '';
      }
    } catch (_) {}
    final token = CancelToken();
    final previewLoader = CoverPreviewLoader(
      _externalDio,
      cancelToken: token,
      onError: (uri, error) => addLog(
        '封面预览失败: source=${uri.queryParameters['source']}, '
        'id=${uri.queryParameters['id']}, ${_externalErrorText(error)}',
      ),
    );
    final searches = <String, Future<List<CoverCandidate>>>{};
    Future<List<CoverCandidate>> search({bool refresh = false}) {
      if (refresh) searches.remove(source);
      return searches.putIfAbsent(
        source,
        () => _searchCoverCandidates(
          metadata.title,
          artist,
          source,
          refresh: refresh,
          cancelToken: token,
          duration: duration,
          lyrics: matchLyrics,
        ),
      );
    }

    var future = search();
    CoverCandidate? selected;
    try {
      selected = await showDialog<CoverCandidate>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('选择封面', style: TextStyle(fontSize: s(25))),
            content: SizedBox(
              width: (MediaQuery.sizeOf(context).width * 0.78).clamp(
                0.0,
                s(820),
              ),
              height: MediaQuery.sizeOf(context).height * 0.54,
              child: Column(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: sources.entries
                          .map(
                            (entry) => Padding(
                              padding: EdgeInsets.only(right: s(8)),
                              child: ChoiceChip(
                                label: Text(
                                  entry.value,
                                  style: TextStyle(fontSize: s(17)),
                                ),
                                selected: source == entry.key,
                                onSelected: (_) => setDialogState(() {
                                  source = entry.key;
                                  future = search();
                                }),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                  SizedBox(height: s(8)),
                  Expanded(
                    child: FutureBuilder<List<CoverCandidate>>(
                      future: future,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done)
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        if (snapshot.hasError)
                          return Center(
                            child: Text(
                              '该来源暂不可用，请重试或切换来源',
                              style: TextStyle(fontSize: s(20)),
                            ),
                          );
                        final rows = snapshot.data ?? [];
                        if (rows.isEmpty)
                          return Center(
                            child: Text(
                              source == 'community'
                                  ? '还没有其他用户为这首歌选择封面，可切换其他来源'
                                  : '该来源没有封面候选，请切换来源',
                              style: TextStyle(fontSize: s(20)),
                            ),
                          );
                        return ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return InkWell(
                              onTap: () => Navigator.pop(dialogContext, row),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: s(4),
                                  vertical: s(8),
                                ),
                                child: Row(
                                  children: [
                                    CoverCandidatePreview(
                                      key: ValueKey('${row.source}:${row.id}'),
                                      loader: previewLoader,
                                      side: s(90),
                                      uri: _coverCandidateUri(
                                        row.imageTitle(metadata.title),
                                        row.imageArtist(artist),
                                        row.source,
                                        id: row.id,
                                        preview: true,
                                        duration: row.imageDuration(duration),
                                      ),
                                    ),
                                    SizedBox(width: s(12)),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            row.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(fontSize: s(21)),
                                          ),
                                          Text(
                                            row.details,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(fontSize: s(16)),
                                          ),
                                          if (row.matchLabel.isNotEmpty)
                                            Text(
                                              row.matchLabel,
                                              style: TextStyle(fontSize: s(14)),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (row.id == selectedId ||
                                        (row.source == 'community' &&
                                            row.id == selectedImageRevision))
                                      Icon(
                                        Icons.check_circle,
                                        color: _lyricHighlightColor,
                                        size: s(24),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    setDialogState(() => future = search(refresh: true)),
                child: Text('重新查询', style: TextStyle(fontSize: s(20))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text('取消', style: TextStyle(fontSize: s(20))),
              ),
            ],
          ),
        ),
      );
    } finally {
      token.cancel('封面选择已关闭');
    }
    if (selected == null ||
        !mounted ||
        request != _playRequestId ||
        !_isCurrentAssetGeneration(song, generation))
      return;
    final choice = ++_coverChoiceRevision;
    _showPlaybackMessage('正在保存所选封面');
    final path = await _downloadAndCacheCover(
      song,
      _coverCandidateUri(
        selected.imageTitle(metadata.title),
        selected.imageArtist(artist),
        selected.source,
        id: selected.id,
        duration: selected.imageDuration(duration),
      ).toString(),
      _externalDio,
      expectedGeneration: generation,
      expectedCoverRevision: choice,
    );
    if (!mounted || request != _playRequestId || choice != _coverChoiceRevision)
      return;
    if (path == null) {
      _showPlaybackMessage('封面保存失败，请换一张或重试');
      return;
    }
    await _prefs.setString(
      _songPreferenceKey('coverSelection', song),
      jsonEncode({
        'id': selected.id,
        'source': selected.source,
        'title': selected.title,
        'artist': selected.artist,
        'album': selected.album,
      }),
    );
    if (!mounted || request != _playRequestId || choice != _coverChoiceRevision)
      return;
    setState(() => currentCoverUrl = path);
    audioHandler.updateCurrentSong(currentPlayingSong, currentArtist, path);
    unawaited(_updatePalette(path));
    _showPlaybackMessage('封面已保存，离线也可使用');
    unawaited(
      _queueSongSelection(song, _selectionSong(song), 'cover', {
        'id': selected.id,
        'source': selected.selectionSource,
        'title': selected.title,
        'artist': selected.artist,
        'album': selected.album,
        'image_path': path,
      }),
    );
  }

  Future<void> _showLyricSelectionDialog() {
    final account = playingAccount;
    if (account == null) return Future.value();
    return runInLibrary(account, _showLyricSelectionDialogInternal);
  }

  Future<void> _showLyricSelectionDialogInternal() async {
    if (_currentFileName.isEmpty) return;
    _resetScreenSaverTimer();
    final songName = _currentFileName;
    final playRequestId = _playRequestId;
    final assetGeneration = _songAssetGeneration(songName);
    final metadata = _metadataForSong(songName);
    final artist = metadata.artist == '私人乐库' ? '' : metadata.artist;
    final selectedCandidateId = _prefs.getInt(
      _songPreferenceKey('lyricCandidateId', songName),
    );
    Future<List<LyricCandidate>> searchFuture = _lyricCandidates.isNotEmpty
        ? Future.value(List<LyricCandidate>.from(_lyricCandidates))
        : _refreshLyricCandidates(
            songName,
            metadata.title,
            artist,
            _totalDuration,
          );

    final selected = await showDialog<LyricCandidate>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(s(24)),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '选择歌词',
                  style: TextStyle(
                    fontSize: s(25),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新搜索',
                icon: Icon(Icons.refresh, size: s(30)),
                onPressed: () => setDialogState(() {
                  searchFuture = _refreshLyricCandidates(
                    songName,
                    metadata.title,
                    artist,
                    _totalDuration,
                  );
                }),
              ),
            ],
          ),
          content: SizedBox(
            width: (MediaQuery.of(context).size.width * 0.7)
                .clamp(s(400), s(720))
                .toDouble(),
            height: (MediaQuery.of(context).size.height * 0.62)
                .clamp(s(260), s(480))
                .toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentLyricSource.isEmpty
                      ? '正在使用：尚未匹配'
                      : '正在使用：$_currentLyricSource',
                  style: TextStyle(fontSize: s(17), color: Colors.black54),
                ),
                SizedBox(height: s(12)),
                Expanded(
                  child: FutureBuilder<List<LyricCandidate>>(
                    future: searchFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final candidates =
                          snapshot.data ?? const <LyricCandidate>[];
                      if (candidates.isEmpty) {
                        return Center(
                          child: Text(
                            '未找到可选歌词，请检查网络后重试',
                            style: TextStyle(
                              fontSize: s(20),
                              color: Colors.black54,
                            ),
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final candidate = candidates[index];
                          final durationText = candidate.durationSeconds > 0
                              ? _printDuration(
                                  Duration(
                                    seconds: candidate.durationSeconds.round(),
                                  ),
                                )
                              : '--:--';
                          final selectedNow =
                              selectedCandidateId != null &&
                              selectedCandidateId == candidate.id;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: s(8),
                              vertical: s(4),
                            ),
                            leading: Icon(
                              selectedNow
                                  ? Icons.check_circle
                                  : (candidate.hasSyncedLyrics
                                        ? Icons.graphic_eq
                                        : Icons.notes),
                              color: selectedNow
                                  ? _lyricHighlightColor
                                  : Colors.black45,
                              size: s(30),
                            ),
                            title: Text(
                              candidate.trackName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: s(21),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${candidate.artistName.isEmpty ? '未知歌手' : candidate.artistName}'
                              '${candidate.albumName.isEmpty ? '' : ' · ${candidate.albumName}'}'
                              ' · $durationText · ${candidate.hasSyncedLyrics ? '滚动歌词' : '纯文本'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: s(16)),
                            ),
                            trailing: Text(
                              '匹配 ${candidate.score}',
                              style: TextStyle(
                                fontSize: s(15),
                                color: Colors.black45,
                              ),
                            ),
                            onTap: () =>
                                Navigator.pop(dialogContext, candidate),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_retryCurrentLyricTranslation());
              },
              child: Text('重试翻译', style: TextStyle(fontSize: s(20))),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('取消', style: TextStyle(fontSize: s(20))),
            ),
          ],
        ),
      ),
    );
    if (selected != null &&
        mounted &&
        _currentFileName == songName &&
        _playRequestId == playRequestId) {
      await _applyLyricCandidate(
        songName,
        selected,
        manuallySelected: true,
        expectedGeneration: assetGeneration,
        expectedPlayRequestId: playRequestId,
      );
    }
  }

  void _showLyricOffsetDialog() {
    if (_currentFileName.isEmpty) return;
    final account = playingAccount;
    if (account == null) return;
    final songName = _currentFileName;
    final playRequestId = _playRequestId;
    var displayedOffset =
        (_prefs.getDouble(_songPreferenceKey('lyricFileShift', songName)) ??
            0) +
        _lyricOffset;
    var isSaving = false;

    Future<void> applyOffset(
      double value,
      StateSetter setDialogState,
      BuildContext dialogContext,
    ) => runInLibrary(account, () async {
      if (isSaving) return;
      if (!mounted ||
          _currentFileName != songName ||
          _playRequestId != playRequestId) {
        if (dialogContext.mounted) Navigator.pop(dialogContext);
        return;
      }
      final nextOffset = (((value.clamp(-30.0, 30.0)) * 10).round() / 10)
          .toDouble();
      if (nextOffset == displayedOffset && _lyricOffset == 0) return;
      setDialogState(() => isSaving = true);
      try {
        final generation = _songAssetGeneration(songName);
        final file = await _lyricCacheFile(songName, createDirectory: false);
        if (!await file.exists() || await file.length() == 0) {
          _showPlaybackMessage('请等待歌词缓存完成后再微调');
          return;
        }
        // 取消旧翻译任务，防止它在微调后把旧时间写回缓存。
        final revision = ++_lyricChoiceRevision;
        _latestLyricsForTranslation.remove(_songTaskKey(songName));
        final pendingWrite = _lyricWriteTasks[_songTaskKey(songName)];
        if (pendingWrite != null) await pendingWrite;
        if (!mounted ||
            _currentFileName != songName ||
            _playRequestId != playRequestId ||
            !_isCurrentAssetGeneration(songName, generation) ||
            revision != _lyricChoiceRevision) {
          return;
        }

        final originalFile = File('${file.path}.original');
        final hasOriginal = await originalFile.exists();
        final original = hasOriginal
            ? await originalFile.readAsString()
            : await file.readAsString();
        final existingFileShift =
            _prefs.getDouble(_songPreferenceKey('lyricFileShift', songName)) ??
            0;
        final shiftFromBase =
            nextOffset - (hasOriginal ? 0 : existingFileShift);
        final shifted = shiftLrcTimestamps(
          original,
          -(shiftFromBase * 1000).round(),
        );
        if (shifted.tagCount == 0) {
          _showPlaybackMessage('当前歌词没有时间标签，无法微调');
          return;
        }
        if (!hasOriginal) {
          await originalFile.writeAsString(original, flush: true);
        }
        final updated = nextOffset == 0 && hasOriginal
            ? original
            : shifted.text;
        final saved = await _writeCachedLyric(
          songName,
          updated,
          expectedGeneration: generation,
          expectedLyricRevision: revision,
        );
        if (!saved) {
          _showPlaybackMessage('歌词微调保存失败');
          return;
        }
        await _prefs.setDouble(
          _songPreferenceKey('lyricFileShift', songName),
          nextOffset,
        );
        await _prefs.setDouble(_songPreferenceKey('lyricOffset', songName), 0);
        final reloaded = await _readCachedLyric(
          songName,
          expectedGeneration: generation,
        );
        if (!mounted ||
            _currentFileName != songName ||
            _playRequestId != playRequestId) {
          return;
        }
        displayedOffset = nextOffset;
        setState(() {
          _lyricOffset = 0;
          _parseRawLrcText(reloaded ?? updated);
        });
        if (dialogContext.mounted) setDialogState(() {});
        // 微调是主动定位，立即结束手动拖动歌词后的自动滚动暂停。
        _lyricAutoScrollResumeTimer?.cancel();
        _lyricsManuallyScrolled = false;
        _cancelLyricScrollAnimations();
        if (_positionUpdatesForRequestId == _playRequestId) {
          _syncPlaybackPosition(forceLyricRecenter: true);
        } else {
          _updateLyricScroll(_currentPosition, force: true);
        }
        addLog('歌词时间已写入本地缓存: $songName (${nextOffset}s)');
      } catch (e) {
        addLog('歌词微调失败: $e');
        _showPlaybackMessage('歌词微调失败，请查看日志');
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() => isSaving = false);
        }
      }
    });

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white.withOpacity(0.9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(s(24)),
              ),
              title: Center(
                child: Text(
                  "单曲歌词微调",
                  style: TextStyle(
                    fontSize: s(24),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '歌词延后 0.2 秒',
                        icon: Icon(
                          Icons.fast_rewind,
                          size: s(48),
                          color: Colors.black87,
                        ),
                        onPressed: isSaving
                            ? null
                            : () => applyOffset(
                                displayedOffset - 0.2,
                                setDialogState,
                                dialogContext,
                              ),
                      ),
                      SizedBox(
                        width: s(120),
                        child: Text(
                          "${displayedOffset > 0 ? '+' : ''}${displayedOffset.toStringAsFixed(1).replaceAll('.0', '')}s",
                          style: TextStyle(
                            fontSize: s(32),
                            fontWeight: FontWeight.bold,
                            color: _lyricHighlightColor,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        tooltip: '歌词提前 0.2 秒',
                        icon: Icon(
                          Icons.fast_forward,
                          size: s(48),
                          color: Colors.black87,
                        ),
                        onPressed: isSaving
                            ? null
                            : () => applyOffset(
                                displayedOffset + 0.2,
                                setDialogState,
                                dialogContext,
                              ),
                      ),
                    ],
                  ),
                  SizedBox(height: s(8)),
                  Text(
                    '− 延后歌词    ＋ 提前歌词',
                    style: TextStyle(fontSize: s(18), color: Colors.black54),
                  ),
                  SizedBox(height: s(4)),
                  Text(
                    isSaving ? '正在保存并重新加载歌词…' : '每次 0.2 秒，修改本地歌词缓存时间',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: s(15), color: Colors.black45),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => applyOffset(0, setDialogState, dialogContext),
                  child: Text('重置', style: TextStyle(fontSize: s(20))),
                ),
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: Text(
                    "完成",
                    style: TextStyle(fontSize: s(22), color: Colors.blueAccent),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDashboardCard({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.55),
          borderRadius: BorderRadius.circular(s(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: s(15),
              offset: Offset(0, s(6)),
            ),
          ],
        ),
        padding: EdgeInsets.all(s(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              flex: 2,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: s(28),
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
            Flexible(
              flex: 3,
              child: Padding(
                padding: EdgeInsets.only(top: s(8)),
                child: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: s(20), color: Colors.black54),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CarAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();
  final PlaybackPositionClock _positionClock = PlaybackPositionClock();
  Duration get playbackPosition => _positionClock.read(
    event: player.playbackEvent,
    advancing:
        player.playing && player.processingState == ProcessingState.ready,
    speed: player.speed,
  );
  MediaItem? _currentMediaItem;
  DateTime? _bufferingStartedAt;

  // 切歌回调，UI层设置
  void Function()? onNextCallback;
  void Function()? onPrevCallback;
  void Function(Object error)? onErrorCallback;

  void _startPlayback() {
    unawaited(
      player.play().catchError((Object error, StackTrace stack) {
        addLog('启动音频播放失败: $error');
        onErrorCallback?.call(error);
      }),
    );
  }

  CarAudioHandler() {
    _currentMediaItem = const MediaItem(
      id: 'init',
      title: '\u7b49\u5f85\u64ad\u653e',
      artist: 'NAS Car Player',
    );
    mediaItem.add(_currentMediaItem!);
    player.playbackEventStream.listen(
      (_) => _broadcastState(player.playing),
      onError: (Object error, StackTrace stack) {
        addLog('音频引擎异常: $error');
        onErrorCallback?.call(error);
      },
    );
    addLog("\ud83d\udd35 [MediaSession] \u521d\u59cb\u5316\u5b8c\u6210");

    // 监听播放状态变化，广播给 MediaSession
    player.playingStream.listen((playing) {
      _broadcastState(playing);
    });
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.buffering && player.playing) {
        if (_bufferingStartedAt == null) {
          _bufferingStartedAt = DateTime.now();
          addLog('网络缓冲开始');
        }
      } else if (state == ProcessingState.ready &&
          _bufferingStartedAt != null) {
        final elapsed = DateTime.now().difference(_bufferingStartedAt!);
        _bufferingStartedAt = null;
        addLog('网络缓冲恢复: ${elapsed.inMilliseconds}ms');
      }
    });
    player.durationStream.listen((duration) {
      if (duration != null &&
          _currentMediaItem != null &&
          duration != _currentMediaItem!.duration) {
        _currentMediaItem = _currentMediaItem!.copyWith(duration: duration);
        mediaItem.add(_currentMediaItem!);
      }
    });
  }

  void _broadcastState(bool playing) {
    playbackState.add(
      playbackState.value.copyWith(
        playing: playing,
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          MediaAction.seek,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        processingState: _mapProcessingState(player.processingState),
        updatePosition: playbackPosition,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  Future<bool> playSong(
    String url,
    String auth, {
    Duration initialPosition = Duration.zero,
    bool Function()? shouldContinue,
  }) async {
    addLog("\ud83c\udfb5 \u64ad\u653e: ${url.split('/').last}");
    try {
      if (url.startsWith('http')) {
        await player.setUrl(url, headers: {'Authorization': auth});
      } else {
        await player.setFilePath(url);
      }
      if (shouldContinue != null && !shouldContinue()) return false;
      if (initialPosition > Duration.zero) {
        final duration = player.duration;
        final resumePosition =
            duration != null &&
                initialPosition >= duration - const Duration(seconds: 1)
            ? Duration.zero
            : initialPosition;
        await player.seek(resumePosition);
      }
      if (shouldContinue != null && !shouldContinue()) return false;
      _startPlayback();
      return true;
    } catch (e) {
      if (shouldContinue != null && !shouldContinue()) return false;
      addLog("\u274c \u64ad\u653e\u5931\u8d25: $e");
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    addLog("[MediaSession] play()");
    _startPlayback();
  }

  @override
  Future<void> pause() async {
    addLog("[MediaSession] pause()");
    await player.pause();
  }

  Future<void> playPause() async {
    addLog("[MediaSession] playPause()");
    if (player.playing) {
      await player.pause();
    } else {
      _startPlayback();
    }
  }

  @override
  Future<void> seek(Duration position) async => await player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    return super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // 不调用 stop()，保持 MediaSession 活跃
  }

  @override
  Future<void> skipToNext() async {
    addLog("\u2705 [MediaSession] skipToNext() - \u65b9\u5411\u76d8 Next");
    if (onNextCallback != null) onNextCallback!();
  }

  @override
  Future<void> skipToPrevious() async {
    addLog("\u2705 [MediaSession] skipToPrevious() - \u65b9\u5411\u76d8 Prev");
    if (onPrevCallback != null) onPrevCallback!();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    addLog("[MediaSession] click($button)");
    switch (button) {
      case MediaButton.media:
        if (player.playing) {
          await player.pause();
        } else {
          _startPlayback();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  void updateCurrentSong(String title, String artist, String coverUrl) {
    _currentMediaItem = MediaItem(
      id: title,
      title: title,
      artist: artist,
      artUri: coverUrl.isEmpty
          ? null
          : (coverUrl.startsWith('http')
                ? Uri.parse(coverUrl)
                : Uri.file(coverUrl)),
    );
    mediaItem.add(_currentMediaItem!);
  }
}
