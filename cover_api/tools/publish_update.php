<?php
declare(strict_types=1);
// Publishing is SSH-only. No upload credentials or writable HTTP endpoint in the app.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$lock = null;
try {
    $input = json_decode((string)base64_decode($argv[1] ?? '', true), true, 32, JSON_THROW_ON_ERROR);
    if (!is_array($input) || !is_int($input['version_code'] ?? null) || $input['version_code'] <= 0
        || !is_string($input['version_name'] ?? null) || strlen($input['version_name']) > 100
        || !preg_match('/^\.incoming-[a-f0-9]{32}\.apk$/D', (string)($input['file'] ?? ''))
        || !preg_match('/^[a-f0-9]{64}$/D', (string)($input['sha256'] ?? ''))
        || !is_int($input['size'] ?? null) || $input['size'] <= 0 || $input['size'] > 512 * 1024 * 1024
        || !is_string($input['notes'] ?? null) || strlen($input['notes']) > 20000) {
        throw new InvalidArgumentException('发布参数无效');
    }
    $dir = dirname(__DIR__) . '/updates';
    if (!is_dir($dir) && !mkdir($dir, 0755, true)) throw new RuntimeException('无法创建版本目录');
    $lock = fopen($dir . '/.publish.lock', 'c');
    if (!$lock || !flock($lock, LOCK_EX)) throw new RuntimeException('无法锁定版本目录');
    $current = is_file($dir . '/latest.json') ? json_decode((string)file_get_contents($dir . '/latest.json'), true, 32, JSON_THROW_ON_ERROR) : null;
    if ($current !== null && $input['version_code'] <= ($current['version_code'] ?? 0)) {
        throw new RuntimeException('版本号必须高于已发布版本，请增加 pubspec.yaml 的 + 数字后重新打包');
    }
    $packages = ['universal' => $input];
    if (isset($input['variants']) && !is_array($input['variants'])) throw new InvalidArgumentException('架构包参数无效');
    foreach ($input['variants'] ?? [] as $abi => $variant) {
        if (!in_array($abi, ['armeabi-v7a', 'arm64-v8a', 'x86_64'], true) || !is_array($variant)
            || !preg_match('/^\.incoming-[a-f0-9]{32}\.apk$/D', (string)($variant['file'] ?? ''))
            || !preg_match('/^[a-f0-9]{64}$/D', (string)($variant['sha256'] ?? ''))
            || !is_int($variant['size'] ?? null) || $variant['size'] <= 0 || $variant['size'] > 512 * 1024 * 1024) {
            throw new InvalidArgumentException('架构包参数无效');
        }
        $packages[$abi] = $variant;
    }
    $downloads = [];
    foreach ($packages as $abi => $package) {
        $source = $dir . '/' . $package['file'];
        if (!is_file($source) || filesize($source) !== $package['size'] || !hash_equals($package['sha256'], (string)hash_file('sha256', $source))) {
            throw new RuntimeException('上传文件校验失败: ' . $abi);
        }
        $zip = new ZipArchive();
        if ($zip->open($source) !== true) throw new RuntimeException('安装包格式错误');
        try {
            if ($zip->locateName('AndroidManifest.xml') === false || $zip->locateName('classes.dex') === false) throw new RuntimeException('不是 APK');
            foreach (['armeabi-v7a', 'arm64-v8a', 'x86_64'] as $architecture) {
                $present = $zip->locateName('lib/' . $architecture . '/libapp.so') !== false;
                if ($present !== ($abi === 'universal' || $abi === $architecture)) throw new RuntimeException('安装包架构不匹配: ' . $abi);
            }
        } finally { $zip->close(); }
        $name = 'player-' . $input['version_code'] . '-' . $abi . '-' . substr($package['sha256'], 0, 12) . '.apk';
        $downloads[$abi] = ['apk_url' => 'updates/' . $name, 'sha256' => $package['sha256'], 'size' => $package['size']];
    }
    $release = [
        'version_code' => $input['version_code'], 'version_name' => $input['version_name'],
        'apk_url' => $downloads['universal']['apk_url'], 'sha256' => $input['sha256'], 'size' => $input['size'],
        'downloads' => $downloads,
        'notes' => $input['notes'], 'published_at' => gmdate('c'),
    ];
    // Validate all uploaded packages before exposing any new version.
    foreach ($packages as $abi => $package) {
        $destination = dirname(__DIR__) . '/' . $downloads[$abi]['apk_url'];
        if (!rename($dir . '/' . $package['file'], $destination)) throw new RuntimeException('无法保存 APK');
        chmod($destination, 0644);
    }
    $temporary = $dir . '/.latest-' . bin2hex(random_bytes(8)) . '.json';
    $json = json_encode($release, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    if (file_put_contents($temporary, $json, LOCK_EX) === false) throw new RuntimeException('无法保存版本信息');
    $history = $dir . '/release-' . $input['version_code'] . '.json';
    if (!copy($temporary, $history) || !rename($temporary, $dir . '/latest.json')) {
        throw new RuntimeException('无法发布版本信息');
    }
    chmod($dir . '/latest.json', 0644);
    echo json_encode(['success' => true, 'release' => $release], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
} catch (Throwable $error) {
    fwrite(STDERR, $error->getMessage() . "\n");
    exit(1);
} finally {
    if (is_resource($lock)) { flock($lock, LOCK_UN); fclose($lock); }
}
