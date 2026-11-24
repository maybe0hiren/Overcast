import os
import sqlite3
from datetime import datetime
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

BASE_PATH = Path(__file__).resolve().parents[1]
DB_NAME = os.getenv("DATABASE_PATH", "database/database.db")

ALLOWED_COLUMNS = {
    "UniqueID",
    "FileName",
    "FilePath",
    "LastEdited",
    "Format",
    "PreviewPath",
    "Link",
    "Encryption",
    "Size",
    "SHA256",
    "CreatedAt",
}


def getDatabasePath():
    databasePath = Path(DB_NAME)
    if not databasePath.is_absolute():
        databasePath = BASE_PATH / databasePath

    databasePath.parent.mkdir(parents=True, exist_ok=True)
    return databasePath.resolve()


def getConnection():
    try:
        conn = sqlite3.connect(
            str(getDatabasePath()),
            timeout=30,
            isolation_level=None,
        )
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA busy_timeout=30000")
        return conn
    except sqlite3.Error as e:
        print(f"Failed to connect to database: {e}")
        return None


def makeTable():
    conn = getConnection()
    if conn is None:
        return -1

    try:
        conn.execute("BEGIN IMMEDIATE")

        conn.execute("""
            CREATE TABLE IF NOT EXISTS Files (
                UniqueID TEXT PRIMARY KEY,
                FileName TEXT NOT NULL,
                FilePath TEXT NOT NULL,
                LastEdited TEXT NOT NULL,
                Format TEXT,
                PreviewPath TEXT,
                Link TEXT,
                Encryption TEXT,
                Size INTEGER NOT NULL DEFAULT 0,
                SHA256 TEXT,
                CreatedAt TEXT
            )
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS Trash (
                UID TEXT PRIMARY KEY,
                LastLoc TEXT NOT NULL,
                TrashedDate TEXT NOT NULL
            )
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS UploadSessions (
                UploadID TEXT PRIMARY KEY,
                UID TEXT NOT NULL,
                FileName TEXT NOT NULL,
                FilePath TEXT NOT NULL,
                Format TEXT NOT NULL,
                TotalSize INTEGER NOT NULL,
                ChunkSize INTEGER NOT NULL,
                TotalChunks INTEGER NOT NULL,
                ExpectedSHA256 TEXT,
                Encryption TEXT NOT NULL DEFAULT 'none',
                Status TEXT NOT NULL DEFAULT 'uploading',
                CreatedAt TEXT NOT NULL,
                UpdatedAt TEXT NOT NULL
            )
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS UploadChunks (
                UploadID TEXT NOT NULL,
                ChunkIndex INTEGER NOT NULL,
                Size INTEGER NOT NULL,
                SHA256 TEXT,
                ReceivedAt TEXT NOT NULL,
                PRIMARY KEY (UploadID, ChunkIndex),
                FOREIGN KEY (UploadID) REFERENCES UploadSessions(UploadID) ON DELETE CASCADE
            )
        """)

        columns = {
            row[1] for row in conn.execute("PRAGMA table_info(Files)").fetchall()
        }

        migrations = {
            "Encryption": "ALTER TABLE Files ADD COLUMN Encryption TEXT",
            "Size": "ALTER TABLE Files ADD COLUMN Size INTEGER NOT NULL DEFAULT 0",
            "SHA256": "ALTER TABLE Files ADD COLUMN SHA256 TEXT",
            "CreatedAt": "ALTER TABLE Files ADD COLUMN CreatedAt TEXT",
        }

        for column, statement in migrations.items():
            if column not in columns:
                conn.execute(statement)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_files_path
            ON Files(FilePath)
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_files_name_path
            ON Files(FilePath, FileName)
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_upload_sessions_updated
            ON UploadSessions(UpdatedAt)
        """)

        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_upload_sessions_lookup
            ON UploadSessions(FilePath, FileName, TotalSize, Status)
        """)

        conn.commit()
        return 0

    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to create database table: {e}")
        return -1
    finally:
        conn.close()


def _rowToDict(row):
    if row is None:
        return None

    return {
        "UniqueID": row[0],
        "FileName": row[1],
        "FilePath": row[2],
        "LastEdited": row[3],
        "Format": row[4],
        "PreviewPath": row[5],
        "Link": row[6],
        "Encryption": row[7],
        "Size": row[8],
        "SHA256": row[9],
        "CreatedAt": row[10],
    }


def _sessionRowToDict(row):
    if row is None:
        return None

    return {
        "UploadID": row[0],
        "UID": row[1],
        "FileName": row[2],
        "FilePath": row[3],
        "Format": row[4],
        "TotalSize": row[5],
        "ChunkSize": row[6],
        "TotalChunks": row[7],
        "ExpectedSHA256": row[8],
        "Encryption": row[9],
        "Status": row[10],
        "CreatedAt": row[11],
        "UpdatedAt": row[12],
    }


def getFile(uniqueID):
    conn = getConnection()
    if conn is None:
        return None

    try:
        row = conn.execute("""
            SELECT UniqueID, FileName, FilePath, LastEdited,
                   Format, PreviewPath, Link, Encryption,
                   Size, SHA256, CreatedAt
            FROM Files
            WHERE UniqueID = ?
        """, (uniqueID,)).fetchone()

        return _rowToDict(row)
    except sqlite3.Error as e:
        print(f"Failed to get file: {e}")
        return None
    finally:
        conn.close()


def getID(filePath, fileName):
    conn = getConnection()
    if conn is None:
        return None

    try:
        row = conn.execute("""
            SELECT UniqueID
            FROM Files
            WHERE FilePath = ? AND FileName = ?
            LIMIT 1
        """, (filePath, fileName)).fetchone()

        return row[0] if row else None
    except sqlite3.Error as e:
        print(f"Failed to get ID: {e}")
        return None
    finally:
        conn.close()


def getValue(uniqueID, column):
    if column not in ALLOWED_COLUMNS:
        raise ValueError(f"Invalid column name: {column}")

    conn = getConnection()
    if conn is None:
        return None

    try:
        row = conn.execute(
            f"SELECT {column} FROM Files WHERE UniqueID = ?",
            (uniqueID,),
        ).fetchone()

        return row[0] if row else None
    except sqlite3.Error as e:
        print(f"Failed to get value: {e}")
        return None
    finally:
        conn.close()


def getFiles(filePath=None, includeTrash=False):
    conn = getConnection()
    if conn is None:
        return []

    try:
        query = """
            SELECT UniqueID, FileName, FilePath, LastEdited,
                   Format, PreviewPath, Link, Encryption,
                   Size, SHA256, CreatedAt
            FROM Files
        """
        values = []
        conditions = []

        if filePath is not None:
            conditions.append("FilePath = ?")
            values.append(filePath)

        if not includeTrash:
            conditions.append("FilePath != ?")
            values.append("Trash/")

        if conditions:
            query += " WHERE " + " AND ".join(conditions)

        query += " ORDER BY FilePath, FileName"

        rows = conn.execute(query, values).fetchall()
        return [_rowToDict(row) for row in rows]

    except sqlite3.Error as e:
        print(f"Failed to get files: {e}")
        return []
    finally:
        conn.close()


def getFilesUnderPrefix(folderPrefix, includeTrash=False):
    conn = getConnection()
    if conn is None:
        return []

    try:
        prefix = folderPrefix if folderPrefix.endswith("/") else f"{folderPrefix}/"
        allRows = getFiles(includeTrash=includeTrash)
        return [
            item for item in allRows
            if item["FilePath"] == prefix or item["FilePath"].startswith(prefix)
        ]
    except Exception as e:
        print(f"Failed to get files under prefix: {e}")
        return []
    finally:
        conn.close()


def addFile(
    filePath,
    fileName,
    encryption="none",
    uniqueID=None,
    size=0,
    sha256=None,
):
    if uniqueID is None:
        from functions.stringPlay import makeUID
        uniqueID = makeUID(filePath, fileName)

    fileFormat = Path(fileName).suffix.lstrip(".").lower() or "bin"

    try:
        from functions.previewHandlers import getPreview
        previewPath = getPreview(uniqueID, fileName, fileFormat)
    except Exception as e:
        print(f"Preview lookup failed: {e}")
        previewPath = None

    now = datetime.now().isoformat(timespec="seconds")
    conn = getConnection()
    if conn is None:
        return None

    try:
        conn.execute("BEGIN IMMEDIATE")

        conn.execute("""
            INSERT INTO Files (
                UniqueID, FileName, FilePath, LastEdited,
                Format, PreviewPath, Link, Encryption,
                Size, SHA256, CreatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(UniqueID) DO UPDATE SET
                FileName = excluded.FileName,
                FilePath = excluded.FilePath,
                LastEdited = excluded.LastEdited,
                Format = excluded.Format,
                PreviewPath = excluded.PreviewPath,
                Link = NULL,
                Encryption = excluded.Encryption,
                Size = excluded.Size,
                SHA256 = excluded.SHA256
        """, (
            uniqueID,
            fileName,
            filePath,
            now,
            fileFormat,
            previewPath,
            None,
            encryption or "none",
            int(size),
            sha256,
            now,
        ))

        conn.execute("DELETE FROM Trash WHERE UID = ?", (uniqueID,))

        conn.commit()
        return uniqueID

    except sqlite3.IntegrityError:
        conn.rollback()
        print("A file with the same UniqueID already exists")
        return None
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to add file: {e}")
        return None
    finally:
        conn.close()


def updateFileMetadata(uniqueID, size, sha256):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        now = datetime.now().isoformat(timespec="seconds")
        cursor = conn.execute("""
            UPDATE Files
            SET Size = ?, SHA256 = ?, LastEdited = ?
            WHERE UniqueID = ?
        """, (int(size), sha256, now, uniqueID))

        conn.commit()
        return 0 if cursor.rowcount else -1
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to update metadata: {e}")
        return -1
    finally:
        conn.close()


def setLink(uniqueID, link):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        cursor = conn.execute(
            "UPDATE Files SET Link = ? WHERE UniqueID = ?",
            (link, uniqueID),
        )
        conn.commit()
        return 0 if cursor.rowcount else -1
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to set link: {e}")
        return -1
    finally:
        conn.close()


def makeLink(uniqueID):
    return getValue(uniqueID, "Link")


def updateLastEdited(uniqueID):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        now = datetime.now().isoformat(timespec="seconds")
        cursor = conn.execute(
            "UPDATE Files SET LastEdited = ? WHERE UniqueID = ?",
            (now, uniqueID),
        )
        conn.commit()
        return 0 if cursor.rowcount else -1
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to update LastEdited: {e}")
        return -1
    finally:
        conn.close()


def editPath(uniqueID, newPath, newName):
    from functions.stringPlay import makeUID

    oldFile = getFile(uniqueID)
    if oldFile is None:
        return None

    newUID = makeUID(newPath, newName)

    conn = getConnection()
    if conn is None:
        return None

    try:
        conn.execute("BEGIN IMMEDIATE")

        if newUID != uniqueID:
            existing = conn.execute(
                "SELECT 1 FROM Files WHERE UniqueID = ?",
                (newUID,),
            ).fetchone()
            if existing:
                conn.rollback()
                return None

        newFormat = Path(newName).suffix.lstrip(".").lower() or oldFile["Format"]
        now = datetime.now().isoformat(timespec="seconds")

        conn.execute("""
            UPDATE Files
            SET UniqueID = ?,
                FileName = ?,
                FilePath = ?,
                Format = ?,
                PreviewPath = NULL,
                Link = NULL,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (
            newUID,
            newName,
            newPath,
            newFormat,
            now,
            uniqueID,
        ))

        conn.commit()
        return newUID

    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to edit path: {e}")
        return None
    finally:
        conn.close()


def moveToTrash(uniqueID):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        conn.execute("BEGIN IMMEDIATE")

        row = conn.execute("""
            SELECT FilePath, FileName
            FROM Files
            WHERE UniqueID = ?
        """, (uniqueID,)).fetchone()

        if row is None:
            conn.rollback()
            return -1

        if row[0] == "Trash/":
            conn.commit()
            return 0

        lastLoc = row[0]
        now = datetime.now().isoformat(timespec="seconds")

        conn.execute("""
            INSERT INTO Trash (UID, LastLoc, TrashedDate)
            VALUES (?, ?, ?)
            ON CONFLICT(UID) DO UPDATE SET
                LastLoc = excluded.LastLoc,
                TrashedDate = excluded.TrashedDate
        """, (uniqueID, lastLoc, now))

        conn.execute("""
            UPDATE Files
            SET FilePath = 'Trash/',
                Link = NULL,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (now, uniqueID))

        conn.commit()
        return 0

    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to move file to trash: {e}")
        return -1
    finally:
        conn.close()


def restoreFromTrash(uniqueID, newPath, newName):
    from functions.stringPlay import makeUID

    newUID = makeUID(newPath, newName)
    conn = getConnection()
    if conn is None:
        return None

    try:
        conn.execute("BEGIN IMMEDIATE")

        fileRow = conn.execute("""
            SELECT FileName, Format
            FROM Files
            WHERE UniqueID = ? AND FilePath = 'Trash/'
        """, (uniqueID,)).fetchone()

        trashRow = conn.execute("""
            SELECT LastLoc
            FROM Trash
            WHERE UID = ?
        """, (uniqueID,)).fetchone()

        if fileRow is None or trashRow is None:
            conn.rollback()
            return None

        if newUID != uniqueID:
            existing = conn.execute(
                "SELECT 1 FROM Files WHERE UniqueID = ?",
                (newUID,),
            ).fetchone()
            if existing:
                conn.rollback()
                return None

        newFormat = Path(newName).suffix.lstrip(".").lower() or fileRow[1]
        now = datetime.now().isoformat(timespec="seconds")

        conn.execute("""
            UPDATE Files
            SET UniqueID = ?,
                FileName = ?,
                FilePath = ?,
                Format = ?,
                PreviewPath = NULL,
                Link = NULL,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (newUID, newName, newPath, newFormat, now, uniqueID))

        conn.execute("DELETE FROM Trash WHERE UID = ?", (uniqueID,))

        conn.commit()
        return newUID

    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to restore file: {e}")
        return None
    finally:
        conn.close()


def permanentlyDelete(uniqueID):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        conn.execute("BEGIN IMMEDIATE")

        row = conn.execute("""
            SELECT 1 FROM Files
            WHERE UniqueID = ? AND FilePath = 'Trash/'
        """, (uniqueID,)).fetchone()

        if row is None:
            conn.rollback()
            return -1

        conn.execute("DELETE FROM Trash WHERE UID = ?", (uniqueID,))
        conn.execute("DELETE FROM Files WHERE UniqueID = ?", (uniqueID,))

        conn.commit()
        return 0

    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to permanently delete file: {e}")
        return -1
    finally:
        conn.close()


def getTrash():
    conn = getConnection()
    if conn is None:
        return []

    try:
        rows = conn.execute("""
            SELECT UID, LastLoc, TrashedDate
            FROM Trash
            ORDER BY TrashedDate DESC
        """).fetchall()

        return [
            {"UID": row[0], "LastLoc": row[1], "TrashedDate": row[2]}
            for row in rows
        ]
    except sqlite3.Error as e:
        print(f"Failed to get trash: {e}")
        return []
    finally:
        conn.close()


def getTrashLocation(uniqueID):
    conn = getConnection()
    if conn is None:
        return None

    try:
        row = conn.execute(
            "SELECT LastLoc FROM Trash WHERE UID = ?",
            (uniqueID,),
        ).fetchone()
        return row[0] if row else None
    except sqlite3.Error as e:
        print(f"Failed to get trash location: {e}")
        return None
    finally:
        conn.close()


def pathExists(filePath):
    conn = getConnection()
    if conn is None:
        return False

    try:
        row = conn.execute("""
            SELECT 1
            FROM Files
            WHERE FilePath = ? AND FilePath != 'Trash/'
            LIMIT 1
        """, (filePath,)).fetchone()
        return row is not None
    except sqlite3.Error as e:
        print(f"Failed to check path: {e}")
        return False
    finally:
        conn.close()


# --- Chunked Upload Session Database Handlers ---

def createUploadSession(
    uploadID,
    uid,
    fileName,
    filePath,
    fileFormat,
    totalSize,
    chunkSize,
    totalChunks,
    expectedSha256=None,
    encryption="none",
):
    conn = getConnection()
    if conn is None:
        return None

    now = datetime.now().isoformat(timespec="seconds")

    try:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("""
            INSERT INTO UploadSessions (
                UploadID, UID, FileName, FilePath, Format,
                TotalSize, ChunkSize, TotalChunks,
                ExpectedSHA256, Encryption, Status,
                CreatedAt, UpdatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'uploading', ?, ?)
        """, (
            uploadID,
            uid,
            fileName,
            filePath,
            fileFormat,
            int(totalSize),
            int(chunkSize),
            int(totalChunks),
            expectedSha256,
            encryption or "none",
            now,
            now,
        ))
        conn.commit()
        return getUploadSession(uploadID)
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to create upload session: {e}")
        return None
    finally:
        conn.close()


def getUploadSession(uploadID):
    conn = getConnection()
    if conn is None:
        return None

    try:
        row = conn.execute("""
            SELECT UploadID, UID, FileName, FilePath, Format,
                   TotalSize, ChunkSize, TotalChunks,
                   ExpectedSHA256, Encryption, Status,
                   CreatedAt, UpdatedAt
            FROM UploadSessions
            WHERE UploadID = ?
        """, (uploadID,)).fetchone()
        return _sessionRowToDict(row)
    except sqlite3.Error as e:
        print(f"Failed to get upload session: {e}")
        return None
    finally:
        conn.close()


def findResumableUploadSession(filePath, fileName, totalSize, chunkSize=None):
    conn = getConnection()
    if conn is None:
        return None

    try:
        if chunkSize is not None:
            row = conn.execute("""
                SELECT UploadID, UID, FileName, FilePath, Format,
                       TotalSize, ChunkSize, TotalChunks,
                       ExpectedSHA256, Encryption, Status,
                       CreatedAt, UpdatedAt
                FROM UploadSessions
                WHERE FilePath = ? AND FileName = ? AND TotalSize = ?
                  AND ChunkSize = ? AND Status = 'uploading'
                ORDER BY UpdatedAt DESC
                LIMIT 1
            """, (filePath, fileName, int(totalSize), int(chunkSize))).fetchone()
        else:
            row = conn.execute("""
                SELECT UploadID, UID, FileName, FilePath, Format,
                       TotalSize, ChunkSize, TotalChunks,
                       ExpectedSHA256, Encryption, Status,
                       CreatedAt, UpdatedAt
                FROM UploadSessions
                WHERE FilePath = ? AND FileName = ? AND TotalSize = ?
                  AND Status = 'uploading'
                ORDER BY UpdatedAt DESC
                LIMIT 1
            """, (filePath, fileName, int(totalSize))).fetchone()
        return _sessionRowToDict(row)
    except sqlite3.Error as e:
        print(f"Failed to find resumable upload session: {e}")
        return None
    finally:
        conn.close()


def countActiveUploadSessions():
    conn = getConnection()
    if conn is None:
        return 0

    try:
        row = conn.execute("""
            SELECT COUNT(*)
            FROM UploadSessions
            WHERE Status IN ('uploading', 'assembling')
        """).fetchone()
        return int(row[0]) if row else 0
    except sqlite3.Error as e:
        print(f"Failed to count active upload sessions: {e}")
        return 0
    finally:
        conn.close()


def recordUploadChunk(uploadID, chunkIndex, size, sha256=None):
    conn = getConnection()
    if conn is None:
        return -1

    now = datetime.now().isoformat(timespec="seconds")

    try:
        conn.execute("BEGIN IMMEDIATE")

        sessionRow = conn.execute("""
            SELECT Status FROM UploadSessions WHERE UploadID = ?
        """, (uploadID,)).fetchone()

        if sessionRow is None or sessionRow[0] != "uploading":
            conn.rollback()
            return -1

        conn.execute("""
            INSERT INTO UploadChunks (UploadID, ChunkIndex, Size, SHA256, ReceivedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(UploadID, ChunkIndex) DO UPDATE SET
                Size = excluded.Size,
                SHA256 = excluded.SHA256,
                ReceivedAt = excluded.ReceivedAt
        """, (uploadID, int(chunkIndex), int(size), sha256, now))

        conn.execute("""
            UPDATE UploadSessions
            SET UpdatedAt = ?
            WHERE UploadID = ?
        """, (now, uploadID))

        conn.commit()
        return 0
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to record upload chunk: {e}")
        return -1
    finally:
        conn.close()


def getUploadChunks(uploadID):
    conn = getConnection()
    if conn is None:
        return []

    try:
        rows = conn.execute("""
            SELECT ChunkIndex, Size, SHA256, ReceivedAt
            FROM UploadChunks
            WHERE UploadID = ?
            ORDER BY ChunkIndex ASC
        """, (uploadID,)).fetchall()
        return [
            {
                "chunkIndex": row[0],
                "size": row[1],
                "sha256": row[2],
                "receivedAt": row[3],
            }
            for row in rows
        ]
    except sqlite3.Error as e:
        print(f"Failed to get upload chunks: {e}")
        return []
    finally:
        conn.close()


def setUploadSessionStatus(uploadID, status, expectedCurrentStatus=None):
    conn = getConnection()
    if conn is None:
        return False

    now = datetime.now().isoformat(timespec="seconds")

    try:
        conn.execute("BEGIN IMMEDIATE")
        if expectedCurrentStatus is not None:
            cursor = conn.execute("""
                UPDATE UploadSessions
                SET Status = ?, UpdatedAt = ?
                WHERE UploadID = ? AND Status = ?
            """, (status, now, uploadID, expectedCurrentStatus))
        else:
            cursor = conn.execute("""
                UPDATE UploadSessions
                SET Status = ?, UpdatedAt = ?
                WHERE UploadID = ?
            """, (status, now, uploadID))
        conn.commit()
        return cursor.rowcount > 0
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to update upload session status: {e}")
        return False
    finally:
        conn.close()


def deleteUploadSession(uploadID):
    conn = getConnection()
    if conn is None:
        return -1

    try:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM UploadChunks WHERE UploadID = ?", (uploadID,))
        conn.execute("DELETE FROM UploadSessions WHERE UploadID = ?", (uploadID,))
        conn.commit()
        return 0
    except sqlite3.Error as e:
        conn.rollback()
        print(f"Failed to delete upload session: {e}")
        return -1
    finally:
        conn.close()


def getExpiredUploadSessions(cutoffIso):
    conn = getConnection()
    if conn is None:
        return []

    try:
        rows = conn.execute("""
            SELECT UploadID, UID, FileName, FilePath, Format,
                   TotalSize, ChunkSize, TotalChunks,
                   ExpectedSHA256, Encryption, Status,
                   CreatedAt, UpdatedAt
            FROM UploadSessions
            WHERE UpdatedAt < ?
        """, (cutoffIso,)).fetchall()
        return [_sessionRowToDict(row) for row in rows]
    except sqlite3.Error as e:
        print(f"Failed to query expired upload sessions: {e}")
        return []
    finally:
        conn.close()


makeTable()
