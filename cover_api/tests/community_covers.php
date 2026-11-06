<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/../src/SongSelectionService.php';
function coverCheck(bool $value, string $message): void { if (!$value) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_community_covers_' . bin2hex(random_bytes(5));
mkdir($root);
$root = realpath($root);
coverCheck(is_string($root) && str_starts_with($root, realpath(sys_get_temp_dir()) . DIRECTORY_SEPARATOR), '测试目录必须在临时目录中');
$chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
$image = static fn(string $rgb, int $side = 512) => "\x89PNG\r\n\x1a\n" .
    $chunk('IHDR', pack('NNCCCCC', $side, $side, 8, 2, 0, 0, 0)) .
    $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat($rgb, $side), $side))) . $chunk('IEND', '');
try {
    $config = ['cache_dir' => $root];
    $devices = [];
    foreach (['a', 'b', 'c', 'd'] as $device) $devices[$device] = new SongSelectionService($config, str_repeat($device, 64));
    $red = $image("\x90\x20\x20"); $blue = $image("\x20\x40\x90");
    $save = static fn($device, $bytes, $source = 'itunes') => $devices[$device]->save('Song', 'Singer', 200, 'cover',
        ['image_base64' => base64_encode($bytes), 'source' => $source, 'id' => 'upstream-id', 'album' => 'Album']);
    $redId = $save('a', $red)['revision']; $save('b', $red); $blueId = $save('c', $blue, 'deezer')['revision'];
    $rows = $devices['d']->coverCandidates('Song', 'Singer', 201);
    coverCheck(count($rows) === 2 && $rows[0]['id'] === $redId && $rows[0]['votes'] === 2, '相同图片合并，按选择人数排序并容忍小幅时长差异');
    coverCheck($rows[0]['source'] === 'community' && $rows[0]['origin_source'] === 'itunes', '保留原始封面来源');
    for ($i = 0; $i < 4; $i++) $save('b', $red);
    coverCheck($devices['d']->coverCandidates('Song', 'Singer', 200)[0]['votes'] === 2, '重复提交不增加人数');
    $mine = $devices['a']->coverCandidates('Song', 'Singer', 200);
    coverCheck(array_sum(array_column($mine, 'votes')) === 2, '只统计其他设备，排除请求设备自身');
    $save('b', $blue, 'deezer');
    $rows = $devices['d']->coverCandidates('Song', 'Singer', 200);
    coverCheck($rows[0]['id'] === $blueId && $rows[0]['votes'] === 2 && $rows[1]['votes'] === 1, '改选会从旧封面撤票');
    $mine = $devices['a']->coverCandidates('Song', 'Singer', 200);
    coverCheck(count($mine) === 1 && $mine[0]['id'] === $blueId && $mine[0]['votes'] === 2, '只有自己选择的封面不进入其他用户来源');
    coverCheck($devices['d']->coverCandidates('Song', 'Singer', 250) === [], '不同录音版本不混用');
    foreach ($devices as $device) $device->save('Song', 'Singer', 250, 'lyrics', ['text' => '[00:01]live']);
    coverCheck($devices['d']->coverCandidates('Song', 'Singer', 0) === [], '无时长且多版本时不猜测');
    $json = json_encode($rows, JSON_THROW_ON_ERROR);
    coverCheck(!str_contains($json, 'tallies') && !str_contains($json, 'image-') && !str_contains($json, str_repeat('a', 64)), '不泄露设备或缓存文件路径');
    $original = $devices['d']->communityImage('Song', 'Singer', 200, $blueId, false);
    coverCheck($original['bytes'] === $blue, '直接读取服务器已保存的原图');
    $preview = $devices['d']->communityImage('Song', 'Singer', 200, $blueId, true);
    if (extension_loaded('gd')) {
        $dimensions = getimagesizefromstring($preview['bytes']);
        coverCheck(max($dimensions[0], $dimensions[1]) === 256 && $preview['mime'] === 'image/jpeg', '预览使用 256 像素缩略图');
        coverCheck($devices['d']->communityImage('Song', 'Singer', 200, $blueId, true)['bytes'] === $preview['bytes'], '缩略图缓存跨请求复用');
    } else coverCheck($preview['bytes'] === $blue, 'GD 不可用时仍能展示有效图片');
    $save('a', $blue, 'deezer');
    coverCheck(count($devices['d']->coverCandidates('Song', 'Singer', 200)) === 1, '无人选用的旧封面不占候选列表');
    coverCheck($devices['d']->communityImage('Song', 'Singer', 200, $redId, false)['bytes'] === $red, '打开窗口后票数变化仍可读取原候选');
    try { $devices['d']->communityImage('Unrelated', 'Singer', 200, $blueId, true); throw new RuntimeException('跨歌图片未拒绝'); }
    catch (InvalidArgumentException) {}
    $legacy = new SongSelectionService($config);
    $legacy->save('Old song', 'Singer', 200, 'cover', ['image_base64' => base64_encode($red), 'source' => 'lastfm']);
    $rows = $devices['d']->coverCandidates('Old song', 'Singer', 200);
    coverCheck(count($rows) === 1 && $rows[0]['legacy'] && $rows[0]['votes'] === 0, '兼容旧共享封面，不虚构人数');
    unlink($root . '/song_selections_v1/image-' . $blueId . '.img');
    coverCheck($devices['d']->coverCandidates('Song', 'Singer', 200) === [], '不展示原图丢失的候选');
    try { $devices['d']->communityImage('Song', 'Singer', 200, $blueId, false); throw new LogicException('丢失图片不应返回空正文'); }
    catch (RuntimeException $e) { coverCheck(!($e instanceof LogicException), '丢失图片应返回错误'); }
    echo "Community cover checks passed\n";
} finally {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
