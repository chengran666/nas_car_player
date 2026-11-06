<?php
declare(strict_types=1);
require __DIR__ . '/../src/SongSelectionService.php';
function expectSelection(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_votes_test_' . bin2hex(random_bytes(5));
mkdir($root);
try {
    $config = ['cache_dir' => $root];
    $devices = [];
    foreach (['a', 'b', 'c', 'd', 'e'] as $id) $devices[$id] = new SongSelectionService($config, str_repeat($id, 64));
    $read = static fn(string $id = 'e', float $duration = 200) => $devices[$id]->get('Song', 'Singer', $duration);
    $save = static fn(string $id, string $text, float $duration = 200) => $devices[$id]->save('Song', 'Singer', $duration, 'lyrics', ['text' => $text]);
    $save('a', '[00:01]First');
    expectSelection($read()['lyrics']['text'] === '[00:01]First' && $read()['lyrics']['votes'] === 1, '未选择的新设备直接复用已有歌词');
    $save('b', '[00:02]Second');
    expectSelection($read()['lyrics']['text'] === '[00:01]First', '同票保持默认稳定');
    $save('c', '[00:02]Second', 202);
    expectSelection($read()['lyrics']['text'] === '[00:02]Second' && $read()['lyrics']['votes'] === 2, '默认选择人数最多，容忍轻微时长差异');
    expectSelection($read('a')['lyrics']['text'] === '[00:01]First' && !isset($read('a')['lyrics']['votes']), '个人选择优先，不被多数覆盖');
    for ($i = 0; $i < 5; $i++) $save('a', '[00:01]First');
    expectSelection($read()['lyrics']['votes'] === 2, '重试和重复点击不增加票数');
    $save('b', '[00:01]First');
    expectSelection($read()['lyrics']['text'] === '[00:01]First' && $read()['lyrics']['votes'] === 2, '改选撤销旧票并加入新票');
    expectSelection(!isset($read()['tallies']), '响应不暴露投票设备和其他候选正文');
    expectSelection($read('e', 250) === null, '不同录音时长不会混用选择');
    $save('d', '[00:03]Live', 250);
    expectSelection($read('e', 250)['lyrics']['text'] === '[00:03]Live' && $read('e', 0) === null, '不同版本独立计票，无时长多版本不猜测');
    $chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
    $image = static fn(string $rgb) => "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) . $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat($rgb, 32), 32))) . $chunk('IEND', '');
    $pngA = $image("\x20\x40\x60"); $pngB = $image("\x90\x10\x20");
    $old = $devices['a']->save('Song', 'Singer', 200, 'cover', ['image_base64' => base64_encode($pngA), 'id' => 'A']);
    $devices['b']->save('Song', 'Singer', 200, 'cover', ['image_base64' => base64_encode($pngB), 'id' => 'B']);
    $devices['c']->save('Song', 'Singer', 200, 'cover', ['image_base64' => base64_encode($pngB), 'id' => 'B']);
    $record = $read();
    expectSelection($record['cover']['id'] === 'B' && $record['cover']['votes'] === 2 && $record['lyrics']['text'] === '[00:01]First', '歌词封面分别选多数，封面不覆盖歌词');
    expectSelection($devices['e']->image('Song', 'Singer', 200, $record['cover']['revision'])['bytes'] === $pngB, '新设备可直接下载多数封面的本地副本');
    expectSelection($devices['e']->image('Song', 'Singer', 200, $old['revision'])['bytes'] === $pngA, '下载途中默认改变仍可读取曾被选择的图片');
    for ($i = 0; $i < 5; $i++) $read();
    expectSelection($read()['cover']['votes'] === 2, '自动复用不投票');
    // Simulate upgrading a server that has device records but no community index.
    foreach (glob($root . '/song_selections_v1/community-*.json') ?: [] as $path) unlink($path);
    $migrated = $read();
    expectSelection($migrated['lyrics']['votes'] === 2 && $migrated['cover']['votes'] === 2, '历史个人选择自动迁移到统计');
    expectSelection($migrated['lyrics']['text'] === '[00:01]First' && $migrated['cover']['id'] === 'B', '迁移结果与选择人数一致');
    $deviceFile = glob($root . '/song_selections_v1/device-' . str_repeat('a', 64) . '-*.json')[0];
    $mtime = filemtime($deviceFile);
    expectSelection((new SongSelectionService($config, str_repeat('f', 64)))->get('Song', 'Singer', 200)['cover']['votes'] === 2, '全新设备无须查询外部封面源');
    expectSelection(filemtime($deviceFile) === $mtime, '读取公共默认不会修改个人选择');
    echo "Selection popularity checks passed\n";
} finally {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
