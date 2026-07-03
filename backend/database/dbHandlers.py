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
            Link TEXT,
            Encryption TEXT
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


def addFile(filePath, fileName, encryption, uniqueID=None):
    if uniqueID is None:
        uniqueID = str(uuid.uuid4())

    fileFormat = os.path.splitext(fileName)[1].lstrip(".")
    previewPath = getPreview(filePath, fileName)      # Function assumed to exist
    lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO Files
        (UniqueID, FileName, FilePath, LastEdited, Format, PreviewPath, Link, Encryption)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        uniqueID,
        fileName,
        filePath,
        lastEdited,
        fileFormat,
        previewPath,
        None,
        encryption
    ))

    conn.commit()
    conn.close()

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


def editPath(uniqueID, newPath, newName):
    conn = getConnection()
    cursor = conn.cursor()

    newFormat = os.path.splitext(newName)[1].lstrip(".")
    lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

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