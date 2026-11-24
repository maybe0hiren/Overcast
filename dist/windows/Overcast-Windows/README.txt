OVERCAST WINDOWS CLIENT
=======================

1. Extract Overcast-Windows.zip on your Windows laptop.
2. Open PowerShell inside the extracted Overcast-Windows folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\setup.ps1

   - If pre-built Release\ binaries are present, setup.ps1 installs them immediately.
   - If transferred directly from Linux, setup.ps1 automatically runs
     `flutter build windows --release` and installs Overcast to:
     %LOCALAPPDATA%\Programs\Overcast\Overcast.exe
     with Start Menu and Desktop shortcuts.
