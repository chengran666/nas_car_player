<?php
declare(strict_types=1);

final class CoverCandidateService
{
    private string $dir;
    private ?Closure $fetcher;
    public function __construct(private array $config, ?callable $fetcher = null)
    {
        $this->dir = rtrim((string)($config['cache_dir'] ?? ''), '/\\') . '/cover_candidates_v2';
        if (!is_dir($this->dir) && !mkdir($this->dir, 0775, true) && !is_dir($this->dir)) throw new RuntimeException('无法创建封面候选缓存');
        $this->fetcher = $fetcher === null ? null : Closure::fromCallable($fetcher);
    }

    public function search(string $title, string $artist, string $source, bool $refresh = false): array
    {
        if (!in_array($source, ['itunes', 'lastfm', 'deezer', 'musicbrainz'], true)) throw new InvalidArgumentException('不支持的封面来源');
        $path = $this->queryPath($title, $artist, $source);
        $old = is_file($path) ? json_decode((string)file_get_contents($path), true) : null;
        if (!$refresh && is_array($old) && ($old['created_at'] ?? 0) + (empty($old['candidates']) ? 300 : 604800) > time()) {
            return ['candidates' => $old['candidates'], 'cached' => true, 'source' => $source];
        }
        $queries = [];
        $variants = $this->artistVariants($artist);
        if ($source === 'itunes') {
            foreach (['cn', 'hk', 'tw', 'us'] as $country) foreach ($variants as $name) {
                $queries[] = 'https://itunes.apple.com/search?' . http_build_query([
                    'term' => trim($title . ' ' . $name), 'media' => 'music', 'entity' => 'musicTrack', 'limit' => 20, 'country' => $country,
                ]);
            }
        } elseif ($source === 'lastfm') {
            $key = trim((string)($this->config['lastfm_api_key'] ?? ''));
            if ($key === '') throw new RuntimeException('Last.fm API Key 未配置');
            foreach ($variants as $name) $queries[] = 'https://ws.audioscrobbler.com/2.0/?' . http_build_query([
                'method' => 'track.getInfo', 'api_key' => $key, 'artist' => $name, 'track' => $title, 'autocorrect' => 1, 'format' => 'json',
            ]);
        } elseif ($source === 'deezer') {
            foreach ($variants as $name) $queries[] = 'https://api.deezer.com/search?' . http_build_query(['q' => trim($title . ' ' . $name), 'limit' => 20]);
        } else {
            $escape = static fn(string $text): string => str_replace(['\\', '"'], ['\\\\', '\\"'], $text);
            $query = 'recording:"' . $escape($title) . '"';
            if ($artist !== '') $query .= ' AND (' . implode(' OR ', array_map(static fn($name) => 'artist:"' . $escape($name) . '"', $variants)) . ')';
            $queries[] = 'https://musicbrainz.org/ws/2/recording/?' . http_build_query(['query' => $query, 'fmt' => 'json', 'limit' => 12]);
        }
        $candidates = [];
        $responses = $this->fetchMany(array_values(array_unique($queries)));
        if ($responses === []) throw new RuntimeException('该封面来源暂不可用，请重试或切换来源');
        foreach ($responses as $json) {
            if ($source === 'itunes') {
                foreach ($json['results'] ?? [] as $track) {
                    $url = preg_replace('/\d+x\d+bb/i', '800x800bb', (string)($track['artworkUrl100'] ?? '')) ?? '';
                    $preview = preg_replace('/\d+x\d+bb/i', '160x160bb', $url) ?? $url;
                    $this->addCandidate($candidates, $title, $artist, $source, (string)($track['trackName'] ?? ''), (string)($track['artistName'] ?? ''), (string)($track['collectionName'] ?? ''), $url, $preview);
                }
            } elseif ($source === 'deezer') {
                foreach ($json['data'] ?? [] as $track) {
                    $album = $track['album'] ?? [];
                    $this->addCandidate($candidates, $title, $artist, $source, (string)($track['title'] ?? ''), (string)($track['artist']['name'] ?? ''), (string)($album['title'] ?? ''), (string)($album['cover_xl'] ?? $album['cover_big'] ?? ''), (string)($album['cover_medium'] ?? $album['cover'] ?? ''));
                }
            } elseif ($source === 'lastfm') {
                $track = $json['track'] ?? [];
                $images = $track['album']['image'] ?? [];
                $urls = array_values(array_filter(array_map(static fn($image) => (string)($image['#text'] ?? ''), $images)));
                if ($urls !== []) $this->addCandidate($candidates, $title, $artist, $source, (string)($track['name'] ?? ''), (string)($track['artist']['name'] ?? ''), (string)($track['album']['title'] ?? ''), end($urls), $urls[min(1, count($urls) - 1)]);
            } else {
                foreach ($json['recordings'] ?? [] as $track) {
                    $names = [];
                    foreach ($track['artist-credit'] ?? [] as $credit) if (is_array($credit)) $names[] = (string)($credit['name'] ?? $credit['artist']['name'] ?? '');
                    foreach ($track['releases'] ?? [] as $album) {
                        $id = (string)($album['id'] ?? '');
                        if (!preg_match('/^[a-f0-9-]{36}$/i', $id)) continue;
                        $base = 'https://coverartarchive.org/release/' . $id;
                        $this->addCandidate($candidates, $title, $artist, $source, (string)($track['title'] ?? ''), implode('、', $names), (string)($album['title'] ?? ''), $base . '/front-500', $base . '/front-250');
                    }
                }
            }
        }
        $candidates = array_values($candidates);
        usort($candidates, static fn($a, $b) => $b['score'] <=> $a['score']);
        $candidates = array_slice($candidates, 0, 24);
        $this->atomicWrite($path, json_encode(['created_at' => time(), 'candidates' => $candidates], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        return ['candidates' => $candidates, 'cached' => false, 'source' => $source];
    }

    public function image(string $title, string $artist, string $source, string $id, bool $preview): array
    {
        if (!preg_match('/^[a-f0-9]{64}$/', $id)) throw new InvalidArgumentException('封面标识无效');
        $path = $this->queryPath($title, $artist, $source);
        $list = is_file($path) ? json_decode((string)file_get_contents($path), true) : [];
        $selected = null;
        foreach ($list['candidates'] ?? [] as $row) if (($row['id'] ?? '') === $id) { $selected = $row; break; }
        if ($selected === null) throw new InvalidArgumentException('封面候选已失效，请重新查询');
        $file = $this->dir . '/' . $id . ($preview ? '.preview' : '') . '.img';
        $bytes = is_file($file) ? file_get_contents($file) : false;
        if (!is_string($bytes)) {
            $url = $preview ? $selected['preview_url'] : $selected['image_url'];
            if (!self::trustedImageUrl($url)) throw new RuntimeException('封面图片地址不可信');
            $bytes = $this->requestImage($url);
            $info = @getimagesizefromstring($bytes);
            if (!is_array($info) || $info[0] < 32 || $info[1] < 32) throw new RuntimeException('来源未返回可用封面图片');
            $this->atomicWrite($file, $bytes);
        }
        $info = @getimagesizefromstring($bytes);
        if (!is_array($info)) throw new RuntimeException('封面图片缓存损坏');
        return ['bytes' => $bytes, 'mime' => $info['mime']];
    }

    private function addCandidate(array &$rows, string $title, string $artist, string $source, string $track, string $singer, string $album, string $url, string $preview): void
    {
        if (!self::trustedImageUrl($url) || str_contains($url, '2a96cbd8b46e442fc41c2b86b821562f')) return;
        $name = $this->normalize($track);
        $expected = $this->normalize($title);
        if ($name === '' || $expected === '' || (!str_contains($name, $expected) && !str_contains($expected, $name))) return;
        $titleMatch = $name === $expected;
        $artistMatch = $artist === '' || $this->matchesArtist($artist, $singer);
        $score = ($titleMatch ? 100 : 50) + ($artistMatch ? 100 : 0);
        if (preg_match('/伴奏|instrumental|karaoke/i', $track)) $score -= 80;
        if (preg_match('/live|现场/i', $track)) $score -= 20;
        $id = hash('sha256', $source . '|' . $url);
        $rows[$id] = ['id' => $id, 'source' => $source, 'title' => $track, 'artist' => $singer, 'album' => $album,
            'score' => $score, 'title_match' => $titleMatch, 'artist_match' => $artistMatch,
            'image_url' => $url, 'preview_url' => self::trustedImageUrl($preview) ? $preview : $url];
    }

    public static function trustedImageUrl(string $url): bool
    {
        $parts = parse_url($url);
        if (!is_array($parts) || ($parts['scheme'] ?? '') !== 'https' || isset($parts['user']) || isset($parts['pass'])) return false;
        $host = strtolower((string)($parts['host'] ?? ''));
        foreach (['mzstatic.com', 'dzcdn.net', 'lastfm.freetls.fastly.net', 'lastfm-img2.akamaized.net', 'coverartarchive.org', 'archive.org'] as $domain) {
            if ($host === $domain || str_ends_with($host, '.' . $domain)) return true;
        }
        return false;
    }

    public static function proxyForUrl(array $config, string $url): string
    {
        // 国内直连正常的 iTunes 保持直连；受限词库及 CAA 跳转图片走已有代理。
        $host = strtolower((string)(parse_url($url, PHP_URL_HOST) ?? ''));
        foreach (['deezer.com', 'dzcdn.net', 'musicbrainz.org', 'coverartarchive.org', 'archive.org'] as $domain) {
            if ($host === $domain || str_ends_with($host, '.' . $domain)) {
                return trim((string)($config['cover_proxy'] ?? $config['openrouter_proxy'] ?? ''));
            }
        }
        return '';
    }

    private function applyProxy($handle, string $url): void
    {
        $proxy = self::proxyForUrl($this->config, $url);
        if ($proxy !== '') {
            curl_setopt($handle, CURLOPT_PROXY, $proxy);
            curl_setopt($handle, CURLOPT_NOPROXY, '');
        }
    }

    private function normalize(string $text): string
    {
        // OpenCC 字符表只用于检索匹配；保留候选原始标题和歌手用于展示。
        static $characters = null;
        if ($characters === null) {
            $characters = [];
            foreach (file(__DIR__ . '/../data/TSCharacters.txt', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
                if (str_starts_with($line, '#')) continue;
                $pair = explode("\t", $line, 2);
                if (count($pair) === 2) $characters[$pair[0]] = explode(' ', $pair[1])[0];
            }
        }
        $text = strtr($text, $characters);
        return mb_strtolower(preg_replace('/[\s\p{P}\p{S}]+/u', '', $text) ?? $text, 'UTF-8');
    }
    private function artistVariants(string $artist): array
    {
        $parts = preg_split('/\s*(?:、|,|，|&|＆|\/|;|；|\bfeat\.?\s*|\bft\.?\s*)\s*/iu', $artist) ?: [];
        return array_slice(array_values(array_unique(array_filter([$artist, ...$parts], static fn($x) => $x !== ''))), 0, 3) ?: [''];
    }
    private function matchesArtist(string $expected, string $actual): bool
    {
        foreach ($this->artistVariants($expected) as $left) foreach ($this->artistVariants($actual) as $right) {
            if ($this->normalize($left) === $this->normalize($right)) return true;
        }
        return false;
    }
    private function queryPath(string $title, string $artist, string $source): string
    {
        return $this->dir . '/q-' . hash('sha256', $this->normalize($title) . '|' . $this->normalize($artist) . '|' . $source) . '.json';
    }
    private function atomicWrite(string $file, string $bytes): void
    {
        $temp = $file . '.' . bin2hex(random_bytes(4)) . '.tmp';
        if (file_put_contents($temp, $bytes, LOCK_EX) === false || !rename($temp, $file)) { @unlink($temp); throw new RuntimeException('封面缓存写入失败'); }
    }

    private function fetchMany(array $urls): array
    {
        if ($this->fetcher !== null) return array_map($this->fetcher, $urls);
        $multi = curl_multi_init();
        $handles = [];
        foreach ($urls as $url) {
            $handle = curl_init($url);
            curl_setopt_array($handle, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 5,
                CURLOPT_TIMEOUT => 15, CURLOPT_USERAGENT => 'NasPlayerCoverAPI/2.0', CURLOPT_ENCODING => '',
                CURLOPT_SSL_VERIFYPEER => (bool)($this->config['verify_tls'] ?? true),
                CURLOPT_SSL_VERIFYHOST => (bool)($this->config['verify_tls'] ?? true) ? 2 : 0]);
            $this->applyProxy($handle, $url);
            curl_multi_add_handle($multi, $handle); $handles[] = $handle;
        }
        do { curl_multi_exec($multi, $active); if ($active) curl_multi_select($multi, 0.5); } while ($active);
        $result = [];
        foreach ($handles as $handle) {
            $status = (int)curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
            $data = json_decode((string)curl_multi_getcontent($handle), true);
            if ($status >= 200 && $status < 300 && is_array($data)) $result[] = $data;
            curl_multi_remove_handle($multi, $handle); curl_close($handle);
        }
        curl_multi_close($multi);
        return $result;
    }

    private function requestImage(string $url): string
    {
        $handle = curl_init($url);
        $bytes = '';
        $max = (int)($this->config['max_image_bytes'] ?? 12582912);
        curl_setopt_array($handle, [CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 4, CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 20, CURLOPT_PROTOCOLS => CURLPROTO_HTTPS, CURLOPT_REDIR_PROTOCOLS => CURLPROTO_HTTPS,
            CURLOPT_SSL_VERIFYPEER => (bool)($this->config['verify_tls'] ?? true),
            CURLOPT_SSL_VERIFYHOST => (bool)($this->config['verify_tls'] ?? true) ? 2 : 0,
            CURLOPT_WRITEFUNCTION => static function ($ch, string $chunk) use (&$bytes, $max): int {
                if (strlen($bytes) + strlen($chunk) > $max) return 0;
                $bytes .= $chunk; return strlen($chunk);
            }]);
        $this->applyProxy($handle, $url);
        $ok = curl_exec($handle);
        $status = (int)curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        curl_close($handle);
        if ($ok === false || $status < 200 || $status >= 300) throw new RuntimeException('封面图片下载失败');
        return $bytes;
    }
}
