<?php
declare(strict_types=1);

// The bare domain is the public installer portal. Cover requests retain the
// existing title query and authentication, so old clients remain compatible.
if (!isset($_GET['title']) && in_array($_SERVER['REQUEST_METHOD'] ?? 'GET', ['GET', 'HEAD'], true)) {
    require __DIR__ . '/download.php';
    exit;
}

require __DIR__ . '/src/CoverService.php';

header('Access-Control-Allow-Origin: *');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: public, max-age=86400, stale-if-error=604800');

function jsonError(int $status, string $message): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => false, 'error' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET' && ($_SERVER['REQUEST_METHOD'] ?? '') !== 'HEAD') {
    header('Allow: GET, HEAD');
    jsonError(405, '只支持 GET/HEAD 请求');
}

$configFile = __DIR__ . '/config.php';
if (!is_file($configFile)) {
    jsonError(500, '缺少 config.php，请复制 config.example.php 后填写配置');
}
$config = require $configFile;
if (!is_array($config)) {
    jsonError(500, 'config.php 格式错误');
}

$requiredToken = trim((string)($config['access_token'] ?? ''));
if ($requiredToken !== '') {
    $authorization = (string)($_SERVER['HTTP_AUTHORIZATION'] ?? '');
    $providedToken = str_starts_with($authorization, 'Bearer ') ? substr($authorization, 7) : (string)($_GET['key'] ?? '');
    if (!hash_equals($requiredToken, $providedToken)) {
        jsonError(401, '访问令牌无效');
    }
}

$title = trim((string)($_GET['title'] ?? ''));
$artist = trim((string)($_GET['artist'] ?? ''));
if ($title === '') jsonError(400, '缺少 title 参数');
if (strlen($title) > 300 || strlen($artist) > 300) jsonError(400, '歌曲名或歌手名过长');
$refresh = filter_var($_GET['refresh'] ?? false, FILTER_VALIDATE_BOOL);
$metadataOnly = (string)($_GET['format'] ?? '') === 'json';

try {
    if (!is_string($_GET['device_id'] ?? '')) throw new InvalidArgumentException('设备识别码无效');
    $deviceId = $_GET['device_id'] ?? '';
    if ($deviceId !== '') header('Cache-Control: private, no-store');
    $service = new CoverService($config);
    $result = $service->resolve($title, $artist, $refresh, (float)($_GET['duration'] ?? 0), $deviceId);
    $etag = '"' . hash('sha256', $result['bytes']) . '"';
    if ((string)($_SERVER['HTTP_IF_NONE_MATCH'] ?? '') === $etag) {
        http_response_code(304);
        exit;
    }
    header('ETag: ' . $etag);
    header('X-Cover-Source: ' . preg_replace('/[^a-z0-9_-]/i', '', (string)$result['source']));
    header('X-Cover-Cache: ' . (!empty($result['cached']) ? 'HIT' : 'MISS'));

    if ($metadataOnly) {
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode([
            'success' => true,
            'title' => $title,
            'artist' => $artist,
            'source' => $result['source'],
            'cached' => (bool)($result['cached'] ?? false),
            'stale' => (bool)($result['stale'] ?? false),
            'mime_type' => $result['mime'],
            'bytes' => strlen($result['bytes']),
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }

    header('Content-Type: ' . $result['mime']);
    header('Content-Length: ' . strlen($result['bytes']));
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'HEAD') {
        echo $result['bytes'];
    }
} catch (InvalidArgumentException $error) {
    jsonError(400, $error->getMessage());
} catch (Throwable $error) {
    error_log('[cover-api] ' . $error->getMessage());
    jsonError(502, $error->getMessage());
}
