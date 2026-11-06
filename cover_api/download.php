<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli' && ($_SERVER['HTTPS'] ?? '') !== 'on') {
    header('Location: https://mp3.whzxc.com/', true, 302);
    exit;
}
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
$latestFile = __DIR__ . '/updates/latest.json';
$latest = is_file($latestFile) ? json_decode((string)file_get_contents($latestFile), true) : null;
$releases = [];
foreach (glob(__DIR__ . '/updates/release-*.json') ?: [] as $file) {
    $release = json_decode((string)file_get_contents($file), true);
    if (is_array($release) && is_int($release['version_code'] ?? null)
        && (!is_array($latest) || $release['version_code'] <= $latest['version_code'])) $releases[$release['version_code']] = $release;
}
if (is_array($latest)) $releases[$latest['version_code']] = $latest;
krsort($releases);
$latest ??= $releases === [] ? null : reset($releases);
$data = json_encode(array_values($releases), JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'HEAD') exit;
?>
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NAS Car Player 下载</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f1f6f5;color:#203b38;font:17px/1.6 system-ui,sans-serif}main{max-width:780px;margin:8vh auto;padding:28px}h1{font-size:34px;line-height:1.2}h2{font-size:21px;margin-top:30px}.card{background:white;border-radius:22px;padding:28px;box-shadow:0 10px 45px #234d3810}.muted{color:#637b77;font-size:15px}a{color:#176859;text-decoration:none}.primary{display:block;border-radius:12px;background:#176859;color:white;padding:18px;text-align:center;font-weight:600;margin:18px 0}select{max-width:100%;font:inherit;border:1px solid #bccfcc;border-radius:9px;padding:10px;background:white}ul{padding:0;list-style:none}li a{display:flex;justify-content:space-between;gap:16px;padding:14px 0;border-bottom:1px solid #e4eeec}pre{white-space:pre-wrap;font:inherit}.warning{color:#996022}@media(max-width:480px){main{padding:16px;margin:3vh auto}.card{padding:20px}h1{font-size:28px}}
</style></head><body><main><h1>NAS Car Player</h1><p class="muted">安卓车机播放器 · 离线音乐 · 桌面歌词</p><section class="card">
<?php if ($releases === []): ?><p>安装包正在准备，请稍后再来。</p><?php else: ?>
<label for="version">选择版本</label> <select id="version"></select>
<p id="device" class="muted">正在识别设备，无法确认架构时推荐通用包。</p>
<a id="recommended" class="primary" href="<?= htmlspecialchars((string)$latest['apk_url'], ENT_QUOTES, 'UTF-8') ?>">下载推荐安装包（通用版）</a>
<p class="muted">点击推荐安装包或下方的架构选项开始下载。下载完成后打开 APK，按系统提示允许安装。更新会保留原有数据。</p>
<h2>手动选择安装包</h2><ul id="packages"><?php foreach (($latest['downloads'] ?? ['universal' => $latest]) as $abi => $package): ?>
<li><a href="<?= htmlspecialchars((string)$package['apk_url'], ENT_QUOTES, 'UTF-8') ?>"><?= htmlspecialchars((string)$abi, ENT_QUOTES, 'UTF-8') ?> <span><?= round($package['size'] / 1048576, 1) ?> MB</span></a></li>
<?php endforeach; ?></ul>
<p class="muted">不清楚设备架构时选择通用版。ARM 32 位适合较旧车机，ARM 64 位适合支持 64 位应用的设备，x86_64 适合部分模拟器。</p>
<h2>更新内容</h2><pre id="notes"></pre><p id="date" class="muted"></p>
<?php endif; ?>
</section><p class="muted">应用内也可通过“设置 → 检查更新”下载安装新版本。翻译每天按设备和 IP 各限 5 首新歌曲，已有缓存不限。</p></main>
<script>
'use strict';
const releases=<?= $data ?>;
const labels={universal:'通用版（所有支持的架构）','armeabi-v7a':'ARM 32 位','arm64-v8a':'ARM 64 位',x86_64:'x86_64（模拟器 / Intel）'};
const android=/Android/i.test(navigator.userAgent);
let preferred='universal';
const version=document.getElementById('version');
function safeUrl(path){if(typeof path!=='string'||!/^updates\/player-[a-z0-9_-]+\.apk$/.test(path))return null;return new URL(path,location.href).href;}
function render(){const release=releases[version.selectedIndex];const packages=release.downloads||{universal:release};const items=document.getElementById('packages');items.textContent='';for(const [abi,entry] of Object.entries(packages)){const url=safeUrl(entry.apk_url);if(!url||!labels[abi])continue;const row=document.createElement('li'),link=document.createElement('a'),size=document.createElement('span');link.href=url;link.textContent=labels[abi];size.textContent=(entry.size/1048576).toFixed(1)+' MB';size.className='muted';link.append(size);row.append(link);items.append(row);}const abi=packages[preferred]?preferred:'universal',entry=packages[abi];const button=document.getElementById('recommended');button.href=safeUrl(entry.apk_url)||'#';button.textContent='下载 '+labels[abi]+' · '+release.version_name;document.getElementById('notes').textContent=release.notes||'优化播放体验';document.getElementById('date').textContent='发布于 '+new Date(release.published_at).toLocaleString('zh-CN');document.getElementById('device').textContent=android?(abi==='universal'?'已识别安卓设备；无法确认应用架构，推荐通用版。':'已识别安卓设备，推荐 '+labels[abi]+'。安装不兼容时请选择通用版。'):'当前不是安卓浏览器，可下载安装包后传到安卓设备。';}
async function init(){if(!version)return;releases.forEach(r=>{const option=document.createElement('option');option.textContent=r.version_name+' ('+r.version_code+')'+(r.version_code===releases[0].version_code?' · 最新':'');version.append(option);});render();version.addEventListener('change',render);
// Client hints are optional. Never infer 64-bit app support from Android version.
if(android&&navigator.userAgentData&&navigator.userAgentData.getHighEntropyValues){try{const hint=await Promise.race([navigator.userAgentData.getHighEntropyValues(['architecture','bitness']),new Promise(resolve=>setTimeout(()=>resolve({}),1200))]);if(hint.architecture==='arm'&&hint.bitness==='64')preferred='arm64-v8a';else if(hint.architecture==='arm'&&hint.bitness==='32')preferred='armeabi-v7a';else if(hint.architecture==='x86'&&hint.bitness==='64')preferred='x86_64';render();}catch{}}
}
init();
</script></body></html>
