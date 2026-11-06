import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nas_car_player/main.dart';

void main() {
  test('授权入口和安装程序缺失的错误分别显示，保留签名校验原因', () {
    final missing = PlatformException(
      code: 'UPDATE_FAILED',
      message:
          'No Activity found to handle Intent { act=android.settings.MANAGE_UNKNOWN_APP_SOURCES }',
    );
    expect(
      updateInstallFailureMessage(missing, requestingPermission: true),
      contains('授权页面'),
    );
    expect(updateInstallFailureMessage(missing), contains('系统安装程序'));
    expect(updateInstallFailureMessage(missing), isNot(contains('Intent')));
    expect(
      updateInstallFailureMessage(
        PlatformException(code: 'UPDATE_FAILED', message: '升级包签名不一致，无法覆盖安装'),
      ),
      '升级包签名不一致，无法覆盖安装',
    );
    expect(
      updateInstallFailureMessage(
        PlatformException(
          code: 'UPDATE_FAILED',
          message: 'java.lang.SecurityException: Permission Denial',
        ),
      ),
      contains('系统限制'),
    );
  });
  final endpoint = Uri.parse('https://mp3.whzxc.com/updates.php');
  Map<String, dynamic> release({String url = 'updates/player-2004.apk'}) => {
    'success': true,
    'release': {
      'version_code': 2004,
      'version_name': '1.0.2',
      'apk_url': url,
      'size': 1024,
      'sha256': 'a' * 64,
      'notes': '更新说明',
    },
  };
  Map<String, dynamic> withSplits() {
    final data = release();
    (data['release'] as Map)['downloads'] = {
      'armeabi-v7a': {
        'apk_url': 'updates/player-2004-arm32.apk',
        'size': 300,
        'sha256': 'b' * 64,
      },
      'arm64-v8a': {
        'apk_url': 'updates/player-2004-arm64.apk',
        'size': 400,
        'sha256': 'c' * 64,
      },
      'x86_64': {
        'apk_url': 'updates/player-2004-x86_64.apk',
        'size': 500,
        'sha256': 'd' * 64,
      },
    };
    return data;
  }

  test('ARM64 Android selects matching URL, size and checksum', () {
    final result = AppRelease.parse(
      withSplits(),
      endpoint,
      supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
    )!;
    expect(result.abi, 'arm64-v8a');
    expect(result.url.path, '/updates/player-2004-arm64.apk');
    expect(result.size, 400);
    expect(result.digest, 'c' * 64);
    expect(result.packageLabel, 'ARM 64 位小包');
    expect(result.code, 2004);
  });
  test('32-bit Android never picks an unsupported 64-bit package', () {
    final result = AppRelease.parse(
      withSplits(),
      endpoint,
      supportedAbis: ['armeabi-v7a', 'armeabi'],
    )!;
    expect(result.abi, 'armeabi-v7a');
    expect(result.size, 300);
    expect(result.digest, 'b' * 64);
  });
  test(
    'emulator follows Android ABI preference before translated ARM ABIs',
    () {
      final result = AppRelease.parse(
        withSplits(),
        endpoint,
        supportedAbis: ['x86_64', 'x86', 'arm64-v8a', 'armeabi-v7a'],
      )!;
      expect(result.abi, 'x86_64');
      expect(result.digest, 'd' * 64);
    },
  );
  test('missing preferred package uses the next compatible package', () {
    final data = withSplits();
    ((data['release'] as Map)['downloads'] as Map).remove('arm64-v8a');
    expect(
      AppRelease.parse(
        data,
        endpoint,
        supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
      )!.abi,
      'armeabi-v7a',
    );
  });
  test('unknown ABI, unavailable splits and old manifests use universal', () {
    for (final abis in [
      <String>[],
      ['riscv64'],
      ['x86'],
    ]) {
      final result = AppRelease.parse(
        withSplits(),
        endpoint,
        supportedAbis: abis,
      )!;
      expect(result.abi, 'universal');
      expect(result.size, 1024);
      expect(result.digest, 'a' * 64);
    }
    expect(
      AppRelease.parse(release(), endpoint, supportedAbis: ['arm64-v8a'])!.abi,
      'universal',
    );
  });
  test('invalid split metadata cannot bypass existing package validation', () {
    for (final invalid in [
      {'apk_url': 'https://other.example/updates/small.apk'},
      {'apk_url': 'http://mp3.whzxc.com/updates/small.apk'},
      {'apk_url': 'updates/../outside.apk'},
      {'size': 0},
      {'size': 600 * 1024 * 1024},
      {'sha256': 'invalid'},
    ]) {
      final data = withSplits();
      final splits = (data['release'] as Map)['downloads'] as Map;
      (splits['arm64-v8a'] as Map).addAll(invalid);
      final fallback = AppRelease.parse(
        data,
        endpoint,
        supportedAbis: ['arm64-v8a'],
      )!;
      expect(fallback.abi, 'universal');
      expect(fallback.url.path, '/updates/player-2004.apk');
      expect(fallback.digest, 'a' * 64);
    }
  });
  test('accepts version manifest and resolves server-relative APK path', () {
    final result = AppRelease.parse(release(), endpoint)!;
    expect(result.code, 2004);
    expect(
      result.url.toString(),
      'https://mp3.whzxc.com/updates/player-2004.apk',
    );
    expect(
      AppRelease.parse({'success': true, 'release': null}, endpoint),
      isNull,
    );
  });
  test('date-based version code retains its exact integer for ABI updates', () {
    final data = withSplits();
    (data['release'] as Map)['version_code'] = 2026101202;
    final result = AppRelease.parse(
      data,
      endpoint,
      supportedAbis: ['arm64-v8a'],
    )!;
    expect(result.code, 2026101202);
    expect(result.code, greaterThan(7014));
    expect(result.abi, 'arm64-v8a');
    expect(jsonDecode(jsonEncode({'code': result.code}))['code'], 2026101202);
  });
  test('rejects off-site, plaintext, traversal and malformed APK URLs', () {
    for (final url in [
      'https://other.example/updates/player.apk',
      'http://mp3.whzxc.com/updates/player.apk',
      'updates/../config.apk',
      'updates/cover.png',
    ]) {
      expect(
        () => AppRelease.parse(release(url: url), endpoint),
        throwsFormatException,
      );
    }
  });
  test('rejects missing checksums and unbounded or invalid package sizes', () {
    for (final field in [
      {'sha256': 'bad'},
      {'size': -1},
      {'size': 600 * 1024 * 1024},
      {'version_code': 0},
      {'version_code': '2004'},
    ]) {
      final data = release();
      (data['release'] as Map).addAll(field);
      expect(() => AppRelease.parse(data, endpoint), throwsFormatException);
    }
  });
  test(
    'migrates saved old translation endpoint and preserves custom servers',
    () {
      expect(
        migrateLyricServiceUrl('https://cover_api.whzxc.com/lyrics.php'),
        'https://mp3.whzxc.com/lyrics.php',
      );
      expect(
        migrateLyricServiceUrl('https://my.example/lyrics.php'),
        'https://my.example/lyrics.php',
      );
      expect(coverProxyBaseUrl, 'https://mp3.whzxc.com/');
      expect(defaultLyricTranslationApiUrl, 'https://mp3.whzxc.com/lyrics.php');
    },
  );
}
