[[(dot)env]]

1. **getFilePath(UID: str, fileExt: str)**: Convert UID and extention into actual file path
2. **readFile(UID: str, fileExt: str)**: Return the file associated with the UID as an object
3. **writeFile(UID: str, fileExt: str, updatedFile)**: Write the content of updated file onto the file associated with the UID. [[dbHandlers.py]]
4. **saveToDisk(UID: str, fileExt: str)**: Saves a new text file on disk.