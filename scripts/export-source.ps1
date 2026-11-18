param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$Revision = 'HEAD'
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
if (Test-Path -LiteralPath $Destination) { throw '源码附件已经存在，请指定新的输出路径。' }
$commit = & git -C $sourceRoot rev-parse --verify "$Revision^{commit}"
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw '源码提交无效。' }
$paths = & git -C $sourceRoot ls-tree -r --name-only $commit
if ($LASTEXITCODE -ne 0) { throw '无法读取源码清单。' }
foreach ($path in $paths) {
    $name = ($path -split '/')[-1]
    if ($path -match '(^|/)(node_modules|\.git|\.dart_tool|cms-secrets|cms-state|cms-uploads|cms-published|download-state|pair_records|pairing_records|Private|secrets|identity)(/|$)' `
        -or ($name -match '^\.env($|\.)' -and $name -ne '.env.example') `
        -or $name -match '\.(pk8|p7b|dpapi|pem|p12|pfx|jks|keystore|sqlite3?|db|apk|exe|dll|zip|bak)$' `
        -or $name -in @('desktop.json', 'iap2loc.json', 'settings.json', 'favorites.json', 'local.properties', 'key.properties', 'runtime.env')) {
        throw '源码清单含本机资料或构建产物，已停止归档。'
    }
}
& git -C $sourceRoot archive --format=zip --prefix=iap2loc-main/ "--output=$Destination" $commit
if ($LASTEXITCODE -ne 0) { throw '源码归档失败。' }
Write-Output "源码归档完成：$commit"
