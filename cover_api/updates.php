<?php
declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    http_response_code(405);
    echo json_encode(['success' => false, 'error' => '只支持 GET']);
    exit;
}
try {
    $path = __DIR__ . '/updates/latest.json';
    $release = is_file($path) ? json_decode((string)file_get_contents($path), true, 32, JSON_THROW_ON_ERROR) : null;
    echo json_encode(['success' => true, 'release' => $release], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
} catch (Throwable $error) {
    error_log('[updates] ' . $error->getMessage());
    http_response_code(503);
    echo json_encode(['success' => false, 'error' => '版本服务暂不可用']);
}
