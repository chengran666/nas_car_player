import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nas_car_player/main.dart';

void main() {
  test('冷启动检查点同时恢复乐库、歌曲和精确进度', () {
    final library = libraryCacheId({
      'url': 'https://nas.example/music/',
      'user': 'driver',
    });
    final checkpoint = PlaybackResumePoint(library, '英文歌.mp3', 123456);
    final restored = PlaybackResumePoint.decode(checkpoint.encode())!;
    expect(
      (restored.libraryId, restored.song, restored.positionMs),
      (library, '英文歌.mp3', 123456),
    );
    expect(PlaybackResumePoint.decode('[$library,"英文歌.mp3",123'), isNull);
    expect(PlaybackResumePoint.decode('["$library","英文歌.mp3",-2]'), isNull);
  });

  test('开机校时前后的音频样本以单调时钟推进，重复缓冲事件不重置', () {
    var elapsed = Duration.zero;
    final clock = PlaybackPositionClock(elapsed: () => elapsed);
    final boot = DateTime.utc(2020, 1, 1);
    final calibrated = DateTime.utc(2026, 11, 5);
    PlaybackEvent event(DateTime time, int ms, {int bufferedMs = 0}) =>
        PlaybackEvent(
          updateTime: time,
          updatePosition: Duration(milliseconds: ms),
          bufferedPosition: Duration(milliseconds: bufferedMs),
          duration: const Duration(minutes: 4),
        );
    Duration read(PlaybackEvent sample) =>
        clock.read(event: sample, advancing: true, speed: 1);
    final before = event(boot, 90750);
    expect(read(before).inMilliseconds, 90750);
    elapsed += const Duration(milliseconds: 300);
    expect(read(event(boot, 90750, bufferedMs: 110000)).inMilliseconds, 91050);
    expect(read(event(calibrated, 91050)).inMilliseconds, 91050);
    elapsed += const Duration(milliseconds: 250);
    final position = read(event(calibrated, 91050));
    expect(position.inMilliseconds, 91300);
    expect(
      lyricIndexAtPosition(
        [const Duration(seconds: 90), const Duration(seconds: 92)],
        position,
        0,
      ),
      0,
    );
  });

  test('恢复实际 seek 位置、缓冲暂停和新歌零点不会沿用旧播放时间', () {
    var elapsed = Duration.zero;
    final clock = PlaybackPositionClock(elapsed: () => elapsed);
    final origin = DateTime.utc(2026, 11, 5);
    Duration read(int ms, {bool advancing = true, int generation = 0}) =>
        clock.read(
          event: PlaybackEvent(
            updateTime: origin.add(Duration(milliseconds: generation)),
            updatePosition: Duration(milliseconds: ms),
            duration: const Duration(minutes: 2),
          ),
          advancing: advancing,
          speed: 1,
        );
    expect(read(87000).inMilliseconds, 87000);
    expect(read(42000, generation: 1).inMilliseconds, 42000);
    expect(read(42300, generation: 2, advancing: false).inMilliseconds, 42300);
    elapsed += const Duration(seconds: 4);
    expect(read(42300, generation: 2, advancing: false).inMilliseconds, 42300);
    expect(read(0, generation: 3).inMilliseconds, 0);
  });
}
