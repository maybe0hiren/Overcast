import database.dbTrashHandlers as dbTrashHandlers
import database.dbHandlers as dbHandlers


def trash(UID: str):
    # get the last location of the file
    lastLoc = dbHandlers.getValue(UID, "FilePath")

    # set the current location to trash/
    dbHandlers.editPath(UID, "trash/")

    # make the entry in trash table
    dbTrashHandlers.trashHandeling(UID, lastLoc)


def restore(UID: str):
    # get the last location of the trashed file
    lastLoc = dbTrashHandlers.getValue(UID, "LastLoc")

    # set the current location to last location if it exits, if dosent, restore to root /
    if (pathExists(lastLoc)):
        dbHandlers.editPath(UID, lastLoc)
    else:
        dbHandlers.editPath(UID, "home/")

    # delete the row from trash table
    dbTrashHandlers.restoreHandeling(UID)


