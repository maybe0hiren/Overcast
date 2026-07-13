import sqlite3
import os
from datetime import datetime

import functions.stringPlay

from dotenv import load_dotenv
load_dotenv()


DB_NAME = os.getenv("DATABASE_PATH")


def getConnection():
    try:
        return sqlite3.connect(DB_NAME)

    except Exception as e:
        print(f"Failed to connect to database: {e}")
        return None


def makeTable():
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return 0

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

    except sqlite3.Error as e:
        if conn:
            conn.rollback()

        print(f"Failed to create table: {e}")

    finally:
        if conn:
            conn.close()

    return 0


def getID(filePath, fileName):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return None

        cursor = conn.cursor()

        cursor.execute("""
            SELECT UniqueID
            FROM Files
            WHERE FilePath = ? AND FileName = ?
        """, (filePath, fileName))

        result = cursor.fetchone()

        if result:
            return result[0]

        return None

    except sqlite3.Error as e:
        print(f"Failed to get ID: {e}")
        return None

    finally:
        if conn:
            conn.close()


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

    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return None

        cursor = conn.cursor()

        cursor.execute(f"""
            SELECT {column}
            FROM Files
            WHERE UniqueID = ?
        """, (uniqueID,))

        row = cursor.fetchone()

        return row[0] if row else None

    except sqlite3.Error as e:
        print(f"Failed to get value: {e}")
        return None

    finally:
        if conn:
            conn.close()


def addFile(filePath, fileName, fileFormat, uniqueID=None):
    conn = None

    try:
        if uniqueID is None:
            uniqueID = stringPlay.makeUID(filePath, fileName + fileFormat)

        previewPath = getPreview(filePath, fileName)
        lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        conn = getConnection()
        cursor = conn.cursor()

        cursor.execute("""
            INSERT INTO Files
            (UniqueID, FileName, FilePath, LastEdited, Format, PreviewPath, Link)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (uniqueID, fileName, filePath, lastEdited, fileFormat, previewPath, None))

        conn.commit()

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to add file: {e}")

    finally:
        if conn:
            conn.close()

    return uniqueID


def deleteFile(uniqueID):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return 0

        cursor = conn.cursor()

        cursor.execute("""
            UPDATE Files
            SET FilePath = ?
            WHERE UniqueID = ?
        """, ("Trash/", uniqueID))

        conn.commit()

    except sqlite3.Error as e:
        if conn:
            conn.rollback()

        print(f"Failed to delete file: {e}")

    finally:
        if conn:
            conn.close()

    return 0


def makeLink(uniqueID):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return None

        cursor = conn.cursor()

        cursor.execute("""
            SELECT Link
            FROM Files
            WHERE UniqueID = ?
        """, (uniqueID,))

        result = cursor.fetchone()

        if result:
            return result[0]

        return None

    except sqlite3.Error as e:
        print(f"Failed to get link: {e}")
        return None

    finally:
        if conn:
            conn.close()


def editPath(uniqueID, newPath, newName=None):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return -1

        cursor = conn.cursor()

        if newName is None:
            newName = getValue(uniqueID, "FileName")
            newFormat = getValue(uniqueID, "Format")
            fileName = newName + newFormat
        else:
            newFormat = os.path.splitext(newName)[1].lstrip(".")
            fileName = newName

        if (
            newPath == getValue(uniqueID, "FilePath")
            and newName == getValue(uniqueID, "FileName")
            and newFormat == getValue(uniqueID, "Format")
        ):
            print("No changes")
            return -1

        newUID = stringPlay.makeUID(newPath, fileName)
        lastEdited = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        cursor.execute("""
            UPDATE Files
            SET UniqueID = ?,
                FilePath = ?,
                FileName = ?,
                Format = ?,
                LastEdited = ?
            WHERE UniqueID = ?
        """, (newUID, newPath, newName, newFormat, lastEdited, uniqueID))

        conn.commit()

        return newUID

    except sqlite3.Error as e:
        if conn:
            conn.rollback()

        print(f"Failed to edit path: {e}")
        return -1

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to edit path: {e}")
        return -1

    finally:
        if conn:
            conn.close()


def updateLastEdited(uniqueID):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return 0

        cursor = conn.cursor()
        currTime = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        cursor.execute("""
            UPDATE Files
            SET LastEdited = ?
            WHERE UniqueID = ?
        """, (currTime, uniqueID))

        conn.commit()

    except sqlite3.Error as e:
        if conn:
            conn.rollback()

        print(f"Failed to update last edited: {e}")

    finally:
        if conn:
            conn.close()

    return 0


def pathExists(filePath: str) -> bool:
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return False

        cursor = conn.cursor()

        cursor.execute("""
            SELECT EXISTS(
                SELECT 1
                FROM Files
                WHERE FilePath = ?
            )
        """, (filePath,))

        exists = bool(cursor.fetchone()[0])

        return exists

    except sqlite3.Error as e:
        print(f"Failed to check path: {e}")
        return False

    finally:
        if conn:
            conn.close()


def updateUID(oldUID, newUID):
    conn = None

    try:
        conn = getConnection()

        if conn is None:
            return False

        cursor = conn.cursor()

        cursor.execute("""
            UPDATE Files
            SET UniqueID = ?
            WHERE UniqueID = ?
        """, (newUID, oldUID))

        conn.commit()

        # Check if a row was actually updated
        if cursor.rowcount == 0:
            return False

        return True

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to update UID: {e}")
        return False

    finally:
        if conn:
            conn.close()


makeTable()

