<?php
declare(strict_types=1);
require_once __DIR__ . '/CoverCandidateService.php';
require_once __DIR__ . '/SongSelectionService.php';

final class CoverService
{
    public function __construct(private array $config)
    {
        $cacheDir = (string)($this->config['cache_dir'] ?? '');
        if ($cacheDir === '') {
            throw new RuntimeException('cache_dir 未配置');
        }
        if (!is_dir($cacheDir) && !mkdir($cacheDir, 0775, true) && !is_dir($cacheDir)) {
            throw new RuntimeException('无法创建缓存目录');
        }
    }

    public function resolve(string $title, string $artist, bool $refresh = false, float $duration = 0, string $deviceId = ''): array
    {
        $choices = new SongSelectionService($this->config, $deviceId);
        $selected = $choices->get($title, $artist, $duration);
        if (isset($selected['cover']['revision'])) {
            return $choices->image($title, $artist, $duration, $selected['cover']['revision']) +
                ['source' => 'manual_selection', 'cached' => true, 'stale' => false];
        }
        $key = hash('sha256', $this->normalize($title) . '|' . $this->normalize($artist) . '|v3');
        if (!$refresh && ($cached = $this->readCache($key, false)) !== null) {
            $cached['cached'] = true;
            return $cached;
        }

        $lockPath = $this->cachePath($key, '.lock');
        $lock = fopen($lockPath, 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) {
            throw new RuntimeException('无法锁定封面缓存');
        }

        try {
            if (!$refresh && ($cached = $this->readCache($key, false)) !== null) {
                $cached['cached'] = true;
                return $cached;
            }

            $result = $this->fromITunes($title, $artist)
                ?? $this->fromLastFm($title, $artist)
                ?? $this->fromDeezer($title, $artist)
                ?? $this->fromMusicBrainz($title, $artist)
                ?? $this->fromOpenRouterSearch($title, $artist);

            if ($result === null) {
                // 上游临时故障时继续提供已经过期的缓存。
                $stale = $this->readCache($key, true);
                if ($stale !== null) {
                    $stale['cached'] = true;
                    $stale['stale'] = true;
                    return $stale;
                }
                throw new RuntimeException('所有封面源都没有返回可用图片');
            }

            $this->writeCache($key, $title, $artist, $result);
            return $result + ['cached' => false, 'stale' => false];
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    private function fromDeezer(string $title, string $artist): ?array
    {
        $terms = [];
        foreach ($this->artistVariants($artist) as $name) {
            $terms[] = trim($title . ' ' . $name);
        }
        $terms[] = $title;
        foreach (array_values(array_unique($terms)) as $term) {
            $json = $this->getJson('https://api.deezer.com/search?' . http_build_query([
                'q' => $term,
                'limit' => 10,
            ]));
            foreach (($json['data'] ?? []) as $item) {
                if (!is_array($item)) continue;
                $resultTitle = (string)($item['title'] ?? '');
                $resultArtist = (string)($item['artist']['name'] ?? '');
                if (!$this->sameText($title, $resultTitle)
                    || ($artist !== '' && !$this->sameArtist($artist, $resultArtist))) {
                    continue;
                }
                $album = is_array($item['album'] ?? null) ? $item['album'] : [];
                foreach (['cover_xl', 'cover_big', 'cover_medium'] as $field) {
                    $url = trim((string)($album[$field] ?? ''));
                    if (($image = $this->downloadImage($url)) !== null) {
                        return $image + ['source' => 'deezer', 'upstream_url' => $url];
                    }
                }
            }
        }
        return null;
    }

     private function fromITunes(string $title, string $artist): ?array
    {
        require_once __DIR__ . '/CoverCandidateService.php';
        try {
            $service = new CoverCandidateService($this->config);
            $result = $service->search($title, $artist, 'itunes');
            $attempts = 0;
            foreach ($result['candidates'] as $row) {
                // 自动封面只接受歌名、歌手都匹配的候选，宽松结果只供用户手选。
                if (!$row['title_match'] || !$row['artist_match']) continue;
                if (++$attempts > 3) break;
                try {
                    $image = $service->image($title, $artist, 'itunes', $row['id'], false);
                    return $image + ['source' => 'itunes', 'track' => $row['title'],
                        'artist' => $row['artist'], 'album' => $row['album'], 'score' => $row['score']];
                } catch (Throwable) { continue; }
            }
        } catch (Throwable) { return null; }
        return null;
    }

    private function fromLastFm(string $title, string $artist): ?array
    {
        $apiKey = trim((string)($this->config['lastfm_api_key'] ?? ''));
        if ($apiKey === '' || $artist === '') {
            return null;
        }
        foreach ($this->artistVariants($artist) as $queryArtist) {
            $json = $this->getJson('https://ws.audioscrobbler.com/2.0/?' . http_build_query([
                'method' => 'track.getInfo',
                'api_key' => $apiKey,
                'artist' => $queryArtist,
                'track' => $title,
                'autocorrect' => 1,
                'format' => 'json',
            ]));
            $track = $json['track'] ?? null;
            if (!is_array($track)) {
                continue;
            }
            $resultArtist = is_array($track['artist'] ?? null)
                ? (string)($track['artist']['name'] ?? '')
                : (string)($track['artist'] ?? '');
            if (!$this->sameText($title, (string)($track['name'] ?? ''))
                || !$this->sameArtist($queryArtist, $resultArtist)) {
                continue;
            }
            $images = is_array($track['album'] ?? null) ? ($track['album']['image'] ?? []) : [];
            foreach (array_reverse(is_array($images) ? $images : []) as $imageInfo) {
                $url = is_array($imageInfo) ? trim((string)($imageInfo['#text'] ?? '')) : '';
                if (($image = $this->downloadImage($url)) !== null) {
                    return $image + ['source' => 'lastfm', 'upstream_url' => $url];
                }
            }
        }
        return null;
    }

    private function fromMusicBrainz(string $title, string $artist): ?array
    {
        $artists = $this->splitArtists($artist);
        $artistQuery = '';
        if (count($artists) === 1) {
            $artistQuery = ' AND artist:"' . $this->luceneEscape($artists[0]) . '"';
        } elseif (count($artists) > 1) {
            $parts = array_map(fn(string $name): string => 'artist:"' . $this->luceneEscape($name) . '"', $artists);
            $artistQuery = ' AND (' . implode(' OR ', $parts) . ')';
        }
        $query = 'recording:"' . $this->luceneEscape($title) . '"' . $artistQuery;
        $json = $this->getJson('https://musicbrainz.org/ws/2/recording/?' . http_build_query([
            'query' => $query,
            'fmt' => 'json',
            'limit' => 8,
        ]), ['User-Agent: NasPlayerCoverAPI/1.0']);

        $urls = [];
        foreach (($json['recordings'] ?? []) as $recording) {
            if (!is_array($recording) || (int)($recording['score'] ?? 0) < 80
                || !$this->sameText($title, (string)($recording['title'] ?? ''))) {
                continue;
            }
            $creditNames = [];
            foreach (($recording['artist-credit'] ?? []) as $credit) {
                if (is_array($credit)) {
                    $creditNames[] = (string)($credit['name'] ?? ($credit['artist']['name'] ?? ''));
                }
            }
            if ($artist !== '' && !$this->sameArtist($artist, implode('、', $creditNames))) {
                continue;
            }
            foreach (($recording['releases'] ?? []) as $release) {
                if (!is_array($release)) {
                    continue;
                }
                $groupId = (string)($release['release-group']['id'] ?? '');
                $releaseId = (string)($release['id'] ?? '');
                if ($groupId !== '') {
                    $urls[] = 'https://coverartarchive.org/release-group/' . rawurlencode($groupId) . '/front-500';
                }
                if ($releaseId !== '') {
                    $urls[] = 'https://coverartarchive.org/release/' . rawurlencode($releaseId) . '/front-500';
                }
            }
        }
        foreach (array_slice(array_values(array_unique($urls)), 0, 8) as $url) {
            if (($image = $this->downloadImage($url)) !== null) {
                return $image + ['source' => 'musicbrainz', 'upstream_url' => $url];
            }
        }
        return null;
    }

    private function fromOpenRouterSearch(string $title, string $artist): ?array
    {
        $apiKey = trim((string)($this->config['openrouter_api_key'] ?? ''));
        if ($apiKey === '') {
            return null;
        }
        $headers = [
            'Authorization: Bearer ' . $apiKey,
            'Content-Type: application/json',
        ];
        $appUrl = trim((string)($this->config['app_url'] ?? ''));
        if ($appUrl !== '') {
            $headers[] = 'HTTP-Referer: ' . $appUrl;
        }
        $model = (string)($this->config['openrouter_search_model'] ?? '~deepseek/deepseek-flash-latest');
        if ($model === 'deepseek/deepseek-flash-latest') {
            $model = '~deepseek/deepseek-flash-latest';
        }
        $response = $this->postJson((string)($this->config['openrouter_chat_url'] ?? 'https://openrouter.ai/api/v1/chat/completions'), [
            'model' => $model,
            'messages' => [
                [
                    'role' => 'system',
                    'content' => 'You locate original music release artwork. Search the web and inspect reliable music catalog pages. Return JSON only: {"candidates":[{"image_url":"direct https image URL","page_url":"source page","title":"matched song","artist":"matched artist","album":"matched release"}]}. Include only actual album or single artwork for the exact recording. Never return artist portraits, fan art, generated art, logos, placeholders, thumbnails from unrelated pages, or guessed URLs.',
                ],
                [
                    'role' => 'user',
                    'content' => "Find the original release cover for this recording.\nSong: {$title}\nArtist credit: {$artist}\nSearch combination and individual artist names. Prefer official stores and established music databases. Return up to 6 direct image candidates.",
                ],
            ],
            'tools' => [
                [
                    'type' => 'openrouter:web_search',
                    'parameters' => [
                        'engine' => 'exa',
                        'max_results' => 6,
                        'max_total_results' => 12,
                        'include_domains' => [
                            'music.apple.com',
                            '*.deezer.com',
                            '*.last.fm',
                            '*.musicbrainz.org',
                            'coverartarchive.org',
                            '*.discogs.com',
                        ],
                    ],
                ],
                ['type' => 'openrouter:web_fetch'],
            ],
            'max_tool_calls' => 6,
            'temperature' => 0.1,
            'max_tokens' => 900,
        ], $headers);
        $content = trim((string)($response['choices'][0]['message']['content'] ?? ''));
        $payload = $this->decodeJsonFromText($content);
        $candidates = is_array($payload['candidates'] ?? null) ? $payload['candidates'] : [];
        foreach ($candidates as $candidate) {
            if (!is_array($candidate)) continue;
            $candidateTitle = trim((string)($candidate['title'] ?? ''));
            $candidateArtist = trim((string)($candidate['artist'] ?? ''));
            if ($candidateTitle !== '' && !$this->sameText($title, $candidateTitle)) continue;
            if ($candidateArtist !== '' && $artist !== '' && !$this->sameArtist($artist, $candidateArtist)) continue;
            $url = trim((string)($candidate['image_url'] ?? ''));
            if (!$this->isTrustedSearchImageUrl($url)) continue;
            if (($image = $this->downloadImage($url)) !== null) {
                return $image + ['source' => 'openrouter-search', 'upstream_url' => $url];
            }
        }
        return null;
    }

    private function decodeJsonFromText(string $content): array
    {
        $content = preg_replace('/^```(?:json)?\s*|\s*```$/i', '', trim($content)) ?? $content;
        $decoded = json_decode($content, true);
        if (is_array($decoded)) return $decoded;
        if (preg_match('/\{.*\}/s', $content, $match) === 1) {
            $decoded = json_decode($match[0], true);
            if (is_array($decoded)) return $decoded;
        }
        return [];
    }

    private function isTrustedSearchImageUrl(string $url): bool
    {
        $host = strtolower((string)parse_url($url, PHP_URL_HOST));
        if (!str_starts_with($url, 'https://') || $host === '') return false;
        $allowed = [
            'mzstatic.com',
            'dzcdn.net',
            'lastfm.freetls.fastly.net',
            'coverartarchive.org',
            'i.discogs.com',
            'i.scdn.co',
        ];
        foreach ($allowed as $domain) {
            if ($host === $domain || str_ends_with($host, '.' . $domain)) return true;
        }
        return false;
    }

    private function getJson(string $url, array $headers = []): array
    {
        try {
            $result = $this->request('GET', $url, null, $headers);
        } catch (Throwable) {
            return [];
        }
        if ($result['status'] < 200 || $result['status'] >= 300) return [];
        $decoded = json_decode($result['body'], true);
        return is_array($decoded) ? $decoded : [];
    }

    private function postJson(string $url, array $payload, array $headers): array
    {
        try {
            $body = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
            $result = $this->request('POST', $url, $body, $headers, true);
        } catch (Throwable) {
            return [];
        }
        if ($result['status'] < 200 || $result['status'] >= 300) return [];
        $decoded = json_decode($result['body'], true);
        return is_array($decoded) ? $decoded : [];
    }

    private function downloadImage(string $url): ?array
    {
        if (!str_starts_with($url, 'https://')) {
            return null;
        }
        try {
            $result = $this->request('GET', $url);
        } catch (Throwable) {
            return null;
        }
        if ($result['status'] < 200 || $result['status'] >= 300) {
            return null;
        }
        $bytes = $result['body'];
        $maxBytes = (int)($this->config['max_image_bytes'] ?? 12582912);
        if ($bytes === '' || strlen($bytes) > $maxBytes) {
            return null;
        }
        $mime = $this->detectImageMime($bytes);
        return $mime === null ? null : ['bytes' => $bytes, 'mime' => $mime];
    }

    private function request(string $method, string $url, ?string $body = null, array $headers = [], bool $useOpenRouterProxy = false): array
    {
        if (!function_exists('curl_init')) {
            throw new RuntimeException('服务器未启用 PHP cURL 扩展');
        }
        $ch = curl_init($url);
        $timeout = max(3, (int)($this->config['request_timeout_seconds'] ?? 15));
        $headers[] = 'Accept: application/json,image/*;q=0.9,*/*;q=0.1';
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS => 4,
            CURLOPT_CONNECTTIMEOUT => min(8, $timeout),
            CURLOPT_TIMEOUT => $timeout,
            CURLOPT_USERAGENT => 'NasPlayerCoverAPI/1.0',
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_ENCODING => '',
            CURLOPT_SSL_VERIFYPEER => (bool)($this->config['verify_tls'] ?? true),
            CURLOPT_SSL_VERIFYHOST => (bool)($this->config['verify_tls'] ?? true) ? 2 : 0,
        ]);
        $proxy = $useOpenRouterProxy
            ? trim((string)($this->config['openrouter_proxy'] ?? ''))
            : CoverCandidateService::proxyForUrl($this->config, $url);
        if ($proxy !== '') {
            curl_setopt($ch, CURLOPT_PROXY, $proxy);
            curl_setopt($ch, CURLOPT_NOPROXY, '');
        }
        if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTPS')) {
            curl_setopt($ch, CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
            curl_setopt($ch, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS);
        }
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }
        $response = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $error = curl_error($ch);
        curl_close($ch);
        if (!is_string($response)) {
            throw new RuntimeException('上游请求失败: ' . $error);
        }
        return ['status' => $status, 'body' => $response];
    }

    private function detectImageMime(string $bytes): ?string
    {
        if (str_starts_with($bytes, "\xFF\xD8\xFF")) return 'image/jpeg';
        if (str_starts_with($bytes, "\x89PNG\r\n\x1A\n")) return 'image/png';
        if (strlen($bytes) >= 12 && substr($bytes, 0, 4) === 'RIFF' && substr($bytes, 8, 4) === 'WEBP') return 'image/webp';
        if (str_starts_with($bytes, 'GIF87a') || str_starts_with($bytes, 'GIF89a')) return 'image/gif';
        return null;
    }

    private function readCache(string $key, bool $allowStale): ?array
    {
        $imagePath = $this->cachePath($key, '.img');
        $metaPath = $this->cachePath($key, '.json');
        if (!is_file($imagePath) || !is_file($metaPath)) return null;
        $meta = json_decode((string)file_get_contents($metaPath), true);
        if (!is_array($meta)) return null;
        $ttl = max(1, (int)($this->config['cache_ttl_days'] ?? 365)) * 86400;
        if (!$allowStale && (int)($meta['created_at'] ?? 0) + $ttl < time()) return null;
        $bytes = file_get_contents($imagePath);
        if (!is_string($bytes) || $this->detectImageMime($bytes) === null) return null;
        return [
            'bytes' => $bytes,
            'mime' => (string)($meta['mime'] ?? $this->detectImageMime($bytes)),
            'source' => (string)($meta['source'] ?? 'cache'),
            'upstream_url' => (string)($meta['upstream_url'] ?? ''),
            'stale' => false,
        ];
    }

    private function writeCache(string $key, string $title, string $artist, array $result): void
    {
        $imagePath = $this->cachePath($key, '.img');
        $metaPath = $this->cachePath($key, '.json');
        $tempImage = $imagePath . '.' . bin2hex(random_bytes(4)) . '.tmp';
        $tempMeta = $metaPath . '.' . bin2hex(random_bytes(4)) . '.tmp';
        if (file_put_contents($tempImage, $result['bytes'], LOCK_EX) === false) {
            throw new RuntimeException('封面缓存写入失败');
        }
        $meta = [
            'title' => $title,
            'artist' => $artist,
            'mime' => $result['mime'],
            'source' => $result['source'],
            'upstream_url' => $result['upstream_url'] ?? '',
            'created_at' => time(),
        ];
        file_put_contents($tempMeta, json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), LOCK_EX);
        rename($tempImage, $imagePath);
        rename($tempMeta, $metaPath);
    }

    private function cachePath(string $key, string $suffix): string
    {
        return rtrim((string)$this->config['cache_dir'], '/\\') . DIRECTORY_SEPARATOR . $key . $suffix;
    }

    private function artistVariants(string $artist): array
    {
        $values = [];
        if (trim($artist) !== '') $values[] = trim($artist);
        foreach ($this->splitArtists($artist) as $part) {
            if (!in_array($part, $values, true)) $values[] = $part;
        }
        return $values;
    }

    private function splitArtists(string $artist): array
    {
        $parts = preg_split('/\s*(?:、|&|＆|\/|,|，|;|；|\+|＋|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)\s*/iu', trim($artist)) ?: [];
        return array_values(array_unique(array_filter(array_map('trim', $parts), fn(string $v): bool => $v !== '')));
    }

    private function sameArtist(string $expected, string $actual): bool
    {
        if ($this->sameText($expected, $actual)) return true;
        foreach ($this->splitArtists($expected) as $left) {
            foreach ($this->splitArtists($actual) as $right) {
                if ($this->sameText($left, $right)) return true;
            }
        }
        return false;
    }

    private function sameText(string $expected, string $actual): bool
    {
        $a = $this->normalize($expected);
        $b = $this->normalize($actual);
        if ($a === '' || $b === '') return false;
        if (str_contains($a, $b) || str_contains($b, $a)) return true;
        $left = preg_split('//u', $a, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        $right = preg_split('//u', $b, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        if (count($left) !== count($right)) return false;
        $differences = 0;
        foreach ($left as $index => $character) {
            if ($character !== $right[$index]) $differences++;
        }
        return $differences <= (count($left) >= 8 ? 2 : 1);
    }

    private function normalize(string $value): string
    {
        $value = function_exists('mb_strtolower') ? mb_strtolower($value, 'UTF-8') : strtolower($value);
        return preg_replace('/[\s\-_.,，。·、\/&＆+＋\\()\[\]【】（）]+/u', '', $value) ?? '';
    }

    private function luceneEscape(string $value): string
    {
        return str_replace(['\\', '"'], ['\\\\', '\\"'], trim($value));
    }
}
