import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  const a = {'url': 'https://nas.example/a/', 'user': 'car', 'pwd': 'old'};
  const b = {'url': 'https://nas.example/b/', 'user': 'car'};

  test('同名歌曲按 NAS 目录和用户隔离，更改密码不丢缓存', () {
    final root = Directory('cache');
    expect(
      libraryCacheDirectory(root, a).path,
      isNot(libraryCacheDirectory(root, b).path),
    );
    expect(libraryCacheId(a), libraryCacheId({...a, 'pwd': 'new'}));
    expect(libraryCacheId(a), isNot(libraryCacheId({...a, 'user': 'other'})));
  });

  test('并行异步任务和嵌套任务保持自己的乐库归属', () async {
    final gate = Completer<void>();
    final first = runInLibrary(a, () async {
      await gate.future;
      expect(currentLibraryTask?['url'], a['url']);
      await runInLibrary(b, () async {
        await Future<void>.delayed(Duration.zero);
        expect(currentLibraryTask?['url'], b['url']);
      });
      expect(currentLibraryTask?['url'], a['url']);
    });
    await runInLibrary(b, () async {
      expect(currentLibraryTask?['url'], b['url']);
      gate.complete();
      await first;
      expect(currentLibraryTask?['url'], b['url']);
    });
    expect(currentLibraryTask, isNull);
  });

  test('版本检测支持同名同大小替换，缺少可选属性不误删', () {
    const old = RemoteSongVersion(etag: 'v1', modified: 'Mon', size: 100);
    expect(
      const RemoteSongVersion(etag: 'v2', size: 100).differsFrom(old),
      isTrue,
    );
    expect(const RemoteSongVersion(modified: 'Tue').differsFrom(old), isTrue);
    expect(const RemoteSongVersion(size: 101).differsFrom(old), isTrue);
    expect(const RemoteSongVersion(size: 100).differsFrom(old), isFalse);
    expect(const RemoteSongVersion().differsFrom(old), isFalse);
    expect(RemoteSongVersion.fromJson(old.toJson()).differsFrom(old), isFalse);
  });

  test('WebDAV 获取成功的版本属性，忽略服务器不支持的属性', () {
    const body = '''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/music/A%20%26%20B.mp3</d:href>
        <d:propstat><d:prop><d:getetag>"v2"</d:getetag>
        <d:getcontentlength>123</d:getcontentlength></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:getlastmodified>invalid</d:getlastmodified></d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
      </d:response></d:multistatus>''';
    final version = parseWebDavVersions(
      body,
      Uri.parse('https://nas/music/'),
    )['A & B.mp3']!;
    expect(version.etag, '"v2"');
    expect(version.size, 123);
    expect(version.modified, isEmpty);
  });

  test('容量统计包括各乐库音频、封面、歌词、备份和未完成文件', () async {
    final root = await Directory.systemTemp.createTemp('nas_inventory_');
    addTearDown(() => root.delete(recursive: true));
    final one = libraryCacheDirectory(root, a);
    final two = libraryCacheDirectory(root, b);
    final key = base64UrlEncode(utf8.encode('same.mp3')).replaceAll('=', '');
    Future<void> write(String path, int size) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List.filled(size, 1));
    }

    await write('${one.path}/same.mp3', 100);
    await write('${one.path}/same.mp3.meta.json', 10);
    await write('${one.path}/lyrics/$key.lrc', 20);
    await write('${one.path}/lyrics/$key.lrc.original', 30);
    await write('${one.path}/covers/$key.jpg', 40);
    await write('${two.path}/same.mp3.part', 50);
    await write('${root.path}/legacy.mp3', 60);
    await write('${root.path}/unknown.bin', 5);
    final result = await readCacheInventory(root);
    expect(result.bytes, 315);
    expect(result.groups, hasLength(3));
    final first = result.groups.singleWhere(
      (g) => g.libraryId == libraryCacheId(a),
    );
    expect(first.song, 'same.mp3');
    expect(first.bytes, 200);
    expect(first.files, hasLength(5));
  });

  test('容量清理保留当前乐库的歌曲和下载，其他乐库同名歌曲可清理', () {
    final current = SongCacheGroup('cache/a', 'a', 'same.mp3');
    final other = SongCacheGroup('cache/b', 'b', 'same.mp3');
    bool eligible(SongCacheGroup group, List<String> downloads) =>
        canEvictSongCache(
          group,
          playingLibraryId: 'a',
          currentSong: 'same.mp3',
          activeDownloads: downloads,
        );
    expect(eligible(current, []), isFalse);
    expect(eligible(other, []), isTrue);
    expect(eligible(other, ['b:same.mp3']), isFalse);
  });

  test('仅剩音频版本记录或无效标记时仍能被同步清理发现', () async {
    final root = await Directory.systemTemp.createTemp('nas_orphans_');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/removed.mp3.meta.json').writeAsString('{}');
    await File('${root.path}/corrupt.flac.invalid').writeAsString('bad');
    expect(await readSongAssetCacheNames(root), {
      'removed.mp3',
      'corrupt.flac',
    });
  });

  group('缓存音源故障恢复', () {
    const local = '/cache/song.mp3';
    const remote = 'https://nas/song.mp3';
    test('有效缓存离线直接播放，不访问网络', () async {
      final calls = <String>[];
      final path = await prepareCachedOrRemote(
        preferred: local,
        remote: remote,
        isCurrent: () => true,
        prepare: (path) async {
          calls.add(path);
          return true;
        },
        onCachedFailure: (_, _) async => fail('不应标记有效缓存'),
      );
      expect(path, local);
      expect(calls, [local]);
    });
    test('损坏缓存只回退一次，两个音源都失败时上报错误', () async {
      final calls = <String>[];
      final invalid = <String>[];
      final result = await prepareCachedOrRemote(
        preferred: local,
        remote: remote,
        isCurrent: () => true,
        prepare: (path) async {
          calls.add(path);
          if (path == local) throw StateError('corrupt');
          return true;
        },
        onCachedFailure: (path, _) async {
          invalid.add(path);
        },
      );
      expect(result, remote);
      expect(calls, [local, remote]);
      expect(invalid, [local]);
      calls.clear();
      await expectLater(
        prepareCachedOrRemote(
          preferred: local,
          remote: remote,
          isCurrent: () => true,
          prepare: (path) async {
            calls.add(path);
            throw StateError('offline');
          },
          onCachedFailure: (_, _) async {},
        ),
        throwsStateError,
      );
      expect(calls, [local, remote]);
    });
    test('网络音源失败不递归重试，也不标记本地缓存', () async {
      var attempts = 0;
      await expectLater(
        prepareCachedOrRemote(
          preferred: remote,
          remote: remote,
          isCurrent: () => true,
          prepare: (_) async {
            attempts++;
            throw StateError('network');
          },
          onCachedFailure: (_, _) async => fail('远程错误不标记缓存'),
        ),
        throwsStateError,
      );
      expect(attempts, 1);
    });
    test('快速切歌取消旧请求，旧缓存错误不覆盖新音源', () async {
      var current = true;
      final calls = <String>[];
      final result = await prepareCachedOrRemote(
        preferred: local,
        remote: remote,
        isCurrent: () => current,
        prepare: (path) async {
          calls.add(path);
          throw StateError('corrupt');
        },
        onCachedFailure: (_, _) async {
          current = false;
        },
      );
      expect(result, isNull);
      expect(calls, [local]);
    });
  });

  test('本地搜索支持大小写和多关键词，筛选排序不修改原歌单', () {
    final songs = ['M2M - The Day.mp3', '金莎、林俊杰 - 夏天.mp3', 'A - Hello.mp3'];
    expect(filterSongList(songs, query: 'm2m DAY'), ['M2M - The Day.mp3']);
    expect(filterSongList(songs, query: '金莎 夏天'), ['金莎、林俊杰 - 夏天.mp3']);
    expect(filterSongList(songs, onlyCached: true, cachedSongs: {songs[1]}), [
      songs[1],
    ]);
    expect(filterSongList(songs, descending: true), [
      songs[1],
      songs[0],
      songs[2],
    ]);
    expect(songs.first, 'M2M - The Day.mp3');
    expect(filterSongList(songs, query: '不存在'), isEmpty);
  });
}
