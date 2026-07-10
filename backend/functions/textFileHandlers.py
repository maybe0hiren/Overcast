import os
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()


import backend.database.dbHandlers as dbHandlers



def getFilePath(UID: str, fileExt: str):
    storage = os.getenv("STORAGE")
    filePath = storage+UID+fileExt
    return filePath


def readFile(UID: str, fileExt: str):
    filePath = getFilePath(UID, fileExt)
    with open(filePath, "r") as file:
        return file


def writeFile(UID: str, fileExt: str, content: str):
    filePath = getFilePath(UID, fileExt)
    with open(filePath, "w") as file:
        file.write(content)
    dbHandlers.updateLastEdited(UID)
    
    return 0

def saveToDisk(UID: str, fileExt: str):
    filePath = Path(getFilePath(UID, fileExt))
    filePath.parent.mkdir(parents=True, exist_ok=True)
    filePath.touch(exist_ok=True)
    return 0


