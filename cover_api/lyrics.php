<?php
declare(strict_types=1);

require __DIR__ . '/src/LyricTranslationService.php';
require __DIR__ . '/src/DailyTranslationQuota.php';
require_once __DIR__ . '/src/ApiRateLimiter.php';

header('Access-Control-Allow-Origin: *');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');

function lyricJsonError(int $status, string $message): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => false, 'error' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    lyricJsonError(405, '只支持 POST 请求');
}

$configFile = __DIR__ . '/config.php';
if (!is_file($configFile)) lyricJsonError(500, '缺少 config.php');
$config = require $configFile;
if (!is_array($config)) lyricJsonError(500, 'config.php 格式错误');

$ip = (string)($_SERVER['REMOTE_ADDR'] ?? 'unknown');
$limits = new ApiRateLimiter($config, $ip);
enforceApiRateLimit($limits, 'translation');

$rawBody = file_get_contents('php://input', false, null, 0, 256 * 1024 + 1);
if (!is_string($rawBody) || $rawBody === '' || strlen($rawBody) > 256 * 1024) {
    lyricJsonError(400, '请求正文为空或过大');
}
$payload = json_decode($rawBody, true);
if (!is_array($payload)) lyricJsonError(400, '请求正文必须是 JSON');

if (!is_string($payload['title'] ?? null) || !is_string($payload['artist'] ?? '')
    || !is_string($payload['device_id'] ?? '')) lyricJsonError(400, '歌曲或设备信息格式错误');
$title = trim($payload['title']);
$artist = trim($payload['artist'] ?? '');
$deviceId = $payload['device_id'] ?? '';
if ($title === '' || strlen($title) > 300 || strlen($artist) > 300) lyricJsonError(400, '歌曲名为空或过长');
if ($deviceId !== '' && !preg_match('/^[a-f0-9]{64}$/D', $deviceId)) lyricJsonError(400, '设备识别码无效');
$lyrics = $payload['lyrics'] ?? null;
if (!is_array($lyrics) || $lyrics === [] || count($lyrics) > 250) {
    lyricJsonError(400, 'lyrics 必须包含 1 至 250 行');
}
$lines = [];
foreach ($lyrics as $line) {
    if (!is_string($line)) lyricJsonError(400, '歌词行格式错误');
    $line = trim($line);
    if ($line === '' || strlen($line) > 1500) lyricJsonError(400, '歌词行为空或过长');
    $lines[] = $line;
}

try {
    $service = new LyricTranslationService($config, limits: $limits);
    // Only trust the web server's resolved peer address, never caller-supplied headers.
    $quota = new DailyTranslationQuota($config, $deviceId, $ip);
    $result = $service->translate($title, $artist, $lines, fn(array $missing) => $quota->reserve($title, $artist, $missing));
    header('Content-Type: application/json; charset=utf-8');
    header('X-Lyric-Translation-Cache: ' . (!empty($result['cached']) ? 'HIT' : 'MISS'));
    echo json_encode(['success' => true] + $result,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
} catch (ApiRateLimitExceeded $error) {
    sendApiRateLimitError($error);
} catch (TranslationQuotaExceeded $error) {
    header('Retry-After: ' . $error->retryAfter);
    lyricJsonError(429, $error->getMessage());
} catch (Throwable $error) {
    error_log('[lyric-translation-api] ' . $error->getMessage());
    lyricJsonError(502, str_contains($error->getMessage(), 'not available in your region')
        ? 'OpenRouter model not available in your region'
        : '歌词翻译暂不可用，请稍后再试');
}
