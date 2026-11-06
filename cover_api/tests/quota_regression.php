<?php
declare(strict_types=1);
require __DIR__ . '/../src/LyricTranslationService.php';
require __DIR__ . '/../src/DailyTranslationQuota.php';
function ensureQuota(bool $condition, string $message): void { if (!$condition) throw new RuntimeException($message); }
$clock = fn() => new DateTimeImmutable('2026-10-11 23:59:50', new DateTimeZone('Asia/Shanghai'));
if (($argv[1] ?? '') === 'worker') {
    try {
        (new DailyTranslationQuota(['cache_dir' => $argv[2]], str_repeat('c', 64), '198.51.100.3', $clock))
            ->reserve($argv[3], '', [hash('sha256', $argv[3]) => $argv[3]]);
        exit(0);
    } catch (TranslationQuotaExceeded) { exit(42); }
}
$root = sys_get_temp_dir() . '/nas-quota-test-' . bin2hex(random_bytes(6));
mkdir($root, 0700);
$config = ['cache_dir' => $root];
$device = str_repeat('a', 64);
$quota = new DailyTranslationQuota($config, $device, '198.51.100.1', $clock);
$line = fn(string $text): array => [LyricTranslationService::lineId($text) => $text];
function denied(callable $request): void {
    try { $request(); } catch (TranslationQuotaExceeded $error) {
        ensureQuota($error->retryAfter === 10, 'Reset must be Shanghai midnight'); return;
    }
    throw new RuntimeException('Quota did not reject the request');
}
try {
    for ($i = 0; $i < 5; $i++) $quota->reserve("Song $i", 'Artist', $line("Line $i"));
    $quota->reserve('  SONG   0 ', 'artist', $line('Another verse'));
    denied(fn() => $quota->reserve('Song 6', 'Artist', $line('New song')));
    denied(fn() => (new DailyTranslationQuota($config, $device, '198.51.100.99', $clock))->reserve('Song 6', '', $line('Device limit')));
    denied(fn() => (new DailyTranslationQuota($config, str_repeat('b', 64), '198.51.100.1', $clock))->reserve('Song 6', '', $line('IP limit')));
    $tomorrow = fn() => new DateTimeImmutable('2026-10-12 00:00:01', new DateTimeZone('Asia/Shanghai'));
    (new DailyTranslationQuota($config, $device, '198.51.100.1', $tomorrow))->reserve('Song 6', '', $line('New day'));
    for ($i = 0; $i < 3; $i++) $quota->reserve('Song 0', 'Artist', $line('Retry line'));
    denied(fn() => $quota->reserve('Song 0', 'Artist', $line('Retry line')));
    $calls = 0;
    $service = new LyricTranslationService($config, function ($model, $title, $artist, $rows) use (&$calls) {
        $calls++;
        return ['lines' => array_map(fn($row) => ['id' => $row['id'], 'translation' => '中文译文'], $rows)];
    });
    $service->translate('Fixture', '', ['Previously translated']);
    $hit = $service->translate('Song 6', 'Artist', ['Previously translated'], fn($missing) => $quota->reserve('Song 6', 'Artist', $missing));
    ensureQuota($hit['cached'] && $calls === 1, 'Cache hit must bypass quota and model');
    denied(fn() => $service->translate('Song 6', 'Artist', ['Never translated'], fn($missing) => $quota->reserve('Song 6', 'Artist', $missing)));
    ensureQuota($calls === 1, 'Blocked request called the paid model');
    // Actual concurrent processes sharing one file may admit exactly five songs.
    $processes = [];
    $nullDevice = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
    for ($i = 0; $i < 10; $i++) {
        $pipes = [];
        $processes[] = proc_open([PHP_BINARY, __FILE__, 'worker', $root, "Parallel $i"], [1 => ['file', $nullDevice, 'w'], 2 => ['file', $nullDevice, 'w']], $pipes);
    }
    $accepted = 0; $rejected = 0;
    foreach ($processes as $process) { $status = proc_close($process); if ($status === 0) $accepted++; elseif ($status === 42) $rejected++; }
    ensureQuota($accepted === 5 && $rejected === 5, 'Concurrent requests bypassed the daily limit');
    echo "Quota regression tests passed\n";
} finally {
    $files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($files as $item) { if ($item->isDir()) rmdir($item->getPathname()); else unlink($item->getPathname()); }
    rmdir($root);
}
