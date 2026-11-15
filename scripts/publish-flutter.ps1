param(
    [string]$Flutter = 'flutter',
    [string]$Dotnet = 'dotnet',
    [string]$InnoCompiler,
    [string]$MsvcRedist,
    [string]$BuildRoot = "$env:SystemDrive\SuixingLocBuild",
    [string]$OutputRoot,
    [string]$Version = '1.1.4',
    [int]$BuildNumber = 9,
    [string]$ProjectGithubUrl = 'https://github.com/yfl520/sxloc',
    [string]$Python = 'python',
    [switch]$TestBuild
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputRoot) { $OutputRoot = Join-Path (Split-Path $sourceRoot -Parent) '发布' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if ($BuildRoot -match '[^\x00-\x7F]') { throw 'Flutter Windows 编译目录必须使用英文路径，请通过 -BuildRoot 指定。' }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号必须为 major.minor.patch 格式。' }
if ($BuildNumber -le 0) { throw '构建号必须为正整数。' }
if ($ProjectGithubUrl -and $ProjectGithubUrl -notmatch '^https://github\.com/[^/?#@\s]+/[^/?#\s]+/?$') { throw '请填写完整的 GitHub 仓库 HTTPS 地址。' }
$flutterCommand = (Get-Command $Flutter -ErrorAction Stop).Source
$dotnetCommand = (Get-Command $Dotnet -ErrorAction Stop).Source
$usbRuntime = & (Join-Path $PSScriptRoot 'prepare-usb-runtime.ps1') -BuildRoot $BuildRoot -Python $Python
$flutterSdk = Split-Path (Split-Path $flutterCommand -Parent) -Parent
New-Item -ItemType Directory -Path $BuildRoot, $OutputRoot -Force | Out-Null
# Keep Flutter's native tool arguments ASCII even when the source or SDK is under a Chinese folder.
if ($flutterSdk -match '[^\x00-\x7F]') {
    $sdkAlias = Join-Path $BuildRoot ('flutter-sdk-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Junction -Path $sdkAlias -Target $flutterSdk | Out-Null
    $flutterCommand = Join-Path $sdkAlias 'bin\flutter.bat'
}
$buildId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stage = Join-Path $BuildRoot "app-$buildId"
New-Item -ItemType Directory -Path $stage | Out-Null
& robocopy (Join-Path $sourceRoot 'FlutterApp') $stage /E /XD build .dart_tool ephemeral .plugin_symlinks .idea .vs /XF .flutter-plugins-dependencies | Out-Null
if ($LASTEXITCODE -ge 8) { throw '复制 Flutter 构建源失败。' }
foreach ($material in @('identity.pk8', 'certificate.p7b')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot "Desktop\Private\$material"))) {
        throw '缺少内置身份材料。请先执行 scripts/import-desktop-identity.ps1。'
    }
}
Push-Location $stage
try {
    & $flutterCommand pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 依赖还原失败。' }
    & $flutterCommand analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 静态分析失败。' }
    & $flutterCommand build windows --release --no-pub --build-name=$Version --build-number=$BuildNumber --dart-define="PROJECT_GITHUB_URL=$ProjectGithubUrl" --dart-define="APP_VERSION=$Version" --dart-define="APP_BUILD=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows 编译失败。' }
} finally { Pop-Location }
$coreOutput = Join-Path $BuildRoot "core-$buildId"
& $dotnetCommand publish (Join-Path $sourceRoot 'Bridge\SuixingLoc.Core.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o $coreOutput --nologo
if ($LASTEXITCODE -ne 0) { throw '.NET 定位组件发布失败。' }
$bundle = Join-Path $OutputRoot '随行定位'
if (Test-Path -LiteralPath $bundle) { throw "发布文件夹已经存在，请选择新的 -OutputRoot：$bundle" }
New-Item -ItemType Directory -Path $bundle, (Join-Path $bundle 'core') | Out-Null
Copy-Item -Path (Join-Path $stage 'build\windows\x64\runner\Release\*') -Destination $bundle -Recurse
Rename-Item -LiteralPath (Join-Path $bundle 'suixing_loc.exe') -NewName '随行定位.exe'
Copy-Item -Path (Join-Path $coreOutput '*') -Destination (Join-Path $bundle 'core') -Recurse
$usbBundle = Join-Path $bundle 'core\usb'
New-Item -ItemType Directory -Path $usbBundle | Out-Null
& robocopy $usbRuntime $usbBundle /E /XD __pycache__ /XF *.pyc | Out-Null
if ($LASTEXITCODE -ge 8) { throw '复制 USB 独立运行时失败。' }
Copy-Item -Path (Join-Path $sourceRoot 'Bridge\UsbWorker\*.py') -Destination $usbBundle

if (-not $MsvcRedist) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw '未找到 VS C++ 运行库，请通过 -MsvcRedist 指定 x64 CRT 文件夹。' }
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $MsvcRedist = Get-ChildItem (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.' } | Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' } |
        Select-Object -First 1 -ExpandProperty FullName
}
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $MsvcRedist $required))) { throw "缺少 x64 C++ 运行库：$required" }
}
Get-ChildItem -LiteralPath $MsvcRedist -Filter '*.dll' -File | Copy-Item -Destination $bundle

$licenses = Join-Path $bundle 'licenses'
New-Item -ItemType Directory -Path $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $usbRuntime 'LICENSE.txt') -Destination (Join-Path $licenses 'Python-3.14.7.txt')
# Wheel metadata includes the complete dependency license payloads. Preserve their paths.
$usbLicenses = Join-Path $licenses 'usb-python'
New-Item -ItemType Directory -Path $usbLicenses | Out-Null
Get-ChildItem -LiteralPath (Join-Path $usbRuntime 'Lib\site-packages') -Directory -Filter '*.dist-info' |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $usbLicenses -Recurse }
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Bridge\UsbWorker\requirements.lock') -Destination $usbLicenses
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path $licenses 'iap2loc-GPL-3.0.txt')
Copy-Item -LiteralPath (Join-Path $flutterSdk 'LICENSE') -Destination (Join-Path $licenses 'Flutter-BSD.txt')
$dotnetRoot = Split-Path $dotnetCommand -Parent
foreach ($file in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
    if (Test-Path -LiteralPath (Join-Path $dotnetRoot $file)) {
        Copy-Item -LiteralPath (Join-Path $dotnetRoot $file) -Destination (Join-Path $licenses "dotnet-$file")
    }
}
$packageConfigPath = Join-Path $stage '.dart_tool\package_config.json'
$packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
foreach ($package in $packageConfig.packages) {
    $uri = [Uri]$package.rootUri
    $packageDirectory = if ($uri.IsAbsoluteUri) { $uri.LocalPath } else { [IO.Path]::GetFullPath((Join-Path (Split-Path $packageConfigPath -Parent) $package.rootUri)) }
    foreach ($file in @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING', 'NOTICE', 'NOTICES')) {
        $licenseFile = Join-Path $packageDirectory $file
        if (Test-Path -LiteralPath $licenseFile -PathType Leaf) {
            Copy-Item -LiteralPath $licenseFile -Destination (Join-Path $licenses ($package.name + '-' + $file + '.txt'))
        }
    }
}
if ($InnoCompiler) {
    Copy-Item -LiteralPath (Join-Path (Split-Path $InnoCompiler -Parent) 'license.txt') -Destination (Join-Path $licenses 'Inno-Setup.txt')
}
foreach ($file in @('THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination $bundle
}
$usage = [IO.File]::ReadAllText((Join-Path $sourceRoot 'README.md')).Replace('](BUILDING.md)', "]($ProjectGithubUrl/blob/main/BUILDING.md)").Replace('](FlutterApp/assets/service_agreement.md)', '](使用协议与免责声明.md)').Replace('](LICENSE)', '](licenses/iap2loc-GPL-3.0.txt)')
[IO.File]::WriteAllText((Join-Path $bundle '使用说明.md'), $usage, [Text.UTF8Encoding]::new($false))

function Assert-GuiExecutable([string]$File) {
    $stream = [IO.File]::OpenRead($File)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "不是 Windows 可执行文件：$File" }
        $stream.Position = 0x3C
        $header = $reader.ReadUInt32()
        $stream.Position = $header + 92
        if ($reader.ReadUInt16() -ne 2) { throw "不是无控制台 GUI 程序：$File" }
    } finally { $reader.Dispose() }
}
Assert-GuiExecutable (Join-Path $bundle '随行定位.exe')
Assert-GuiExecutable (Join-Path $bundle 'core\SuixingLoc.Core.exe')
foreach ($required in @('data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin', 'flutter_windows.dll', 'core\SuixingLoc.Core.exe', 'core\usb\python.exe', 'core\usb\worker.py', 'core\usb\prepare_image.py', 'core\usb\Lib\site-packages\pymobiledevice3\__init__.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "发布文件缺失：$required" }
}

$bundleInfo = @{ schemaVersion = 1; platform = 'windows-x64'; version = $Version; buildNumber = $BuildNumber } | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $bundle 'app_info.json'), $bundleInfo, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $sourceRoot 'FlutterApp/assets/service_agreement.md') -Destination (Join-Path $bundle '使用协议与免责声明.md')

if ($TestBuild) {
    Write-Output "测试构建完成：$bundle。未生成安装包或压缩包，未启动应用。"
    return
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$portableZip = Join-Path $OutputRoot '随行定位-便携版.zip'
$updatePayload = Join-Path $OutputRoot 'sxloc-windows-x64.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($bundle, $updatePayload, [IO.Compression.CompressionLevel]::Optimal, $true)
$updateHash = (Get-FileHash -LiteralPath $updatePayload -Algorithm SHA256).Hash.ToLowerInvariant()
$updateSize = (Get-Item -LiteralPath $updatePayload).Length
$updateInfo = @{ schemaVersion = 1; platform = 'windows-x64'; version = $Version; buildNumber = $BuildNumber; fileName = 'sxloc-windows-x64.zip'; size = $updateSize; sha256 = $updateHash } | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $OutputRoot 'sxloc-update.json'), $updateInfo, [Text.UTF8Encoding]::new($false))
[IO.File]::Copy($updatePayload, $portableZip, $true)
$sourceZip = Join-Path $OutputRoot '随行定位-源码.zip'
$archive = [IO.Compression.ZipFile]::Open($sourceZip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        if ($relative -match '(^|\\)(bin|obj|build|dist|publish|releases|__pycache__|\.dart_tool|\.git|\.vs|\.idea|ephemeral|\.plugin_symlinks|Private|test-identity|test-ident|secrets|ident|identity)(\\|$)') { continue }
        if ($relative -match '(^|\\)\.gradle(\\|$)') { continue }
        if ($file.Name -match '\.(apk|pk8|p7b|dpapi|pfx|pem|jks|keystore|user|log|pdb|dll|exe|zip)$' -or $file.Name -in @('iap2loc.json', 'desktop.json', '.flutter-plugins-dependencies', 'local.properties', 'key.properties')) { continue }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, ('iap2loc-main/' + $relative.Replace('\', '/')), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }

if ($InnoCompiler) {
    & $InnoCompiler "/DBundleDir=$bundle" "/DReleaseDir=$OutputRoot" "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'windows-installer.iss')
    if ($LASTEXITCODE -ne 0) { throw '中文安装包编译失败。' }
}
$hashes = Get-ChildItem -LiteralPath $OutputRoot -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
[IO.File]::WriteAllLines((Join-Path $OutputRoot 'SHA256SUMS.txt'), [string[]]$hashes, [Text.UTF8Encoding]::new($false))
Write-Output "发布完成：$OutputRoot。未启动应用，界面、安装及手机定位由用户验收。"
