<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/../src/ApiRateLimiter.php';
require __DIR__ . '/../src/LyricTranslationService.php';

function rateCheck(bool $ok, string $message): void
{
    if (!$ok) throw new RuntimeException($message);
}

function rateDenied(callable $request, int $wait): void
{
    try {
        $request();
    } catch (ApiRateLimitExceeded $error) {
        rateCheck($error->retryAfter === $wait, 'Incorrect Retry-After');
        return;
    }
    throw new RuntimeException('Request exceeded its limit');
}

$now = (new DateTimeImmutable('2026-11-06 23:58:55', new DateTimeZone('Asia/Shanghai')))->getTimestamp();
if (($argv[1] ?? '') === 'worker') {
    try {
        (new ApiRateLimiter(['cache_dir' => $argv[2], 'api_rate_limits' => ['cover' => [3, 10]]],
            '198.51.100.3', $now))->consume('cover');
        exit(0);
    } catch (ApiRateLimitExceeded) { exit(42); }
}

$root = sys_get_temp_dir() . '/nas-api-rate-' . bin2hex(random_bytes(8));
mkdir($root, 0700);
$config = [
    'cache_dir' => $root,
    'api_rate_limits' => ['selection_write' => [2, 3, 4], 'translation_ai' => [5, 5, 1]],
    'translation_reference_search' => false,
    'openrouter_api_key' => 'unit-test-placeholder',
];
$limiter = fn(string $ip, int $time) => new ApiRateLimiter($config, $ip, $time);
$first = $limiter('198.51.100.1', $now);
$second = $limiter('198.51.100.2', $now);
try {
    $first->consume('selection_write');
    $first->consume('selection_write');
    rateDenied(fn() => $first->consume('selection_write'), 5);
    $second->consume('selection_write');
    $nextMinute = $limiter('198.51.100.1', $now + 5);
    $nextMinute->consume('selection_write');
    rateDenied(fn() => $nextMinute->consume('selection_write'), 60);
    rateDenied(fn() => $second->consume('selection_write'), 65);
    $first->consume('selection_read');
    $limiter('198.51.100.1', $now + 65)->consume('selection_write');

    $upstream = static function ($url, $payload, $headers): array {
        $request = json_decode($payload['messages'][1]['content'], true, 32, JSON_THROW_ON_ERROR);
        $lines = array_map(fn($line) => ['id' => $line['id'], 'translation' => '测试译文'], $request['lines']);
        return ['choices' => [['message' => ['content' => json_encode(['lines' => $lines])]]]];
    };
    $translation = new LyricTranslationService($config, transport: $upstream, limits: $first);
    $translation->translate('Example', '', ['Previously translated']);
    rateDenied(fn() => $translation->translate('Example', '', ['New line']), 65);
    rateCheck($translation->translate('Example', '', ['Previously translated'])['cached'],
        'Cached lines must remain available after the paid quota is spent');

    $processes = [];
    $nullDevice = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
    for ($i = 0; $i < 8; $i++) {
        $processes[] = proc_open([PHP_BINARY, __FILE__, 'worker', $root],
            [1 => ['file', $nullDevice, 'w'], 2 => ['file', $nullDevice, 'w']], $pipes);
    }
    $results = array_count_values(array_map('proc_close', $processes));
    rateCheck(($results[0] ?? 0) === 3 && ($results[42] ?? 0) === 5,
        'Concurrent requests exceeded the minute budget');
    echo "API rate limit regression checks passed\n";
} finally {
    unset($first, $second, $nextMinute, $translation);
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
