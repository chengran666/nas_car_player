<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/../src/LyricTranslationService.php';
function checkReference(bool $ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
$root = sys_get_temp_dir() . '/nas_references_test_' . bin2hex(random_bytes(5));
mkdir($root);
try {
    $requests = [];
    $failSearch = false;
    $transport = static function ($url, $payload, $headers) use (&$requests, &$failSearch): array {
        $requests[] = $payload;
        if ($failSearch && isset($payload['plugins'])) throw new RuntimeException('Plugin unsupported');
        $user = json_decode($payload['messages'][1]['content'], true);
        $lines = array_reverse(array_map(static fn($row) => ['id' => $row['id'], 'translation' => '自然中文译文'], $user['lines']));
        return ['choices' => [['message' => ['content' => json_encode(['lines' => $lines]), 'annotations' => [
            ['url_citation' => ['url' => 'https://example.com/translation', 'title' => 'Fixture translation', 'content' => 'The supplied lyric line 对应的中文译文']],
            ['url_citation' => ['url' => 'http://untrusted.test/text', 'content' => '不安全来源']],
        ]]]]];
    };
    $config = ['cache_dir' => $root, 'openrouter_api_key' => 'test-not-a-real-key'];
    $service = new LyricTranslationService($config, null, $transport);
    $result = $service->translate('Fixture Song', 'Fixture Artist', ['A quiet invented line', 'Another invented line']);
    checkReference($requests[0]['model'] === '~openai/gpt-sol-latest', '默认使用最新 Sol 翻译模型别名');
    checkReference($requests[0]['plugins'] === [['id' => 'web', 'engine' => 'exa', 'max_results' => 3]], '首次缺失译文带一次受限联网搜索');
    checkReference($result['translations'] === ['自然中文译文', '自然中文译文'], '参考搜索仍严格按原文标识配对');
    $user = json_decode($requests[0]['messages'][1]['content'], true);
    checkReference($user['context'] === ['A quiet invented line', 'Another invented line'], '翻译能看到本次其他歌词行的上下文');
    $service->translate('Fixture Song', 'Fixture Artist', ['New invented line']);
    $user = json_decode($requests[1]['messages'][1]['content'], true);
    checkReference(!isset($requests[1]['plugins']) && count($user['references']) === 1, '后续批次复用有真实检索来源的参考，不再搜索');
    checkReference($user['references'][0]['url'] === 'https://example.com/translation', '只保存搜索提供的有效 HTTPS 来源');
    $hit = $service->translate('Other Song', 'Other Artist', ['New invented line'], static function () { throw new RuntimeException('缓存命中不应占用额度'); });
    checkReference($hit['cached'] && count($requests) === 2, '共享逐行译文命中不搜索、不调用模型、不占额度');
    $failSearch = true;
    $service->translate('No Search Song', 'Artist', ['Uncached fallback line']);
    checkReference(count($requests) === 4 && isset($requests[2]['plugins']) && !isset($requests[3]['plugins']), '搜索不受支持时自动回退，仍返回译文');
    $service->translate('No Search Song', 'Artist', ['Another fallback line']);
    checkReference(count($requests) === 5 && !isset($requests[4]['plugins']), '失败的搜索也缓存，后续批次不会反复尝试');
    $disabled = new LyricTranslationService($config + ['translation_reference_search' => false], null, $transport);
    $disabled->translate('Disabled Song', '', ['Disabled fixture line']);
    checkReference(!isset($requests[5]['plugins']), '可配置关闭搜索，同时保留自然翻译');
    echo "Translation reference checks passed\n";
} finally {
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($iterator as $item) $item->isDir() ? rmdir($item->getPathname()) : unlink($item->getPathname());
    rmdir($root);
}
