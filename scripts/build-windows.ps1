# Builds the Windows app and packages it as a zip: ReviewBot.exe, the Swift runtime DLLs it
# needs, and a version.txt the dashboard shows. The Windows counterpart of build-app.sh.
#
#   pwsh scripts\build-windows.ps1              -> dist\ReviewBot-dev-windows-x64.zip
#   $env:APP_VERSION = 'v1.2.3'; pwsh scripts\build-windows.ps1
#
# Unzip anywhere and run ReviewBot.exe. There is no installer: launch-at-login is a registry
# entry the app writes for itself, pointing at wherever the .exe is.

param([string]$Version = $env:APP_VERSION)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

swift build -c release --product ReviewBot
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build -c release --show-bin-path).Trim()

$dist = Join-Path $root 'dist\ReviewBot-windows'
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Path $dist | Out-Null
Copy-Item (Join-Path $bin 'ReviewBot.exe') $dist

# The Swift runtime. The toolchain installer puts it on Path (Program Files\Swift\Runtimes\
# <version>\usr\bin); a machine without the toolchain has none of it, so the zip carries the
# whole directory. Look on Path first, then in the default install location.
$runtime = $null
foreach ($dir in ($env:Path -split ';')) {
    if ($dir -and (Test-Path (Join-Path $dir 'swiftCore.dll'))) { $runtime = $dir; break }
}
if (-not $runtime) {
    $candidate = Get-ChildItem 'C:\Program Files\Swift\Runtimes\*\usr\bin' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { $runtime = $candidate.FullName }
}
if (-not $runtime) { throw "Could not find the Swift runtime (swiftCore.dll) on Path or under Program Files\Swift\Runtimes" }
Write-Host "Swift runtime: $runtime"
Get-ChildItem -Path $runtime -Filter '*.dll' | Copy-Item -Destination $dist

$clean = if ($Version) { $Version -replace '^v', '' } else { '' }
if ($clean) { Set-Content -Path (Join-Path $dist 'version.txt') -Value $clean -NoNewline }

$label = if ($clean) { $clean } else { 'dev' }
$zip = Join-Path $root "dist\ReviewBot-$label-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip

Write-Host "Built: $zip"
Write-Host "Unzip it anywhere and run ReviewBot.exe; it appears in the notification area."
