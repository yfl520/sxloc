param([string]$ApkPath)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$expected = '7d04db263834f22010a86847766928113d3503a273e4d2d3440d21552e173139'
if (-not $ApkPath) {
    $ApkPath = Join-Path ([IO.Path]::GetTempPath()) 'SuixingLoc-DiPlay-0.2.22.apk'
    if (-not (Test-Path -LiteralPath $ApkPath)) {
        Invoke-WebRequest 'https://github.com/shihabal3amri/DiPlay/releases/download/v0.2.22/DiPlay-0.2.22.apk' -OutFile $ApkPath
    }
}
if ((Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'APK 与固定的 DiPlay v0.2.22 官方发布哈希不符，已停止导入。其他 APK 可在应用设置中导入。'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$destination = Join-Path $taskRoot 'Desktop\Private'
[IO.Directory]::CreateDirectory($destination) | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ApkPath).Path)
try {
    foreach ($file in @('identity.pk8', 'certificate.p7b')) {
        $entry = $zip.GetEntry('assets/offline-mfi/' + $file)
        if (-not $entry -or $entry.Length -le 0 -or $entry.Length -gt 65536) { throw 'APK 身份材料缺失或格式异常' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $destination $file), $true)
    }
} finally { $zip.Dispose() }
Write-Output '已从校验通过的官方 APK 导入构建身份；材料不会写入日志。'
