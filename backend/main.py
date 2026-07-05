import functions.textFileHandlers
import functions.stringPlay

import database.dbHandlers


def createTextFile(fileName: str, filePath: str):
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




