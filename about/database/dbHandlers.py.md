[[(dot)env]]
1. **makeTable():** Creates a table
2. **getID(filePath, fileName)**: Retrieves id of the row with given file path and file name
3. **addFile(filePath, fileName, encryption, uniqueID=None)**: Adds new row
4. **deleteFile(uniqueID)**: Moves the file into "Trash"
5. **makeLink(uniqueID)**: Retrieves the "link" column of the row
6. **editPath(uniqueID, newPath, newName)**: Changes the path of the file