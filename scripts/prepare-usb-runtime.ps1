param(
    [string]$BuildRoot = "$env:SystemDrive\SuixingLocBuild",
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$lock = Join-Path $sourceRoot 'Bridge\UsbWorker\requirements.lock'
$fingerprint = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()
$runtime = Join-Path $BuildRoot ('usb-runtime-11.55.0-' + $fingerprint.Substring(0, 12))
$marker = Join-Path $runtime 'runtime-lock.sha256'
if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $fingerprint) {
    foreach ($file in @('python.exe', 'python314.dll', 'python314._pth', 'Lib\site-packages\pymobiledevice3\__init__.py')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $file))) { throw "USB 运行时缓存不完整：$file" }
    }
    Write-Output $runtime
    return
}
$pythonCommand = (Get-Command $Python -ErrorAction Stop).Source
& $pythonCommand -c 'import sys; assert sys.version_info[:2] == (3, 14), "Build requires Python 3.14"'
if ($LASTEXITCODE -ne 0) { throw '准备 USB 运行时需要 Python 3.14 x64 及 pip。成品无需用户安装 Python。' }
New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
$archive = Join-Path $BuildRoot 'python-3.14.7-embed-amd64.zip'
$expected = 'd297e5ff019966817ad8502465176139f2d3d840fa4ed84b13bed399a6ab1f15'
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-amd64.zip' -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Python 官方嵌入式运行时 SHA256 校验失败。'
}
$wheels = Join-Path $BuildRoot 'usb-wheels-11.55.0'
New-Item -ItemType Directory -Path $wheels -Force | Out-Null
& $pythonCommand -m pip download --only-binary=:all: --no-deps --require-hashes -r $lock --dest $wheels 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'USB 依赖下载或哈希校验失败。' }
$temporary = Join-Path $BuildRoot ('usb-prepare-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Expand-Archive -LiteralPath $archive -DestinationPath $temporary
& $pythonCommand -m pip install --no-index --find-links $wheels --require-hashes --no-deps -r $lock --target (Join-Path $temporary 'Lib\site-packages') --no-compile --no-warn-script-location 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'USB 依赖安装失败。' }
[IO.File]::WriteAllLines((Join-Path $temporary 'python314._pth'), [string[]]@('python314.zip', '.', 'Lib/site-packages', 'import site'), [Text.Encoding]::ASCII)
& (Join-Path $temporary 'python.exe') -c 'import win32api; from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel; from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation; from pymobiledevice3.services.simulate_location import DtSimulateLocation' 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'USB 独立运行时导入检查失败。' }
Copy-Item -LiteralPath $lock -Destination (Join-Path $temporary 'requirements.lock')
[IO.File]::WriteAllText((Join-Path $temporary 'runtime-lock.sha256'), $fingerprint, [Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $runtime) { throw "发现不完整的旧缓存，请检查后手动移开该目录：$runtime" }
Move-Item -LiteralPath $temporary -Destination $runtime
Write-Output $runtime
