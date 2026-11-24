# Overcast Backend (Docker Edition)

Overcast Backend is the self-hosted Python + Flask + Gunicorn + SQLite server that powers the Overcast LAN cloud storage system.

It is packaged for **one-command Docker deployment** on Debian/Ubuntu Linux while preserving full backward compatibility with existing Overcast SQLite databases and stored user files.

---

## Directory Contents

- `main.py` — Flask REST API including chunked upload protocol, range streaming, bulk ZIP download, bulk delete, text editor API, and trash management.
- `run.py` — Development runner entrypoint.
- `database/dbHandlers.py` & `database/dbTrashHandlers.py` — SQLite (WAL mode) persistence layer for `Files`, `Trash`, `UploadSessions`, and `UploadChunks`.
- `functions/` — File UID hashing, share-link encoding, text file atomic writers, preview handlers, and trash utilities.
- `Dockerfile` — Production container image (`python:3.12-slim-bookworm` + Gunicorn).
- `docker-compose.yml` — Container orchestration with persistent bind mounts and automatic restart policy (`unless-stopped`).
- `.env.example` — Configurable environment variables (ports, chunk sizes, upload limits, worker threads).
- `setup.sh` — Idempotent one-command installer and runtime lifecycle manager.
- `tests/test_overcast_backend.py` — Automated backend test suite.

---

## One-Command Installation on Debian

1. Extract `Overcast-Backend.zip` (or copy the `backend/` folder) onto your Debian machine.
2. Run:

```bash
./setup.sh
```

`setup.sh` automatically:
1. Detects the Debian environment and installs any missing system utilities (`curl`, `iproute2`, `sqlite3`).
2. Installs **Docker Engine** and the **Docker Compose plugin** if not already present.
3. Enables the Docker daemon in `systemd` so the Overcast container starts automatically after every reboot.
4. Creates `.env` from `.env.example` (preserving any existing `.env` on subsequent runs).
5. Prepares persistent host directories under `./data/`:
   - `./data/storage` — Permanent user files (`<UniqueID>.<format>`)
   - `./data/database` — SQLite database (`database.db` in WAL mode)
   - `./data/preview` — File previews
   - `./data/temp` — Temporary upload chunks (`chunks/`) and bulk ZIP staging (`zips/`)
6. Migrates any existing non-Docker Overcast files or database from `./storage`, `./database/database.db`, or `/opt/overcast` if `./data` is empty.
7. Builds the Docker image and launches the `overcast-backend` container.
8. Verifies `GET /api/health` returns `"status": "ok"`.
9. Detects and displays the Debian server's LAN IP address and connection URLs.

---

## Runtime Management Commands

All runtime actions are managed through `./setup.sh`:

```bash
./setup.sh            # Initial install or idempotent upgrade
./setup.sh status     # Show container state, health check, and LAN URLs
./setup.sh start      # Start the Overcast backend container
./setup.sh stop       # Stop the Overcast backend container (data is preserved)
./setup.sh restart    # Restart the Overcast backend container
./setup.sh logs       # Tail live Gunicorn/Flask container logs
./setup.sh update     # Rebuild Docker image and restart container without data loss
```

> **Data Safety Note:** User files and the SQLite database live on the host under `./data/` via Docker bind mounts. Rebuilding or restarting the container never deletes user files.

---

## REST API Reference

### System & Health
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/health` | Returns `status` (`ok`/`degraded`), `database`, `storage`, `chunkUploadSize`, and `maxUploadSize`. |
| `GET` | `/api/storage` | Returns disk capacity in bytes: `total`, `used`, `free`. |

### Files & Media
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/files` | Lists files (optional `?path=home/folder/`). Excludes `Trash/`. |
| `GET` | `/api/files/<UniqueID>` | Returns metadata for a single file. |
| `POST` | `/api/files/upload` | Single-request multipart upload (`file`, `path`, `encryption`) for small files. |
| `POST` | `/api/files/text` | Creates a new text file (`fileName`, `filePath`, `content`). |
| `GET` | `/api/files/<UniqueID>/text` | Reads UTF-8 text file content. |
| `PUT` | `/api/files/<UniqueID>/text` | Atomically updates text file content and recalculates size & SHA-256. |
| `GET` | `/api/files/<UniqueID>/download` | Downloads a file as an attachment. |
| `GET` | `/api/files/<UniqueID>/preview` | Serves inline file preview. |
| `GET` | `/api/files/<UniqueID>/stream` | Streams media with full HTTP `Range` (`206 Partial Content`) support. |
| `PUT` | `/api/files/<UniqueID>/path` | Moves or renames a file (`newPath`, `newName`). |
| `DELETE` | `/api/files/<UniqueID>` | Moves a file to Trash. |
| `POST` | `/api/files/<UniqueID>/link` | Creates/returns a shareable download link. |
| `GET` | `/sharing/<encoded>.file` | Public download endpoint for shared files. |

### Chunked File Upload Protocol
Default chunk size: **4 MiB** (`4,194,304` bytes), configurable via `CHUNK_UPLOAD_SIZE` (`64 KiB` to `64 MiB`).

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/uploads/init` | Initializes or resumes (`resume: true`) a chunked upload session. Validates path, disk space, and parameters (`fileName`, `filePath`, `totalSize`, `chunkSize`, `totalChunks`, optional `sha256`, optional `uploadId`). Returns `uploadId`, `receivedChunks`, and `missingChunks`. |
| `PUT` / `POST` | `/api/uploads/<uploadID>/chunks/<chunkIndex>` | Uploads a single chunk (`0 <= chunkIndex < totalChunks`). Validates exact expected byte length and optional `X-Chunk-SHA256` header, writes atomically to a `.tmp` file then `os.replace()` into `chunk_<index>.part` to prevent duplicate chunk corruption. |
| `GET` | `/api/uploads/<uploadID>` | Queries session status and verifies received chunks on disk (`receivedChunks`, `missingChunks`, `receivedBytes`). |
| `POST` | `/api/uploads/<uploadID>/complete` | Verifies all chunks `0..totalChunks-1` exist with exact sizes, streams them in order into a temporary file, verifies total size and SHA-256 checksum, atomically publishes to `STORAGE`, registers in SQLite `Files`, and deletes temporary chunks. |
| `DELETE` | `/api/uploads/<uploadID>` | Cancels an active or assembling upload session and deletes all temporary chunks. |

### Bulk File Operations
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/files/bulk-download` | Packages multiple selected `fileIds` and/or `folderPaths` into a disk-backed temporary ZIP archive (with ZipSlip path sanitization and collision deduplication) without loading files into RAM, streams the ZIP with `Content-Length`, and deletes the temp ZIP immediately upon completion or cancellation. |
| `POST` | `/api/files/bulk-delete` | Bulk-deletes multiple `fileIds` and/or `folderPaths` (moves to Trash by default, or permanently deletes from Trash when `permanent: true`). Returns `deletedCount`, `succeeded`, and `failed`. |

### Trash Management
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/trash` | Lists all trashed items and their original `LastLoc`. |
| `POST` | `/api/trash/<UniqueID>/restore` | Restores a trashed file to its original folder. |
| `DELETE` | `/api/trash/<UniqueID>` | Permanently deletes a file from Trash and disk. |

