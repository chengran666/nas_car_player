import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_car_player/main.dart';

void main() {
  group('歌曲文件名解析', () {
    test('带空格分隔符时按“歌手 - 歌名”解析', () {
      final metadata = parseSongFileName('阿桑 - 一直很安静.mp3');
      expect(metadata.title, '一直很安静');
      expect(metadata.artist, '阿桑');
    });

    test('紧凑分隔符时按“歌名-歌手”解析', () {
      final metadata = parseSongFileName('一直很安静-阿桑.flac');
      expect(metadata.title, '一直很安静');
      expect(metadata.artist, '阿桑');
    });

    test('没有歌手信息时使用私人乐库', () {
      final metadata = parseSongFileName('纯音乐.wav');
      expect(metadata.title, '纯音乐');
      expect(metadata.artist, '私人乐库');
    });

    test('封面搜索使用智能解析后的歌名和歌手', () {
      final metadata = parseSongFileName('金莎、林俊杰 - 被风吹过的夏天.mp3');
      final query = buildMusicBrainzRecordingQuery(
        metadata.title,
        metadata.artist,
      );
      expect(query, 'recording:"被风吹过的夏天" AND (artist:"金莎" OR artist:"林俊杰")');
      expect(buildArtistSearchVariants(metadata.artist), [
        '金莎、林俊杰',
        '金莎',
        '林俊杰',
      ]);
      expect(isLikelySameArtistCredit(metadata.artist, '金莎 & 林俊傑'), isTrue);
      expect(isLikelySameArtistCredit(metadata.artist, '金莎'), isTrue);
    });

    test('封面结果允许简繁体单字差异', () {
      expect(isLikelySameSongText('一直很安静', '一直很安靜'), isTrue);
      expect(isLikelySameSongText('一直很安静', '完全不同的歌曲'), isFalse);
    });

    test('歌词候选优先选择歌名歌手和时长都匹配的滚动歌词', () {
      final exact = scoreLyricCandidate(
        expectedTitle: '一直很安静',
        expectedArtist: '阿桑',
        expectedDuration: const Duration(seconds: 251),
        actualTitle: '一直很安靜',
        actualArtist: '阿桑',
        actualDurationSeconds: 251.4,
        hasSyncedLyrics: true,
      );
      final wrongVersion = scoreLyricCandidate(
        expectedTitle: '一直很安静',
        expectedArtist: '其他歌手',
        expectedDuration: const Duration(seconds: 251),
        actualTitle: '一直很安静',
        actualArtist: '阿桑',
        actualDurationSeconds: 285,
        hasSyncedLyrics: true,
      );
      expect(exact, greaterThan(wrongVersion));
      expect(exact, greaterThanOrEqualTo(70));
    });

    test('歌词解析会合并同时间戳的原文和翻译', () {
      final lyrics = parseLrcText(
        '[00:10.50]Summer wind\n[00:10.500]夏日的风\n[00:15.00]下一句',
      );
      expect(lyrics, hasLength(2));
      expect(lyrics.first.time, const Duration(seconds: 10, milliseconds: 500));
      expect(lyrics.first.text, 'Summer wind\n夏日的风');
    });

    test('歌词源把中文标在下一句时间时会自动前移并恢复英文主行', () {
      final lyrics = parseLrcText(
        '[00:19.85]Well I wonder\n'
        '[00:22.31]我想知道\n'
        '[00:22.31]Could it be\n'
        '[00:24.89]这是我的幻觉吗\n'
        "[00:24.89]When I was dreaming 'bout you baby\n"
        '[00:27.75]当我梦见你时\n'
        '[00:27.75]You were dreaming of me',
      );
      expect(lyrics, hasLength(4));
      expect(lyrics[0].text, 'Well I wonder\n我想知道');
      expect(lyrics[1].text, 'Could it be\n这是我的幻觉吗');
      expect(lyrics[2].text, "When I was dreaming 'bout you baby\n当我梦见你时");
      expect(lyrics[3].text, 'You were dreaming of me');
    });

    test('歌词解析支持一行多个时间戳并按时间排序', () {
      final lyrics = parseLrcText('[00:20.00][00:05.20]重复副歌\n[00:12.00]中间一句');
      expect(lyrics.map((line) => line.time), [
        const Duration(seconds: 5, milliseconds: 200),
        const Duration(seconds: 12),
        const Duration(seconds: 20),
      ]);
      expect(lyrics.first.text, '重复副歌');
      expect(lyrics.last.text, '重复副歌');
    });

    test('歌词解析支持文件内置毫秒偏移', () {
      final lyrics = parseLrcText('[offset:+500]\n[00:01.00]延后显示');
      expect(lyrics.single.time, const Duration(seconds: 1, milliseconds: 500));
    });

    test('歌词微调按正值提前、负值延后，并在时间边界切换', () {
      final lyricTimes = [
        const Duration(seconds: 10),
        const Duration(seconds: 15),
      ];
      expect(
        lyricIndexAtPosition(lyricTimes, const Duration(milliseconds: 9900), 0),
        -1,
      );
      expect(
        lyricIndexAtPosition(
          lyricTimes,
          const Duration(milliseconds: 9900),
          0.2,
        ),
        0,
      );
      expect(
        lyricIndexAtPosition(
          lyricTimes,
          const Duration(milliseconds: 10100),
          -0.2,
        ),
        -1,
      );
    });

    test('歌词微调会改写普通、区间和逐字时间标签，保留元信息', () {
      const source =
          '[ar:歌手]\n[offset:+500]\n[00:10.50][00:30.000]副歌\n'
          '[00:23:340,00:26:400]区间\n[00:05.00]<00:05.25>英文';
      final shifted = shiftLrcTimestamps(source, -200);
      expect(shifted.tagCount, 5);
      expect(shifted.text, contains('[ar:歌手]\n[offset:+500]'));
      expect(shifted.text, contains('[00:10.300][00:29.800]副歌'));
      expect(shifted.text, contains('[00:23.140,00:26.200]区间'));
      expect(shifted.text, contains('[00:04.800]<00:05.050>英文'));
      expect(
        parseLrcText(shifted.text).first.time,
        const Duration(seconds: 5, milliseconds: 300),
      );
    });

    test('歌词微调在零点截断，无时间标签时不会修改正文', () {
      expect(shiftLrcTimestamps('[00:00.10]开始', -200).text, '[00:00.000]开始');
      final untimed = shiftLrcTimestamps('[ar:歌手]\n只有文本', 200);
      expect(untimed.tagCount, 0);
      expect(untimed.text, '[ar:歌手]\n只有文本');
    });

    test('备用词库的开始结束区间只生成一行歌词', () {
      final lyrics = parseLrcText(
        '[00:23:340,00:26:400]我们 像没发生事一样\n'
        '[00:26:940,00:29:370]自顾地走在路上',
      );
      expect(lyrics, hasLength(2));
      expect(lyrics.first.time, const Duration(seconds: 23, milliseconds: 340));
      expect(lyrics.first.text, '我们 像没发生事一样');
    });

    test('短时间内连续的相同歌词会折叠', () {
      final lyrics = parseLrcText('[00:23.00][00:24.00][00:25.00]我们 像没发生事一样');
      expect(lyrics, hasLength(1));
      expect(lyrics.single.time, const Duration(seconds: 23));
    });

    test('不同歌词行的重复句保留各自时间点', () {
      final lyrics = parseLrcText(
        '[00:23.00]Oh baby\n[00:27.00]Oh baby\n[00:31.00]下一句',
      );
      expect(lyrics, hasLength(3));
      expect(lyrics[1].time, const Duration(seconds: 27));
    });

    test('封面代表色优先选择占比大的主体色', () {
      final selected = selectRepresentativeCoverColor([
        (color: const Color(0xFF174C70), population: 820),
        (color: const Color(0xFFD6B767), population: 130),
        (color: const Color(0xFFF4F4F1), population: 50),
      ]);
      final selectedHue = HSLColor.fromColor(selected).hue;
      expect(selectedHue, inInclusiveRange(190, 220));
    });

    test('封面缓存只接受实际图片内容，文件重建后使用新的图片键', () {
      expect(
        isSupportedCoverImageHeader([
          0xFF,
          0xD8,
          0xFF,
          0xE0,
          ...List.filled(12, 0),
        ]),
        isTrue,
      );
      expect(
        isSupportedCoverImageHeader('{"error":"failed"}'.codeUnits),
        isFalse,
      );
      const path = 'C:/cache/cover.jpg';
      final file = File(path);
      expect(VersionedFileImage(file, 1), isNot(VersionedFileImage(file, 2)));
    });

    test('封面主题色生成可读的高亮色和同色系浅色背景', () {
      final theme = buildCoverThemeColors(const Color(0xFF174C70));
      final accentHsl = HSLColor.fromColor(theme.accent);
      final glowHsl = HSLColor.fromColor(theme.glow);
      expect(accentHsl.hue, closeTo(glowHsl.hue, 2));
      expect(theme.accent.computeLuminance(), lessThan(0.30));
      expect(theme.glow.computeLuminance(), greaterThan(0.65));
    });

    test('纯英文歌词会进入翻译流程，中文和双语歌词不会重复翻译', () {
      const english =
          '[00:01.00]When the night has come\n'
          '[00:05.00]And the land is dark\n'
          '[00:09.00]And the moon is the only light we see';
      expect(isPredominantlyEnglishLyrics(english), isTrue);
      expect(
        isPredominantlyEnglishLyrics('$english\n[00:01.00]当夜幕降临'),
        isFalse,
      );
      expect(isPredominantlyEnglishLyrics('[00:01.00]今晚一起看月亮'), isFalse);
    });

    test('英文原文和中文译文会按同一时间戳合并展示', () {
      final original = parseLrcText(
        '[00:01.00]When the night has come\n[00:05.50]And the land is dark',
      );
      final bilingual = buildBilingualLrc(original, ['当夜幕降临', '大地陷入黑暗']);
      final parsed = parseLrcText(bilingual);
      expect(parsed, hasLength(2));
      expect(parsed.first.text, 'When the night has come\n当夜幕降临');
      expect(parsed.last.text, 'And the land is dark\n大地陷入黑暗');
    });

    test('歌词翻译接口支持完整地址和服务根地址', () {
      expect(
        parseLyricTranslationApiUrl(
          'https://cover_api.whzxc.com/lyrics.php',
        ).toString(),
        'https://cover_api.whzxc.com/lyrics.php',
      );
      expect(
        parseLyricTranslationApiUrl('https://cover_api.whzxc.com/').toString(),
        'https://cover_api.whzxc.com/lyrics.php',
      );
      expect(
        () => parseLyricTranslationApiUrl('cover_api.whzxc.com'),
        throwsFormatException,
      );
    });
  });
}
