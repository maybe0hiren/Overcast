# Overcast Packaging & Client Deployment Guide

This directory contains the automated build, packaging, and one-command installer scripts for all Overcast targets:

```text
deployment/
├── backend/
│   └── package_backend.sh      # Packages Overcast-Backend.zip for Debian Docker setup
├── linux/
│   ├── package_linux.sh        # Builds Flutter Linux release & creates Overcast-Linux.zip
│   └── setup.sh                # One-command user installer included inside Overcast-Linux.zip
├── windows/
│   ├── package_windows.ps1     # Builds Flutter Windows release & creates Overcast-Windows.zip
│   └── setup.ps1               # One-command PowerShell installer included inside Overcast-Windows.zip
└── android/
    └── build.sh                # One-command Android release APK builder
```

All generated distribution artifacts are placed in `dist/`:
- `dist/backend/Overcast-Backend.zip`
- `dist/linux/Overcast-Linux.zip` (and `Overcast-Linux.tar.gz`)
- `dist/windows/Overcast-Windows.zip` (when built on Windows)
- `dist/android/Overcast-Android.apk`

---

## 1. Backend Packaging & Debian Installation

### Package the Backend
From the repository root:
```bash
./deployment/backend/package_backend.sh
```
Output: `dist/backend/Overcast-Backend.zip`

### Install on Debian
Transfer `Overcast-Backend.zip` to the Debian laptop, extract it, and run `./setup.sh`:
```bash
unzip Overcast-Backend.zip
cd Overcast-Backend
./setup.sh
```

---

## 2. Linux Desktop Client

### Build and Package
From the repository root on a Linux machine with Flutter installed:
```bash
./deployment/linux/package_linux.sh
```
Output: `dist/linux/Overcast-Linux.zip` (and `dist/linux/Overcast-Linux.tar.gz`).

### Install on Target Linux Machine (No Flutter Required)
Transfer `Overcast-Linux.zip` to any Linux desktop, extract it, and run `./setup.sh`:
```bash
unzip Overcast-Linux.zip
cd Overcast-Linux
./setup.sh
```
What `setup.sh` does:
- Checks/installs required GTK3 runtime libraries.
- Installs the complete Flutter Linux bundle to `~/.local/share/Overcast`.
- Creates the CLI launcher at `~/.local/bin/overcast`.
- Installs the application icon and creates a desktop entry at `~/.local/share/applications/overcast.desktop`.

---

## 3. Windows Desktop Client

### Build and Package (on Windows)
On a Windows machine with Flutter installed, run PowerShell from the repository root:
```powershell
powershell -ExecutionPolicy Bypass -File .\deployment\windows\package_windows.ps1
```
Output: `dist\windows\Overcast-Windows.zip` (contains the full `Release\` directory with all required `.dll` and `data\` files plus `setup.ps1`).

### Install on Target Windows Machine (No Flutter Required)
1. Extract `Overcast-Windows.zip`.
2. Open PowerShell in the extracted `Overcast-Windows` folder and run:
```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```
What `setup.ps1` does:
- Checks for the Visual C++ Runtime (`vcruntime140.dll`) and installs it via `winget` if missing.
- Copies all Flutter runtime files and DLLs to `%LOCALAPPDATA%\Programs\Overcast`.
- Creates a **Start Menu** shortcut (`Overcast.lnk`) and a **Desktop** shortcut (`Overcast.lnk`).
- Safely stops any running instance before upgrading files.

---

## 4. Android Mobile Client

### Build the Release APK
From the repository root:
```bash
./deployment/android/build.sh
```
Output: `dist/android/Overcast-Android.apk` (also copied to `~/Documents/Cache/temp/Overcast/Overcast-Android.apk`).

Install `Overcast-Android.apk` on any Android device connected to the same LAN as your Overcast server.

