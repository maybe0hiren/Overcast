# Overcast

**Overcast** is a private, self-hosted, LAN-based cloud storage system that turns a Debian/Linux machine into a personal file server with cross-platform clients for **Linux**, **Windows**, and **Android**.

---

## Key Features

### Storage & File Management
- **Browse & Search:** Navigate virtual folders, search files and directories, and toggle between Grid and List layouts.
- **Chunked File Uploads:** Large files are automatically split into **4 MiB chunks** (`CHUNK_UPLOAD_SIZE`), uploaded sequentially with per-chunk SHA-256 validation, automatic chunk-level retry on transient failures, session resume support, and atomic server-side assembly with full-file SHA-256 verification.
- **Non-Blocking Background Transfer Manager:** All uploads, downloads, and bulk ZIP downloads run asynchronously in the background. Users can browse directories, preview media, edit text files, create folders, and manage files while large transfers are in progress.
- **Upload & Download Cancellation:** Individual active or queued transfers can be cancelled at any time. Cancelling an upload aborts the network request, notifies the backend (`DELETE /api/uploads/<uploadID>`), and purges temporary chunk files. Cancelling a download aborts the stream and removes the partial `.overcast.part` file.
- **Desktop Multi-File Selection:**
  - **Single Click / Checkmark:** Select an item.
  - **Ctrl + Click (or Cmd + Click):** Toggle individual files or folders in the selection.
  - **Shift + Click:** Select a contiguous range of files/folders.
  - **Rubber-Band Drag Selection:** Click and drag across the file grid or list to draw a visual selection rectangle and select all intersecting items in real time.
  - **Keyboard Shortcuts:** `Ctrl + A` (Select All), `Escape` (Clear Selection), `Delete` (Bulk Delete selected items).
- **Mobile Multi-File Selection:**
  - **Long Press:** Enter selection mode and select the item.
  - **Tap:** Toggle additional files and folders while in selection mode.
- **Bulk File Operations:**
  - **Bulk Download (Streaming ZIP):** Packages all selected files and folders into a ZIP archive on disk on the backend (without loading files into RAM), streams it to the client through the background transfer manager, and automatically cleans up temporary server ZIP files upon completion or cancellation.
  - **Bulk Delete:** Moves all selected files and folders (including folder descendants) to Trash (or permanently deletes selected items from Trash) with confirmation and partial-failure reporting.
- **Built-in Media & Text Tools:**
  - In-app text file creation and code/text editor.
  - Inline image viewer, HTTP `Range`-enabled video player, and audio player.
  - Trash management with one-click restore or permanent deletion.
  - Obfuscated file-sharing links (`/sharing/<encoded>.file`).

---

## Architecture

```text
                        HOME / LAN NETWORK
                                |
          +---------------------+---------------------+
          |                     |                     |
          v                     v                     v
    Linux Desktop        Windows Desktop        Android Mobile
    Flutter Client       Flutter Client         Flutter Client
          |                     |                     |
          +---------------------+---------------------+
                                |
                                | HTTP REST API (Chunked Uploads,
                                | Range Streams, Bulk ZIP Streams)
                                v
               +---------------------------------+
               |     Debian Homelab Server       |
               |                                 |
               |  Docker Engine (auto-restart)   |
               |  +---------------------------+  |
               |  | overcast-backend          |  |
               |  | Gunicorn + Flask (Python) |  |
               |  +-------------+-------------+  |
               |                |                |
               |     Persistent Bind Mounts      |
               |      (./data/ on host OS)       |
               |     /          |          \     |
               |    v           v           v    |
               | SQLite     Permanent     Temp   |
               | (WAL)       Storage    Chunks & |
               |   DB        (Files)      ZIPs   |
               +---------------------------------+
```

---

## Repository Structure

```text
Overcast/
├── backend/
│   ├── main.py                      # Flask REST API, chunked uploads, bulk ZIP/delete
│   ├── run.py                       # Direct Python entrypoint
│   ├── requirements.txt             # Python dependencies (Flask, Gunicorn, Werkzeug, dotenv)
│   ├── Dockerfile                   # Debian Bookworm Python 3.12 container definition
│   ├── docker-compose.yml           # Docker Compose service & persistent volume mappings
│   ├── .env.example                 # Default environment configuration
│   ├── .dockerignore                # Docker build context exclusions
│   ├── setup.sh                     # One-command Debian Docker installer & manager
│   ├── README.md                    # Backend deployment & API documentation
│   ├── database/
│   │   ├── dbHandlers.py            # SQLite handlers (Files, Trash, UploadSessions, UploadChunks)
│   │   └── dbTrashHandlers.py       # Trash table helpers
│   ├── functions/
│   │   ├── previewHandlers.py       # Preview lookup helpers
│   │   ├── stringPlay.py            # SHA-256 UID generation & share link encoding
│   │   ├── textFileHandlers.py      # Atomic text file read/write utilities
│   │   └── trashHandeling.py        # Soft-delete and restore wrappers
│   └── tests/
│       └── test_overcast_backend.py # Automated backend test suite
│
├── frontend/
│   ├── pubspec.yaml                 # Flutter project manifest
│   ├── build_overcast.sh            # Master build script for Backend, Linux, and Android
│   ├── lib/
│   │   ├── main.dart                # Overcast UI, multi-selection, drag-select, transfer panel
│   │   ├── api.dart                 # HTTP/Dio client for standard, chunked, and bulk APIs
│   │   ├── models.dart              # Data models (OvercastFile, UploadSessionInfo, etc.)
│   │   └── transfer_manager.dart    # Non-blocking background transfer queue & chunk uploader
│   ├── test/
│   │   └── widget_test.dart         # Unit and integration tests for models & TransferManager
│   ├── linux/                       # Linux desktop runner
│   ├── windows/                     # Windows desktop runner
│   └── android/                     # Android mobile runner
│
├── deployment/
│   ├── README.md                    # Packaging & cross-platform installer guide
│   ├── backend/
│   │   └── package_backend.sh       # Creates dist/backend/Overcast-Backend.zip
│   ├── linux/
│   │   ├── package_linux.sh         # Builds Linux client & creates dist/linux/Overcast-Linux.zip
│   │   └── setup.sh                 # One-command Linux client installer
│   ├── windows/
│   │   ├── package_windows.ps1      # Builds Windows client & creates dist/windows/Overcast-Windows.zip
│   │   └── setup.ps1                # One-command Windows PowerShell client installer
│   └── android/
│       └── build.sh                 # One-command Android release APK builder
│
├── dist/                            # Generated release packages (Backend, Linux, Windows, Android)
├── TESTING_REPORT.md                # Comprehensive verification and test report
└── README.md
```

---

## Exact Usage & Deployment Instructions

### 1. Packaging the Backend

From the repository root:

```bash
./deployment/backend/package_backend.sh
```

This creates:
- `dist/backend/Overcast-Backend.zip`
- `dist/backend/Overcast-Backend.tar.gz`

### 2. Installing the Backend on Debian (One Command)

Transfer `dist/backend/Overcast-Backend.zip` to your Debian laptop, extract it, and run `./setup.sh`:

```bash
unzip Overcast-Backend.zip
cd Overcast-Backend
./setup.sh
```

What `./setup.sh` does automatically:
1. Detects Debian/Ubuntu and installs any missing system utilities (`curl`, `iproute2`, `sqlite3`).
2. Installs **Docker Engine** and the **Docker Compose plugin** if not already installed.
3. Enables the Docker service in `systemd` so Overcast starts automatically after every reboot.
4. Creates `.env` from `.env.example` (preserving any existing `.env` on re-runs).
5. Prepares persistent host directories under `./data/` (`storage/`, `database/`, `preview/`, `temp/`) and migrates any existing legacy files/SQLite DB if found.
6. Builds and starts the `overcast-backend` container with `restart: unless-stopped`.
7. Verifies `/api/health` and prints the Debian server's LAN IP address and connection URLs.

### 3. Starting, Stopping, Updating & Viewing Logs of the Backend

From inside the extracted `Overcast-Backend/` (or `backend/`) directory:

```bash
# Check container status, health check response, and LAN URLs
./setup.sh status

# Follow live backend container logs
./setup.sh logs

# Stop the backend container (all persistent files & database remain intact)
./setup.sh stop

# Start the backend container
./setup.sh start

# Restart the backend container
./setup.sh restart

# Rebuild image and update the container while preserving all persistent data
./setup.sh update
```

---

### 4. Building & Packaging the Linux Client

On a Linux machine with Flutter installed, run from the repository root:

```bash
./deployment/linux/package_linux.sh
```

This runs `flutter pub get`, `flutter analyze`, `flutter test`, builds the Linux release bundle (`flutter build linux --release`), and packages it with the Linux installer script into:
- `dist/linux/Overcast-Linux.zip`
- `dist/linux/Overcast-Linux.tar.gz`

### 5. Installing the Linux Client (No Flutter Required)

Transfer `dist/linux/Overcast-Linux.zip` to any Linux desktop machine, extract it, and run `./setup.sh`:

```bash
unzip Overcast-Linux.zip
cd Overcast-Linux
./setup.sh
```

This installs the self-contained bundle into `~/.local/share/Overcast`, creates the desktop entry at `~/.local/share/applications/overcast.desktop`, installs the app icon, and creates the CLI launcher at `~/.local/bin/overcast`.

---

### 6. Building & Packaging the Windows Client

On a Windows machine with Flutter installed, run PowerShell from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\deployment\windows\package_windows.ps1
```

This runs `flutter pub get`, `flutter analyze`, `flutter build windows --release`, and packages the complete `build\windows\x64\runner\Release\` directory (executable, `flutter_windows.dll`, plugin DLLs, `data\`) together with `setup.ps1` into:
- `dist\windows\Overcast-Windows.zip`

### 7. Installing the Windows Client (No Flutter Required)

Transfer `Overcast-Windows.zip` to any Windows 10/11 machine, extract it, open PowerShell in the extracted folder, and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

This installs all runtime files into `%LOCALAPPDATA%\Programs\Overcast`, verifies the Visual C++ runtime, and creates both **Start Menu** and **Desktop** shortcuts (`Overcast.lnk`).

---

### 8. Building the Android Release APK

On a machine with Flutter and the Android SDK installed, run from the repository root:

```bash
./deployment/android/build.sh
```

This verifies the Flutter and Android SDKs, resolves dependencies, runs `flutter analyze`, builds the release APK (`flutter build apk --release`), and places the installable APK at:
- `dist/android/Overcast-Android.apk`

---

## Chunked Upload & Bulk Operations Protocol Summary

### Chunked Upload Flow
1. **Initialize Session (`POST /api/uploads/init`):**
   - Client sends `fileName`, `filePath`, `totalSize`, `chunkSize` (default `4194304` bytes / 4 MiB), `totalChunks`, and `resume: true`.
   - Backend validates path traversal rules, disk space (requiring at least 512 MiB free buffer), and active session limits, then creates a session in SQLite `UploadSessions` and a dedicated chunk directory in `TEMP_STORAGE/chunks/<uploadId>`.
   - Returns `uploadId` (32-character hex token), `receivedChunks`, and `missingChunks`.
2. **Upload Individual Chunks (`PUT /api/uploads/<uploadId>/chunks/<chunkIndex>`):**
   - Client reads one 4 MiB chunk at a time via `RandomAccessFile` without loading the entire file into memory.
   - Backend validates `0 <= chunkIndex < totalChunks`, verifies exact expected byte length and optional `X-Chunk-SHA256`, writes to a temporary file, fsyncs, and atomically replaces `chunk_<index>.part` via `os.replace()`.
   - Failed chunks are retried automatically up to 4 times with exponential backoff and status verification (`GET /api/uploads/<uploadId>`).
3. **Finalize & Assemble (`POST /api/uploads/<uploadId>/complete`):**
   - Backend verifies all expected chunks exist on disk with exact byte sizes.
   - Streams all chunks in order into a temporary assembled file while calculating the full SHA-256 digest and checking for mid-assembly cancellation.
   - Verifies final byte size and SHA-256 checksum, atomically moves the completed file into `STORAGE/<UID>.<format>`, inserts the record into SQLite `Files`, and deletes the temporary chunk directory.
4. **Cancel Upload (`DELETE /api/uploads/<uploadId>`):**
   - Marks the session as `cancelled`, aborts assembly if in progress, and deletes all temporary chunks so no partial file ever enters user storage.

### Bulk Operations
- **Bulk Download (`POST /api/files/bulk-download`):** Accepts `fileIds`, `folderPaths`, `basePath`, and `archiveName`. Streams selected files and recursive folder contents into a temporary ZIP on disk in 8 MiB chunks (with ZipSlip path sanitization), streams the ZIP back with `Content-Length`, and deletes the temporary ZIP file immediately in a `finally:` block when the stream finishes or is cancelled.
- **Bulk Delete (`POST /api/files/bulk-delete`):** Accepts `fileIds`, `folderPaths`, and `permanent`. Expands folders to all descendant files and moves items to Trash (or permanently deletes from Trash if `permanent: true`), returning `deletedCount`, `succeeded`, and `failed`.

---

## Android Background Execution Notes

- On Android, transfers run asynchronously inside the Dart event loop via `TransferManager` while the application is in the foreground or briefly backgrounded.
- `OvercastHome` registers a `WidgetsBindingObserver` (`didChangeAppLifecycleState`) to notify `TransferManager` when the app transitions between `paused` and `resumed`.
- Because modern Android versions (Android 12+) restrict indefinite background socket execution for standard activities when the screen is off or the app is swiped away, if the Android OS suspends network sockets during a very large multi-gigabyte upload, the upload session remains persisted on the Overcast backend (`UploadSessions` table + verified `.part` chunks on disk for 24 hours). When the user reopens the app and taps **Retry** in the Transfer Panel, Overcast automatically queries `POST /api/uploads/init` with `resume: true` and resumes from the last completed chunk without re-uploading earlier chunks.
