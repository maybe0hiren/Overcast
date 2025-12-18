import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";

import api from "../api";
import FileItem from "../components/FileItem";
import Header from "../components/Header";
import FileViewer from "../components/FileViewer";
import NewItemModal from "../components/NewItemModal";
import RenameModal from "../components/RenameModal";
import MoveModal from "../components/MoveModal";

import "./FileExplorer.css";

function FileExplorer() {
  const location = useLocation();
  const navigate = useNavigate();

  const path = decodeURIComponent(location.pathname.slice(1));

  const [data, setData] = useState({ folders: [], files: [] });
  const [activeFile, setActiveFile] = useState(null);
  const [renameItem, setRenameItem] = useState(null);
  const [moveItem, setMoveItem] = useState(null);
  const [showNewItem, setShowNewItem] = useState(false);

  /* ======================
     LOAD DIRECTORY
     ====================== */
  useEffect(() => {
    load();
  }, [path]);

  async function load() {
    const res = await api.get("/list", { params: { path } });
    setData(res.data);
  }

  /* ======================
     NAVIGATION
     ====================== */
  function openFolder(name) {
    navigate(`/${path ? `${path}/` : ""}${name}`);
  }

  function goBack() {
    if (!path) return;
    const parent = path.split("/").slice(0, -1).join("/");
    navigate(parent ? `/${parent}` : "/");
  }

  /* ======================
     UPLOAD FILES
     ====================== */
  async function uploadFiles(e) {
    const files = Array.from(e.target.files);
    if (!files.length) return;

    const formData = new FormData();

    files.forEach(file => {
      formData.append("files", file);
      const rel = path ? `${path}/${file.name}` : file.name;
      formData.append("relative_path", rel);
    });

    await api.post("/upload", formData);
    e.target.value = null;
    load();
  }

  /* ======================
     UPLOAD FOLDER
     ====================== */
  async function uploadFolder(e) {
    const files = Array.from(e.target.files);
    if (!files.length) return;

    const formData = new FormData();

    files.forEach(file => {
      formData.append("files", file);
      const rel = path
        ? `${path}/${file.webkitRelativePath}`
        : file.webkitRelativePath;
      formData.append("relative_path", rel);
    });

    await api.post("/upload", formData);
    e.target.value = null;
    load();
  }

  /* ======================
     CREATE FILE / FOLDER
     ====================== */
  function hasExtension(name) {
    return /\.[^./\\]+$/.test(name);
  }

  async function createItem(name) {
    const fullPath = path ? `${path}/${name}` : name;

    if (hasExtension(name)) {
      const formData = new FormData();
      const emptyFile = new File([""], name);
      formData.append("files", emptyFile);
      formData.append("relative_path", fullPath);
      await api.post("/upload", formData);
    } else {
      await api.post("/createFolder", { path: fullPath });
    }

    setShowNewItem(false);
    load();
  }

  /* ======================
     DOWNLOAD
     ====================== */
  function downloadItem(item) {
    const url = item.mime
      ? `/download?path=${encodeURIComponent(item.path)}`
      : `/downloadFolder?path=${encodeURIComponent(item.path)}`;

    window.open(api.defaults.baseURL + url);
  }

  /* ======================
     DELETE
     ====================== */
  async function deleteItem(item) {
    if (!window.confirm(`Delete "${item.name}"?`)) return;
    await api.post("/delete", { path: item.path });
    load();
  }

  /* ======================
     RENAME
     ====================== */
  function startRename(item) {
    setRenameItem(item);
  }

  async function confirmRename(newName) {
    const oldPath = renameItem.path;
    const base = oldPath.split("/").slice(0, -1).join("/");
    const newPath = base ? `${base}/${newName}` : newName;

    await api.post("/renameMove", {
      old_path: oldPath,
      new_path: newPath
    });

    setRenameItem(null);
    load();
  }

  /* ======================
     MOVE
     ====================== */
  function startMove(item) {
    setMoveItem(item);
  }

  async function confirmMove(dest) {
    const newPath = dest ? `${dest}/${moveItem.name}` : moveItem.name;

    await api.post("/renameMove", {
      old_path: moveItem.path,
      new_path: newPath
    });

    setMoveItem(null);
    load();
  }

  /* ======================
     RENDER
     ====================== */
  return (
    <>
      <Header
        showBack={!!path}
        onBack={goBack}
        onUploadFiles={uploadFiles}
        onUploadFolder={uploadFolder}
        onCreateItem={() => setShowNewItem(true)}
      />

      <div className="explorer">
        <div className="file-grid">
          {data.folders.map(f => (
            <FileItem
              key={f.path}
              item={f}
              isFolder
              onOpen={() => openFolder(f.name)}
              onDownload={downloadItem}
              onRename={startRename}
              onMove={startMove}
              onDelete={deleteItem}
            />
          ))}

          {data.files.map(file => (
            <FileItem
              key={file.path}
              item={file}
              isFolder={false}
              onOpen={() => setActiveFile(file)}
              onDownload={downloadItem}
              onRename={startRename}
              onMove={startMove}
              onDelete={deleteItem}
            />
          ))}
        </div>
      </div>

      {activeFile && (
        <FileViewer
          file={activeFile}
          onClose={() => setActiveFile(null)}
        />
      )}

      {showNewItem && (
        <NewItemModal
          onCreate={createItem}
          onClose={() => setShowNewItem(false)}
        />
      )}

      {renameItem && (
        <RenameModal
          item={renameItem}
          onClose={() => setRenameItem(null)}
          onConfirm={confirmRename}
        />
      )}

      {moveItem && (
        <MoveModal
          currentPath={path}
          onClose={() => setMoveItem(null)}
          onConfirm={confirmMove}
        />
      )}
    </>
  );
}

export default FileExplorer;
