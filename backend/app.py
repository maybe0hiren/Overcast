import os
import tempfile
import zipfile
import mimetypes
from pathlib import Path
from functools import wraps
from flask import Flask, request, jsonify, send_file, abort, Response, stream_with_context
from flask_cors import CORS
from werkzeug.utils import secure_filename



#Configuration
STORAGE = Path(os.environ.get("STORAGE", "storage")).resolve()
ACCESS_TOKEN= os.environ.get("ACCESS_TOKEN")
MAX_FILE_SIZE = None

STORAGE.mkdir(parents=True, exist_ok=True)

#Initializing Flask App
app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = MAX_FILE_SIZE
CORS(app)

#Authentication
def auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if ACCESS_TOKEN:
            token = request.headers.get("X-Auth-Token") or request.args.get("token")
            if not token or token != ACCESS_TOKEN:
                return jsonify({"error" : "Unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper

#Avoiding path traversal(Giving access to the entire device instead of just the storage folder)
def antiPathTraversal(root: Path, relative: str) -> Path:
    if relative is None or relative == "":
        rel = Path(".")
    else:
        rel = Path(relative)
    target = (root/rel).resolve()
    if not str(target).startswith(str(root)):
        raise ValueError("Path Traversal Detected")
    return target

#Providing meta data (Folders, files, file size, MINE type)
def getMetaData(path: Path):
    files = []
    folders = []
    for child in sorted(path.iterdir(), key=lambda p: p.name.lower()):
        if child.is_dir():
            folders.append({
                "name" : child.name, 
                "path" : str(child.relative_to(STORAGE)),
            })
        else:
            files.append({
                "name" : child.name,
                "path" : str(child.relative_to(STORAGE)),
                "size" : child.stat().st_size,
                "mime" : mimetypes.guess_type(str(child))[0] or "application/octate-stream"
            })
    return {"folders" : folders, "files" : files}


#API Routes

#Status of the server
@app.route("/serverCheck", methods=["GET"])
def serverCheckAPI():
    return jsonify({"status" : "ok", "storage" : str(STORAGE)})

#Getting files and fodlers insde a directory
@app.route("/list", methods=["GET"])
@auth
def listAPI():
    rel = request.args.get("path", "")
    try: 
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "Invalid Path"}), 400
    if not target.exists():
        return jsonify({"error" : "Not Found"}), 404
    if not target.is_dir():
        return jsonify({"error" : "Not a directory"}), 400
    return jsonify(getMetaData(target))


#Creating a new folder
@app.route("/createFolder", methods={"POST"})
@auth
def createFolderAPI():
    data = request.get_json(force=True, silent=True) or {}
    rel = data.get("path", "")
    try:
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "Invalid Path"}), 400
    target.mkdir(parents=True, exist_ok=True)
    return jsonify({"created" : str(target.relative_to(STORAGE))})



