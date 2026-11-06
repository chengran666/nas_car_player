<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
$site = $argv[1] ?? dirname(__DIR__);
$base = rtrim($argv[2] ?? 'https://mp3.whzxc.com', '/');
$config = require $site . '/config.php';
$title = 'NasCommunityHttp' . bin2hex(random_bytes(8));
$song = ['title' => $title, 'artist' => 'CommunityHttpTest', 'duration' => 200];
$ids = array_map(static fn($id) => hash('sha256', $title . ':' . $id), ['a', 'b', 'c', 'd']);
$chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
$image = static fn() => "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 512, 512, 8, 2, 0, 0, 0)) .
    $chunk('tEXt', "TestNonce\x00" . bin2hex(random_bytes(16))) .
    $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat(random_bytes(3), 512), 512))) . $chunk('IEND', '');
$images = [$image(), $image()];
$revisions = array_map(static fn($image) => hash('sha256', $image), $images);
function communityHttpCheck(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$request = static function ($path, $payload = null, $authorized = true) use ($base, $config): array {
    $ch = curl_init($base . '/' . $path);
    $headers = ['Content-Type: application/json'];
    if ($authorized) $headers[] = 'Authorization: Bearer ' . $config['access_token'];
    curl_setopt_array($ch, [CURLOPT_HTTPHEADER => $headers, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20]);
    if ($payload !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($payload, JSON_THROW_ON_ERROR)); }
    $bytes = curl_exec($ch); $status = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    return [$status, $bytes];
};
try {
    for ($i = 0; $i < 3; $i++) {
        [$status] = $request('selections.php', $song + ['device_id' => $ids[$i], 'kind' => 'cover',
            'choice' => ['image_base64' => base64_encode($images[$i === 2 ? 1 : 0]), 'source' => 'itunes']]);
        communityHttpCheck($status === 200, '测试选择保存失败');
    }
    $query = $song + ['source' => 'community', 'device_id' => $ids[3]];
    [$status] = $request('covers.php?' . http_build_query($query), null, false);
    communityHttpCheck($status === 401, '未鉴权请求必须拒绝');
    [$status, $bytes] = $request('covers.php?' . http_build_query($query));
    $rows = json_decode((string)$bytes, true, 512, JSON_THROW_ON_ERROR)['candidates'];
    communityHttpCheck($status === 200 && count($rows) === 2 && $rows[0]['votes'] === 2 && $rows[0]['id'] === $revisions[0], '公开来源合并和排序错误');
    foreach ($ids as $id) communityHttpCheck(!str_contains($bytes, $id), '不能暴露设备标识');
    [$status, $bytes] = $request('covers.php?' . http_build_query(array_replace($query, ['device_id' => $ids[0]])));
    $ownRows = json_decode((string)$bytes, true)['candidates'];
    communityHttpCheck($status === 200 && array_sum(array_column($ownRows, 'votes')) === 2, '未排除自身选择');
    [$status, $bytes] = $request('covers.php?' . http_build_query($query + ['action' => 'image', 'id' => $revisions[0]]));
    communityHttpCheck($status === 200 && $bytes === $images[0], '原图必须来自已保存的服务器缓存');
    [$status, $bytes] = $request('covers.php?' . http_build_query($query + ['action' => 'image', 'id' => $revisions[0], 'preview' => '1']));
    $size = is_string($bytes) ? @getimagesizefromstring($bytes) : false;
    communityHttpCheck($status === 200 && is_array($size), '预览图片不可显示');
    if (extension_loaded('gd')) communityHttpCheck(max($size[0], $size[1]) === 256, '预览没有缩略');
    [$status, $bytes] = $request('covers.php?' . http_build_query(array_replace($query, ['duration' => 250])));
    communityHttpCheck($status === 200 && json_decode((string)$bytes, true)['candidates'] === [], '不同版本不能混用');
    [$status] = $request('covers.php?' . http_build_query(array_replace($query, ['device_id' => '../bad'])));
    communityHttpCheck($status === 400, '非法设备识别码必须拒绝');
    [$status] = $request('covers.php?' . http_build_query(array_replace($query, ['title' => $title . 'Wrong']) + ['action' => 'image', 'id' => $revisions[0]]));
    communityHttpCheck($status === 400, '不允许跨歌下载图片');
    echo 'Community cover HTTP checks passed; preview ' . $size[0] . 'x' . $size[1] . "\n";
} finally {
    $dir = rtrim($config['cache_dir'], '/\\') . '/song_selections_v1';
    $hash = hash('sha256', strtolower($title) . '|communityhttptest');
    foreach ($ids as $id) foreach ([$dir . '/device-' . $id . '-' . $hash . '.json', $dir . '/device-' . $id . '-' . $hash . '.json.lock'] as $path) if (is_file($path)) unlink($path);
    foreach ([$hash . '.json', 'community-' . $hash . '.json', 'community-' . $hash . '.json.lock', 'community-' . $hash . '.defaults.json'] as $file) if (is_file($dir . '/' . $file)) unlink($dir . '/' . $file);
    $wrongHash = hash('sha256', strtolower($title . 'Wrong') . '|communityhttptest');
    foreach (glob($dir . '/community-' . $wrongHash . '*') ?: [] as $path) if (is_file($path)) unlink($path);
    foreach ($revisions as $revision) foreach (['image-' . $revision . '.img', 'preview-v1-' . $revision . '.jpg'] as $file) if (is_file($dir . '/' . $file)) unlink($dir . '/' . $file);
}
