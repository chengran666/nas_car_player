<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
$root = $argv[1] ?? dirname(__DIR__);
$base = rtrim($argv[2] ?? 'https://cover_api.whzxc.com', '/');
$config = require $root . '/config.php';
$title = 'NasSelectionCheck' . bin2hex(random_bytes(6));
$song = ['title' => $title, 'artist' => 'SelectionTest', 'duration' => 200];
$deviceA = hash('sha256', $title . ':a'); $deviceB = hash('sha256', $title . ':b');
$deviceC = hash('sha256', $title . ':c'); $deviceD = hash('sha256', $title . ':d');
$songA = $song + ['device_id' => $deviceA]; $songB = $song + ['device_id' => $deviceB];
$songC = $song + ['device_id' => $deviceC]; $songD = $song + ['device_id' => $deviceD];
$chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
$png = "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
    $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat(random_bytes(3), 32), 32))) . $chunk('IEND', '');
$newPng = "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
    $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat(random_bytes(3), 32), 32))) . $chunk('IEND', '');
function smokeCheck(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$request = static function (string $path, ?array $payload = null, bool $authorized = true) use ($config, $base): array {
    $ch = curl_init($base . '/' . $path);
    $headers = ['Content-Type: application/json'];
    if ($authorized) $headers[] = 'Authorization: Bearer ' . $config['access_token'];
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $headers, CURLOPT_TIMEOUT => 15]);
    if ($payload !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($payload, JSON_THROW_ON_ERROR)); }
    $bytes = curl_exec($ch); $status = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    return [$status, $bytes];
};
try {
    [$status] = $request('selections.php?' . http_build_query($song), null, false);
    smokeCheck($status === 401, '必须拒绝未鉴权请求');
    [$status, $bytes] = $request('selections.php', $song + ['kind' => 'lyrics', 'choice' => ['text' => '[00:01]Chosen lyric', 'candidate_id' => 42]]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '歌词保存接口失败');
    [$status, $bytes] = $request('selections.php', $song + ['kind' => 'cover', 'choice' => ['image_base64' => base64_encode($png), 'source' => 'test', 'id' => 'selection-check']]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '封面保存接口失败');
    $revision = json_decode($bytes, true)['revision'];
    [$status, $bytes] = $request('selections.php?' . http_build_query($song));
    $selected = json_decode($bytes, true)['selection'];
    smokeCheck($status === 200 && $selected['lyrics']['candidate_id'] === 42 && $selected['cover']['revision'] === $revision, '保存后不能复用两个选择');
    [$status, $bytes] = $request('selections.php?' . http_build_query($song + ['action' => 'image', 'revision' => $revision]));
    smokeCheck($status === 200 && $bytes === $png, '独立封面正文不一致');
    [$status, $bytes] = $request('selections.php', $song + ['kind' => 'lyrics', 'choice' => ['text' => '[00:02]Latest lyric', 'candidate_id' => 43]]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '最后一次歌词提交失败');
    [$status, $bytes] = $request('selections.php', $song + ['kind' => 'cover', 'choice' => ['image_base64' => base64_encode($newPng), 'source' => 'test', 'id' => 'latest-selection-check']]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '最后一次封面提交失败');
    $latestRevision = json_decode($bytes, true)['revision'];
    [$status, $bytes] = $request('selections.php?' . http_build_query($song));
    $latest = json_decode($bytes, true)['selection'];
    smokeCheck($status === 200 && $latest['lyrics']['text'] === '[00:02]Latest lyric' && $latest['lyrics']['candidate_id'] === 43 && $latest['cover']['id'] === 'latest-selection-check', '新客户端读取未返回最后提交的歌词和封面');
    [$status, $bytes] = $request('selections.php?' . http_build_query($song + ['action' => 'image', 'revision' => $latestRevision]));
    smokeCheck($status === 200 && $bytes === $newPng, '读取的不是最后选定的封面图片');
    [$status, $bytes] = $request('?' . http_build_query($song + ['format' => 'json']));
    smokeCheck($status === 200 && json_decode($bytes, true)['source'] === 'manual_selection', '旧封面入口未优先复用手选结果');
    [$status, $bytes] = $request('selections.php?' . http_build_query(array_replace($song, ['duration' => 250])));
    smokeCheck($status === 200 && json_decode($bytes, true)['selection'] === null, '时长不同不应该复用');
    [$status, $bytes] = $request('selections.php?' . http_build_query($songA));
    smokeCheck($status === 200 && json_decode($bytes, true)['selection']['lyrics']['candidate_id'] === 43, '新设备未复用旧默认记录');
    [$status, $bytes] = $request('selections.php', $songA + ['kind' => 'lyrics', 'choice' => ['text' => '[00:03]Device A', 'candidate_id' => 44]]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '设备 A 歌词保存失败');
    [$status, $bytes] = $request('selections.php', $songA + ['kind' => 'cover', 'choice' => ['image_base64' => base64_encode($png), 'id' => 'device-a-cover']]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '设备 A 封面保存失败');
    [$status, $bytes] = $request('selections.php', $songB + ['kind' => 'cover', 'choice' => ['image_base64' => base64_encode($newPng), 'id' => 'device-b-cover']]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '设备 B 封面保存失败');
    [$status, $bytes] = $request('selections.php?' . http_build_query($songB));
    smokeCheck($status === 200 && json_decode($bytes, true)['selection']['lyrics']['candidate_id'] === 44, '设备 B 没选歌词时应直接复用设备 A 歌词');
    [$status, $bytes] = $request('selections.php', $songB + ['kind' => 'lyrics', 'choice' => ['text' => '[00:04]Device B', 'candidate_id' => 45]]);
    smokeCheck($status === 200 && json_decode($bytes, true)['success'], '设备 B 歌词保存失败');
    [$status, $bytes] = $request('selections.php?' . http_build_query($songA));
    $restoredA = json_decode($bytes, true)['selection'];
    smokeCheck($status === 200 && $restoredA['lyrics']['candidate_id'] === 44 && $restoredA['cover']['id'] === 'device-a-cover', '设备 A 重装读取的不是自己的最后选择');
    [$status, $bytes] = $request('selections.php?' . http_build_query($songA + ['action' => 'image', 'revision' => $revision]));
    smokeCheck($status === 200 && $bytes === $png, '设备 A 封面正文隔离失败');
    [$status, $bytes] = $request('?' . http_build_query($songB));
    smokeCheck($status === 200 && $bytes === $newPng, '封面入口没有使用设备 B 的封面');
    [$status, $bytes] = $request('selections.php?' . http_build_query($song));
    smokeCheck($status === 200 && json_decode($bytes, true)['selection']['lyrics']['candidate_id'] === 43, '设备写入覆盖了公共默认记录');
    foreach (['lyrics' => ['text' => '[00:04]Device B', 'candidate_id' => 45], 'cover' => ['image_base64' => base64_encode($newPng), 'id' => 'device-b-cover']] as $kind => $choice) {
        [$status, $bytes] = $request('selections.php', $songC + ['kind' => $kind, 'choice' => $choice]);
        smokeCheck($status === 200 && json_decode($bytes, true)['success'], '第三个设备的投票失败');
    }
    $started = microtime(true);
    [$status, $bytes] = $request('selections.php?' . http_build_query($songD));
    $elapsed = (microtime(true) - $started) * 1000;
    $popular = json_decode($bytes, true)['selection'];
    smokeCheck($status === 200 && $popular['lyrics']['candidate_id'] === 45 && $popular['lyrics']['votes'] === 2 && $popular['cover']['votes'] === 2, '新设备应复用两个资源各自选择人数最多的结果');
    smokeCheck(!isset($popular['tallies']) && !str_contains($bytes, $deviceA), '接口不应暴露其他设备标识');
    [$status, $bytes] = $request('selections.php?' . http_build_query($songD + ['action' => 'image', 'revision' => $popular['cover']['revision']]));
    smokeCheck($status === 200 && $bytes === $newPng, '新设备无法读取多数封面副本');
    [$status, $bytes] = $request('?' . http_build_query($songD + ['format' => 'json']));
    smokeCheck($status === 200 && json_decode($bytes, true)['source'] === 'manual_selection', '普通封面入口未复用多数选择');
    echo 'New-device cached lookup: ' . round($elapsed, 1) . " ms\n";
    [$status] = $request('selections.php?' . http_build_query($song + ['device_id' => '../bad-id']));
    smokeCheck($status === 400, '接口应拒绝非法设备标识');
    echo "Production selection HTTP checks passed\n";
} finally {
    $dir = rtrim($config['cache_dir'], '/\\') . '/song_selections_v1';
    $file = $dir . '/' . hash('sha256', strtolower($title) . '|selectiontest') . '.json';
    foreach ([$deviceA, $deviceB, $deviceC, $deviceD] as $device) {
        $profileFile = $dir . '/device-' . $device . '-' . basename($file);
        foreach ([$profileFile, $profileFile . '.lock'] as $path) if (is_file($path)) unlink($path);
    }
    $communityFile = $dir . '/community-' . basename($file);
    foreach ([$communityFile, $communityFile . '.lock', substr($communityFile, 0, -5) . '.defaults.json'] as $path) if (is_file($path)) unlink($path);
    foreach ([$file, $file . '.lock', $dir . '/image-' . hash('sha256', $png) . '.img', $dir . '/image-' . hash('sha256', $newPng) . '.img'] as $path) if (is_file($path)) unlink($path);
}
