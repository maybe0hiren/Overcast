import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";

import api from "../api";
import FileItem from "../components/FileItem";
import Header from "../components/Header";
import FileViewer from "../components/FileViewer";
import NewItemModal from "../components/NewItemModal";
import RenameModal from "../components/RenameModal";

import "./FileExplorer.css";

function FileExplorer() {
  const location = useLocation();
  const navigate = useNavigate();

  // URL → backend path
  const path = decodeURIComponent(location.pathname.slice(1));

  const [data, setData] = useState({ folders: [], files: [] });
  const [error, setError] = useState("");
  const [activeFile, setActiveFile] = useState(null);
  const [showNewItem, setShowNewItem] = useState(false);
  const [renameItem, setRenameItem] = useState(null);

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path]);

  async function load() {
    try {
      const res = await api.get("/list", {
        params: { path }
      });
      setData(res.data);
      setError("");
    } catch {
      setError("Failed to load files");
    }
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

    try {
      await api.post("/delete", { path: item.path });
      setActiveFile(null);
      load();
    } catch {
      alert("Delete failed");
    }
  }

  /* ======================
     RENAME
     ====================== */
  function startRename(item) {
    setRenameItem(item);
  }

  async function confirmRename(newName) {
    const oldPath = renameItem.path;
    const parts = oldPath.split("/");
    parts.pop();
    const newPath = [...parts, newName].filter(Boolean).join("/");

    try {
      await api.post("/renameMove", {
        old_path: oldPath,
        new_path: newPath
      });
      setRenameItem(null);
      load();
    } catch {
      alert("Rename failed");
    }
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

    try {
      await api.post("/upload", formData);
      load();
      e.target.value = null;
    } catch {
      alert("File upload failed");
    }
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

    try {
      await api.post("/upload", formData);
      load();
      e.target.value = null;
    } catch {
      alert("Folder upload failed");
    }
  }

  /* ======================
     CREATE FILE / FOLDER
     ====================== */
  function hasExtension(name) {
    return /\.[^./\\]+$/.test(name);
  }

  async function createItem(name) {
    const fullPath = path ? `${path}/${name}` : name;

    try {
      if (hasExtension(name)) {
        // Create empty file
        const formData = new FormData();
        const emptyFile = new File([""], name, { type: "text/plain" });

        formData.append("files", emptyFile);
        formData.append("relative_path", fullPath);

        await api.post("/upload", formData);
      } else {
        // Create folder
        await api.post("/createFolder", { path: fullPath });
      }

      setShowNewItem(false);
      load();
    } catch {
      alert("Failed to create item");
    }
  }

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
        {error && !activeFile && <p className="error">{error}</p>}

        <div className="file-grid">
          {data.folders.map(f => (
            <FileItem
              key={f.path}
              item={f}
              isFolder
              onOpen={() => openFolder(f.name)}
              onDownload={downloadItem}
              onRename={startRename}
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
    </>
  );
}

export default FileExplorer;
