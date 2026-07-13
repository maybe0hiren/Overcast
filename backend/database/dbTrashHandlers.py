import sqlite3
from datetime import datetime, timedelta
import os

from dotenv import load_dotenv
load_dotenv()


DB_NAME = os.getenv("DATABASE_PATH")


def getConnection():
    return sqlite3.connect(DB_NAME)


def makeTable():
    conn = None

    try:
        conn = getConnection()
        cursor = conn.cursor()

        cursor.execute("""
            CREATE TABLE IF NOT EXISTS Trash (
                UID TEXT PRIMARY KEY,
                LastLoc TEXT NOT NULL,
                TrashedDate TEXT NOT NULL
            )
        """)

        conn.commit()

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to create trash table: {e}")

    finally:
        if conn:
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

    conn = None

    try:
        conn = getConnection()
        cursor = conn.cursor()

        cursor.execute(f"""
            SELECT {column}
            FROM Trash
            WHERE UID = ?
        """, (uid,))
        row = cursor.fetchone()

        return row[0] if row else None

    except Exception as e:
        print(f"Failed to get trash value: {e}")
        return None

    finally:
        if conn:
            conn.close()


def trashHandeling(uid: str, lastLoc: str):
    conn = None


    try:
        today = datetime.now().strftime("%Y-%m-%d")
        conn = getConnection()
        cursor = conn.cursor()

        cursor.execute("""
            INSERT OR REPLACE INTO Trash

            (UID, LastLoc, TrashedDate)
            VALUES (?, ?, ?)
        """, (uid, lastLoc, today))

        conn.commit()

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to handle trash: {e}")

    finally:
        if conn:
            conn.close()

    return 0


def restoreHandeling(uid: str):
    conn = None

    try:
        conn = getConnection()
        cursor = conn.cursor()
        cursor.execute("""
            SELECT LastLoc
            FROM Trash
            WHERE UID = ?
        """, (uid,))

        row = cursor.fetchone()

        if row is None:
            return None

        lastLoc = row[0]

        cursor.execute("""
            DELETE FROM Trash
            WHERE UID = ?
        """, (uid,))

        conn.commit()

        return lastLoc

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to handle restore: {e}")
        return None

    finally:
        if conn:
            conn.close()


def clearing(UID=None):
    conn = None

    try:
        conn = getConnection()
        cursor = conn.cursor()

        if UID is None:
            cutoffDate = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")

            cursor.execute("""
                DELETE FROM Trash
                WHERE TrashedDate < ?
            """, (cutoffDate,))
        else:
            cursor.execute("""
                DELETE FROM Trash
                WHERE UID = ?
            """, (UID,))

        conn.commit()

    except Exception as e:
        if conn:
            conn.rollback()

        print(f"Failed to clear trash: {e}")

    finally:
        if conn:
            conn.close()

    return 0


if __name__ == "__main__":
    makeTable()
