import sqlite3
import os
from datetime import datetime
import uuid

from dotenv import load_dotenv
load_dotenv()


DB_NAME = os.getenv("DATABASE_PATH")


def getConnection():
    return sqlite3.connect(DB_NAME)


def makeTable():
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS Files (
            UniqueID TEXT PRIMARY KEY,
            FileName TEXT NOT NULL,
            FilePath TEXT NOT NULL,
            LastEdited TEXT NOT NULL,
            Format TEXT,
            PreviewPath TEXT,
            Link TEXT
        )
    """)

    conn.commit()
    conn.close()


def getID(filePath, fileName):
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT UniqueID
        FROM Files
        WHERE FilePath = ? AND FileName = ?
    """, (filePath, fileName))

    result = cursor.fetchone()
    conn.close()

    if result:
        return result[0]
    return None

def getValue(uniqueID: str, column: str):
    allowed_columns = {
        "UniqueID",
        "FileName",
        "FilePath",
        "LastEdited",
        "Format",
        "PreviewPath",
        "Link",
    }

    if column not in allowed_columns:
        raise ValueError(f"Invalid column name: {column}")

    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute(f"""
        SELECT {column}
        FROM Files
        WHERE UniqueID = ?
    """, (uniqueID,))

    row = cursor.fetchone()
    conn.close()

    return row[0] if row else None


def addFile(filePath, fileName, fileFormat, uniqueID=None):
    if uniqueID is None:
        newUniqueID = str(uuid.uuid4())

    previewPath = getPreview(filePath, fileName)      # Function assumed to exist
    lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO Files
        (UniqueID, FileName, FilePath, LastEdited, Format, PreviewPath, Link)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        newUniqueID,
        fileName,
        filePath,
        lastEdited,
        fileFormat,
        previewPath,
        None,
    ))

    conn.commit()
    conn.close()

    if uniqueID is None:
        return newUniqueID
    else:
        return uniqueID


def deleteFile(uniqueID):
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        UPDATE Files
        SET FilePath = ?
        WHERE UniqueID = ?
    """, ("Trash/", uniqueID))

    conn.commit()
    conn.close()


def makeLink(uniqueID):
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT Link
        FROM Files
        WHERE UniqueID = ?
    """, (uniqueID,))

    result = cursor.fetchone()
    conn.close()

    if result:
        return result[0]
    return None


def editPath(uniqueID, newPath, newName=None):
    conn = getConnection()
    cursor = conn.cursor()

    lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if newName is None:
        cursor.execute("""
            UPDATE Files
            SET FilePath = ?,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (
            newPath,
            lastEdited,
            uniqueID
        ))
    else:
        newFormat = os.path.splitext(newName)[1].lstrip(".")

        cursor.execute("""
            UPDATE Files
            SET FilePath = ?,
                FileName = ?,
                Format = ?,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (
            newPath,
            newName,
            newFormat,
            lastEdited,
            uniqueID
        ))

    conn.commit()
    conn.close()


def updateLastEdited(uniqueID):
    conn = getConnection()
    cursor = conn.cursor()

    currTime = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    cursor.execute("""
        UPDATE Files
        SET LastEdited = ?
        WHERE UniqueID = ?
    """, (currTime, uniqueID))

    conn.commit()
    conn.close()

def pathExists(filePath: str) -> bool:
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT EXISTS(
            SELECT 1
            FROM Files
            WHERE FilePath = ?
        )
    """, (filePath,))

    exists = bool(cursor.fetchone()[0])

    conn.close()
    return exists



makeTable()