import hashlib
import math
import mimetypes
import os
import re
import secrets
import shutil
import tempfile
import time
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass
from flask import (
    Flask,
    Response,
    jsonify,
    request,
    send_file,
    stream_with_context,
)
from werkzeug.exceptions import HTTPException, RequestEntityTooLarge
from werkzeug.utils import secure_filename

import database.dbHandlers as dbHandlers
import database.dbTrashHandlers as dbTrashHandlers
import functions.stringPlay as stringPlay
import functions.textFileHandlers as textFileHandlers
import functions.trashHandeling as trashHandeling


HOST = os.getenv("HOST", "127.0.0.1")
PORT = int(os.getenv("PORT", "8000"))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", str(8 * 1024 * 1024)))
DEFAULT_CHUNK_UPLOAD_SIZE = int(
    os.getenv("CHUNK_UPLOAD_SIZE", str(4 * 1024 * 1024))
)
MIN_CHUNK_UPLOAD_SIZE = int(
    os.getenv("MIN_CHUNK_UPLOAD_SIZE", str(64 * 1024))
)
MAX_CHUNK_UPLOAD_SIZE = int(
    os.getenv("MAX_CHUNK_UPLOAD_SIZE", str(64 * 1024 * 1024))
)
MAX_UPLOAD_SIZE = int(
    os.getenv("MAX_UPLOAD_SIZE", str(20 * 1024 * 1024 * 1024))
)
UPLOAD_SESSION_TTL_SECONDS = int(
    os.getenv("UPLOAD_SESSION_TTL_SECONDS", str(24 * 3600))
)
MAX_ACTIVE_UPLOAD_SESSIONS = int(
    os.getenv("MAX_ACTIVE_UPLOAD_SESSIONS", "150")
)

UPLOAD_ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")

BASE_PATH = Path(__file__).resolve().parent


def getConfiguredPath(name, default):
    value = Path(os.getenv(name, default))

    if not value.is_absolute():
        value = BASE_PATH / value

    return value.resolve()


STORAGE = getConfiguredPath("STORAGE", "storage/")
PREVIEW_STORAGE = getConfiguredPath("PREVIEW_STORAGE", "preview/")
TEMP_STORAGE = getConfiguredPath("TEMP_STORAGE", "temp/")
CHUNK_TEMP_STORAGE = TEMP_STORAGE / "chunks"
ZIP_TEMP_STORAGE = TEMP_STORAGE / "zips"
DATABASE_PATH = dbHandlers.getDatabasePath()

TEXT_EXTENSIONS = {
    "txt", "md", "json", "xml", "csv", "log", "py", "js", "ts",
    "jsx", "tsx", "html", "css", "scss", "c", "cpp", "h", "hpp",
    "java", "kt", "rs", "go", "php", "rb", "sh", "yml", "yaml",
}

VIDEO_EXTENSIONS = {
    "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
    "mpeg", "mpg", "3gp",
}

IMAGE_EXTENSIONS = {
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg",
}

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_SIZE


def initialise():
    STORAGE.mkdir(parents=True, exist_ok=True)
    PREVIEW_STORAGE.mkdir(parents=True, exist_ok=True)
    TEMP_STORAGE.mkdir(parents=True, exist_ok=True)
    CHUNK_TEMP_STORAGE.mkdir(parents=True, exist_ok=True)
    ZIP_TEMP_STORAGE.mkdir(parents=True, exist_ok=True)

    if dbHandlers.makeTable() != 0:
        raise RuntimeError("Database initialization failed")

    cleanupAbandonedTempFiles()


def normalisePath(filePath: str):
    if filePath is None:
        return None

    filePath = str(filePath).replace("\\", "/").strip()
    filePath = filePath.strip("/")

    if not filePath:
        return "home/"

    parts = [part for part in filePath.split("/") if part]

    if any(part in {".", ".."} for part in parts):
        raise ValueError("Invalid path")

    return "/".join(parts) + "/"


def sanitizeFileName(rawName: str):
    if not rawName:
        return ""
    rawName = str(rawName).replace("\\", "/").split("/")[-1].strip()
    if rawName in {".", ".."}:
        return ""
    safe = secure_filename(rawName)
    return safe


def getPhysicalPath(UID: str, fileFormat: str):
    safeFormat = (fileFormat or "bin").lstrip(".").lower()

    if not safeFormat.isalnum():
        raise ValueError("Invalid file format")

    return STORAGE / f"{UID}.{safeFormat}"


def isValidUploadId(uploadID: str) -> bool:
    return bool(uploadID and UPLOAD_ID_PATTERN.match(uploadID))


def getSessionDir(uploadID: str) -> Path:
    if not isValidUploadId(uploadID):
        raise ValueError("Invalid upload ID")
    sessionDir = (CHUNK_TEMP_STORAGE / uploadID).resolve()
    if sessionDir.parent != CHUNK_TEMP_STORAGE.resolve():
        raise ValueError("Invalid upload session directory")
    return sessionDir


def getChunkFilePath(uploadID: str, chunkIndex: int) -> Path:
    sessionDir = getSessionDir(uploadID)
    if chunkIndex < 0:
        raise ValueError("Invalid chunk index")
    return sessionDir / f"chunk_{chunkIndex:06d}.part"


def expectedChunkByteSize(totalSize: int, chunkSize: int, totalChunks: int, chunkIndex: int) -> int:
    if chunkIndex < 0 or chunkIndex >= totalChunks:
        raise ValueError("Chunk index out of bounds")
    if totalSize == 0:
        return 0
    if chunkIndex < totalChunks - 1:
        return chunkSize
    return totalSize - (chunkIndex * chunkSize)


def cleanupSessionFiles(uploadID: str):
    try:
        sessionDir = getSessionDir(uploadID)
        if sessionDir.exists():
            shutil.rmtree(sessionDir, ignore_errors=True)
    except ValueError:
        pass

    assembleTemp = TEMP_STORAGE / f".assemble-{uploadID}.tmp"
    assembleTemp.unlink(missing_ok=True)
    storageAssembleTemp = STORAGE / f".assemble-{uploadID}.tmp"
    storageAssembleTemp.unlink(missing_ok=True)


def cleanupAbandonedTempFiles():
    now = datetime.now()
    cutoff = (now - timedelta(seconds=UPLOAD_SESSION_TTL_SECONDS)).isoformat(timespec="seconds")

    expiredSessions = dbHandlers.getExpiredUploadSessions(cutoff)
    for session in expiredSessions:
        uploadID = session["UploadID"]
        cleanupSessionFiles(uploadID)
        dbHandlers.deleteUploadSession(uploadID)

    # Clean up any orphaned chunk directories not tracked in DB
    if CHUNK_TEMP_STORAGE.exists():
        for child in CHUNK_TEMP_STORAGE.iterdir():
            if not child.is_dir():
                continue
            name = child.name
            if not isValidUploadId(name):
                continue
            if dbHandlers.getUploadSession(name) is None:
                try:
                    age = time.time() - child.stat().st_mtime
                    if age > 300:
                        shutil.rmtree(child, ignore_errors=True)
                except OSError:
                    pass

    # Clean up stale temporary ZIP archives
    if ZIP_TEMP_STORAGE.exists():
        for zipFile in ZIP_TEMP_STORAGE.iterdir():
            if not zipFile.is_file():
                continue
            try:
                age = time.time() - zipFile.stat().st_mtime
                if age > UPLOAD_SESSION_TTL_SECONDS:
                    zipFile.unlink(missing_ok=True)
            except OSError:
                pass


def verifyReceivedChunksOnDisk(session: dict):
    uploadID = session["UploadID"]
    totalSize = int(session["TotalSize"])
    chunkSize = int(session["ChunkSize"])
    totalChunks = int(session["TotalChunks"])

    sessionDir = getSessionDir(uploadID)
    receivedChunks = []
    missingChunks = []
    receivedBytes = 0

    for idx in range(totalChunks):
        partPath = sessionDir / f"chunk_{idx:06d}.part"
        expectedSize = expectedChunkByteSize(totalSize, chunkSize, totalChunks, idx)
        if partPath.exists():
            try:
                actualSize = partPath.stat().st_size
                if actualSize == expectedSize:
                    receivedChunks.append(idx)
                    receivedBytes += actualSize
                else:
                    missingChunks.append(idx)
            except OSError:
                missingChunks.append(idx)
        else:
            missingChunks.append(idx)

    return receivedChunks, missingChunks, receivedBytes


def getFileRecord(UID: str):
    return dbHandlers.getFile(UID)


def calculateSHA256(filePath):
    digest = hashlib.sha256()
    size = 0

    with Path(filePath).open("rb") as file:
        while True:
            chunk = file.read(CHUNK_SIZE)
            if not chunk:
                break

            digest.update(chunk)
            size += len(chunk)

    return size, digest.hexdigest()


def checkDiskSpace(requiredBytes=0):
    usage = shutil.disk_usage(STORAGE)

    # Keep at least 512 MiB free after an upload.
    minimumFree = 512 * 1024 * 1024

    return usage.free >= requiredBytes + minimumFree


def saveUploadedFile(file, filePath, encryption="none"):
    if file is None or not file.filename:
        return None

    fileName = sanitizeFileName(file.filename)

    if not fileName:
        return None

    filePath = normalisePath(filePath)
    UID = stringPlay.makeUID(filePath, fileName)

    fileFormat = Path(fileName).suffix.lstrip(".").lower() or "bin"
    finalPath = getPhysicalPath(UID, fileFormat)

    tempFile = None

    try:
        if not checkDiskSpace():
            return None

        STORAGE.mkdir(parents=True, exist_ok=True)
        fd, tempName = tempfile.mkstemp(
            prefix=f".upload-{UID}-",
            suffix=".tmp",
            dir=str(STORAGE),
        )
        os.close(fd)
        tempFile = Path(tempName)

        file.save(str(tempFile))

        if not tempFile.exists():
            return None

        size, sha256 = calculateSHA256(tempFile)

        if size > MAX_UPLOAD_SIZE:
            tempFile.unlink(missing_ok=True)
            return None

        if not checkDiskSpace(size):
            tempFile.unlink(missing_ok=True)
            return None

        # Atomic publish on the same filesystem (STORAGE):
        os.replace(tempFile, finalPath)
        tempFile = None

        addedUID = dbHandlers.addFile(
            filePath,
            fileName,
            encryption,
            UID,
            size,
            sha256,
        )

        if addedUID is None:
            finalPath.unlink(missing_ok=True)
            return None

        return addedUID

    except Exception as e:
        print(f"Failed to save upload: {e}")

        if tempFile is not None:
            tempFile.unlink(missing_ok=True)

        return None


def createTextFile(fileName, filePath, content=""):
    fileName = sanitizeFileName(fileName or "")

    if not fileName or content is None:
        return -1

    try:
        filePath = normalisePath(filePath)
    except ValueError:
        return -1

    fileFormat = Path(fileName).suffix.lstrip(".").lower()

    if not fileFormat or fileFormat not in TEXT_EXTENSIONS:
        return -1

    UID = stringPlay.makeUID(filePath, fileName)

    if textFileHandlers.saveToDisk(UID, fileFormat) != 0:
        return -1

    if textFileHandlers.writeFile(UID, fileFormat, content) != 0:
        getPhysicalPath(UID, fileFormat).unlink(missing_ok=True)
        return -1

    size, sha256 = calculateSHA256(getPhysicalPath(UID, fileFormat))

    addedUID = dbHandlers.addFile(
        filePath,
        fileName,
        "none",
        UID,
        size,
        sha256,
    )

    if addedUID is None:
        getPhysicalPath(UID, fileFormat).unlink(missing_ok=True)
        return -1

    return 0


def movePhysicalFile(oldUID, newUID, oldFormat, newFormat=None):
    newFormat = newFormat or oldFormat

    oldPath = getPhysicalPath(oldUID, oldFormat)
    newPath = getPhysicalPath(newUID, newFormat)

    if oldPath == newPath:
        return True

    if not oldPath.exists() or newPath.exists():
        return False

    try:
        os.replace(oldPath, newPath)
        return True
    except OSError as e:
        print(f"Failed to move physical file: {e}")
        return False


def editFilePath(uniqueID, newPath, newName):
    file = dbHandlers.getFile(uniqueID)
    if file is None:
        return None

    newName = sanitizeFileName(newName or "")
    if not newName:
        return None

    try:
        newPath = normalisePath(newPath)
    except ValueError:
        return None

    newUID = stringPlay.makeUID(newPath, newName)

    if newUID != uniqueID and dbHandlers.getFile(newUID) is not None:
        return None

    oldFormat = file["Format"]
    newFormat = Path(newName).suffix.lstrip(".").lower() or oldFormat

    if not movePhysicalFile(
        uniqueID,
        newUID,
        oldFormat,
        newFormat,
    ):
        return None

    result = dbHandlers.editPath(uniqueID, newPath, newName)

    if result is None:
        movePhysicalFile(
            newUID,
            uniqueID,
            newFormat,
            oldFormat,
        )
        return None

    return result


def restoreFile(uniqueID):
    file = dbHandlers.getFile(uniqueID)
    if file is None or file["FilePath"] != "Trash/":
        return None

    lastLoc = dbHandlers.getTrashLocation(uniqueID)

    if lastLoc is None:
        return None

    newUID = stringPlay.makeUID(lastLoc, file["FileName"])

    if newUID != uniqueID and dbHandlers.getFile(newUID) is not None:
        return None

    oldFormat = file["Format"]
    newFormat = Path(file["FileName"]).suffix.lstrip(".").lower() or oldFormat

    if not movePhysicalFile(
        uniqueID,
        newUID,
        oldFormat,
        newFormat,
    ):
        return None

    result = dbHandlers.restoreFromTrash(
        uniqueID,
        lastLoc,
        file["FileName"],
    )

    if result is None:
        movePhysicalFile(
            newUID,
            uniqueID,
            newFormat,
            oldFormat,
        )
        return None

    return result


@app.after_request
def addCorsHeaders(response):
    origin = request.headers.get("Origin")

    if origin:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Vary"] = "Origin"

    response.headers["Access-Control-Allow-Headers"] = (
        "Content-Type, Authorization, Range, X-Chunk-SHA256, X-Chunk-Index"
    )
    response.headers["Access-Control-Allow-Methods"] = (
        "GET, POST, PUT, DELETE, OPTIONS"
    )
    response.headers["Access-Control-Expose-Headers"] = (
        "Content-Length, Content-Range, Accept-Ranges, Content-Disposition"
    )

    return response


@app.errorhandler(RequestEntityTooLarge)
def uploadTooLarge(error):
    return jsonify({
        "error": "File exceeds the configured upload limit"
    }), 413


@app.errorhandler(Exception)
def handleUnexpectedError(error):
    if isinstance(error, HTTPException):
        return jsonify({"error": error.description}), error.code
    print(f"Unhandled backend error: {error}")
    return jsonify({"error": "Internal server error"}), 500


@app.route("/api/<path:_path>", methods=["OPTIONS"])
def options(_path):
    return Response(status=204)


@app.get("/api/health")
def health():
    databaseOK = dbHandlers.makeTable() == 0
    storageOK = STORAGE.exists() and STORAGE.is_dir()

    return jsonify({
        "status": "ok" if databaseOK and storageOK else "degraded",
        "database": databaseOK,
        "storage": storageOK,
        "chunkUploadSize": DEFAULT_CHUNK_UPLOAD_SIZE,
        "maxUploadSize": MAX_UPLOAD_SIZE,
    })


@app.get("/api/storage")
def storageInfo():
    usage = shutil.disk_usage(STORAGE)

    return jsonify({
        "total": usage.total,
        "used": usage.used,
        "free": usage.free,
    })


@app.get("/api/files")
def listFiles():
    try:
        filePath = request.args.get("path")

        if filePath:
            filePath = normalisePath(filePath)

        return jsonify(dbHandlers.getFiles(filePath))

    except ValueError as e:
        return jsonify({"error": str(e)}), 400


@app.get("/api/files/<uniqueID>")
def getFile(uniqueID):
    file = getFileRecord(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    return jsonify(file)


@app.post("/api/files/upload")
def uploadFile():
    file = request.files.get("file")
    filePath = request.form.get("path", "home/")
    encryption = request.form.get("encryption", "none")

    try:
        filePath = normalisePath(filePath)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    if file is None:
        return jsonify({"error": "No file provided"}), 400

    UID = saveUploadedFile(file, filePath, encryption)

    if UID is None:
        return jsonify({"error": "Could not save file (already exists or invalid)"}), 409

    return jsonify(dbHandlers.getFile(UID)), 201


# --- Feature 1: Chunked Upload Protocol Endpoints ---

@app.post("/api/uploads/init")
def initChunkedUpload():
    cleanupAbandonedTempFiles()

    data = request.get_json(silent=True) or {}

    rawFileName = data.get("fileName")
    fileName = sanitizeFileName(rawFileName)
    if not fileName:
        return jsonify({"error": "Valid fileName is required"}), 400

    try:
        filePath = normalisePath(data.get("filePath", "home/"))
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    try:
        totalSize = int(data.get("totalSize"))
    except (TypeError, ValueError):
        return jsonify({"error": "Valid totalSize is required"}), 400

    if totalSize < 0:
        return jsonify({"error": "totalSize cannot be negative"}), 400

    if totalSize > MAX_UPLOAD_SIZE:
        return jsonify({"error": "File exceeds maximum allowed upload size"}), 413

    requestedChunkSize = data.get("chunkSize")
    if requestedChunkSize is not None:
        try:
            chunkSize = int(requestedChunkSize)
        except (TypeError, ValueError):
            return jsonify({"error": "Invalid chunkSize"}), 400
    else:
        chunkSize = DEFAULT_CHUNK_UPLOAD_SIZE

    if chunkSize < MIN_CHUNK_UPLOAD_SIZE or chunkSize > MAX_CHUNK_UPLOAD_SIZE:
        return jsonify({
            "error": (
                f"chunkSize must be between {MIN_CHUNK_UPLOAD_SIZE} "
                f"and {MAX_CHUNK_UPLOAD_SIZE} bytes"
            )
        }), 400

    expectedTotalChunks = 1 if totalSize == 0 else math.ceil(totalSize / chunkSize)
    providedTotalChunks = data.get("totalChunks")
    if providedTotalChunks is not None:
        try:
            if int(providedTotalChunks) != expectedTotalChunks:
                return jsonify({
                    "error": "totalChunks does not match totalSize and chunkSize",
                    "expectedTotalChunks": expectedTotalChunks,
                }), 400
        except (TypeError, ValueError):
            return jsonify({"error": "Invalid totalChunks"}), 400

    expectedSha256 = data.get("sha256")
    if expectedSha256 is not None:
        expectedSha256 = str(expectedSha256).strip().lower()
        if expectedSha256 and not re.match(r"^[a-f0-9]{64}$", expectedSha256):
            return jsonify({"error": "Invalid SHA-256 format"}), 400

    encryption = str(data.get("encryption", "none") or "none")

    UID = stringPlay.makeUID(filePath, fileName)
    fileFormat = Path(fileName).suffix.lstrip(".").lower() or "bin"

    try:
        finalPath = getPhysicalPath(UID, fileFormat)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    if not checkDiskSpace(totalSize):
        return jsonify({
            "error": "Insufficient disk space on Overcast server"
        }), 507

    # Support resuming an existing session by uploadId or matching file signature
    resumeRequested = bool(data.get("resume", False))
    requestedUploadId = data.get("uploadId")

    existingSession = None
    if requestedUploadId and isValidUploadId(str(requestedUploadId)):
        candidate = dbHandlers.getUploadSession(str(requestedUploadId))
        if (
            candidate is not None
            and candidate["Status"] == "uploading"
            and candidate["FilePath"] == filePath
            and candidate["FileName"] == fileName
            and int(candidate["TotalSize"]) == totalSize
        ):
            existingSession = candidate
    elif resumeRequested:
        existingSession = dbHandlers.findResumableUploadSession(
            filePath,
            fileName,
            totalSize,
            chunkSize,
        )

    if existingSession is not None:
        uploadID = existingSession["UploadID"]
        sessionDir = getSessionDir(uploadID)
        sessionDir.mkdir(parents=True, exist_ok=True)
        receivedChunks, missingChunks, receivedBytes = verifyReceivedChunksOnDisk(
            existingSession
        )
        return jsonify({
            "uploadId": uploadID,
            "uid": existingSession["UID"],
            "fileName": existingSession["FileName"],
            "filePath": existingSession["FilePath"],
            "totalSize": int(existingSession["TotalSize"]),
            "chunkSize": int(existingSession["ChunkSize"]),
            "totalChunks": int(existingSession["TotalChunks"]),
            "receivedChunks": receivedChunks,
            "missingChunks": missingChunks,
            "receivedBytes": receivedBytes,
            "resumed": True,
            "status": existingSession["Status"],
        }), 200

    if dbHandlers.countActiveUploadSessions() >= MAX_ACTIVE_UPLOAD_SESSIONS:
        return jsonify({
            "error": "Too many active upload sessions. Please try again shortly."
        }), 429

    uploadID = secrets.token_hex(16)
    sessionDir = getSessionDir(uploadID)
    sessionDir.mkdir(parents=True, exist_ok=True)

    session = dbHandlers.createUploadSession(
        uploadID=uploadID,
        uid=UID,
        fileName=fileName,
        filePath=filePath,
        fileFormat=fileFormat,
        totalSize=totalSize,
        chunkSize=chunkSize,
        totalChunks=expectedTotalChunks,
        expectedSha256=expectedSha256 or None,
        encryption=encryption,
    )

    if session is None:
        shutil.rmtree(sessionDir, ignore_errors=True)
        return jsonify({"error": "Failed to initialize upload session"}), 500

    return jsonify({
        "uploadId": uploadID,
        "uid": UID,
        "fileName": fileName,
        "filePath": filePath,
        "totalSize": totalSize,
        "chunkSize": chunkSize,
        "totalChunks": expectedTotalChunks,
        "receivedChunks": [],
        "missingChunks": list(range(expectedTotalChunks)),
        "receivedBytes": 0,
        "resumed": False,
        "status": "uploading",
    }), 201


@app.route("/api/uploads/<uploadID>/chunks/<int:chunkIndex>", methods=["PUT", "POST"])
def uploadChunkByIndex(uploadID, chunkIndex):
    return _handleChunkUpload(uploadID, chunkIndex)


@app.route("/api/uploads/<uploadID>/chunk", methods=["PUT", "POST"])
def uploadChunkFromParam(uploadID):
    rawIndex = (
        request.args.get("chunkIndex")
        or request.form.get("chunkIndex")
        or request.headers.get("X-Chunk-Index")
    )
    try:
        chunkIndex = int(rawIndex)
    except (TypeError, ValueError):
        return jsonify({"error": "Valid chunkIndex is required"}), 400

    return _handleChunkUpload(uploadID, chunkIndex)


def _handleChunkUpload(uploadID: str, chunkIndex: int):
    if not isValidUploadId(uploadID):
        return jsonify({"error": "Invalid upload ID"}), 400

    session = dbHandlers.getUploadSession(uploadID)
    if session is None:
        return jsonify({"error": "Upload session not found"}), 404

    if session["Status"] != "uploading":
        return jsonify({
            "error": f"Cannot upload chunk while session is '{session['Status']}'"
        }), 409

    totalSize = int(session["TotalSize"])
    chunkSize = int(session["ChunkSize"])
    totalChunks = int(session["TotalChunks"])

    if chunkIndex < 0 or chunkIndex >= totalChunks:
        return jsonify({
            "error": f"chunkIndex must be between 0 and {totalChunks - 1}"
        }), 400

    expectedSize = expectedChunkByteSize(
        totalSize,
        chunkSize,
        totalChunks,
        chunkIndex,
    )

    expectedChunkSha256 = (
        request.headers.get("X-Chunk-SHA256")
        or request.args.get("sha256")
        or request.form.get("sha256")
    )
    if expectedChunkSha256:
        expectedChunkSha256 = expectedChunkSha256.strip().lower()
        if not re.match(r"^[a-f0-9]{64}$", expectedChunkSha256):
            return jsonify({"error": "Invalid chunk SHA-256 format"}), 400

    sessionDir = getSessionDir(uploadID)
    if not sessionDir.exists():
        return jsonify({"error": "Upload session storage missing"}), 404

    partPath = getChunkFilePath(uploadID, chunkIndex)
    tempPartPath = None

    try:
        fd, tempName = tempfile.mkstemp(
            prefix=f".chunk-{chunkIndex:06d}-",
            suffix=".tmp",
            dir=str(sessionDir),
        )
        tempPartPath = Path(tempName)

        digest = hashlib.sha256()
        writtenBytes = 0

        uploadedFile = request.files.get("chunk") or request.files.get("file")

        with os.fdopen(fd, "wb") as outHandle:
            if uploadedFile is not None:
                while True:
                    buf = uploadedFile.stream.read(min(CHUNK_SIZE, 256 * 1024))
                    if not buf:
                        break
                    writtenBytes += len(buf)
                    if writtenBytes > expectedSize:
                        break
                    digest.update(buf)
                    outHandle.write(buf)
            else:
                # Raw binary body stream
                rawData = request.get_data(cache=False)
                writtenBytes = len(rawData)
                if writtenBytes <= expectedSize:
                    digest.update(rawData)
                    outHandle.write(rawData)

            outHandle.flush()
            os.fsync(outHandle.fileno())

        if writtenBytes != expectedSize:
            tempPartPath.unlink(missing_ok=True)
            return jsonify({
                "error": (
                    f"Chunk {chunkIndex} size mismatch: "
                    f"expected {expectedSize} bytes, got {writtenBytes} bytes"
                )
            }), 400

        actualChunkSha256 = digest.hexdigest()
        if expectedChunkSha256 and actualChunkSha256 != expectedChunkSha256:
            tempPartPath.unlink(missing_ok=True)
            return jsonify({
                "error": f"Chunk {chunkIndex} SHA-256 verification failed"
            }), 400

        # Re-check session hasn't been cancelled while receiving chunk
        latestSession = dbHandlers.getUploadSession(uploadID)
        if latestSession is None or latestSession["Status"] != "uploading":
            tempPartPath.unlink(missing_ok=True)
            return jsonify({"error": "Upload session was cancelled"}), 409

        # Atomic replacement prevents duplicate chunk uploads from corrupting data
        os.replace(tempPartPath, partPath)
        tempPartPath = None

        if dbHandlers.recordUploadChunk(
            uploadID,
            chunkIndex,
            writtenBytes,
            actualChunkSha256,
        ) != 0:
            partPath.unlink(missing_ok=True)
            return jsonify({"error": "Upload session no longer active"}), 409

        chunks = dbHandlers.getUploadChunks(uploadID)

        return jsonify({
            "uploadId": uploadID,
            "chunkIndex": chunkIndex,
            "size": writtenBytes,
            "sha256": actualChunkSha256,
            "receivedCount": len(chunks),
            "totalChunks": totalChunks,
        }), 200

    except Exception as e:
        print(f"Chunk upload failed for {uploadID} [{chunkIndex}]: {e}")
        if tempPartPath is not None:
            tempPartPath.unlink(missing_ok=True)
        return jsonify({"error": "Failed to store chunk"}), 500


@app.get("/api/uploads/<uploadID>")
def getUploadStatus(uploadID):
    if not isValidUploadId(uploadID):
        return jsonify({"error": "Invalid upload ID"}), 400

    session = dbHandlers.getUploadSession(uploadID)
    if session is None:
        return jsonify({"error": "Upload session not found"}), 404

    receivedChunks, missingChunks, receivedBytes = verifyReceivedChunksOnDisk(
        session
    )

    return jsonify({
        "uploadId": uploadID,
        "uid": session["UID"],
        "fileName": session["FileName"],
        "filePath": session["FilePath"],
        "totalSize": int(session["TotalSize"]),
        "chunkSize": int(session["ChunkSize"]),
        "totalChunks": int(session["TotalChunks"]),
        "receivedChunks": receivedChunks,
        "missingChunks": missingChunks,
        "receivedBytes": receivedBytes,
        "status": session["Status"],
        "createdAt": session["CreatedAt"],
        "updatedAt": session["UpdatedAt"],
    }), 200


@app.post("/api/uploads/<uploadID>/complete")
def completeChunkedUpload(uploadID):
    if not isValidUploadId(uploadID):
        return jsonify({"error": "Invalid upload ID"}), 400

    session = dbHandlers.getUploadSession(uploadID)
    if session is None:
        return jsonify({"error": "Upload session not found"}), 404

    if session["Status"] == "completed":
        existing = dbHandlers.getFile(session["UID"])
        if existing is not None:
            return jsonify(existing), 200

    if session["Status"] != "uploading":
        return jsonify({
            "error": f"Upload session is currently '{session['Status']}'"
        }), 409

    receivedChunks, missingChunks, _ = verifyReceivedChunksOnDisk(session)
    if missingChunks:
        return jsonify({
            "error": "Cannot finalize upload: missing or invalid chunks",
            "missingChunks": missingChunks,
            "receivedChunks": receivedChunks,
        }), 400

    if not dbHandlers.setUploadSessionStatus(
        uploadID,
        "assembling",
        expectedCurrentStatus="uploading",
    ):
        return jsonify({"error": "Upload session state conflict"}), 409

    data = request.get_json(silent=True) or {}
    expectedSha256 = (
        data.get("sha256")
        or session.get("ExpectedSHA256")
    )
    if expectedSha256:
        expectedSha256 = str(expectedSha256).strip().lower()

    UID = session["UID"]
    fileName = session["FileName"]
    filePath = session["FilePath"]
    fileFormat = session["Format"]
    totalSize = int(session["TotalSize"])
    totalChunks = int(session["TotalChunks"])
    encryption = session["Encryption"]

    finalPath = getPhysicalPath(UID, fileFormat)

    if not checkDiskSpace(totalSize):
        dbHandlers.setUploadSessionStatus(uploadID, "uploading")
        return jsonify({"error": "Insufficient disk space to assemble file"}), 507

    STORAGE.mkdir(parents=True, exist_ok=True)
    assembleTemp = STORAGE / f".assemble-{uploadID}.tmp"
    digest = hashlib.sha256()
    assembledSize = 0

    try:
        with assembleTemp.open("wb") as outHandle:
            for idx in range(totalChunks):
                # Check if cancelled during assembly
                current = dbHandlers.getUploadSession(uploadID)
                if current is None or current["Status"] == "cancelled":
                    outHandle.close()
                    cleanupSessionFiles(uploadID)
                    dbHandlers.deleteUploadSession(uploadID)
                    return jsonify({"error": "Upload cancelled during assembly"}), 409

                partPath = getChunkFilePath(uploadID, idx)
                if not partPath.exists():
                    outHandle.close()
                    assembleTemp.unlink(missing_ok=True)
                    dbHandlers.setUploadSessionStatus(uploadID, "uploading")
                    return jsonify({
                        "error": f"Chunk {idx} missing during assembly",
                        "missingChunks": [idx],
                    }), 400

                with partPath.open("rb") as partHandle:
                    while True:
                        buf = partHandle.read(CHUNK_SIZE)
                        if not buf:
                            break
                        outHandle.write(buf)
                        digest.update(buf)
                        assembledSize += len(buf)

            outHandle.flush()
            os.fsync(outHandle.fileno())

        # Final check before atomic publish in case cancellation arrived right at the end
        current = dbHandlers.getUploadSession(uploadID)
        if current is None or current["Status"] == "cancelled":
            cleanupSessionFiles(uploadID)
            dbHandlers.deleteUploadSession(uploadID)
            return jsonify({"error": "Upload cancelled"}), 409

        if assembledSize != totalSize:
            assembleTemp.unlink(missing_ok=True)
            dbHandlers.setUploadSessionStatus(uploadID, "uploading")
            return jsonify({
                "error": (
                    f"Assembled file size ({assembledSize}) does not match "
                    f"expected totalSize ({totalSize})"
                )
            }), 400

        calculatedSha256 = digest.hexdigest()
        if expectedSha256 and calculatedSha256 != expectedSha256:
            assembleTemp.unlink(missing_ok=True)
            dbHandlers.setUploadSessionStatus(uploadID, "uploading")
            return jsonify({
                "error": "SHA-256 checksum verification failed",
                "expectedSha256": expectedSha256,
                "actualSha256": calculatedSha256,
            }), 400

        # Atomically move verified assembled file to permanent storage
        os.replace(assembleTemp, finalPath)

        addedUID = dbHandlers.addFile(
            filePath,
            fileName,
            encryption,
            UID,
            assembledSize,
            calculatedSha256,
        )

        if addedUID is None:
            finalPath.unlink(missing_ok=True)
            cleanupSessionFiles(uploadID)
            dbHandlers.deleteUploadSession(uploadID)
            return jsonify({"error": "Could not register file in database"}), 409

        cleanupSessionFiles(uploadID)
        dbHandlers.deleteUploadSession(uploadID)

        return jsonify(dbHandlers.getFile(addedUID)), 201

    except Exception as e:
        print(f"Failed to assemble chunked upload {uploadID}: {e}")
        assembleTemp.unlink(missing_ok=True)
        dbHandlers.setUploadSessionStatus(uploadID, "uploading")
        return jsonify({"error": "Failed to assemble uploaded chunks"}), 500


@app.delete("/api/uploads/<uploadID>")
def cancelChunkedUpload(uploadID):
    if not isValidUploadId(uploadID):
        return jsonify({"error": "Invalid upload ID"}), 400

    session = dbHandlers.getUploadSession(uploadID)
    if session is not None:
        dbHandlers.setUploadSessionStatus(uploadID, "cancelled")

    cleanupSessionFiles(uploadID)
    dbHandlers.deleteUploadSession(uploadID)

    return jsonify({
        "status": "cancelled",
        "uploadId": uploadID,
    }), 200


# --- Feature 5: Bulk File Operations Endpoints ---

@app.post("/api/files/bulk-delete")
def bulkDeleteFiles():
    data = request.get_json(silent=True) or {}
    fileIds = data.get("fileIds") or []
    folderPaths = data.get("folderPaths") or []
    permanent = bool(data.get("permanent", False))

    if not isinstance(fileIds, list) or not isinstance(folderPaths, list):
        return jsonify({"error": "fileIds and folderPaths must be lists"}), 400

    if not fileIds and not folderPaths:
        return jsonify({"error": "No files or folders specified for deletion"}), 400

    targetIds = []
    seenIds = set()

    for rawId in fileIds:
        uid = str(rawId or "").strip()
        if uid and uid not in seenIds:
            seenIds.add(uid)
            targetIds.append(uid)

    failed = []

    for rawFolder in folderPaths:
        try:
            normFolder = normalisePath(str(rawFolder))
        except ValueError:
            failed.append({
                "folder": str(rawFolder),
                "error": "Invalid folder path",
            })
            continue

        if normFolder in {"home/", "Trash/"}:
            failed.append({
                "folder": normFolder,
                "error": "Cannot bulk delete root directory",
            })
            continue

        descendants = dbHandlers.getFilesUnderPrefix(
            normFolder,
            includeTrash=permanent,
        )
        for desc in descendants:
            uid = desc["UniqueID"]
            if uid not in seenIds:
                seenIds.add(uid)
                targetIds.append(uid)

    succeeded = []

    for uid in targetIds:
        file = dbHandlers.getFile(uid)
        if file is None:
            failed.append({"id": uid, "error": "File not found"})
            continue

        if permanent:
            if file["FilePath"] != "Trash/":
                failed.append({
                    "id": uid,
                    "error": "File must be in Trash before permanent deletion",
                })
                continue

            try:
                physicalPath = getPhysicalPath(uid, file["Format"])
                if physicalPath.exists():
                    physicalPath.unlink()
            except Exception as e:
                failed.append({
                    "id": uid,
                    "error": f"Could not delete physical file: {e}",
                })
                continue

            if dbHandlers.permanentlyDelete(uid) == 0:
                succeeded.append(uid)
            else:
                failed.append({"id": uid, "error": "Database delete failed"})
        else:
            if trashHandeling.trash(uid) == 0:
                succeeded.append(uid)
            else:
                failed.append({"id": uid, "error": "Could not move file to Trash"})

    return jsonify({
        "status": "completed" if not failed else "partial",
        "deletedCount": len(succeeded),
        "succeeded": succeeded,
        "failed": failed,
    }), 200


def _sanitizeZipArcname(relPath: str, usedNames: set) -> str:
    cleaned = str(relPath).replace("\\", "/").strip("/")
    parts = [
        secure_filename(p) or "item"
        for p in cleaned.split("/")
        if p and p not in {".", ".."}
    ]
    if not parts:
        parts = ["file"]

    candidate = "/".join(parts)
    if candidate.lower() not in usedNames:
        usedNames.add(candidate.lower())
        return candidate

    lastPart = parts[-1]
    dotIndex = lastPart.rfind(".")
    if dotIndex > 0:
        stem = lastPart[:dotIndex]
        ext = lastPart[dotIndex:]
    else:
        stem = lastPart
        ext = ""

    prefix = "/".join(parts[:-1])
    for counter in range(1, 100000):
        numbered = f"{stem} ({counter}){ext}"
        fullCandidate = f"{prefix}/{numbered}" if prefix else numbered
        if fullCandidate.lower() not in usedNames:
            usedNames.add(fullCandidate.lower())
            return fullCandidate

    return candidate


@app.route("/api/files/bulk-download", methods=["POST", "GET"])
def bulkDownloadFiles():
    cleanupAbandonedTempFiles()

    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        fileIds = data.get("fileIds") or []
        folderPaths = data.get("folderPaths") or []
        basePath = data.get("basePath", "home/")
        archiveName = data.get("archiveName", "Overcast-Download.zip")
    else:
        rawIds = request.args.get("ids", "")
        rawFolders = request.args.get("folders", "")
        fileIds = [x.strip() for x in rawIds.split(",") if x.strip()]
        folderPaths = [x.strip() for x in rawFolders.split(",") if x.strip()]
        basePath = request.args.get("basePath", "home/")
        archiveName = request.args.get("archiveName", "Overcast-Download.zip")

    if not isinstance(fileIds, list) or not isinstance(folderPaths, list):
        return jsonify({"error": "fileIds and folderPaths must be lists"}), 400

    try:
        normBase = normalisePath(basePath) if basePath else "home/"
    except ValueError:
        normBase = "home/"

    safeArchiveName = sanitizeFileName(archiveName) or "Overcast-Download.zip"
    if not safeArchiveName.lower().endswith(".zip"):
        safeArchiveName += ".zip"

    entriesToPack = []
    seenUIDs = set()

    for rawId in fileIds:
        uid = str(rawId or "").strip()
        if not uid or uid in seenUIDs:
            continue
        file = dbHandlers.getFile(uid)
        if file is None or file["FilePath"] == "Trash/":
            continue
        if file["FileName"] == "__overcast_folder__.txt":
            continue
        try:
            phys = getPhysicalPath(uid, file["Format"])
        except ValueError:
            continue
        if not phys.exists():
            continue

        seenUIDs.add(uid)
        fileDir = file["FilePath"]
        if fileDir.startswith(normBase):
            relDir = fileDir[len(normBase):].strip("/")
        else:
            relDir = ""
        relArc = f"{relDir}/{file['FileName']}" if relDir else file["FileName"]
        entriesToPack.append((phys, relArc))

    for rawFolder in folderPaths:
        try:
            normFolder = normalisePath(str(rawFolder))
        except ValueError:
            continue

        folderName = normFolder.strip("/").split("/")[-1]
        parentPrefix = normFolder[:-len(folderName) - 1] if normFolder.endswith(f"{folderName}/") else normBase

        descendants = dbHandlers.getFilesUnderPrefix(normFolder, includeTrash=False)
        for file in descendants:
            uid = file["UniqueID"]
            if uid in seenUIDs or file["FileName"] == "__overcast_folder__.txt":
                continue
            try:
                phys = getPhysicalPath(uid, file["Format"])
            except ValueError:
                continue
            if not phys.exists():
                continue

            seenUIDs.add(uid)
            fileDir = file["FilePath"]
            if fileDir.startswith(parentPrefix):
                relDir = fileDir[len(parentPrefix):].strip("/")
            else:
                relDir = folderName
            relArc = f"{relDir}/{file['FileName']}" if relDir else file["FileName"]
            entriesToPack.append((phys, relArc))

    if not entriesToPack:
        return jsonify({"error": "No valid files found to download"}), 404

    ZIP_TEMP_STORAGE.mkdir(parents=True, exist_ok=True)
    fd, tempZipName = tempfile.mkstemp(
        prefix=".overcast-bulk-",
        suffix=".zip",
        dir=str(ZIP_TEMP_STORAGE),
    )
    os.close(fd)
    tempZipPath = Path(tempZipName)

    try:
        usedArcNames = set()
        with zipfile.ZipFile(
            tempZipPath,
            mode="w",
            compression=zipfile.ZIP_STORED,
            allowZip64=True,
        ) as zf:
            for physPath, rawArcName in entriesToPack:
                safeArcName = _sanitizeZipArcname(rawArcName, usedArcNames)
                zinfo = zipfile.ZipInfo.from_file(physPath, arcname=safeArcName)
                zinfo.compress_type = zipfile.ZIP_STORED
                with physPath.open("rb") as src, zf.open(zinfo, mode="w") as dst:
                    shutil.copyfileobj(src, dst, length=CHUNK_SIZE)

        zipSize = tempZipPath.stat().st_size

        def streamZip():
            try:
                with tempZipPath.open("rb") as zipHandle:
                    while True:
                        chunk = zipHandle.read(CHUNK_SIZE)
                        if not chunk:
                            break
                        yield chunk
            finally:
                tempZipPath.unlink(missing_ok=True)

        response = Response(
            stream_with_context(streamZip()),
            status=200,
            mimetype="application/zip",
            direct_passthrough=True,
        )
        response.headers["Content-Length"] = str(zipSize)
        response.headers["Content-Disposition"] = (
            f'attachment; filename="{safeArchiveName}"'
        )
        return response

    except Exception as e:
        print(f"Failed to create bulk ZIP archive: {e}")
        tempZipPath.unlink(missing_ok=True)
        return jsonify({"error": "Failed to generate ZIP archive"}), 500


@app.post("/api/files/text")
def createText():
    data = request.get_json(silent=True) or {}

    status = createTextFile(
        data.get("fileName"),
        data.get("filePath", "home/"),
        data.get("content", ""),
    )

    if status != 0:
        return jsonify({"error": "Could not create text file"}), 409

    UID = dbHandlers.getID(
        normalisePath(data.get("filePath", "home/")),
        sanitizeFileName(data.get("fileName", "")),
    )

    return jsonify(dbHandlers.getFile(UID)), 201


@app.get("/api/files/<uniqueID>/download")
def downloadFile(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    physicalPath = getPhysicalPath(uniqueID, file["Format"])

    if not physicalPath.exists():
        return jsonify({"error": "File is missing from storage"}), 404

    return send_file(
        physicalPath,
        as_attachment=True,
        download_name=file["FileName"],
        mimetype=mimetypes.guess_type(file["FileName"])[0],
        conditional=True,
    )


@app.get("/api/files/<uniqueID>/preview")
def previewFile(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    physicalPath = getPhysicalPath(uniqueID, file["Format"])

    if not physicalPath.exists():
        return jsonify({"error": "File is missing from storage"}), 404

    return send_file(
        physicalPath,
        mimetype=mimetypes.guess_type(file["FileName"])[0]
        or "application/octet-stream",
        conditional=True,
    )


@app.get("/api/files/<uniqueID>/text")
def readText(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    if (file["Format"] or "").lower() not in TEXT_EXTENSIONS:
        return jsonify({"error": "File is not a text file"}), 400

    try:
        return jsonify({
            "content": textFileHandlers.readFile(
                uniqueID,
                file["Format"],
            )
        })
    except (OSError, UnicodeError):
        return jsonify({"error": "Could not read file"}), 500


@app.put("/api/files/<uniqueID>/text")
def editText(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    if (file["Format"] or "").lower() not in TEXT_EXTENSIONS:
        return jsonify({"error": "File is not a text file"}), 400

    data = request.get_json(silent=True) or {}

    if "content" not in data or not isinstance(data["content"], str):
        return jsonify({"error": "Content is required"}), 400

    if textFileHandlers.writeFile(
        uniqueID,
        file["Format"],
        data["content"],
    ) != 0:
        return jsonify({"error": "Could not edit file"}), 500

    physicalPath = getPhysicalPath(uniqueID, file["Format"])
    size, sha256 = calculateSHA256(physicalPath)
    dbHandlers.updateFileMetadata(uniqueID, size, sha256)

    return jsonify(dbHandlers.getFile(uniqueID))


@app.get("/api/files/<uniqueID>/stream")
def streamFile(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    physicalPath = getPhysicalPath(uniqueID, file["Format"])

    if not physicalPath.exists():
        return jsonify({"error": "File is missing from storage"}), 404

    fileSize = physicalPath.stat().st_size
    mimeType = (
        mimetypes.guess_type(file["FileName"])[0]
        or "application/octet-stream"
    )

    rangeHeader = request.headers.get("Range")

    if not rangeHeader:
        resp = send_file(
            physicalPath,
            mimetype=mimeType,
            conditional=True,
        )
        resp.headers["Accept-Ranges"] = "bytes"
        resp.headers["Content-Length"] = str(fileSize)
        return resp

    if not rangeHeader.startswith("bytes="):
        return Response(
            status=416,
            headers={"Content-Range": f"bytes */{fileSize}"},
        )

    try:
        value = rangeHeader[6:].split(",", 1)[0]
        startText, endText = value.split("-", 1)

        if startText:
            start = int(startText)
            end = int(endText) if endText else fileSize - 1
        else:
            suffixLength = int(endText)
            if suffixLength <= 0:
                raise ValueError
            start = max(fileSize - suffixLength, 0)
            end = fileSize - 1

        if start < 0 or start >= fileSize:
            raise ValueError

        end = min(end, fileSize - 1)

        if start > end:
            raise ValueError

    except (ValueError, TypeError):
        return Response(
            status=416,
            headers={"Content-Range": f"bytes */{fileSize}"},
        )

    length = end - start + 1

    def generate():
        with physicalPath.open("rb") as fileHandle:
            fileHandle.seek(start)
            remaining = length

            while remaining:
                chunk = fileHandle.read(min(CHUNK_SIZE, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    response = Response(
        stream_with_context(generate()),
        status=206,
        mimetype=mimeType,
        direct_passthrough=True,
    )

    response.headers["Content-Range"] = (
        f"bytes {start}-{end}/{fileSize}"
    )
    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Content-Length"] = str(length)

    return response


@app.put("/api/files/<uniqueID>/path")
def editPath(uniqueID):
    data = request.get_json(silent=True) or {}

    newPath = data.get("newPath")
    newName = data.get("newName")

    if not newPath or not newName:
        return jsonify({
            "error": "newPath and newName are required"
        }), 400

    result = editFilePath(uniqueID, newPath, newName)

    if result is None:
        return jsonify({
            "error": "Could not move or rename file"
        }), 409

    return jsonify(dbHandlers.getFile(result))


@app.delete("/api/files/<uniqueID>")
def trashFile(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    if trashHandeling.trash(uniqueID) != 0:
        return jsonify({
            "error": "Could not move file to trash"
        }), 500

    return jsonify({
        "status": "trashed",
        "UniqueID": uniqueID,
    })


@app.get("/api/trash")
def listTrash():
    trash = dbTrashHandlers.getTrash()
    files = []

    for item in trash:
        file = dbHandlers.getFile(item["UID"])

        if file is not None:
            file.update(item)
            files.append(file)

    return jsonify(files)


@app.post("/api/trash/<uniqueID>/restore")
def restoreTrash(uniqueID):
    newUID = restoreFile(uniqueID)

    if newUID is None:
        return jsonify({
            "error": "Could not restore file"
        }), 409

    return jsonify(dbHandlers.getFile(newUID))


@app.delete("/api/trash/<uniqueID>")
def permanentlyDelete(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None:
        return jsonify({"error": "File not found"}), 404

    if file["FilePath"] != "Trash/":
        return jsonify({
            "error": "File is not in trash"
        }), 400

    physicalPath = getPhysicalPath(
        uniqueID,
        file["Format"],
    )

    try:
        if physicalPath.exists():
            physicalPath.unlink()
    except OSError as e:
        print(f"Failed to delete physical file: {e}")
        return jsonify({
            "error": "Could not delete physical file"
        }), 500

    if dbHandlers.permanentlyDelete(uniqueID) != 0:
        return jsonify({
            "error": "Could not update database"
        }), 500

    return jsonify({
        "status": "deleted",
        "UniqueID": uniqueID,
    })


@app.post("/api/files/<uniqueID>/link")
def createShareLink(uniqueID):
    file = dbHandlers.getFile(uniqueID)

    if file is None or file["FilePath"] == "Trash/":
        return jsonify({"error": "File not found"}), 404

    link = dbHandlers.makeLink(uniqueID)

    if link is None:
        endpoint = os.getenv("SHARING_ENDPOINT", "").strip()

        if not endpoint:
            endpoint = request.host_url.rstrip("/") + "/sharing"

        link = stringPlay.makeLink(uniqueID, endpoint)

        if dbHandlers.setLink(uniqueID, link) != 0:
            return jsonify({
                "error": "Could not save share link"
            }), 500

    return jsonify({"Link": link})


@app.get("/sharing/<encoded>.file")
def sharing(encoded):
    UID = stringPlay.decodeUID(encoded)

    if UID is None:
        return jsonify({"error": "Invalid sharing link"}), 400

    file = dbHandlers.getFile(UID)

    if file is None or file["FilePath"] == "Trash/":
        return jsonify({"error": "File not found"}), 404

    physicalPath = getPhysicalPath(
        UID,
        file["Format"],
    )

    if not physicalPath.exists():
        return jsonify({
            "error": "File is missing from storage"
        }), 404

    return send_file(
        physicalPath,
        as_attachment=True,
        download_name=file["FileName"],
        mimetype=mimetypes.guess_type(file["FileName"])[0],
        conditional=True,
    )


initialise()


if __name__ == "__main__":
    print(f"Cloud Storage backend running on http://{HOST}:{PORT}")
    app.run(
        host=HOST,
        port=PORT,
        debug=False,
        threaded=True,
    )
