<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/../src/SongSelectionService.php';
function matchCheck(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_cover_match_' . bin2hex(random_bytes(5));
mkdir($root); $root = realpath($root);
matchCheck(is_string($root) && str_starts_with($root, realpath(sys_get_temp_dir()) . DIRECTORY_SEPARATOR), '测试目录必须在临时目录中');
$chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
$image = static fn(string $rgb) => "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
    $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat($rgb, 32), 32))) . $chunk('IEND', '');
try {
    $config = ['cache_dir' => $root];
    $reader = new SongSelectionService($config, str_repeat('f', 64));
    $lyrics = "[ti:Ignored title]\n[00:01.00]Dreaming of the summer night\n[00:02.00]Walking by the ocean blue\n[00:03.00]Remember all the words you said\n[00:04.00]Waiting for the morning light\n[00:05.00]You will always be my guiding star";
    $other = "[00:01]Another road beyond the sky\n[00:02]A distant place I used to know\n[00:03]The clouds are drifting over mountains\n[00:04]Listen to the sound of falling rain\n[00:05]The river carries every memory";
    $save = static function ($device, $title, $artist, $rgb, $text, $duration = 200) use ($config, $image) {
        $service = new SongSelectionService($config, hash('sha256', $device));
        $service->save($title, $artist, $duration, 'lyrics', ['text' => $text]);
        return $service->save($title, $artist, $duration, 'cover', ['image_base64' => base64_encode($image($rgb)), 'source' => 'itunes'])['revision'];
    };
    $exact = $save('exact', 'Summer Night', 'Singer', "\x90\x20\x20", $lyrics);
    $alias = $save('alias', 'Summer Nigh', 'Singer', "\x20\x40\x90", $lyrics);
    for ($i = 0; $i < 5; $i++) $fuzzy = $save('fuzzy-' . $i, 'Summer Nights', 'Singer', "\x20\x90\x40", $other);
    $save('live', 'Summer Night (Live)', 'Singer', "\x10\x10\x10", $lyrics);
    $save('wrong-artist', 'Summer Night', 'Other singer', "\x30\x30\x30", $other);
    // Ignore metadata/timing/case/punctuation when comparing source lyrics.
    $shifted = str_replace(['[ti:Ignored title]', '[00:01.00]', 'Dreaming'], ['[ar:Another artist]', '[01:09.20]', 'DREAMING!'], $lyrics);
    $rows = $reader->coverCandidates(' SUMMER-NIGHT ', 'singer', 201, $shifted);
    matchCheck(array_column($rows, 'id') === [$exact, $alias, $fuzzy], '先精确歌曲和歌词，再歌词精确，最后模糊；更多票不能越级');
    matchCheck(array_column($rows, 'match_type') === ['exact_song_lyrics', 'exact_lyrics', 'fuzzy'], '明确标识匹配等级');
    matchCheck($rows[2]['votes'] === 5 && $rows[1]['lookup_title'] === 'Summer Nigh', '保留人数和图片所属歌曲');
    $imageResult = $reader->communityImage($rows[1]['lookup_title'], $rows[1]['lookup_artist'], (float)$rows[1]['lookup_duration'], $rows[1]['id'], true);
    matchCheck(strlen($imageResult['bytes']) > 12, '模糊或歌词关联候选可按原歌曲读取预览');
    $withoutLyrics = $reader->coverCandidates('Summer Night', 'Singer', 200);
    matchCheck($withoutLyrics[0]['id'] === $exact && $withoutLyrics[0]['match_type'] === 'exact_song', '没有歌词也能优先精确歌名歌手');
    matchCheck($reader->coverCandidates('Summer Night', 'Singer', 250, $lyrics) === [], '不混入不同时长的录音');
    matchCheck($reader->coverCandidates('Unrelated song', 'Stranger', 200, '[00:01]love') === [], '短词和常见短句不能用于跨歌曲匹配');
    $liveRows = $reader->coverCandidates('Summer Night (Live)', 'Singer', 200, $lyrics);
    matchCheck(count($liveRows) === 1 && $liveRows[0]['match_type'] === 'exact_song_lyrics', '现场和录音室的版本词保持隔离');
    $save('new-song', 'Distant Place', 'New singer', "\x40\x60\x80", $other);
    matchCheck(count($reader->coverCandidates('Distant Place', 'New singer', 200, $other)) >= 1, '索引建立后的新选择可立即查询');
    $save('exact-2', 'Summer Night', 'Singer', "\x90\x20\x20", $lyrics);
    matchCheck($reader->coverCandidates('Summer Night', 'Singer', 200, $lyrics)[0]['votes'] === 2, '已有索引更新后仍正确统计最后一票');
    $traditional = "[00:01]未來的風伴隨我們走向遠方\n[00:02]夢裡的聲音依然陪在身旁\n[00:03]這一刻讓心中的愛繼續流轉\n[00:04]願所有時光都有你的模樣";
    $simplified = "[00:12]未来的风伴随我们走向远方\n[00:15]梦里的声音依然陪在身旁\n[00:18]这一刻让心中的爱继续流转\n[00:20]愿所有时光都有你的模样";
    $chinese = $save('chinese', '未來的風', '歌手甲、歌手乙', "\x50\x60\x70", $traditional);
    $rows = $reader->coverCandidates('未来的风', '歌手乙 & 歌手甲', 200, $simplified);
    matchCheck($rows[0]['id'] === $chinese && $rows[0]['match_type'] === 'exact_song_lyrics', '简繁和双歌手顺序统一后精确匹配');
    $partial = str_replace('You will always be my guiding star', 'A brand new line of the same song', $lyrics);
    matchCheck($reader->coverCandidates('Summer Nighs', 'Singer', 200, $partial)[0]['match_type'] === 'fuzzy', '歌词少量差异仅标记模糊，不能冒充精确');
    $json = json_encode($reader->coverCandidates('Summer Night', 'Singer', 200, $lyrics));
    matchCheck(!str_contains($json, 'Dreaming') && !str_contains($json, 'voters') && !str_contains($json, hash('sha256', 'exact')), '候选不暴露歌词正文或设备信息');
    $indexPath = $root . '/song_selections_v1/cover-search-v1.json';
    $before = file_get_contents($indexPath);
    $reader->coverCandidates('Summer Night', 'Singer', 200, $lyrics);
    matchCheck(file_get_contents($indexPath) === $before && !str_contains($before, 'Dreaming'), '重复查询只读索引，索引不保存歌词正文');
    try { $reader->coverCandidates('Song', 'Singer', 200, str_repeat('a', 262145)); throw new LogicException('超长歌词未拒绝'); }
    catch (InvalidArgumentException) {}
    echo "Community cover matching checks passed\n";
} finally {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
