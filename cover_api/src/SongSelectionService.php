<?php
declare(strict_types=1);

final class SongSelectionService
{
    private string $dir;
    public function __construct(array $config, private string $deviceId = '')
    {
        if ($deviceId !== '' && !preg_match('/^[a-f0-9]{64}$/', $deviceId)) {
            throw new InvalidArgumentException('设备识别码无效');
        }
        $this->dir = rtrim((string)($config['cache_dir'] ?? ''), '/\\') . '/song_selections_v1';
        if (!is_dir($this->dir) && !mkdir($this->dir, 0775, true) && !is_dir($this->dir)) {
            throw new RuntimeException('无法创建歌曲选择目录');
        }
    }

    private static function normalize(string $text): string
    {
        static $characters = null;
        if ($characters === null) {
            $characters = [];
            foreach (file(__DIR__ . '/../data/TSCharacters.txt', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
                $pair = explode("\t", $line, 2);
                if (count($pair) === 2) $characters[$pair[0]] = explode(' ', $pair[1])[0];
            }
        }
        return mb_strtolower(preg_replace('/[\s\p{P}\p{S}]+/u', '', strtr($text, $characters)) ?? $text, 'UTF-8');
    }

    private function path(string $title, string $artist, bool $shared = false): string
    {
        if (trim($title) === '' || strlen($title) > 300 || strlen($artist) > 300 || !mb_check_encoding($title . $artist, 'UTF-8')) {
            throw new InvalidArgumentException('歌曲名或歌手名无效');
        }
        $parts = preg_split('/\s*(?:、|,|，|&|＆|\/|;|；|\+|＋|\bfeaturing\b|\bfeat\.?\s*|\bft\.?\s*)\s*/iu', $artist) ?: [];
        $parts = array_values(array_unique(array_filter(array_map(self::normalize(...), $parts))));
        sort($parts, SORT_STRING);
        $prefix = !$shared && $this->deviceId !== '' ? 'device-' . $this->deviceId . '-' : '';
        return $this->dir . '/' . $prefix . hash('sha256', self::normalize($title) . '|' . implode('|', $parts)) . '.json';
    }

    private function validateDuration(float $duration): void
    {
        if (!is_finite($duration) || $duration < 0 || $duration > 86400) throw new InvalidArgumentException('歌曲时长无效');
    }

    private function read(string $path): array
    {
        if (!is_file($path)) return [];
        $data = json_decode((string)file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        return is_array($data['versions'] ?? null) ? $data['versions'] : [];
    }

    private function matchingIndex(array $versions, float $duration): ?int
    {
        // 无时长时只复用唯一版本，避免同名现场版与录音室版混用。
        if ($duration === 0.0) return count($versions) === 1 ? 0 : null;
        $matches = [];
        foreach ($versions as $index => $version) {
            $length = (float)($version['duration'] ?? 0);
            if ($length > 0 && abs($length - $duration) <= 3.0) $matches[$index] = abs($length - $duration);
        }
        if ($matches !== []) { asort($matches, SORT_NUMERIC); return array_key_first($matches); }
        return count($versions) === 1 && (float)$versions[0]['duration'] === 0.0 ? 0 : null;
    }

    private function selectedRecord(string $title, string $artist, float $duration): ?array
    {
        $this->validateDuration($duration);
        $versions = $this->read($this->path($title, $artist));
        $index = $this->matchingIndex($versions, $duration);
        $record = $index === null ? null : $versions[$index];
        if ($this->deviceId !== '') {
            // Personal choices win independently for each asset. Community winners
            // are materialized on writes, so normal reads never scan all devices.
            $community = $this->community($title, $artist);
            $communityIndex = $this->matchingIndex($community, $duration);
            if ($communityIndex !== null) {
                $default = $community[$communityIndex];
                if ($record === null) $record = array_intersect_key($default, array_flip(['title', 'artist', 'duration']));
                foreach (['lyrics', 'cover'] as $kind) {
                    if (!isset($record[$kind]) && isset($default[$kind])) $record[$kind] = $default[$kind];
                }
            }
            $defaults = $this->read($this->path($title, $artist, true));
            $defaultIndex = $this->matchingIndex($defaults, $duration);
            if ($defaultIndex !== null) {
                $default = $defaults[$defaultIndex];
                if ($record === null) $record = $default;
                else foreach (['lyrics', 'cover'] as $kind) {
                    if (!isset($record[$kind]) && isset($default[$kind])) $record[$kind] = $default[$kind];
                }
            }
        }
        return $record;
    }

    public function get(string $title, string $artist, float $duration): ?array
    {
        $record = $this->selectedRecord($title, $artist, $duration);
        if (isset($record['cover'])) unset($record['cover']['file']);
        return $record;
    }

    public function coverCandidates(string $title, string $artist, float $duration, string $lyrics = '', bool $related = true): array
    {
        $this->validateDuration($duration);
        $this->path($title, $artist); // Validate before reading the shared index.
        if (!$related) return $this->exactCoverCandidates($title, $artist, $duration);
        $queryLyrics = self::lyricSignature($lyrics);
        $queryTitle = self::normalize($title);
        $queryArtists = self::artistParts($artist);
        $rows = [];
        foreach ($this->coverSearchIndex() as $song) {
            $index = $this->matchingIndex($song['versions'], $duration);
            if ($index === null) continue;
            $version = $song['versions'][$index];
            if (self::versionTags($title) !== self::versionTags($song['title'])) continue;
            $sameTitle = $queryTitle === $song['normalized_title'];
            $sameArtists = $queryArtists !== [] && $queryArtists === $song['artists'];
            $lyricsExact = false; $lyricSimilarity = 0.0;
            foreach ($version['lyrics'] as $signature) {
                if ($queryLyrics === null) break;
                $lyricsExact = $lyricsExact || $queryLyrics['hash'] === $signature['hash'];
                $overlap = count(array_intersect($queryLyrics['lines'], $signature['lines']));
                $lyricSimilarity = max($lyricSimilarity, 2 * $overlap / max(1, count($queryLyrics['lines']) + count($signature['lines'])));
            }
            $titleSimilarity = self::textSimilarity($queryTitle, $song['normalized_title']);
            $artistCompatible = $queryArtists === [] || array_intersect($queryArtists, $song['artists']) !== [];
            $lyricsConflict = $queryLyrics !== null && $version['lyrics'] !== [] && !$lyricsExact && $lyricSimilarity < 0.75;
            if ($sameTitle && $sameArtists && $lyricsExact) {
                $rank = 400; $type = 'exact_song_lyrics'; $label = '歌名、歌手和歌词精确匹配';
            } elseif ($sameTitle && $sameArtists && !$lyricsConflict) {
                $rank = 300; $type = 'exact_song'; $label = '歌名和歌手精确匹配';
            } elseif ($lyricsExact) {
                $rank = 280; $type = 'exact_lyrics'; $label = '歌词精确匹配 · 歌曲信息有差异';
            } elseif ($sameTitle && $sameArtists) {
                $rank = 180; $type = 'fuzzy'; $label = '歌曲信息一致 · 歌词不同，请核对';
            } elseif (($titleSimilarity >= 0.82 && $artistCompatible) || ($lyricSimilarity >= 0.75 && $titleSimilarity >= 0.6)) {
                $rank = 100 + (int)round(50 * max($titleSimilarity, $lyricSimilarity));
                $type = 'fuzzy'; $label = '模糊匹配 · 请核对歌名、歌手和版本';
            } else continue;
            foreach ($this->exactCoverCandidates($song['title'], $song['artist'], (float)$version['duration']) as $row) {
                $row += ['match_type' => $type, 'match_label' => $label,
                    'lookup_title' => $song['title'], 'lookup_artist' => $song['artist'], 'lookup_duration' => $version['duration']];
                $row['score'] = $rank;
                $row['artist_match'] = $sameArtists;
                // The same image may be selected for several spellings/recordings.
                // Retain its strongest match instead of adding votes across songs.
                $previous = $rows[$row['id']] ?? null;
                if ($previous === null || self::compareCandidates($row, $previous) < 0) $rows[$row['id']] = $row;
            }
        }
        $rows = array_values($rows);
        usort($rows, self::compareCandidates(...));
        return array_slice($rows, 0, 24);
    }

    private static function compareCandidates(array $a, array $b): int
    {
        return ($b['score'] <=> $a['score']) ?: ($b['votes'] <=> $a['votes']) ?: strcmp($a['id'], $b['id']);
    }

    private static function artistParts(string $artist): array
    {
        if (trim($artist) === '私人乐库') return [];
        $parts = preg_split('/\s*(?:、|,|，|&|＆|\/|;|；|\+|＋|\bfeaturing\b|\bfeat\.?\s*|\bft\.?\s*)\s*/iu', $artist) ?: [];
        $parts = array_values(array_unique(array_filter(array_map(self::normalize(...), $parts))));
        sort($parts, SORT_STRING);
        return $parts;
    }

    private static function versionTags(string $title): array
    {
        $tags = [];
        foreach (['live' => '/\blive\b|现场|現場/iu', 'instrumental' => '/\binstrumental\b|伴奏|纯音乐|純音樂/iu',
            'remix' => '/\bremix\b|混音/iu', 'acoustic' => '/\bacoustic\b|不插电|不插電/iu'] as $tag => $pattern) {
            if (preg_match($pattern, $title)) $tags[] = $tag;
        }
        return $tags;
    }

    private function coverSearchIndex(?array $changedSong = null): array
    {
        $path = $this->dir . '/cover-search-v1.json';
        // Saves never trigger a global migration during normal playback. The
        // first manual cover query builds it; subsequent saves update one song.
        // A first search may be building the index concurrently. In that case
        // wait on its lock and merge this save, rather than losing the new song.
        if ($changedSong !== null && !is_file($path) && !is_file($path . '.lock')) return [];
        if ($changedSong === null && is_file($path)) {
            $data = json_decode((string)file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
            return $data['songs'] ?? [];
        }
        $lock = fopen($path . '.lock', 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) throw new RuntimeException('无法锁定封面搜索索引');
        try {
            if (is_file($path)) {
                $data = json_decode((string)file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
                $songs = $data['songs'] ?? [];
            } else {
                $songs = []; $names = [];
                // One-time migration includes old personal and anonymous
                // records. Queries thereafter only read this compact index.
                foreach (glob($this->dir . '/*.json') ?: [] as $file) {
                    if (!preg_match('/^(?:device-[a-f0-9]{64}-|community-)?[a-f0-9]{64}\.json$/', basename($file))) continue;
                    foreach ($this->read($file) as $record) {
                        $key = basename($this->path($record['title'], $record['artist'], true));
                        $names[$key] = [$record['title'], $record['artist']];
                    }
                }
                foreach ($names as $key => [$title, $artist]) $songs[$key] = $this->coverSearchSong($title, $artist);
            }
            if ($changedSong !== null) {
                [$title, $artist] = $changedSong;
                $songs[basename($this->path($title, $artist, true))] = $this->coverSearchSong($title, $artist);
            }
            $this->atomicWrite($path, json_encode(['schema_version' => 1, 'songs' => $songs], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
            return $songs;
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }

    private function coverSearchSong(string $title, string $artist): array
    {
        $community = $this->community($title, $artist, true);
        $legacy = $this->read($this->path($title, $artist, true));
        $versions = $community;
        foreach ($legacy as $record) {
            $index = $this->matchingIndex($versions, (float)$record['duration']);
            if ($index === null) $versions[] = $record;
            elseif (isset($record['lyrics'])) $versions[$index]['legacy_lyrics'] = $record['lyrics'];
        }
        $summaries = [];
        foreach ($versions as $version) {
            $tally = $version['tallies']['lyrics'] ?? [];
            $texts = [];
            foreach (array_unique($tally['voters'] ?? []) as $revision) {
                if (isset($tally['choices'][$revision]['text'])) $texts[] = $tally['choices'][$revision]['text'];
            }
            foreach (['lyrics', 'legacy_lyrics'] as $field) if (isset($version[$field]['text'])) $texts[] = $version[$field]['text'];
            $signatures = [];
            foreach ($texts as $text) {
                $signature = self::lyricSignature($text);
                if ($signature !== null) $signatures[$signature['hash']] = $signature;
            }
            $summaries[] = ['duration' => (float)$version['duration'], 'lyrics' => array_values($signatures)];
        }
        return ['title' => $title, 'artist' => $artist, 'normalized_title' => self::normalize($title),
            'artists' => self::artistParts($artist), 'versions' => $summaries];
    }

    private static function lyricSignature(string $text): ?array
    {
        if (strlen($text) > 262144 || !mb_check_encoding($text, 'UTF-8')) throw new InvalidArgumentException('歌词正文无效或过长');
        $lines = [];
        foreach (preg_split('/\R/u', $text) ?: [] as $line) {
            if (preg_match('/^\s*\[(?:ar|ti|al|by|offset|length|re|ve):/iu', $line)) continue;
            $line = self::normalize(preg_replace('/\[\d+:\d+(?:[.:]\d+)?\]/u', '', $line) ?? $line);
            if ($line !== '') $lines[] = $line;
        }
        $unique = array_values(array_unique($lines));
        // A shared word or chorus alone cannot identify a recording.
        if (count($unique) < 4 || mb_strlen(implode('', $unique), 'UTF-8') < 40) return null;
        return ['hash' => hash('sha256', implode('\n', $lines)),
            'lines' => array_map(static fn($line) => substr(hash('sha256', $line), 0, 24), array_slice($unique, 0, 256))];
    }

    private static function textSimilarity(string $left, string $right): float
    {
        if ($left === $right) return 1.0;
        // Unicode edit distance, so Chinese characters do not count as 3 bytes.
        $a = mb_str_split($left); $b = mb_str_split($right);
        if ($a === [] || $b === []) return 0.0;
        $previous = range(0, count($b));
        foreach ($a as $i => $character) {
            $next = [$i + 1];
            foreach ($b as $j => $other) $next[] = min($next[$j] + 1, $previous[$j + 1] + 1, $previous[$j] + ($character === $other ? 0 : 1));
            $previous = $next;
        }
        return 1 - end($previous) / max(count($a), count($b));
    }

    private function exactCoverCandidates(string $title, string $artist, float $duration): array
    {
        $this->validateDuration($duration);
        $community = $this->community($title, $artist, true);
        $index = $this->matchingIndex($community, $duration);
        $rows = [];
        if ($index !== null) {
            $tally = $community[$index]['tallies']['cover'] ?? [];
            // Each hardware contributes only its last selection. Exclude this
            // hardware so the source actually represents other users' choices.
            $others = array_filter($tally['voters'] ?? [], fn($revision, $device) => $device !== $this->deviceId, ARRAY_FILTER_USE_BOTH);
            foreach (array_count_values($others) as $revision => $votes) {
                $cover = $tally['choices'][$revision] ?? null;
                if (is_array($cover) && is_file($this->dir . '/' . $cover['file'])) {
                    $rows[$revision] = $this->coverCandidate($cover, $title, $artist, $votes, false);
                }
            }
        }
        // Older anonymous selections have no hardware count; identify them as
        // historical shared choices instead of inventing a vote count.
        $legacy = $this->read($this->path($title, $artist, true));
        $legacyIndex = $this->matchingIndex($legacy, $duration);
        $cover = $legacyIndex === null ? null : ($legacy[$legacyIndex]['cover'] ?? null);
        if (is_array($cover) && !isset($rows[$cover['revision']]) && is_file($this->dir . '/' . $cover['file'])) {
            $rows[$cover['revision']] = $this->coverCandidate($cover, $title, $artist, 0, true);
        }
        $rows = array_values($rows);
        usort($rows, static fn($a, $b) => ($b['votes'] <=> $a['votes']) ?: strcmp($a['id'], $b['id']));
        return array_slice($rows, 0, 24);
    }

    private function coverCandidate(array $cover, string $title, string $artist, int $votes, bool $legacy): array
    {
        $source = $cover['source'] ?? '';
        return ['id' => $cover['revision'], 'source' => 'community',
            'title' => trim((string)($cover['title'] ?? '')) ?: $title,
            'artist' => trim((string)($cover['artist'] ?? '')) ?: $artist,
            'album' => (string)($cover['album'] ?? ''), 'score' => 200,
            'artist_match' => true, 'votes' => $votes, 'legacy' => $legacy,
            'origin_source' => in_array($source, ['itunes', 'lastfm', 'deezer', 'musicbrainz'], true) ? $source : ''];
    }

    public function communityImage(string $title, string $artist, float $duration, string $revision, bool $preview): array
    {
        $image = $this->image($title, $artist, $duration, $revision);
        if (!$preview || !extension_loaded('gd')) return $image;
        $path = $this->dir . '/preview-v1-' . $revision . '.jpg';
        if (is_file($path)) return ['bytes' => (string)file_get_contents($path), 'mime' => 'image/jpeg'];
        $size = @getimagesizefromstring($image['bytes']);
        // Bound GD memory on a modest server; small originals need no decode.
        if (!is_array($size) || max($size[0], $size[1]) <= 256 || $size[0] * $size[1] > 4194304) return $image;
        $source = @imagecreatefromstring($image['bytes']);
        if ($source === false) return $image;
        $ratio = 256 / max($size[0], $size[1]);
        $thumb = imagecreatetruecolor(max(1, (int)round($size[0] * $ratio)), max(1, (int)round($size[1] * $ratio)));
        try {
            imagefill($thumb, 0, 0, imagecolorallocate($thumb, 255, 255, 255));
            imagecopyresampled($thumb, $source, 0, 0, 0, 0, imagesx($thumb), imagesy($thumb), $size[0], $size[1]);
            ob_start();
            try { imagejpeg($thumb, null, 82); $bytes = (string)ob_get_contents(); }
            finally { ob_end_clean(); }
            if ($bytes === '') return $image;
            $this->atomicWrite($path, $bytes);
            return ['bytes' => $bytes, 'mime' => 'image/jpeg'];
        } finally { imagedestroy($source); imagedestroy($thumb); }
    }

    public function image(string $title, string $artist, float $duration, string $revision): array
    {
        $this->validateDuration($duration);
        if (!preg_match('/^[a-f0-9]{64}$/', $revision)) throw new InvalidArgumentException('封面版本无效');
        $record = $this->selectedRecord($title, $artist, $duration);
        $cover = $record['cover'] ?? null;
        // The winner can change between metadata and image requests. Previously
        // voted images for this song remain readable without a new search.
        if (!is_array($cover) || $cover['revision'] !== $revision) {
            $community = $this->community($title, $artist, true);
            $index = $this->matchingIndex($community, $duration);
            $cover = $index === null ? null : ($community[$index]['tallies']['cover']['choices'][$revision] ?? null);
        }
        if (!is_array($cover) || $cover['revision'] !== $revision) throw new InvalidArgumentException('所选封面已更新，请重新读取');
        $bytes = @file_get_contents($this->dir . '/' . $cover['file']);
        if (!is_string($bytes) || strlen($bytes) < 12) throw new RuntimeException('所选封面缓存不可用，请重新选择');
        return ['bytes' => $bytes, 'mime' => $cover['mime']];
    }

    public function save(string $title, string $artist, float $duration, string $kind, array $choice): array
    {
        $path = $this->path($title, $artist);
        $this->validateDuration($duration);
        if ($kind === 'lyrics') {
            $text = $choice['text'] ?? null;
            if (!is_string($text) || trim($text) === '' || strlen($text) > 262144 || !mb_check_encoding($text, 'UTF-8')) {
                throw new InvalidArgumentException('歌词正文无效或过长');
            }
            $asset = ['text' => $text, 'source' => mb_substr((string)($choice['source'] ?? 'LRCLIB'), 0, 100),
                'candidate_id' => max(0, (int)($choice['candidate_id'] ?? 0)), 'revision' => hash('sha256', $text)];
        } elseif ($kind === 'cover') {
            $encoded = $choice['image_base64'] ?? null;
            if (!is_string($encoded) || strlen($encoded) > 12 * 1024 * 1024) throw new InvalidArgumentException('封面正文无效或过大');
            $bytes = base64_decode($encoded, true);
            $info = is_string($bytes) ? @getimagesizefromstring($bytes) : false;
            if (!is_array($info) || strlen($bytes) > 8 * 1024 * 1024 || $info[0] < 32 || $info[1] < 32 || $info[0] > 8192 || $info[1] > 8192 ||
                !in_array($info['mime'], ['image/jpeg', 'image/png', 'image/webp', 'image/gif'], true)) {
                throw new InvalidArgumentException('封面必须是有效的 JPG/PNG/WebP 图片');
            }
            $revision = hash('sha256', $bytes);
            $file = 'image-' . $revision . '.img';
            if (!is_file($this->dir . '/' . $file)) $this->atomicWrite($this->dir . '/' . $file, $bytes);
            $asset = ['file' => $file, 'mime' => $info['mime'], 'revision' => $revision];
            foreach (['id', 'source', 'title', 'artist', 'album'] as $field) $asset[$field] = mb_substr((string)($choice[$field] ?? ''), 0, 300);
        } else {
            throw new InvalidArgumentException('选择类型无效');
        }
        $asset['saved_at'] = time();
        $communityPath = $this->communityPath($title, $artist);
        $lock = fopen($communityPath . '.lock', 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) throw new RuntimeException('无法锁定歌曲选择');
        try {
            $community = $this->communityLocked($title, $artist);
            $versions = $this->read($path);
            // 保存时，未知时长的选择不会覆盖已知版本。
            $index = $duration === 0.0 ? null : $this->matchingIndex($versions, $duration);
            if ($duration === 0.0) foreach ($versions as $i => $version) if ((float)$version['duration'] === 0.0) { $index = $i; break; }
            if ($index === null) { $index = count($versions); $versions[] = ['title' => $title, 'artist' => $artist, 'duration' => $duration]; }
            if ((float)$versions[$index]['duration'] === 0.0 && $duration > 0) $versions[$index]['duration'] = $duration;
            $versions[$index][$kind === 'lyrics' ? 'lyrics' : 'cover'] = $asset;
            $this->atomicWrite($path, json_encode(['schema_version' => 1, 'versions' => $versions], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
            if ($this->deviceId !== '') {
                $this->vote($community, $title, $artist, $duration, $kind, $asset, $this->deviceId);
                $this->writeCommunity($communityPath, $community);
            }
        } finally { flock($lock, LOCK_UN); fclose($lock); }
        // Read the newest song history under the index lock; concurrent saves
        // cannot overwrite a newer index with an earlier in-memory snapshot.
        $this->coverSearchIndex([$title, $artist]);
        return ['revision' => $asset['revision']];
    }

    private function communityPath(string $title, string $artist): string
    {
        return $this->dir . '/community-' . basename($this->path($title, $artist, true));
    }

    private function community(string $title, string $artist, bool $history = false): array
    {
        $path = $this->communityPath($title, $artist);
        $readPath = $history ? $path : substr($path, 0, -5) . '.defaults.json';
        if (is_file($readPath)) return $this->read($readPath);
        $lock = fopen($path . '.lock', 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) throw new RuntimeException('无法锁定公共歌曲选择');
        try {
            $versions = $this->communityLocked($title, $artist);
            if (!is_file($readPath)) $this->writeCommunity($path, $versions);
            return $history ? $versions : $this->read($readPath);
        }
        finally { flock($lock, LOCK_UN); fclose($lock); }
    }

    private function communityLocked(string $title, string $artist): array
    {
        $path = $this->communityPath($title, $artist);
        if (is_file($path)) return $this->read($path);
        $versions = [];
        // Migrate existing votes once per song, including selections made before
        // this feature. Empty indexes are also persisted to avoid repeated scans.
        $songFile = basename($this->path($title, $artist, true));
        foreach (glob($this->dir . '/device-*-' . $songFile) ?: [] as $deviceFile) {
            if (!preg_match('/^device-([a-f0-9]{64})-/', basename($deviceFile), $match)) continue;
            foreach ($this->read($deviceFile) as $record) foreach (['lyrics', 'cover'] as $kind) {
                if (isset($record[$kind])) $this->vote($versions, $title, $artist, (float)$record['duration'], $kind, $record[$kind], $match[1]);
            }
        }
        $this->writeCommunity($path, $versions);
        return $versions;
    }

    private function vote(array &$versions, string $title, string $artist, float $duration, string $kind, array $asset, string $device): void
    {
        $index = $duration === 0.0 ? null : $this->matchingIndex($versions, $duration);
        if ($duration === 0.0) foreach ($versions as $i => $record) if ((float)$record['duration'] === 0.0) { $index = $i; break; }
        if ($index === null) { $index = count($versions); $versions[] = ['title' => $title, 'artist' => $artist, 'duration' => $duration]; }
        if ((float)$versions[$index]['duration'] === 0.0 && $duration > 0) $versions[$index]['duration'] = $duration;
        $version = &$versions[$index];
        $tally = &$version['tallies'][$kind];
        $revision = $asset['revision'];
        $tally['choices'][$revision] = $asset;
        $tally['voters'][$device] = $revision;
        $counts = array_count_values($tally['voters']);
        $winner = $version[$kind]['revision'] ?? $revision;
        // Keep the incumbent on ties; retries and ties must not flicker defaults.
        foreach ($counts as $candidate => $count) if ($count > ($counts[$winner] ?? 0)) $winner = $candidate;
        $version[$kind] = $tally['choices'][$winner] + ['selection_scope' => 'community', 'votes' => $counts[$winner]];
    }

    private function writeCommunity(string $path, array $versions): void
    {
        $this->atomicWrite($path, json_encode(['schema_version' => 1, 'versions' => $versions], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        $defaults = array_map(static function (array $record): array {
            unset($record['tallies']);
            return $record;
        }, $versions);
        $this->atomicWrite(substr($path, 0, -5) . '.defaults.json', json_encode(['schema_version' => 1, 'versions' => $defaults], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    }

    private function atomicWrite(string $path, string $bytes): void
    {
        $temp = $path . '.' . bin2hex(random_bytes(6)) . '.tmp';
        try {
            if (file_put_contents($temp, $bytes, LOCK_EX) === false || !rename($temp, $path)) throw new RuntimeException('歌曲选择写入失败');
        } finally { if (is_file($temp)) unlink($temp); }
    }
}
