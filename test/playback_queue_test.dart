import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  final songs = List.generate(60, (index) => 'song-$index.mp3');

  test('顺序队列复制源列表，单曲自动重复，手动上下曲正常移动', () {
    final order = buildPlaybackOrder(['a', 'b', 'c', 'b'], shuffled: false);
    expect(order, ['a', 'b', 'c']);
    expect(playbackQueueNeighbor(order, 'b', 1, repeatCurrent: true), 'b');
    expect(playbackQueueNeighbor(order, 'b', 1), 'c');
    expect(playbackQueueNeighbor(order, 'b', -1), 'a');
    expect(playbackQueueNeighbor(order, 'a', -1), 'c');
  });

  test('100 种随机顺序中，听完一整轮之前没有重复，当前歌曲不会提前重播', () {
    for (var seed = 0; seed < 100; seed++) {
      final order = buildPlaybackOrder(
        songs,
        shuffled: true,
        currentSong: songs[20],
        random: Random(seed),
      );
      expect(order.first, songs[20]);
      var current = songs[20];
      final played = {current};
      for (var i = 1; i < songs.length; i++) {
        current = playbackQueueNeighbor(order, current, 1)!;
        expect(played.add(current), isTrue);
      }
      expect(played, songs.toSet());
      expect(playbackQueueNeighbor(order, current, 1), songs[20]);
    }
  });

  test('随机上下曲沿同一队列往返，不依赖单独的随机游标', () {
    final order = buildPlaybackOrder(songs, shuffled: true, random: Random(7));
    for (final current in order) {
      final next = playbackQueueNeighbor(order, current, 1)!;
      expect(playbackQueueNeighbor(order, next, -1), current);
      final previous = playbackQueueNeighbor(order, current, -1)!;
      expect(playbackQueueNeighbor(order, previous, 1), current);
    }
  });

  test('后台同步或手动选歌不会重排已有随机队列', () {
    final order = buildPlaybackOrder(songs, shuffled: true, random: Random(2));
    for (final selected in [order[12], order[43], order[8]]) {
      expect(
        buildPlaybackOrder(
          songs.reversed,
          shuffled: true,
          previousOrder: order,
          currentSong: selected,
          random: Random(9),
        ),
        order,
      );
    }
    expect(songs.first, 'song-0.mp3');
  });

  test('NAS 增删及同长度替换只影响变化项，保留其余歌曲相对顺序', () {
    final order = buildPlaybackOrder(songs, shuffled: true, random: Random(3));
    final removed = order[12];
    final updated = buildPlaybackOrder(
      [...songs.where((s) => s != removed), 'new.mp3'],
      shuffled: true,
      previousOrder: order,
      random: Random(5),
    );
    expect(updated, [...order.where((s) => s != removed), 'new.mp3']);
    expect(updated.toSet().length, 60);
  });

  test('持久化的随机顺序可恢复，切回顺序模式仍按 NAS 列表', () {
    final order = buildPlaybackOrder(songs, shuffled: true, random: Random(10));
    final restored = (jsonDecode(jsonEncode(order)) as List).cast<String>();
    expect(
      buildPlaybackOrder(songs, shuffled: true, previousOrder: restored),
      order,
    );
    expect(
      buildPlaybackOrder(songs, shuffled: false, previousOrder: restored),
      songs,
    );
  });

  test('空歌单、单首歌、删除当前歌曲均有确定结果', () {
    expect(playbackQueueNeighbor([], 'a', 1), isNull);
    expect(playbackQueueNeighbor(['a'], 'a', -1), 'a');
    expect(playbackQueueNeighbor(['a', 'b'], 'removed', 1), 'a');
    expect(
      buildPlaybackOrder([], shuffled: true, previousOrder: ['a']),
      isEmpty,
    );
  });
}
