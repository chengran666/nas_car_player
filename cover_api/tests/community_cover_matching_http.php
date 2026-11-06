<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/../src/SongSelectionService.php';
function matchingHttpCheck(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_cover_http_' . bin2hex(random_bytes(5));
mkdir($root); $root = realpath($root);
matchingHttpCheck(is_string($root) && str_starts_with($root, realpath(sys_get_temp_dir()) . DIRECTORY_SEPARATOR), '测试目录必须在临时目录中');
$process = null;
try {
    mkdir($root . '/src'); mkdir($root . '/data');
    foreach (['covers.php', 'src/SongSelectionService.php', 'src/CoverCandidateService.php', 'data/TSCharacters.txt'] as $file) copy(__DIR__ . '/../' . $file, $root . '/' . $file);
    $config = ['cache_dir' => $root . '/cache', 'access_token' => 'local-test-token'];
    file_put_contents($root . '/config.php', '<?php return ' . var_export($config, true) . ';');
    $chunk = static fn($type, $data) => pack('N', strlen($data)) . $type . $data . pack('N', crc32($type . $data));
    $png = "\x89PNG\r\n\x1a\n" . $chunk('IHDR', pack('NNCCCCC', 32, 32, 8, 2, 0, 0, 0)) .
        $chunk('IDAT', gzcompress(str_repeat("\x00" . str_repeat("\x20\x40\x60", 32), 32))) . $chunk('IEND', '');
    $lyrics = "[00:01]Dreaming of the summer night\n[00:02]Walking by the ocean blue\n[00:03]Remember all the words you said\n[00:04]Waiting for the morning light";
    $writer = new SongSelectionService($config, str_repeat('a', 64));
    $writer->save('Summer Night', 'Singer', 200, 'lyrics', ['text' => $lyrics]);
    $revision = $writer->save('Summer Night', 'Singer', 200, 'cover', ['image_base64' => base64_encode($png)])['revision'];
    $socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
    matchingHttpCheck($socket !== false, '无法分配测试端口');
    $address = stream_socket_get_name($socket, false); fclose($socket);
    $process = proc_open([PHP_BINARY, '-S', $address, '-t', $root], [0 => ['pipe', 'r'], 1 => ['file', $root . '/http.log', 'a'], 2 => ['file', $root . '/http.log', 'a']], $pipes);
    matchingHttpCheck(is_resource($process), '无法启动本地测试服务'); fclose($pipes[0]);
    for ($attempt = 0; $attempt < 100; $attempt++) {
        $probe = @stream_socket_client('tcp://' . $address, $errno, $error, 0.1);
        if ($probe !== false) { fclose($probe); break; }
        usleep(20000);
    }
    $request = static function (string $method, array $input, ?string $body = null, bool $authorized = true) use ($address): array {
        $url = 'http://' . $address . '/covers.php' . ($method === 'GET' ? '?' . http_build_query($input) : '');
        $headers = ['Content-Type: application/json'];
        if ($authorized) $headers[] = 'Authorization: Bearer local-test-token';
        $context = stream_context_create(['http' => ['method' => $method, 'header' => implode("\r\n", $headers), 'content' => $method === 'POST' ? ($body ?? json_encode($input)) : '', 'ignore_errors' => true, 'timeout' => 5]]);
        $bytes = file_get_contents($url, false, $context);
        preg_match('/\s(\d{3})\s/', $http_response_header[0] ?? '', $match);
        return [(int)($match[1] ?? 0), $bytes];
    };
    $query = ['source' => 'community', 'title' => 'Summer Nigh', 'artist' => 'Singer', 'duration' => 200, 'device_id' => str_repeat('f', 64), 'lyrics' => $lyrics];
    [$status, $body] = $request('POST', $query);
    $rows = json_decode((string)$body, true, 512, JSON_THROW_ON_ERROR)['candidates'];
    matchingHttpCheck($status === 200 && count($rows) === 1 && $rows[0]['match_type'] === 'exact_lyrics', 'POST 按歌词查找关联封面');
    $row = $rows[0];
    [$status, $bytes] = $request('GET', ['source' => 'community', 'action' => 'image', 'id' => $row['id'], 'title' => $row['lookup_title'], 'artist' => $row['lookup_artist'], 'duration' => $row['lookup_duration']]);
    matchingHttpCheck($status === 200 && $bytes === $png, '返回参数可以下载原图');
    [$status, $body] = $request('GET', $query);
    matchingHttpCheck($status === 200 && json_decode((string)$body, true)['candidates'] === [], '旧 GET 客户端只返回精确歌曲，避免图片参数不兼容');
    $query['title'] = 'Summer Night'; unset($query['lyrics']);
    [$status, $body] = $request('GET', $query);
    matchingHttpCheck($status === 200 && json_decode((string)$body, true)['candidates'][0]['id'] === $revision, '旧 GET 精确候选仍可使用');
    matchingHttpCheck($request('POST', $query, null, false)[0] === 401, 'POST 仍要求鉴权');
    matchingHttpCheck($request('POST', $query, '{invalid-json')[0] === 400, '无效 JSON 返回 400');
    matchingHttpCheck($request('POST', $query + ['lyrics' => ['bad']])[0] === 400, '拒绝非字符串歌词');
    matchingHttpCheck($request('POST', $query + ['lyrics' => str_repeat('a', 262145)])[0] === 400, '拒绝超长歌词');
    matchingHttpCheck($request('POST', array_replace($query, ['source' => 'itunes']))[0] === 405, 'POST 不会触发其他来源请求');
    echo "Community cover matching HTTP checks passed\n";
} finally {
    if (is_resource($process)) { proc_terminate($process); proc_close($process); }
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
