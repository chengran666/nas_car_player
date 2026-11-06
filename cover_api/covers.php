<?php
declare(strict_types=1);
require __DIR__ . '/src/CoverCandidateService.php';
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
function candidateError(int $status, string $message): never {
    http_response_code($status); header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['success' => false, 'error' => $message], JSON_UNESCAPED_UNICODE); exit;
}
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
if (!in_array($method, ['GET', 'POST'], true)) candidateError(405, '只支持 GET/POST');
$config = require __DIR__ . '/config.php';
$token = trim((string)($config['access_token'] ?? ''));
$auth = (string)($_SERVER['HTTP_AUTHORIZATION'] ?? '');
if ($token !== '' && !hash_equals($token, str_starts_with($auth, 'Bearer ') ? substr($auth, 7) : '')) candidateError(401, '访问令牌无效');
try {
    $input = $_GET;
    if ($method === 'POST') {
        $body = file_get_contents('php://input', false, null, 0, 270337);
        if ($body === false || strlen($body) > 270336) candidateError(413, '请求过大');
        $input = json_decode($body, true, 32, JSON_THROW_ON_ERROR);
    }
    if (!is_array($input) || !is_string($input['title'] ?? null) || !is_string($input['artist'] ?? '') || !is_string($input['source'] ?? 'itunes')) candidateError(400, '歌曲参数无效');
    $title = trim($input['title']); $artist = trim($input['artist'] ?? ''); $source = $input['source'] ?? 'itunes';
    if ($title === '' || strlen($title) > 300 || strlen($artist) > 300) candidateError(400, '歌曲名或歌手名无效');
    if (!in_array($source, ['community', 'itunes', 'lastfm', 'deezer', 'musicbrainz'], true)) candidateError(400, '封面来源无效');
    if ($method === 'POST' && ($source !== 'community' || isset($input['action']))) candidateError(405, 'POST 仅支持其他用户封面查询');
    if ($source === 'community') {
        require_once __DIR__ . '/src/SongSelectionService.php';
        if (!is_numeric($input['duration'] ?? 0) || !is_string($input['device_id'] ?? '') || !is_string($input['lyrics'] ?? '')) throw new InvalidArgumentException('歌曲或设备参数无效');
        $duration = (float)($input['duration'] ?? 0);
        $service = new SongSelectionService($config, $input['device_id'] ?? '');
        if (($input['action'] ?? '') === 'image') {
            $image = $service->communityImage($title, $artist, $duration, (string)($input['id'] ?? ''), ($input['preview'] ?? '') === '1');
            header('Content-Type: ' . $image['mime']); header('Cache-Control: private, max-age=86400');
            echo $image['bytes'];
        } else {
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(['success' => true, 'source' => 'community', 'cached' => true,
                'candidates' => $service->coverCandidates($title, $artist, $duration, $input['lyrics'] ?? '', $method === 'POST')], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        }
        exit;
    }
    $service = new CoverCandidateService($config);
    if (($_GET['action'] ?? '') === 'image') {
        $image = $service->image($title, $artist, $source, (string)($_GET['id'] ?? ''), ($_GET['preview'] ?? '') === '1');
        header('Content-Type: ' . $image['mime']); header('Cache-Control: private, max-age=86400');
        echo $image['bytes'];
    } else {
        $result = $service->search($title, $artist, $source, ($_GET['refresh'] ?? '') === '1');
        // 图片地址由客户端构造回本站，不暴露上游凭证。
        foreach ($result['candidates'] as &$row) unset($row['image_url'], $row['preview_url']);
        unset($row);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['success' => true] + $result, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    }
} catch (InvalidArgumentException | JsonException $error) { candidateError(400, $error->getMessage()); }
catch (Throwable $error) { error_log('[cover-candidates] ' . $error->getMessage()); candidateError(502, '封面来源暂不可用，请重试或切换来源'); }
