import sqlite3
from datetime import datetime, timedelta
import os

from dotenv import load_dotenv
load_dotenv()


DB_NAME = os.getenv("DATABASE_PATH")


def getConnection():
    return sqlite3.connect(DB_NAME)


def makeTable():
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute(f"""
        CREATE TABLE IF NOT EXISTS Trash (
            UID TEXT PRIMARY KEY,
            LastLoc TEXT NOT NULL,
            TrashedDate TEXT NOT NULL
        )
    """)

    conn.commit()
    conn.close()
    return 0

def getValue(uid: str, column: str):
    allowed_columns = {
        "UID",
        "LastLoc",
        "TrashedDate"
    }

    if column not in allowed_columns:
        raise ValueError(f"Invalid column name: {column}")

    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute(f"""
        SELECT {column}
        FROM Trash
        WHERE UID = ?
    """, (uid,))

    row = cursor.fetchone()
    conn.close()

    return row[0] if row else None


def trashHandeling(uid: str, lastLoc: str):
    today = datetime.now().strftime("%Y-%m-%d")

    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute(f"""
        INSERT OR REPLACE INTO Trash
        (UID, LastLoc, TrashedDate)
        VALUES (?, ?, ?)
    """, (uid, lastLoc, today))

    conn.commit()
    conn.close()
    return 0


def restoreHandeling(uid: str):
    conn = getConnection()
    cursor = conn.cursor()

    cursor.execute(f"""
        SELECT LastLoc
        FROM Trash
        WHERE UID = ?
    """, (uid,))

    row = cursor.fetchone()

    if row is None:
        conn.close()
        return None

    lastLoc = row[0]

    cursor.execute(f"""
        DELETE FROM Trash
        WHERE UID = ?
    """, (uid,))

    conn.commit()
    conn.close()

    return lastLoc


def clearing(UID = None):
    conn = getConnection()
    cursor = conn.cursor()

    if UID is None:
        cutoffDate = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")
        cursor.execute(f"""
            DELETE FROM Trash
            WHERE TrashedDate < ?
        """, (cutoffDate,))
    else:
        cursor.execute(f"""
            DELETE FROM Trash
            WHERE UID = ?
        """, (UID,))

    conn.commit()
    conn.close()
    return 0


if __name__ == "__main__":
    makeTable()