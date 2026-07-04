1. **getConnection()**: connects to the DB. [[(dot)env]]
2. **makeTable()**: Creates the table
3. **getValue(uid: str, column: str)**: Returns the value under the mentioned column of the mentioned UID.
4. **trashHandeling(uid: str, lastLoc: str)**: makes the entry of the trashed file in trash table
5. **restoreHandeling(uid: str)**: returns the last location and deletes the entry from trash table.
6. **cleaning()**: delete the entries with TrashedDate older than 30 days