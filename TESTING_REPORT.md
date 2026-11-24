# Overcast Upgrade – Comprehensive Testing & Verification Report

## 1. Executive Summary

This report documents the automated unit, integration, build, and packaging tests executed against the upgraded **Overcast** system, as well as clearly identifying which platform/hardware deployment tests require physical target hardware (Debian host reboot, Windows OS machine, and physical Android device).

---

## 2. Backend Automated Test Suite (`backend/tests/test_overcast_backend.py`)

Command executed:
```bash
./backend/env/bin/python ./backend/tests/test_overcast_backend.py
```

### Test Cases & Results (8 / 8 Passed)

| Test ID | Feature Tested | Verification Details | Result |
| :--- | :--- | :--- | :--- |
| `test_01_health_and_storage` | `/api/health` & `/api/storage` | Verified database initialization, storage directory check, chunk upload configuration output, and disk usage reporting. | **PASSED** |
| `test_02_small_file_upload_and_download` | Single-request small file upload & download | Uploaded small file to `home/docs/readme.txt` via `POST /api/files/upload`, verified SHA-256 calculation, size, and byte-exact download via `GET /api/files/<UID>/download`. | **PASSED** |
| `test_03_chunked_upload_multi_chunk_and_integrity` | Multi-chunk upload, out-of-order upload, ordered assembly & SHA-256 verification | Divided a 700 KiB random binary payload into 3 chunks (`256 KiB`, `256 KiB`, `188 KiB`), initialized session (`POST /api/uploads/init`), uploaded chunks out-of-order (`2, 0, 1`) with `X-Chunk-SHA256` verification, checked `GET /api/uploads/<id>`, finalized via `POST /api/uploads/<id>/complete`, verified temp chunk directory cleanup and byte-for-byte SHA-256 match on download. | **PASSED** |
| `test_04_missing_chunk_detection_and_duplicate_chunk_safety` | Duplicate chunk retry, missing chunk detection, and session resume | Uploaded chunk `0` twice to verify atomic replacement without corruption. Called `/complete` while chunks `1` and `2` were missing and confirmed `400 Bad Request` with `"missingChunks": [1, 2]`. Resumed session via `POST /api/uploads/init` (`resume: true`), confirmed `receivedChunks: [0]`, uploaded remaining chunks, and finalized cleanly. | **PASSED** |
| `test_05_upload_cancellation_cleans_up_and_prevents_partial_file` | Upload cancellation (`DELETE /api/uploads/<id>`) | Started multi-chunk upload, uploaded chunk `0`, then cancelled via `DELETE /api/uploads/<id>`. Verified temporary chunk directory was deleted, `STORAGE` contained 0 files, `Files` table was empty, and subsequent chunk uploads returned `404`. | **PASSED** |
| `test_06_security_validations` | Path traversal, uploadId manipulation, out-of-bounds chunk index, size & checksum tampering | Confirmed `400`/`404` rejections on `home/../../etc/` path traversal, invalid `uploadId` strings, out-of-range `chunkIndex`, wrong chunk byte size, and mismatched `X-Chunk-SHA256`. | **PASSED** |
| `test_07_bulk_download_zip_and_bulk_delete` | Bulk ZIP download & Bulk Delete (Trash + Permanent) | Uploaded files across `home/` and `home/Projects/`. Requested `POST /api/files/bulk-download` with multiple files and a folder, verified valid streamed ZIP contents and relative paths (`alpha.txt`, `beta.txt`, `Projects/code.py`), and verified immediate cleanup of `TEMP_STORAGE/zips/`. Executed `POST /api/files/bulk-delete` to move selected files and folder descendants to Trash, then permanently deleted from Trash (`permanent: true`). | **PASSED** |
| `test_08_abandoned_upload_cleanup_policy` | Abandoned upload session TTL cleanup | Created an upload session, backdated `UpdatedAt` beyond `UPLOAD_SESSION_TTL_SECONDS`, invoked `cleanupAbandonedTempFiles()`, and verified both on-disk chunks and SQLite session rows were purged. | **PASSED** |

---

## 3. Frontend Analyzer, Unit & Integration Tests (`frontend/test/widget_test.dart`)

Commands executed:
```bash
cd frontend
flutter analyze
flutter test
```

### Results
- **`flutter analyze`**: `No issues found!` (0 errors, 0 warnings, 0 lints).
- **`flutter test`** (`3 / 3 Passed`):
  1. **Model Serialization (`OvercastFile`, `UploadSessionInfo`, `BulkDeleteResult`)**: Verified JSON parsing of file metadata, chunked upload session state (`receivedChunks`, `missingChunks`, `resumed`), and bulk delete summaries. (**PASSED**)
  2. **End-to-End Multi-Chunk Upload with Automatic Chunk Retry (`TransferManager`)**: Spun up an embedded local HTTP server simulating the Overcast chunked upload endpoints, forced chunk `1` to fail with HTTP `500` on its first attempt, and verified that `TransferManager` automatically queried session status, retried only the failed chunk without restarting chunk `0`, completed chunk `2`, finalized the upload, and reached `TransferState.completed` (`progress == 1.0`). (**PASSED**)
  3. **Download Cancellation & Partial File Cleanup (`TransferManager`)**: Enqueued a background download, cancelled it via `cancelTransfer()`, and verified immediate transition to `TransferState.cancelled`, token cancellation, and queue cleanup. (**PASSED**)

---

## 4. Multi-Selection & Responsiveness Verification

- **Desktop Multi-Selection (`frontend/lib/main.dart`)**:
  - **Single Click / Checkmark**: Selects individual file or folder card; double-click opens the file or enters the folder.
  - **Ctrl + Click**: Toggles clicked file or folder in `_selectedKeys`.
  - **Shift + Click**: Selects contiguous range between `_lastSelectedKey` and current item across both folders and files.
  - **Rubber-Band Drag Selection**: Dragging across the Grid or List view renders a translucent selection box and selects all cards whose `RenderBox` bounds intersect the drag rectangle in real time.
  - **Keyboard Shortcuts**: `Ctrl + A` selects all items in current directory; `Escape` clears selection; `Delete` triggers bulk delete confirmation.
- **Mobile Multi-Selection (`frontend/lib/main.dart`)**:
  - **Long Press**: Enters `_mobileSelectionMode` and selects the item.
  - **Tap in Selection Mode**: Toggles additional items and exits selection mode automatically when the last item is deselected.
- **Non-Blocking Responsiveness (`frontend/lib/transfer_manager.dart`)**:
  - Blocking modal `AlertDialog` progress popups were removed and replaced with a floating, minimizable/closable **Transfers Panel** and a top-bar live badge.
  - File reading uses asynchronous `RandomAccessFile` chunk slices (`4 MiB`) and UI notifications are throttled to `~110ms` intervals so directory navigation, previews, search, and text editing remain responsive during large transfers.

---

## 5. Build, Packaging & Deployment Verification

| Target | Build / Package Script | Verification Status | Output Artifact |
| :--- | :--- | :--- | :--- |
| **Docker Backend Package** | `./deployment/backend/package_backend.sh` | **VERIFIED** — Validated `setup.sh`, `Dockerfile`, `docker-compose.yml`, `.env.example`, and packaged archive. | `dist/backend/Overcast-Backend.zip` (`26 KB`) |
| **Linux Desktop Client** | `./deployment/linux/package_linux.sh` | **VERIFIED** — Built native Linux x64 release bundle via `flutter build linux --release` and packaged with `deployment/linux/setup.sh`. | `dist/linux/Overcast-Linux.zip` (`9.9 MB`) & `Overcast-Linux.tar.gz` (`9.9 MB`) |
| **Android Mobile Client** | `./deployment/android/build.sh` | **VERIFIED** — Built release APK via `flutter build apk --release`. | `dist/android/Overcast-Android.apk` |
| **Windows Desktop Client** | `.\deployment\windows\package_windows.ps1` | **SCRIPT VERIFIED / UNVERIFIED ON WINDOWS OS** — PowerShell build and installer scripts (`package_windows.ps1` and `setup.ps1`) are complete, but building and running the Windows `.exe` requires a Windows host machine. | Run `package_windows.ps1` on Windows to generate `dist\windows\Overcast-Windows.zip` |
| **Debian Host Reboot & Physical Android Device** | `./setup.sh` on Debian laptop & APK install on Android phone | **REQUIRES TARGET HARDWARE** — Docker `restart: unless-stopped` and `systemctl enable --now docker` are configured in `backend/setup.sh`; physical reboot test on the Debian homelab laptop and physical Android handset installation remain to be run on your hardware. | `dist/backend/Overcast-Backend.zip` & `dist/android/Overcast-Android.apk` |

