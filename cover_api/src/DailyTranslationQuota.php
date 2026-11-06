<?php
declare(strict_types=1);

final class TranslationQuotaExceeded extends RuntimeException
{
    public function __construct(string $message, public readonly int $retryAfter)
    { parent::__construct($message); }
}

// Reserve before calling the paid model. Failed upstream calls also use the
// reservation; otherwise repeated failures could bypass the spending limit.
final class DailyTranslationQuota
{
    private Closure $clock;
    private string $directory;
    public function __construct(private array $config, private string $deviceId, private string $ip, ?callable $clock = null)
    {
        $this->directory = rtrim((string)$config['cache_dir'], '/\\') . '/translation_quota';
        if (!is_dir($this->directory) && !mkdir($this->directory, 0775, true) && !is_dir($this->directory)) {
            throw new RuntimeException('无法保存翻译限额');
        }
        $this->clock = $clock === null ? fn() => new DateTimeImmutable('now', new DateTimeZone('Asia/Shanghai')) : Closure::fromCallable($clock);
    }

    public function reserve(string $title, string $artist, array $missingLines): void
    {
        if ($missingLines === []) return;
        $now = ($this->clock)()->setTimezone(new DateTimeZone('Asia/Shanghai'));
        $retryAfter = max(1, $now->modify('tomorrow')->setTime(0, 0)->getTimestamp() - $now->getTimestamp());
        $day = $now->format('Y-m-d');
        $limit = max(1, min(100, (int)($this->config['translation_daily_song_limit'] ?? 5)));
        $normalize = static fn(string $text): string => function_exists('mb_strtolower')
            ? mb_strtolower(LyricTranslationService::normalizeLine($text), 'UTF-8')
            : strtolower(LyricTranslationService::normalizeLine($text));
        $song = hash('sha256', json_encode([$normalize($title), $normalize($artist)], JSON_THROW_ON_ERROR));
        $ipKey = hash('sha256', $this->ip);
        // Older clients still obey the IP limit; no random fallback on each call.
        $deviceKey = $this->deviceId === '' ? 'legacy-' . $ipKey : $this->deviceId;
        $file = $this->directory . '/' . $day . '.json';
        $lock = fopen($this->directory . '/' . $day . '.lock', 'c');
        if (!$lock || !flock($lock, LOCK_EX)) throw new RuntimeException('无法锁定翻译限额');
        try {
            $state = is_file($file) ? json_decode((string)file_get_contents($file), true, 512, JSON_THROW_ON_ERROR) : [];
            if (!is_array($state)) throw new RuntimeException('翻译限额记录损坏');
            foreach (['devices' => $deviceKey, 'ips' => $ipKey] as $scope => $identity) {
                $songs = $state[$scope][$identity] ?? [];
                if (!isset($songs[$song]) && count($songs) >= $limit) {
                    throw new TranslationQuotaExceeded("今天的歌词翻译额度已用完（每个客户端、每个 IP 每天 {$limit} 首），已有缓存仍可使用，请明天再试", $retryAfter);
                }
                $record = $songs[$song] ?? ['lines' => [], 'bytes' => 0];
                foreach ($missingLines as $id => $text) {
                    $attempts = $record['lines'][$id] ?? 0;
                    if ($attempts === 0) $record['bytes'] += strlen($text);
                    $record['lines'][$id] = $attempts + 1;
                    // Prevent unlimited text under one reused song title. Three
                    // attempts per uncached line still permit transient retries.
                    if ($attempts >= 3 || count($record['lines']) > 250 || $record['bytes'] > 75000) {
                        throw new TranslationQuotaExceeded('这首歌曲今天的翻译或重试次数已达上限，已有缓存仍可使用，请明天再试', $retryAfter);
                    }
                }
                $state[$scope][$identity][$song] = $record;
            }
            $temp = $file . '.' . bin2hex(random_bytes(8)) . '.tmp';
            try {
                if (file_put_contents($temp, json_encode($state, JSON_THROW_ON_ERROR), LOCK_EX) === false || !rename($temp, $file)) {
                    throw new RuntimeException('无法写入翻译限额');
                }
            } finally { if (is_file($temp)) unlink($temp); }
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }
}
