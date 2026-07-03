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


def writeFile(UID: str, fileExt: str, updatedFile):
    filePath = getFilePath(UID, fileExt)
    with open(filePath, "w") as file:
        file.write(updatedFile.read())
    dbHandlers.updateLastEdited(UID)
    
    return("Success")

