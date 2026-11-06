<?php
declare(strict_types=1);

final class ApiRateLimitExceeded extends RuntimeException
{
    public function __construct(public readonly int $retryAfter)
    {
        parent::__construct('请求次数已达上限，请稍后再试');
    }
}

final class ApiRateLimiter
{
    // Each policy is [requests per IP per minute, per IP per day, site-wide per day].
    private const LIMITS = [
        'cover' => [40, 800, 0],
        'cover_candidates' => [120, 1200, 0],
        'selection_read' => [60, 1200, 0],
        'selection_write' => [8, 60, 600],
        'translation' => [30, 240, 0],
        'cover_ai' => [3, 12, 100],
        'translation_ai' => [15, 100, 200],
    ];

    private ?SQLite3 $db = null;
    private string $client;

    public function __construct(private array $config, string $ip, private ?int $now = null)
    {
        // Only the web server's peer address is trusted, never request headers.
        $address = filter_var($ip, FILTER_VALIDATE_IP) ? inet_pton($ip) : 'unknown';
        $this->client = hash('sha256', $address);
    }

    public function consume(string $route): void
    {
        $defaults = self::LIMITS[$route];
        $configured = $this->config['api_rate_limits'][$route] ?? [];
        $minuteLimit = max(1, (int)($configured[0] ?? $defaults[0]));
        $dailyLimit = max(1, (int)($configured[1] ?? $defaults[1]));
        $siteLimit = max(0, (int)($configured[2] ?? $defaults[2]));
        $now = $this->now ?? time();
        $minute = intdiv($now, 60);
        $day = intdiv($now + 28800, 86400); // Asia/Shanghai (UTC+8).
        $minuteWait = 60 - $now % 60;
        $dayWait = 86400 - ($now + 28800) % 86400;

        $db = $this->database();
        $db->exec('BEGIN IMMEDIATE');
        try {
            $this->increment($db, $route . ':' . $this->client, $minute, $day,
                $minuteLimit, $dailyLimit, $minuteWait, $dayWait);
            if ($siteLimit > 0) {
                $this->increment($db, $route . ':site', $minute, $day,
                    $siteLimit, $siteLimit, $dayWait, $dayWait);
            }
            $db->exec('DELETE FROM requests WHERE day < ' . ($day - 1));
            $db->exec('COMMIT');
        } catch (Throwable $error) {
            $db->exec('ROLLBACK');
            throw $error;
        }
    }

    private function database(): SQLite3
    {
        if ($this->db !== null) return $this->db;
        $root = rtrim((string)($this->config['cache_dir'] ?? ''), '/\\');
        if ($root === '') throw new RuntimeException('cache_dir 未配置');
        $dir = $root . '/api_rate_limits';
        if (!is_dir($dir) && !@mkdir($dir, 0775, true) && !is_dir($dir)) {
            throw new RuntimeException('无法创建接口限流目录');
        }
        $db = new SQLite3($dir . '/requests.sqlite3');
        $db->enableExceptions(true);
        $db->busyTimeout(3000);
        $db->exec('CREATE TABLE IF NOT EXISTS requests (
            bucket TEXT PRIMARY KEY, minute INTEGER NOT NULL, minute_count INTEGER NOT NULL,
            day INTEGER NOT NULL, day_count INTEGER NOT NULL
        )');
        $db->exec('CREATE INDEX IF NOT EXISTS requests_day ON requests(day)');
        return $this->db = $db;
    }

    private function increment(SQLite3 $db, string $bucket, int $minute, int $day,
        int $minuteLimit, int $dailyLimit, int $minuteWait, int $dayWait): void
    {
        $read = $db->prepare('SELECT minute, minute_count, day, day_count FROM requests WHERE bucket = :bucket');
        $read->bindValue(':bucket', $bucket, SQLITE3_TEXT);
        $result = $read->execute();
        $row = $result->fetchArray(SQLITE3_ASSOC);
        $result->finalize();
        $read->close();
        $minuteCount = ($row['minute'] ?? null) === $minute ? (int)$row['minute_count'] : 0;
        $dayCount = ($row['day'] ?? null) === $day ? (int)$row['day_count'] : 0;
        if ($dayCount >= $dailyLimit) throw new ApiRateLimitExceeded($dayWait);
        if ($minuteCount >= $minuteLimit) throw new ApiRateLimitExceeded($minuteWait);

        $write = $db->prepare('INSERT OR REPLACE INTO requests VALUES (:bucket, :minute, :minute_count, :day, :day_count)');
        $write->bindValue(':bucket', $bucket, SQLITE3_TEXT);
        $write->bindValue(':minute', $minute, SQLITE3_INTEGER);
        $write->bindValue(':minute_count', $minuteCount + 1, SQLITE3_INTEGER);
        $write->bindValue(':day', $day, SQLITE3_INTEGER);
        $write->bindValue(':day_count', $dayCount + 1, SQLITE3_INTEGER);
        $write->execute()->finalize();
        $write->close();
    }
}

function sendApiRateLimitError(ApiRateLimitExceeded $error): never
{
    header('Retry-After: ' . $error->retryAfter);
    sendApiLimitResponse(429, $error->getMessage());
}

function sendApiLimitResponse(int $status, string $message): never
{
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    http_response_code($status);
    echo json_encode(['success' => false, 'error' => $message], JSON_UNESCAPED_UNICODE);
    exit;
}

function enforceApiRateLimit(ApiRateLimiter $limiter, string $route): void
{
    try {
        $limiter->consume($route);
    } catch (ApiRateLimitExceeded $error) {
        sendApiRateLimitError($error);
    } catch (Throwable $error) {
        error_log('[api-rate-limit] ' . $error->getMessage());
        sendApiLimitResponse(503, '服务暂不可用，请稍后再试');
    }
}
