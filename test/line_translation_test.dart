import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  test('分批补译只改文字，毫秒时间轴和原文保持不变', () {
    final source = parseLrcText(
      '[offset:+125]\n[00:01.237]First line\n[00:04.569]Second line\n[00:07.891]Third line',
    );
    final cache = <String, String>{};
    final times = source.map((line) => line.time).toList();
    for (final entry in {
      'First line': '第一句',
      'Second line': '第二句',
      'Third line': '第三句',
    }.entries) {
      cache[lyricTranslationLineId(entry.key)] = entry.value;
      final display = mergeLyricTranslations(source, cache);
      expect(display.map((line) => line.time), times);
      expect(display.map((line) => line.text.split('\n').first), [
        'First line',
        'Second line',
        'Third line',
      ]);
      final reloaded = parseLrcText(
        buildBilingualLrc(display, List.filled(display.length, '')),
      );
      expect(reloaded.map((line) => line.time), times);
      expect(
        lyricIndexAtPosition(
          times,
          times[1] - const Duration(milliseconds: 1),
          0,
        ),
        0,
      );
      expect(lyricIndexAtPosition(times, times[1], 0), 1);
    }
    expect(source.first.text, 'First line');
  });

  test('切换歌词或拖动进度后，复用译文仍使用新来源的时间而不是旧时间', () {
    final cached = {
      lyricTranslationLineId('Love me'): '爱我',
      lyricTranslationLineId('Stay here'): '留在这里',
    };
    for (final lyrics in [
      '[00:05.123]Love me\n[00:08.456]Stay here',
      '[00:25.789]Love me\n[00:30.987]Stay here',
    ]) {
      final source = parseLrcText(lyrics);
      final display = mergeLyricTranslations(source, cached);
      final times = display.map((line) => line.time).toList();
      expect(times, source.map((line) => line.time));
      expect(
        lyricIndexAtPosition(
          times,
          times.last + const Duration(seconds: 15),
          0,
        ),
        1,
      );
      expect(
        lyricIndexAtPosition(
          times,
          times.first - const Duration(milliseconds: 1),
          0,
        ),
        -1,
      );
      expect(mergeLyricTranslations(display, cached), display);
    }
  });
  test('原文行标识忽略空白，不依赖时间戳、歌曲或歌词来源', () {
    expect(
      lyricTranslationLineId('  Hello   world  '),
      lyricTranslationLineId('Hello world'),
    );
    expect(
      lyricTranslationLineId('Hello world'),
      isNot(lyricTranslationLineId('Hello world!')),
    );
  });

  test('逐行提取去重，重复副歌只翻译一次，跳过中文与段落标记', () {
    final rows = missingLyricTranslationLines(
      '[00:01]Hello world\n[00:02]Hello world\n[00:03][Chorus]\n[00:04]中文歌词\n[00:05]Love me',
      {},
    );
    expect(rows.values, ['Hello world', 'Love me']);
  });

  test('更换歌词后复用相同行，只补新原文，改时间不重翻', () {
    final cached = {lyricTranslationLineId('Hello world'): '你好世界'};
    expect(
      missingLyricTranslationLines(
        '[00:22]Hello world\n[00:30]New line',
        cached,
      ).values,
      ['New line'],
    );
    expect(missingLyricTranslationLines('[03:12]Hello world', cached), isEmpty);
    expect(
      parseLrcText(
        composeLineTranslatedLrc('[03:12]Hello world', cached),
      ).single.text,
      'Hello world\n你好世界',
    );
  });

  test('切换为中文或完整双语歌词时无需自动翻译', () {
    for (final lyrics in [
      '[00:01]我们像没发生事一样\n[00:02]继续往前走',
      '[00:01]Hello world\n[00:01]你好世界\n[00:02]Love me\n[00:02]爱我',
      '[00:01][Instrumental]',
    ]) {
      expect(missingLyricTranslationLines(lyrics, {}), isEmpty);
    }
  });

  test('切换后的短英文歌词也会识别，已有译文只复用不重翻', () {
    const lyrics = '[00:12]Love me\n[00:15]Stay here';
    final cache = {lyricTranslationLineId('Love me'): '爱我'};
    expect(missingLyricTranslationLines(lyrics, cache).values, ['Stay here']);
    cache[lyricTranslationLineId('Stay here')] = '留在这里';
    expect(missingLyricTranslationLines(lyrics, cache), isEmpty);
    expect(
      parseLrcText(composeLineTranslatedLrc(lyrics, cache)).map((r) => r.text),
      ['Love me\n爱我', 'Stay here\n留在这里'],
    );
  });

  test('翻译按原文标识合并，服务端改变返回顺序也不串行', () {
    final rows = missingLyricTranslationLines(
      '[00:01]One day\n[00:02]Two days',
      {},
    );
    final response = {
      'schema_version': 3,
      'lines': [
        {
          'id': lyricTranslationLineId('Two days'),
          'source': 'Two days',
          'translation': '两天',
        },
        {
          'id': lyricTranslationLineId('One day'),
          'source': 'One day',
          'translation': '一天',
        },
      ],
    };
    final cached = validateLyricLineTranslations(response, rows);
    final result = parseLrcText(
      composeLineTranslatedLrc('[00:01]One day\n[00:02]Two days', cached),
    );
    expect(result.map((r) => r.text), ['One day\n一天', 'Two days\n两天']);
    expect(result.map((r) => r.time.inSeconds), [1, 2]);
  });

  test('部分双语歌词只补缺失英文行，并保留已有译文', () {
    const lyrics = '[00:01]One day\n[00:01]一天\n[00:02]Two days';
    expect(missingLyricTranslationLines(lyrics, {}).values, ['Two days']);
    final composed = composeLineTranslatedLrc(lyrics, {
      lyricTranslationLineId('Two days'): '两天',
    });
    expect(parseLrcText(composed).map((r) => r.text), [
      'One day\n一天',
      'Two days\n两天',
    ]);
  });

  test('缺行、重复标识、不同原文、旧接口结果都不会写入译文', () {
    final expected = {lyricTranslationLineId('Hello'): 'Hello'};
    for (final response in [
      {
        'translations': ['你好'],
      },
      {'schema_version': 3, 'lines': []},
      {
        'schema_version': 3,
        'lines': [
          {
            'id': expected.keys.single,
            'source': 'Different',
            'translation': '你好',
          },
        ],
      },
      {
        'schema_version': 3,
        'lines': [
          {
            'id': expected.keys.single,
            'source': 'Hello',
            'translation': 'Hello',
          },
        ],
      },
      {
        'schema_version': 3,
        'lines': [
          for (var i = 0; i < 2; i++)
            {
              'id': expected.keys.single,
              'source': 'Hello',
              'translation': '你好',
            },
        ],
      },
    ]) {
      expect(
        () => validateLyricLineTranslations(response, expected),
        throwsFormatException,
      );
    }
  });

  test('原文和行缓存分离，组合双语歌词不修改原行缓存', () {
    const original = '[00:01]Hello world';
    final cached = {lyricTranslationLineId('Hello world'): '你好世界'};
    composeLineTranslatedLrc(original, cached);
    expect(original, '[00:01]Hello world');
    expect(cached, hasLength(1));
    expect(composeLineTranslatedLrc(original, {}), original);
  });

  test('封面候选保留来源、歌手、专辑，忽略无效标识和未知来源', () {
    final id = 'a' * 64;
    final rows = CoverCandidate.parse({
      'candidates': [
        {
          'id': id,
          'source': 'itunes',
          'title': 'Summer',
          'artist': 'A、B',
          'album': 'Album',
          'score': 200,
          'artist_match': false,
        },
        {'id': '../../x', 'source': 'itunes'},
        {'id': id, 'source': 'unknown'},
      ],
    });
    expect(rows, hasLength(1));
    expect(rows.single.artist, 'A、B');
    expect(rows.single.album, 'Album');
    expect(rows.single.source, 'itunes');
    expect(rows.single.score, 200);
    expect(rows.single.artistMatches, isFalse);
  });
}
