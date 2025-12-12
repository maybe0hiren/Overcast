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
                "mime" : mimetypes.guess_type(str(child))[0] or "application/octet-stream"
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
@app.route("/createFolder", methods=["POST"])
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


#Uploading files/folders
@app.route("/upload", methods=["POST"])
@auth
def uploadAPI():
    results = []
    for key in request.files:
        uploaded = request.files.getlist(key)
        rels = request.form.getlist(f"{key}_relative") or request.form.getlist("relative_path")
        for idx, file in enumerate(uploaded):
            filename = secure_filename(file.filename) or "unnamed"
            rel = rels[idx] if idx < len(rels) else ""
            if rel:
                if rel.endswith("/") or rel.endswith("\\"):
                    relPath = Path(rel) / filename
                else:
                    rp = Path(rel)
                    if rp.suffix:
                        relPath = rp
                    else:
                        relPath = rp / filename
            else:
                relPath = Path(filename)
            try:
                target = antiPathTraversal(STORAGE, str(relPath))
            except ValueError:
                results.append({"filename" : filename, "status" : "error", "reason" : "invalid path"})
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "wb") as f:
                chunk = file.stream.read(8192) #8129 btytes = 8kb
                while chunk:
                    f.write(chunk)
                    chunk = file.stream.read(8192)
            results.append({
                "filename" : filename,
                "saved_as" : str(target.relative_to(STORAGE)),
                "size" : target.stat().st_size
            })
    if not results:
        return jsonify({"error" : "No files uploaded"}), 400
    return jsonify({"uploaded" : results})

#Downloadig a file
@app.route("/download", methods=["GET"])
@auth
def downloadAPI():
    rel = request.args.get("path")
    if not rel:
        return jsonify({"error" : "path parameter required"}), 400
    try:
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "invalid path"}), 400
    if not target.exists() or target.is_dir():
        return jsonify({"error" : "File not found or entry is a directory"}), 404
    return send_file(
        str(target),
        as_attachment=True,
        download_name=target.name,
        conditional=True
    )

#Downloading a folder after zipping it
@app.route("/downloadFolder", methods=["GET"])
@auth
def downloadFolderAPI():
    rel = request.args.get("path", "")
    try:
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "invalid path"}), 400
    if not target.exists() or not target.is_dir():
        return jsonify({"error" : "Not a directory"}), 404
    temp = tempfile.NamedTemporaryFile(prefix="folder_", suffix=".zip", delete=False)
    tempPath = Path(temp.name)
    temp.close()
    try:
        with zipfile.ZipFile(str(tempPath), "w", zipfile.ZIP_DEFLATED) as zf:
            for root, dirs, files in os.walk(str(target)):
                for file in files:
                    fullName = Path(root) / file
                    arcName = str(fullName.relative_to(target.parent))
                    zf.write(str(fullName), arcName)
        return send_file(
            str(tempPath),
            as_attachment=True,
            download_name=f"{target.name}.zip"
        )
    finally:
        try:
            os.remove(str(tempPath))
        except Exception:
            pass


#deleting a file or a folder
@app.route("/delete", methods=["POST"])
@auth
def deleteAPI():
    data = request.get_json(force=True, silent=True) or {}
    rel = data.get("path")
    if not rel:
        return jsonify({"error" : "Path required"}), 400
    try:
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "invalid path"}), 400
    if not target.exists():
        return jsonify({"error" : "Not found"}), 404
    try:
        #deletes the children first then the folder
        if target.is_file():
            target.unlink()
        else:
            for child in reversed(list(target.rglob("*"))):
                if child.is_file():
                    child.unlink()
                else:
                    try:
                        child.rmdir()
                    except OSError:
                        pass
            try:
                target.rmdir()
            except OSError:
                pass
        return jsonify({"delete" : rel})
    except Exception as e:
        return jsonify({"error" : str(e)}), 500


#rename/move a file or folder
@app.route("/renameMove", methods=["POST"])
@auth
def renameMoveAPI():
    data = request.get_json(force=True, silent=True) or {}
    oldName = data.get("old_path")
    newName = data.get("new_path")
    if not oldName or not newName:
        return jsonify({"error" : "Old and New path required"}), 400
    try:
        oldPath = antiPathTraversal(STORAGE, oldName)
        newPath = antiPathTraversal(STORAGE, newName)
    except ValueError:
        return jsonify({"error" : "Invalid path"}), 400
    if not oldPath.exists():
        return jsonify({"error" : "Old path not found"}), 404
    newPath.parent.mkdir(parents=True, exist_ok=True)
    oldPath.rename(newPath)
    return jsonify({"renamed" : {"from" : oldName, "to" : newName}})


@app.route("/stream", methods=["GET"])
@auth
def streamAPI():
    rel = request.args.get("path")
    if not rel:
        return jsonify({"error" : "Path required"}), 400
    try:
        target = antiPathTraversal(STORAGE, rel)
    except ValueError:
        return jsonify({"error" : "invalid path"}), 400
    if not target.exists():
        return jsonify({"error" : "Not found"}), 404
    fileSize = target.stat().st_size
    rangeHeader = request.headers.get("Range", None)
    if not rangeHeader:
        return send_file(str(target), conditional=True)
    try:
        units, rng = rangeHeader.split("=", 1)
        start, end = rng.split("-", 1)
        start = int(start) if start else 0
        end = int(end) if end else fileSize-1
    except Exception:
        return jsonify({"error" : "Invalid Range"}), 400
    
    if start >= fileSize:
        return Response(status=416)
    end = min(end, fileSize-1)
    length = end - start + 1

    def streamGenerator(path, start, length):
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunkSize = 8192 if remaining >= 8192 else remaining
                data = f.read(chunkSize)
                if not data:
                    break
                remaining -= len(data)
                yield data
    mime = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
    rv = Response(stream_with_context(streamGenerator(str(target), start, length)),
                status= 206, mimetype=mime,
                headers={
                    "Content-Range" : f"bytes {start}-{end}/{fileSize}",
                    "Accept-Ranges" : "bytes",
                    "Content-Length" : str(length),
                })
    return rv


@app.route("/", methods=["GET"])
def index():
    return jsonify({
        "message" : "Spare Laptop as Cloud Storage",
        "endpoints" : {
            "/list?path=" : "List folder contents",
            "/createFolder" : "POST JSON {path}",
            "/upload" : "POST multipart from files; optional '<field>_relative' from field for paths",
            "/download?path=" : "Download a file",
            "/downloadFolder?path=" : "Download a folder as zip",
            "/delete" : "POST JSON {path}",
            "/rename" : "POST JSON {oldPath, newPath}",
            "/stream?path=" : "Media streaming with range support"
        },
        "auth" : "Set ACCESS_TOKEN env var and include X-AUTH_Token beader or ?token=..."
    })


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=5000)

