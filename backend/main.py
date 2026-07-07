import os
from pathlib import Path
from dotenv import load_dotenv
load_dotenv()


import functions.textFileHandlers
import functions.stringPlay

import database.dbHandlers
import database.dbTrashHandlers


def createTextFile(fileName: str, filePath: str):
    print("creatTextFile() called")
    # safety check
    if not fileName or not filePath:
        return -1

    # get UID for the file
    UID = stringPlay.makeUID(filePath, fileName)

    # extract file format
    fileFormat = fileName.rsplit(".", 1)[-1]

    # Save file to disk
    status = textFileHandlers.saveToDisk(UID, fileFormat)
    if status != 0:
        return -1
    
    # add entry to main DB
    UID = dbHandlers.addFile(filePath, fileName, fileFormat, UID)

def moveToTrash(fileName: str, filePath: str): 
    print("moveToTrash() called")
    status = 0
    
    # generate the UID of the file
    UID = dbHandlers.getID(filePath, fileName)
    if UID is None:
        print("Error getting UID")
        return -1

    # chage the path in main database
    status = dbHandlers.editPath(UID, "trash/")
    if status != 0:
        print ("Error mainDB")
        return -1

    # make entry in the trash DB
    status = dbTrashHandlers.trashHandeling(UID, filePath)
    if status != 0:
        print ("Error trashDB")
        return -1

    return 0


def openFile(fileName: str, filePath: str):
    print("openFile() called")

    VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".wmv",
    ".flv", ".webm", ".m4v", ".mpeg", ".mpg", ".3gp"
    }
    
    # get UID for the file
    UID = dbHandlers.getID(filePath, fileName)

    # get the format
    fileFormat = dbHandlers.getValue(UID, "Format")
    if fileFormat in VIDEO_EXTENSIONS:
        # call openVideoFile()
        continue

    # get the file from storage
    storage = os.getenv("STORAGE")
    if not storage:
        print("Error: Storage missing")
        return -1
    
    file = Path(storage)/fileName
    if not file:
        print("Error: File missing in storage")
        return -1
    
    return file


