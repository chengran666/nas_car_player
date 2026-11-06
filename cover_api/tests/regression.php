<?php
declare(strict_types=1);
require __DIR__ . '/../src/LyricTranslationService.php';
require __DIR__ . '/../src/CoverCandidateService.php';
require __DIR__ . '/../src/SongSelectionService.php';
function check(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_api_test_' . bin2hex(random_bytes(5));
mkdir($root);
try {
    $calls = [];
    $fake = static function ($model, $title, $artist, $rows) use (&$calls): array {
        $calls[] = $rows;
        return ['lines' => array_reverse(array_map(static fn($row) => ['id' => $row['id'], 'translation' => '译文：' . $row['text']], $rows))];
    };
    $config = ['cache_dir' => $root, 'openrouter_translation_model' => 'openai/gpt-5.6-sol'];
    $service = new LyricTranslationService($config, $fake);
    $first = $service->translate('One', 'A', ['Hello world', 'Hello world', 'Love me']);
    check(count($calls) === 1 && count($calls[0]) === 2, '重复原文只请求一次');
    check($first['translations'] === ['译文：Hello world', '译文：Hello world', '译文：Love me'], '返回乱序仍正确配对');
    $second = $service->translate('Different song', 'Different artist', ['Love me', '  Hello   world  ', 'New line']);
    check(count($calls[1]) === 1 && $calls[1][0]['text'] === 'New line', '改歌曲、顺序或空白仍按行复用缓存');
    check($second['cache_hits'] === 2, '逐行命中统计正确');
    check($service->translate('Third', '', ['Hello world'])['cached'], '全缓存命中无需模型请求');
    $other = new LyricTranslationService(['cache_dir' => $root, 'openrouter_translation_model' => 'different-model'], $fake);
    $other->translate('', '', ['Hello world']);
    check(count($calls) === 3, '不同模型的行缓存独立');
    foreach ([['lines' => []], ['lines' => [['id' => 'wrong', 'translation' => '错误']]],
        ['lines' => [['id' => LyricTranslationService::lineId('Hello'), 'translation' => 'Hello']]]] as $bad) {
        try { LyricTranslationService::validateResult([['id' => LyricTranslationService::lineId('Hello'), 'text' => 'Hello']], $bad); throw new LogicException('应拒绝错误翻译'); }
        catch (RuntimeException $expected) {}
    }
    $requests = [];
    $cover = new CoverCandidateService($config, static function ($url) use (&$requests) {
        $requests[] = $url;
        if (str_contains($url, 'itunes')) return ['results' => [
            ['trackName' => 'Summer', 'artistName' => 'Right', 'collectionName' => 'Right album', 'artworkUrl100' => 'https://is1-ssl.mzstatic.com/image/right/100x100bb.jpg'],
            ['trackName' => 'Summer', 'artistName' => 'Wrong', 'collectionName' => 'Wrong album', 'artworkUrl100' => 'https://is1-ssl.mzstatic.com/image/wrong/100x100bb.jpg'],
        ]];
        return ['data' => []];
    });
    $rows = $cover->search('Summer', 'Right', 'itunes')['candidates'];
    check(count($rows) === 2 && $rows[0]['artist'] === 'Right', '封面按歌曲歌手排序、跨国家重复结果去重');
    check($rows[0]['artist_match'] && !$rows[1]['artist_match'], '同名不同歌手只供手选，不可自动选错');
    $count = count($requests);
    check($cover->search('Summer', 'Right', 'itunes')['cached'] && count($requests) === $count, '封面候选使用来源缓存');
    $cover->search('Summer', 'Right', 'deezer');
    check(count($requests) > $count && str_contains(end($requests), 'deezer'), '每个来源单独查询');
    $traditional = new CoverCandidateService($config, static fn($url) => ['results' => [
        ['trackName' => '被風吹過的夏天', 'artistName' => '林俊傑', 'collectionName' => '原版', 'artworkUrl100' => 'https://is1-ssl.mzstatic.com/image/duet/100x100bb.jpg'],
    ]]);
    $matched = $traditional->search('被风吹过的夏天', '金莎、林俊杰', 'itunes', true)['candidates'];
    check(count($matched) === 1 && $matched[0]['title_match'] && $matched[0]['artist_match'], '简繁标题和双歌手匹配原版候选');
    check(!CoverCandidateService::trustedImageUrl('https://mzstatic.com.evil.example/x'), '拒绝伪造 CDN 主机');
    check(!CoverCandidateService::trustedImageUrl('http://is1.mzstatic.com/x'), '拒绝不安全图片地址');
    $proxyConfig = ['openrouter_proxy' => 'http://127.0.0.1:10809'];
    check(CoverCandidateService::proxyForUrl($proxyConfig, 'https://archive.org/download/cover.jpg') !== '', '受限图片走现有代理');
    check(CoverCandidateService::proxyForUrl($proxyConfig, 'https://api.deezer.com/search') !== '', 'Deezer 查询走现有代理');
    check(CoverCandidateService::proxyForUrl($proxyConfig, 'https://itunes.apple.com/search') === '', 'iTunes 保持直连');
    check(CoverCandidateService::proxyForUrl($proxyConfig, 'https://archive.org.other.example/x') === '', '代理域名必须精确匹配');
    $choices = new SongSelectionService($config);
    check($choices->get('Song', 'Singer', 200) === null, '无选择时明确返回未命中');
    $lrc = "[00:01.00]First line\n[00:02.00]Second line";
    $choices->save('Song', 'Singer', 200, 'lyrics', ['text' => $lrc, 'candidate_id' => 123]);
    check($choices->get(' song ', 'SINGER', 202)['lyrics']['text'] === $lrc, '标题空白与大小写、时长轻微差异复用歌词正文');
    check($choices->get('Song', 'Other singer', 200) === null, '同名不同歌手隔离');
    check($choices->get('Song (Live)', 'Singer', 200) === null, '保留版本词，不混用现场版');
    check($choices->get('Song', 'Singer', 250) === null, '时长明显不符不命中');
    $chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
    $png = "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
        $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat("\x20\x40\x60", 32), 32))) . $chunk('IEND', '');
    $coverChoice = ['image_base64' => base64_encode($png), 'id' => 'old-candidate', 'source' => 'deezer'];
    $savedCover = $choices->save('Song', 'Singer', 200, 'cover', $coverChoice);
    $again = (new SongSelectionService($config))->get('Song', 'Singer', 200);
    check($again['lyrics']['candidate_id'] === 123 && $again['cover']['id'] === 'old-candidate', '独立保存封面不覆盖歌词，重启仍保留');
    check(!isset($again['cover']['file']) && !isset($again['cover']['image_base64']), '接口不暴露存储路径或重复图像正文');
    check($choices->image('Song', 'Singer', 200, $savedCover['revision'])['bytes'] === $png, '候选查询缓存失效后仍使用独立图片副本');
    $choices->save('Song', 'Singer', 250, 'lyrics', ['text' => '[00:02]Live version']);
    check($choices->get('Song', 'Singer', 0) === null, '多个录音版本且无时长时不猜测');
    check($choices->get('Song', 'Singer', 250)['lyrics']['text'] === '[00:02]Live version', '重复版本使用对应歌词');
    $choices->save('Song', 'Singer', 200, 'lyrics', ['text' => '[00:03]Corrected']);
    check($choices->get('Song', 'Singer', 200)['cover']['revision'] === $savedCover['revision'], '再次选词保留既有封面');
    $latestCover = $choices->save('Song', 'Singer', 200, 'cover', array_replace($coverChoice, ['id' => 'latest-candidate', 'source' => 'itunes']));
    $restored = (new SongSelectionService($config))->get('Song', 'Singer', 200);
    check($restored['lyrics']['text'] === '[00:03]Corrected' && $restored['cover']['id'] === 'latest-candidate', '新客户端始终读取两种资源最后成功提交的选择');
    check($restored['cover']['revision'] === $latestCover['revision'], '同一图片重新选择也保留最后提交的元数据');
    $deviceA = str_repeat('a', 64); $deviceB = str_repeat('b', 64);
    $a = new SongSelectionService($config, $deviceA);
    $b = new SongSelectionService($config, $deviceB);
    check($a->get('Song', 'Singer', 200) === $restored, '新设备未选择时复用旧默认记录');
    $a->save('Song', 'Singer', 200, 'lyrics', ['text' => '[00:04]Device A']);
    check($a->get('Song', 'Singer', 200)['cover']['id'] === 'latest-candidate', '只选择歌词时仍可读取默认封面');
    $pngA = "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
        $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat("\x90\x10\x20", 32), 32))) . $chunk('IEND', '');
    $coverA = $a->save('Song', 'Singer', 200, 'cover', ['image_base64' => base64_encode($pngA), 'id' => 'cover-a']);
    $b->save('Song', 'Singer', 200, 'cover', array_replace($coverChoice, ['id' => 'cover-b']));
    check($b->get('Song', 'Singer', 200)['lyrics']['text'] === '[00:04]Device A', '只选择封面时复用其他设备所选歌词');
    $b->save('Song', 'Singer', 200, 'lyrics', ['text' => '[00:05]Device B']);
    $reinstalledA = new SongSelectionService($config, $deviceA);
    check($reinstalledA->get('Song', 'Singer', 200)['lyrics']['text'] === '[00:04]Device A' && $reinstalledA->get('Song', 'Singer', 200)['cover']['id'] === 'cover-a', '同一设备重装恢复自己的选择，另一设备不覆盖');
    check($b->get('Song', 'Singer', 200)['lyrics']['text'] === '[00:05]Device B' && $b->get('Song', 'Singer', 200)['cover']['id'] === 'cover-b', '第二台设备保留独立的歌词封面');
    check($choices->get('Song', 'Singer', 200) === $restored, '设备选择不修改旧默认记录');
    check($reinstalledA->image('Song', 'Singer', 200, $coverA['revision'])['bytes'] === $pngA, '封面图读取也隔离设备');
    check($b->image('Song', 'Singer', 200, $savedCover['revision'])['bytes'] === $png, '第二台设备只读取自己的封面内容');
    $rejected = false;
    try { new SongSelectionService($config, '../bad-id'); } catch (InvalidArgumentException $error) { $rejected = true; }
    check($rejected, '拒绝无效设备识别码');
    $choices->save('被風吹過的夏天', '林俊傑、金莎', 240, 'lyrics', ['text' => '[00:01]双歌手']);
    check($choices->get('被风吹过的夏天', '金莎 & 林俊杰', 240)['lyrics']['text'] === '[00:01]双歌手', '简繁与双歌手顺序统一识别');
    foreach ([['cover', ['image_base64' => base64_encode('<html>invalid</html>')]], ['lyrics', ['text' => '']]] as [$kind, $choice]) {
        $rejected = false;
        try { $choices->save('Song', 'Singer', 200, $kind, $choice); } catch (InvalidArgumentException $error) { $rejected = true; }
        check($rejected, '拒绝无效的所选内容');
    }
    echo "PHP regression checks passed\n";
} finally {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
