<?php
declare(strict_types=1);
require __DIR__ . '/src/SongSelectionService.php';
require_once __DIR__ . '/src/ApiRateLimiter.php';
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
function selectionError(int $status, string $message): never {
    http_response_code($status); header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => false, 'error' => $message], JSON_UNESCAPED_UNICODE); exit;
}
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
if (!in_array($method, ['GET', 'POST'], true)) selectionError(405, '只支持 GET/POST');
$config = require __DIR__ . '/config.php';
enforceApiRateLimit(new ApiRateLimiter($config, (string)($_SERVER['REMOTE_ADDR'] ?? '')),
    $method === 'POST' ? 'selection_write' : 'selection_read');
try {
    $input = $_GET;
    if ($method === 'POST') {
        $body = file_get_contents('php://input', false, null, 0, 12 * 1024 * 1024 + 4097);
        if ($body === false || strlen($body) > 12 * 1024 * 1024 + 4096) selectionError(413, '请求过大');
        $input = json_decode($body, true, 64, JSON_THROW_ON_ERROR);
    }
    if (!is_array($input) || !is_string($input['title'] ?? null) || !is_string($input['artist'] ?? '') || !is_numeric($input['duration'] ?? 0)) selectionError(400, '歌曲参数无效');
    $title = $input['title']; $artist = $input['artist'] ?? ''; $duration = (float)($input['duration'] ?? 0);
    if (!is_string($input['device_id'] ?? '')) selectionError(400, '设备识别码无效');
    $service = new SongSelectionService($config, $input['device_id'] ?? '');
    if ($method === 'POST') {
        if (($input['device_id'] ?? '') === '') throw new InvalidArgumentException('保存选择时需要设备识别码');
        if (!is_array($input['choice'] ?? null) || !is_string($input['kind'] ?? null)) selectionError(400, '选择参数无效');
        $result = $service->save($title, $artist, $duration, $input['kind'], $input['choice']);
    } elseif (($input['action'] ?? '') === 'image') {
        $result = $service->image($title, $artist, $duration, (string)($input['revision'] ?? ''));
        header('Content-Type: ' . $result['mime']); header('Cache-Control: private, max-age=86400');
        echo $result['bytes']; exit;
    } else {
        $result = ['selection' => $service->get($title, $artist, $duration)];
    }
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => true, 'schema_version' => 1] + $result, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
} catch (InvalidArgumentException | JsonException $error) { selectionError(400, $error->getMessage()); }
catch (Throwable $error) { error_log('[song-selection] ' . $error->getMessage()); selectionError(500, '歌曲选择服务暂不可用'); }
