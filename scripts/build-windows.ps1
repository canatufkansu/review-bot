# Builds the Windows app and packages it twice: as a zip (ReviewBot.exe, the Swift runtime
# DLLs it needs, and a version.txt the dashboard shows) and, when Inno Setup is installed, as
# a setup.exe built from Packaging\ReviewBot.iss. The Windows counterpart of build-app.sh.
#
#   pwsh scripts\build-windows.ps1              -> dist\ReviewBot-dev-windows-x64.zip
#                                                  dist\ReviewBot-dev-setup.exe
#   $env:APP_VERSION = 'v1.2.3'; pwsh scripts\build-windows.ps1
#
# The zip needs no installation: unzip anywhere and run ReviewBot.exe. The installer adds a
# Start-menu entry, an uninstaller and an optional start-at-sign-in task.

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

# The installer. Inno Setup ships on GitHub's Windows runners and installs with
# `winget install JRSoftware.InnoSetup`; without it the zip is still a complete build.
$iscc = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $iscc) {
    $candidate = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (Test-Path $candidate) { $iscc = $candidate }
}
if ($iscc) {
    $script = Join-Path $root 'Packaging\ReviewBot.iss'
    & $iscc /Q "/DAppVersion=$label" "/DSourceDir=$dist" "/DOutputDir=$(Join-Path $root 'dist')" $script
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
    Write-Host "Built: $(Join-Path $root "dist\ReviewBot-$label-setup.exe")"
} else {
    Write-Host "Inno Setup (ISCC.exe) not found; skipped the installer. winget install JRSoftware.InnoSetup"
}
Write-Host "Run the setup.exe, or unzip the zip anywhere and run ReviewBot.exe; it appears in the notification area."
