param(
    [Parameter(Mandatory)][ValidateSet('android', 'windows-x64')][string]$Platform,
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][int]$BuildNumber,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $BuildNumber -le 0) { throw '版本号或构建号无效。' }
$inputFile = Get-Item -LiteralPath $Package
if ($inputFile.PSIsContainer -or $inputFile.Length -le 0) { throw '请指定完整的 APK 或 Windows 更新 ZIP。' }
$fileName = if ($Platform -eq 'android') { 'sxloc-android.apk' } else { 'sxloc-windows-x64.zip' }
$extension = if ($Platform -eq 'android') { '.apk' } else { '.zip' }
if ($inputFile.Extension -ne $extension) { throw "此平台需要 $extension 文件。" }
if (Test-Path -LiteralPath $OutputDirectory) { throw '请指定不存在的新目录，避免覆盖已准备的版本。' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$outputFile = Join-Path $OutputDirectory $fileName
Copy-Item -LiteralPath $inputFile.FullName -Destination $outputFile
$manifest = @{
    schemaVersion = 1; platform = $Platform; version = $Version; buildNumber = $BuildNumber
    fileName = $fileName; size = $inputFile.Length
    sha256 = (Get-FileHash -LiteralPath $outputFile -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'sxloc-update.json'), ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$prefix = if ($Platform -eq 'android') { 'android' } else { 'windows' }
Write-Output "已准备更新文件。对应 Release 标签：$prefix-v$Version+$BuildNumber。尚未上传或发布。"
