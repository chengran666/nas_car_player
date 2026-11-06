param(
    [string]$ApkPath = "$PSScriptRoot/build/app/outputs/flutter-apk/app-release.apk",
    [string]$Notes = '',
    [string]$NotesFile = '',
    [switch]$IncludeSplitApks,
    [string]$Server = 'lsai',
    [string]$SiteRoot = '/www/wwwroot/cover_api.whzxc.com'
)
$ErrorActionPreference = 'Stop'
if (!$env:JAVA_HOME -and (Test-Path -LiteralPath 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe')) {
    $env:JAVA_HOME = 'C:/Program Files/Android/Android Studio/jbr'
}
$apk = (Resolve-Path -LiteralPath $ApkPath).Path
if ($Server -notmatch '^[a-zA-Z0-9_.-]+$' -or $SiteRoot -notmatch '^/[a-zA-Z0-9_./-]+$') { throw '服务器或目录参数无效' }
$sdk = $env:ANDROID_HOME
if (!$sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (!$sdk) {
    $properties = Get-Content -LiteralPath "$PSScriptRoot/android/local.properties"
    $sdkLine = $properties | Where-Object { $_ -like 'sdk.dir=*' } | Select-Object -First 1
    $sdk = $sdkLine.Substring(8).Replace('\:', ':').Replace('\\', '\')
}
$buildTools = Get-ChildItem -LiteralPath "$sdk/build-tools" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$aapt = Join-Path $buildTools.FullName 'aapt.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
$badging = & $aapt dump badging $apk
if ($LASTEXITCODE -ne 0) { throw '无法读取 APK' }
$package = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
if ($badging -match '^application-debuggable') { throw '请上传 release APK，不能发布调试包' }
if ($package -notmatch "name='com\.example\.nas_car_player' versionCode='([0-9]+)' versionName='([^']+)'") { throw '不是本播放器的 APK' }
$code = [int]$Matches[1]
$name = $Matches[2]
$versionText = Get-Content -LiteralPath "$PSScriptRoot/pubspec.yaml" -Raw -Encoding UTF8
$versionMatch = [regex]::Match($versionText, '(?m)^version:\s*([^\s+]+)\+([0-9]+)\s*$')
if (!$versionMatch.Success) { throw 'pubspec.yaml 中缺少有效的版本号' }
$expectedCode = [long]$versionMatch.Groups[2].Value
if ($expectedCode -le 0 -or $expectedCode -gt [int]::MaxValue) { throw '版本码超出 Android 整数范围' }
if ($code -ne $expectedCode -or $name -ne $versionMatch.Groups[1].Value) { throw 'APK 与当前 pubspec.yaml 版本不同，请重新打包后发布' }
$datedCode = $versionMatch.Groups[2].Value
if ($datedCode -notmatch '^[0-9]{8}(0[1-9]|[1-9][0-9])$') { throw '版本码请使用 yyyyMMddNN，例如 2026101202' }
try { [void][datetime]::ParseExact($datedCode.Substring(0, 8), 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture) }
catch { throw '版本码中的年月日无效' }
$signing = & $apksigner verify --print-certs $apk
if ($LASTEXITCODE -ne 0) { throw 'APK 签名验证失败' }
$key = Join-Path $PSScriptRoot 'android/signing/player.keystore'
$keytool = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/keytool.exe' } else { 'keytool' }
$certificate = & $keytool -exportcert -keystore $key -alias androiddebugkey -storepass android -rfc 2>$null
if ($LASTEXITCODE -ne 0) { throw '无法读取播放器签名，请配置 JAVA_HOME' }
$pem = ($certificate -join '').Replace('-----BEGIN CERTIFICATE-----', '').Replace('-----END CERTIFICATE-----', '')
$certBytes = [Convert]::FromBase64String($pem)
$hasher = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = ([BitConverter]::ToString($hasher.ComputeHash($certBytes))).Replace('-', '').ToLowerInvariant() }
finally { $hasher.Dispose() }
if (!($signing | Where-Object { $_ -match "certificate SHA-256 digest: $fingerprint$" })) { throw 'APK 没有使用现有播放器签名，无法覆盖安装' }
if ($NotesFile) { $Notes = Get-Content -LiteralPath $NotesFile -Raw -Encoding UTF8 }
$incoming = '.incoming-' + [guid]::NewGuid().ToString('N') + '.apk'
$metadata = @{
    version_code = $code; version_name = $name; file = $incoming; notes = $Notes
    size = (Get-Item -LiteralPath $apk).Length
    sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
}
$uploads = @(@{ path = $apk; file = $incoming })
if ($IncludeSplitApks) {
    $variants = @{}
    foreach ($abi in @('armeabi-v7a', 'arm64-v8a', 'x86_64')) {
        $split = Join-Path (Split-Path $apk) "app-$abi-release.apk"
        if (!(Test-Path -LiteralPath $split)) { throw "缺少架构包: $split，请先运行 build_apk.bat" }
        $splitBadging = & $aapt dump badging $split
        if ($LASTEXITCODE -ne 0 -or ($splitBadging -match '^application-debuggable')) { throw "架构包读取失败: $abi" }
        $splitPackage = $splitBadging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
        if ($splitPackage -notmatch "name='com\.example\.nas_car_player' versionCode='([0-9]+)' versionName='([^']+)'") { throw "架构包不属于播放器: $abi" }
        if ([int]$Matches[1] -ne $code -or $Matches[2] -ne $name) { throw "架构包版本不同: $abi，请重新打包" }
        $splitSigning = & $apksigner verify --print-certs $split
        if ($LASTEXITCODE -ne 0 -or !($splitSigning | Where-Object { $_ -match "certificate SHA-256 digest: $fingerprint$" })) { throw "架构包签名错误: $abi" }
        $splitIncoming = '.incoming-' + [guid]::NewGuid().ToString('N') + '.apk'
        $variants[$abi] = @{
            file = $splitIncoming; size = (Get-Item -LiteralPath $split).Length
            sha256 = (Get-FileHash -LiteralPath $split -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $uploads += @{ path = $split; file = $splitIncoming }
    }
    $metadata.variants = $variants
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($metadata | ConvertTo-Json -Compress -Depth 8)))
& ssh -o BatchMode=yes $Server "mkdir -p $SiteRoot/updates"
if ($LASTEXITCODE -ne 0) { throw '创建服务器目录失败' }
foreach ($upload in $uploads) {
    & scp -- $upload.path "${Server}:$SiteRoot/updates/$($upload.file)"
    if ($LASTEXITCODE -ne 0) { throw '上传失败，未发布新版本' }
}
& ssh -o BatchMode=yes $Server "php $SiteRoot/tools/publish_update.php $encoded"
if ($LASTEXITCODE -ne 0) { throw '发布失败，旧版本仍然有效，请查看上方错误' }
Write-Host "已发布 $name ($code)，下载页面 https://mp3.whzxc.com/，播放器也会自动检查更新。"
