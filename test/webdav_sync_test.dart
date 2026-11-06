import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

String entry(String href, {bool folder = false, int status = 200}) =>
    '''
<d:response><d:href>$href</d:href><d:propstat>
<d:prop><d:resourcetype>${folder ? '<d:collection/>' : ''}</d:resourcetype></d:prop>
<d:status>HTTP/1.1 $status Status</d:status></d:propstat></d:response>''';

String directoryResponse(List<String> children) =>
    '<d:multistatus xmlns:d="DAV:">'
    '${entry('/music/', folder: true)}${children.join()}'
    '</d:multistatus>';

void main() {
  final directory = Uri.parse('https://nas.example/music/');

  group('WebDAV 完整目录校验', () {
    test('正确读取新歌曲、编码文件名、XML 实体并忽略文件夹和歌词文件', () {
      final body = directoryResponse([
        entry('/music/old.mp3'),
        entry('/music/%E6%96%B0%E6%AD%8C.FLAC'),
        entry('/music/A%20%26%20B.mp3'),
        entry('/music/Rock&amp;Roll.m4a'),
        entry('/music/folder.mp3/', folder: true),
        entry('/music/old.lrc'),
        entry('/music/old.mp3'),
      ]);
      expect(parseWebDavSongList(body, directory), [
        'A & B.mp3',
        'old.mp3',
        'Rock&Roll.m4a',
        '新歌.FLAC',
      ]);
    });

    test('支持默认 DAV 命名空间和不以斜线结尾的配置目录', () {
      final body = directoryResponse([
        entry('new.mp3'),
      ]).replaceAll('xmlns:d=', 'xmlns=').replaceAll('d:', '');
      expect(
        parseWebDavSongList(body, Uri.parse('https://nas.example/music')),
        ['new.mp3'],
      );
    });

    test('支持编码目录及绝对文件地址', () {
      final body =
          '<d:multistatus xmlns:d="DAV:">'
          '${entry('/%E9%9F%B3%E4%B9%90/', folder: true)}'
          '${entry('https://nas.example/%E9%9F%B3%E4%B9%90/new.mp3')}'
          '</d:multistatus>';
      expect(
        parseWebDavSongList(
          body,
          Uri.parse('https://nas.example/%E9%9F%B3%E4%B9%90/'),
        ),
        ['new.mp3'],
      );
    });

    test('确认目录存在后，允许真正的空歌单参与删除同步', () {
      expect(parseWebDavSongList(directoryResponse([]), directory), isEmpty);
    });

    test('HTML、截断 XML、缺少目录自身的响应不能触发删除', () {
      for (final body in [
        '<html><body>Login</body></html>',
        directoryResponse([
          entry('/music/new.mp3'),
        ]).replaceAll('</d:multistatus>', ''),
        '<d:multistatus xmlns:d="DAV:"/>',
        '<d:multistatus xmlns:d="DAV:">${entry('/music/new.mp3')}</d:multistatus>',
      ]) {
        expect(
          () => parseWebDavSongList(body, directory),
          throwsA(isA<Exception>()),
        );
      }
    });

    test('权限错误和不完整文件属性不能被当成歌曲已经删除', () {
      expect(
        () => parseWebDavSongList(
          directoryResponse([entry('/music/private.mp3', status: 403)]),
          directory,
        ),
        throwsFormatException,
      );
      final incomplete = directoryResponse([
        entry('/music/new.mp3'),
      ]).replaceAll('<d:resourcetype></d:resourcetype>', '');
      expect(
        () => parseWebDavSongList(incomplete, directory),
        throwsFormatException,
      );
    });

    test('其他目录、其他主机和深层子目录不能作为当前目录同步', () {
      for (final href in [
        '/other/else.mp3',
        'https://other.example/music/else.mp3',
        '/music/sub/else.mp3',
      ]) {
        expect(
          () =>
              parseWebDavSongList(directoryResponse([entry(href)]), directory),
          throwsFormatException,
        );
      }
    });
  });

  group('歌曲缓存删除范围', () {
    test('缓存盘点包含独立歌词、封面、微调备份和未完成音频', () async {
      final cache = await Directory.systemTemp.createTemp('nas_sync_test_');
      addTearDown(() => cache.delete(recursive: true));
      String key(String name) =>
          base64UrlEncode(utf8.encode(name)).replaceAll('=', '');
      await File('${cache.path}/audio.mp3').writeAsString('audio');
      await File('${cache.path}/pending.mp3.part').writeAsString('partial');
      await Directory('${cache.path}/lyrics').create();
      await Directory('${cache.path}/covers').create();
      await File(
        '${cache.path}/lyrics/${key('歌词.flac')}.lrc.original',
      ).writeAsString('lyric');
      await File(
        '${cache.path}/covers/${key('封面.m4a')}.jpg',
      ).writeAsString('cover');
      await File('${cache.path}/covers/invalid!.jpg').writeAsString('unknown');
      await File('${cache.path}/metadata.json').writeAsString('{}');
      expect(await readSongAssetCacheNames(cache), {
        'audio.mp3',
        'pending.mp3',
        '歌词.flac',
        '封面.m4a',
      });
    });

    test('删除旧歌单中已不存在的歌曲，保留现有歌曲和新增歌曲', () {
      expect(
        songCachesToRemove(
          knownSongs: ['old.mp3', 'keep.mp3'],
          remoteSongs: ['keep.mp3', 'new.mp3'],
        ),
        {'old.mp3'},
      );
    });

    test('其他乐库引用的同名缓存受到保护', () {
      expect(
        songCachesToRemove(
          knownSongs: ['old.mp3', 'shared.mp3', 'keep.mp3'],
          remoteSongs: ['keep.mp3'],
          otherLibrarySongs: ['shared.mp3'],
        ),
        {'old.mp3'},
      );
    });

    test('真正空目录可清理旧缓存，但目录穿越和非音频条目不会被删除', () {
      expect(
        songCachesToRemove(
          knownSongs: [
            'old.mp3',
            '../outside.mp3',
            r'..\outside.mp3',
            'metadata.json',
          ],
          remoteSongs: [],
        ),
        {'old.mp3'},
      );
    });

    test('重试清理时，NAS 重新加入的歌曲会退出待删除范围', () {
      expect(
        songCachesToRemove(
          knownSongs: ['pending.mp3', 'returned.mp3'],
          remoteSongs: ['returned.mp3'],
        ),
        {'pending.mp3'},
      );
    });
  });
}
