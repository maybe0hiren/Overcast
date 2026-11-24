<#
.SYNOPSIS
    Overcast Windows Client - One-Command User-Level Installer (setup.ps1)

.DESCRIPTION
    Installs the self-contained Overcast Windows desktop release into:
      %LOCALAPPDATA%\Programs\Overcast
    Creates a Start Menu shortcut and an optional Desktop shortcut.
    Safe to re-run for upgrades or reinstallation.
#>

[CmdletBinding()]
param(
    [switch]$NoDesktopShortcut,
    [switch]$LaunchAfterInstall
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "                OVERCAST WINDOWS CLIENT INSTALLER                     " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Locate release directory containing flutter_windows.dll and data\
$CandidateDirs = @(
    (Join-Path $ScriptDir "Release"),
    (Join-Path $ScriptDir "Overcast"),
    $ScriptDir,
    (Join-Path $ScriptDir "..\..\frontend\build\windows\x64\runner\Release")
)

$SourceDir = $null
foreach ($Dir in $CandidateDirs) {
    if ((Test-Path (Join-Path $Dir "flutter_windows.dll")) -and (Test-Path (Join-Path $Dir "data"))) {
        $SourceDir = (Resolve-Path $Dir).Path
        break
    }
}

if (-not $SourceDir) {
    $LocalSourceFrontend = $null
    foreach ($CandFrontend in @(
        (Join-Path $ScriptDir "frontend"),
        (Join-Path $ScriptDir "..\..\frontend")
    )) {
        if (Test-Path (Join-Path $CandFrontend "pubspec.yaml")) {
            $LocalSourceFrontend = (Resolve-Path $CandFrontend).Path
            break
        }
    }

    if ($LocalSourceFrontend -and (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Host "Pre-built Windows binary not found; building Windows release with Flutter..." -ForegroundColor Yellow
        Push-Location $LocalSourceFrontend
        try {
            flutter pub get
            flutter build windows --release
        } finally {
            Pop-Location
        }
        $BuiltDir = Join-Path $LocalSourceFrontend "build\windows\x64\runner\Release"
        if (Test-Path (Join-Path $BuiltDir "flutter_windows.dll")) {
            $SourceDir = (Resolve-Path $BuiltDir).Path
        }
    }
}

if (-not $SourceDir) {
    Write-Error "Could not locate Overcast Windows runtime files (flutter_windows.dll and data/). If you packaged Overcast-Windows-Source.zip from Linux, make sure Flutter is installed on Windows or run deployment\windows\package_windows.ps1 first."
    exit 1
}

$ExeName = $null
foreach ($CandidateExe in @("overcast.exe", "frontend.exe")) {
    if (Test-Path (Join-Path $SourceDir $CandidateExe)) {
        $ExeName = $CandidateExe
        break
    }
}

if (-not $ExeName) {
    Write-Error "Could not find overcast.exe or frontend.exe in $SourceDir"
    exit 1
}

# Check Visual C++ Runtime DLL availability
$Sys32 = [Environment]::GetFolderPath("System")
$VcRuntime = Join-Path $Sys32 "vcruntime140.dll"
if (-not (Test-Path $VcRuntime)) {
    Write-Warning "Microsoft Visual C++ Redistributable (vcruntime140.dll) was not detected in System32."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing Microsoft Visual C++ Redistributable via winget..." -ForegroundColor Yellow
        winget install --id Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Warning "If Overcast fails to start, install the Microsoft Visual C++ 2015-2022 Redistributable (x64)."
    }
}

$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\Overcast"

# Stop running Overcast process if upgrading
$ProcBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
Get-Process -Name $ProcBaseName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "overcast" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "Installing Overcast runtime files to: $InstallDir" -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item -Path (Join-Path $SourceDir "*") -Destination $InstallDir -Recurse -Force

# Normalize executable name so Overcast.exe is always available
$InstalledExe = Join-Path $InstallDir "Overcast.exe"
$OriginalInstalledExe = Join-Path $InstallDir $ExeName
if ($ExeName -ne "Overcast.exe" -and (Test-Path $OriginalInstalledExe)) {
    Copy-Item -Path $OriginalInstalledExe -Destination $InstalledExe -Force
}

# Create Start Menu & Desktop shortcuts
$WshShell = New-Object -ComObject WScript.Shell

$StartMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$StartMenuShortcutPath = Join-Path $StartMenuDir "Overcast.lnk"
$StartShortcut = $WshShell.CreateShortcut($StartMenuShortcutPath)
$StartShortcut.TargetPath = $InstalledExe
$StartShortcut.WorkingDirectory = $InstallDir
$StartShortcut.Description = "Overcast LAN Cloud Storage Client"
$StartShortcut.IconLocation = "$InstalledExe,0"
$StartShortcut.Save()
Write-Host "[OK] Created Start Menu shortcut: $StartMenuShortcutPath" -ForegroundColor Green

if (-not $NoDesktopShortcut) {
    $DesktopDir = [Environment]::GetFolderPath("Desktop")
    $DesktopShortcutPath = Join-Path $DesktopDir "Overcast.lnk"
    $DesktopShortcut = $WshShell.CreateShortcut($DesktopShortcutPath)
    $DesktopShortcut.TargetPath = $InstalledExe
    $DesktopShortcut.WorkingDirectory = $InstallDir
    $DesktopShortcut.Description = "Overcast LAN Cloud Storage Client"
    $DesktopShortcut.IconLocation = "$InstalledExe,0"
    $DesktopShortcut.Save()
    Write-Host "[OK] Created Desktop shortcut: $DesktopShortcutPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "          OVERCAST WINDOWS CLIENT INSTALLATION COMPLETE               " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  Installed Location: $InstalledExe"
Write-Host "  Launch Overcast from the Start Menu or Desktop shortcut."
Write-Host "======================================================================" -ForegroundColor Green

if ($LaunchAfterInstall) {
    Start-Process -FilePath $InstalledExe -WorkingDirectory $InstallDir
}

