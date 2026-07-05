1. **getConnection()**: connects to the DB.[[(dot)env]]
2. **makeTable():** Creates a table
3. **getID(filePath, fileName)**: Retrieves id of the row with given file path and file name
4. **getValue(uid: str, column: str)**: Returns the value under the mentioned column of the mentioned UID.
5. **addFile(filePath, fileName, fileFormat, uniqueID=None)**: Adds new row and returns the UID.
6. **deleteFile(uniqueID)**: Moves the file into "Trash"
7. **makeLink(uniqueID)**: Retrieves the "link" column of the row
8. **editPath(uniqueID, newPath, newName)**: Changes the path of the file
9. **updateLastEdited(uniqueID)**: Update the last edited column of the provided UID