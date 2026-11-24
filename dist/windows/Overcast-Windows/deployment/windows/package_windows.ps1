<#
.SYNOPSIS
    Builds and packages the Overcast Windows release into dist\windows\Overcast-Windows.zip
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$FrontendDir = Join-Path $RootDir "frontend"
$DistDir = Join-Path $RootDir "dist\windows"
$StageDir = Join-Path $DistDir "Overcast-Windows"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter SDK is not in PATH. Please run this script on a Windows machine with Flutter installed."
    exit 1
}

Push-Location $FrontendDir
try {
    flutter pub get
    flutter analyze
    flutter build windows --release
} finally {
    Pop-Location
}

$ReleaseDir = Join-Path $FrontendDir "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $ReleaseDir "flutter_windows.dll"))) {
    Write-Error "Windows release output not found at $ReleaseDir"
    exit 1
}

if (Test-Path $StageDir) {
    Remove-Item -Path $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $StageDir "Release") -Force | Out-Null

Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination (Join-Path $StageDir "Release") -Recurse -Force
Copy-Item -Path (Join-Path $ScriptDir "setup.ps1") -Destination (Join-Path $StageDir "setup.ps1") -Force

$ReadmeContent = @"
OVERCAST WINDOWS CLIENT
=======================

Installation (No Flutter or development tools required):

1. Extract Overcast-Windows.zip to any folder.
2. Right-click setup.ps1 and choose "Run with PowerShell"
   (or open PowerShell in this folder and run:
    powershell -ExecutionPolicy Bypass -File .\setup.ps1)
3. Launch Overcast from your Start Menu or Desktop shortcut.
"@
Set-Content -Path (Join-Path $StageDir "README.txt") -Value $ReadmeContent -Encoding UTF8

$ZipPath = Join-Path $DistDir "Overcast-Windows.zip"
if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force
}
Compress-Archive -Path $StageDir -DestinationPath $ZipPath -Force

Write-Host "[OK] Created Windows distribution archive: $ZipPath" -ForegroundColor Green

