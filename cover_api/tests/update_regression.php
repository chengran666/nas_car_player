<?php
declare(strict_types=1);
$root = sys_get_temp_dir() . '/nas-update-test-' . bin2hex(random_bytes(6));
mkdir($root . '/tools', 0700, true);
mkdir($root . '/updates', 0700, true);
copy(dirname(__DIR__) . '/tools/publish_update.php', $root . '/tools/publish_update.php');
copy(dirname(__DIR__) . '/updates.php', $root . '/updates.php');
function publishTest(string $root, int $code, bool $badHash = false, bool $split = false, bool $variants = false, bool $badVariant = false): int {
    $name = '.incoming-' . bin2hex(random_bytes(16)) . '.apk';
    $file = $root . '/updates/' . $name;
    $zip = new ZipArchive(); $zip->open($file, ZipArchive::CREATE);
    foreach (['AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libapp.so'] as $part) $zip->addFromString($part, 'fixture');
    if (!$split) foreach (['armeabi-v7a', 'x86_64'] as $abi) $zip->addFromString('lib/' . $abi . '/libapp.so', 'fixture');
    $zip->close();
    $payload = ['file' => $name, 'version_code' => $code, 'version_name' => '1.0.1',
        'size' => filesize($file), 'sha256' => $badHash ? str_repeat('0', 64) : hash_file('sha256', $file), 'notes' => '测试'];
    if ($variants) {
        foreach (['armeabi-v7a', 'arm64-v8a', 'x86_64'] as $abi) {
            $incoming = '.incoming-' . bin2hex(random_bytes(16)) . '.apk';
            $path = $root . '/updates/' . $incoming;
            $archive = new ZipArchive(); $archive->open($path, ZipArchive::CREATE);
            foreach (['AndroidManifest.xml', 'classes.dex', 'lib/' . $abi . '/libapp.so'] as $part) $archive->addFromString($part, 'fixture');
            $archive->close();
            $payload['variants'][$abi] = ['file' => $incoming, 'size' => filesize($path),
                'sha256' => $badVariant && $abi === 'x86_64' ? str_repeat('0', 64) : hash_file('sha256', $path)];
        }
    }
    $process = proc_open([PHP_BINARY, $root . '/tools/publish_update.php', base64_encode(json_encode($payload))],
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    stream_get_contents($pipes[1]); stream_get_contents($pipes[2]);
    foreach ($pipes as $pipe) fclose($pipe);
    return proc_close($process);
}
function ensure(bool $condition, string $message): void { if (!$condition) throw new RuntimeException($message); }
try {
    ensure(publishTest($root, 2003) === 0, 'First publication failed');
    $original = file_get_contents($root . '/updates/latest.json');
    ensure(publishTest($root, 2003) !== 0, 'Equal version was accepted');
    ensure(publishTest($root, 2002) !== 0, 'Downgrade was accepted');
    ensure(publishTest($root, 2004, true) !== 0, 'Invalid checksum was accepted');
    ensure(publishTest($root, 2004, false, true) !== 0, 'Single ABI was accepted');
    ensure(file_get_contents($root . '/updates/latest.json') === $original, 'Failed publish changed active release');
    ensure(publishTest($root, 2004) === 0, 'Newer publication failed');
    $latest = json_decode(file_get_contents($root . '/updates/latest.json'), true);
    ensure($latest['version_code'] === 2004 && count(glob($root . '/updates/player-*.apk')) === 2, 'Old download was removed');
    ob_start(); include $root . '/updates.php'; $response = json_decode(ob_get_clean(), true);
    ensure($response['success'] && $response['release']['version_code'] === 2004, 'Endpoint failed');
    $before = file_get_contents($root . '/updates/latest.json');
    ensure(publishTest($root, 2005, false, false, true, true) !== 0, 'Bad split checksum accepted');
    ensure(file_get_contents($root . '/updates/latest.json') === $before, 'Partial upload changed current version');
    ensure(publishTest($root, 2005, false, false, true) === 0, 'Multi-ABI publication failed');
    $latest = json_decode(file_get_contents($root . '/updates/latest.json'), true);
    ensure(count($latest['downloads']) === 4 && count(glob($root . '/updates/release-*.json')) === 3, 'Packages or history missing');
    foreach ($latest['downloads'] as $package) ensure(is_file($root . '/' . $package['apk_url']), 'Download missing');
    ensure(publishTest($root, 2026101202, false, false, true) === 0, 'Date-based version publication failed');
    $dated = json_decode(file_get_contents($root . '/updates/latest.json'), true);
    ensure($dated['version_code'] === 2026101202 && count($dated['downloads']) === 4, 'Date-based version or ABI packages changed');
    foreach ($dated['downloads'] as $package) ensure(str_contains($package['apk_url'], 'player-2026101202-'), 'Date-based filename missing');
    ensure(publishTest($root, 2026101202) !== 0, 'Duplicate dated release accepted');
    ensure(publishTest($root, 2026101199) !== 0, 'Earlier day accepted');
    ensure(publishTest($root, 2026101301) === 0, 'Next-day counter reset failed');
    echo "Update regression tests passed\n";
} finally {
    $files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($files as $item) { if ($item->isDir()) rmdir($item->getPathname()); else unlink($item->getPathname()); }
    rmdir($root);
}
