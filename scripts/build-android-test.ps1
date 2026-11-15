param(
    [string]$Flutter = 'D:\SuixingLocBuild\flutter-sdk\bin\flutter.bat',
    [string]$JavaHome = 'D:\SuixingLocBuild\android-tools\java\jdk-21.0.13+9',
    [string]$AndroidSdk = 'D:\SuixingLocBuild\android-sdk',
    [string]$BuildRoot = 'D:\SuixingLocBuild',
    [string]$OutputRoot,
    [string]$Version = '1.2.7',
    [int]$BuildNumber = 14,
    [string]$ProjectGithubUrl = 'https://github.com/yfl520/sxloc'
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputRoot) { $OutputRoot = Join-Path (Split-Path $sourceRoot -Parent) '测试版\安卓蓝牙' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if ($BuildRoot -match '[^\x00-\x7F]') { throw '安卓编译目录需为英文路径。' }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号格式无效。' }
if ($ProjectGithubUrl -and $ProjectGithubUrl -notmatch '^https://github\.com/[^/?#@\s]+/[^/?#\s]+/?$') { throw '请填写完整的 GitHub 仓库 HTTPS 地址。' }
foreach ($item in @($Flutter, (Join-Path $JavaHome 'bin\javac.exe'), (Join-Path $AndroidSdk 'platforms\android-36\android.jar'))) {
    if (-not (Test-Path -LiteralPath $item)) { throw "缺少构建依赖：$item" }
}
$identity = Join-Path $sourceRoot 'Desktop\Private'
foreach ($material in @('identity.pk8', 'certificate.p7b')) {
    if (-not (Test-Path -LiteralPath (Join-Path $identity $material))) { throw '请先运行 import-desktop-identity.ps1 恢复实验身份材料。' }
}
$flutterCommand = (Get-Command $Flutter).Source
$flutterSdk = Split-Path (Split-Path $flutterCommand -Parent) -Parent
if ($flutterSdk -match '[^\x00-\x7F]') {
    $alias = Join-Path $BuildRoot ('flutter-sdk-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Junction -Path $alias -Target $flutterSdk | Out-Null
    $flutterSdk = $alias; $flutterCommand = Join-Path $alias 'bin\flutter.bat'
}
$stage = Join-Path $BuildRoot 'android-test-app'
New-Item -ItemType Directory -Force $stage | Out-Null
& robocopy (Join-Path $sourceRoot 'FlutterApp') $stage /E /XD build .dart_tool .gradle ephemeral .plugin_symlinks .idea .vs /XF .flutter-plugins-dependencies local.properties *.iml | Out-Null
if ($LASTEXITCODE -ge 8) { throw '复制安卓源码失败。' }
$assets = Join-Path $stage 'android\app\src\main\assets\offline-mfi'
New-Item -ItemType Directory -Force $assets | Out-Null
foreach ($material in @('identity.pk8', 'certificate.p7b')) { Copy-Item -LiteralPath (Join-Path $identity $material) -Destination $assets -Force }
@("sdk.dir=$($AndroidSdk.Replace('\','/'))", "flutter.sdk=$($flutterSdk.Replace('\','/'))") |
    Set-Content -LiteralPath (Join-Path $stage 'android\local.properties') -Encoding utf8
$oldJava = $env:JAVA_HOME; $oldAndroid = $env:ANDROID_HOME; $oldSdkRoot = $env:ANDROID_SDK_ROOT
$oldIdentity = $env:ANDROID_TEST_IDENTITY_DIR
$oldGradleOptions = $env:GRADLE_OPTS
$env:JAVA_HOME = $JavaHome; $env:ANDROID_HOME = $AndroidSdk; $env:ANDROID_SDK_ROOT = $AndroidSdk
$env:ANDROID_TEST_IDENTITY_DIR = $identity
# Java does not automatically use HTTP(S)_PROXY, unlike Flutter's downloader.
if ($env:HTTPS_PROXY) {
    $proxyUri = [Uri]$env:HTTPS_PROXY
    if ($proxyUri.Scheme -eq 'http' -and -not $proxyUri.UserInfo) {
        $env:GRADLE_OPTS = "$oldGradleOptions -Dhttps.proxyHost=$($proxyUri.Host) -Dhttps.proxyPort=$($proxyUri.Port) -Dhttp.proxyHost=$($proxyUri.Host) -Dhttp.proxyPort=$($proxyUri.Port)"
    }
}
try {
    Push-Location $stage
    try {
        & $flutterCommand pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Flutter 依赖还原失败。' }
        & $flutterCommand analyze --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter 静态分析失败。' }
        & $flutterCommand test --no-pub --reporter expanded
        if ($LASTEXITCODE -ne 0) { throw '安卓搜索输入焦点检查失败。' }
        & (Join-Path $flutterSdk 'bin\dart.bat') run tool/check_android_coordinates.dart
        if ($LASTEXITCODE -ne 0) { throw '安卓地图坐标检查失败。' }
        & (Join-Path $flutterSdk 'bin\dart.bat') run tool/check_android_search.dart
        if ($LASTEXITCODE -ne 0) { throw '安卓搜索离线集成检查失败。' }
        & $flutterCommand build apk --release --no-pub -t lib/main_android.dart --build-name=$Version --build-number=$BuildNumber --dart-define="PROJECT_GITHUB_URL=$ProjectGithubUrl" --target-platform android-arm,android-arm64,android-x64
        if ($LASTEXITCODE -ne 0) { throw '安卓 APK 编译失败。' }
        Push-Location android
        try {
            & .\gradlew.bat :app:testDebugUnitTest '-Ptarget=lib/main_android.dart' --console=plain
            if ($LASTEXITCODE -ne 0) { throw '安卓离线协议测试失败。' }
        } finally { Pop-Location }
    } finally { Pop-Location }
    $destination = Join-Path $OutputRoot "$Version-$BuildNumber"
    if (Test-Path -LiteralPath $destination) { throw "输出目录已存在，请保留已交付版本并使用新的构建号：$destination" }
    New-Item -ItemType Directory -Force $destination | Out-Null
    $apk = Join-Path $destination '随行定位-安卓蓝牙验证版.apk'
    Copy-Item -LiteralPath (Join-Path $stage 'build\app\outputs\flutter-apk\app-release.apk') -Destination $apk
    $signer = Join-Path $AndroidSdk 'build-tools\36.0.0\apksigner.bat'
    & $signer verify --verbose --print-certs $apk | Set-Content (Join-Path $destination 'APK签名校验.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'APK 签名校验失败。' }
    (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash | Set-Content (Join-Path $destination 'SHA256.txt') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'README-安卓蓝牙验证.md') -Destination (Join-Path $destination '使用说明.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path $destination 'LICENSE-GPL-3.0.txt')
    Write-Output "安卓测试 APK 已生成：$apk"
} finally {
    $env:JAVA_HOME = $oldJava; $env:ANDROID_HOME = $oldAndroid; $env:ANDROID_SDK_ROOT = $oldSdkRoot
    $env:ANDROID_TEST_IDENTITY_DIR = $oldIdentity
    $env:GRADLE_OPTS = $oldGradleOptions
}
