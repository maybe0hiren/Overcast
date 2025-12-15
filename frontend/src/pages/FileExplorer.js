import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";

import api from "../api";
import FileItem from "../components/FileItem";
import Header from "../components/Header";
import FileViewer from "../components/FileViewer";

import "./FileExplorer.css";

function FileExplorer() {
  const location = useLocation();
  const navigate = useNavigate();

  const path = decodeURIComponent(location.pathname.slice(1));

  const [data, setData] = useState({ folders: [], files: [] });
  const [error, setError] = useState("");
  const [activeFile, setActiveFile] = useState(null);

  useEffect(() => {
    load();
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

  function openFolder(name) {
    navigate(`/${path ? `${path}/` : ""}${name}`);
  }

  function goBack() {
    if (!path) return;
    const parent = path.split("/").slice(0, -1).join("/");
    navigate(parent ? `/${parent}` : "/");
  }


  async function uploadFiles(e) {
    const files = Array.from(e.target.files);
    if (!files.length) return;

    const formData = new FormData();

    files.forEach(file => {
      formData.append("files", file);

      const rel = path
        ? `${path}/${file.name}`
        : file.name;

      formData.append("relative_path", rel);
    });

    try {
      await api.post("/upload", formData);
      load();
    } catch {
      alert("File upload failed");
    }
  }

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
    } catch {
      alert("Folder upload failed");
    }
  }

  async function createFolder() {
    const name = prompt("Enter folder name");
    if (!name) return;

    const folderPath = path ? `${path}/${name}` : name;

    try {
      await api.post("/createFolder", {
        path: folderPath
      });
      load();
    } catch {
      alert("Failed to create folder");
    }
  }

  return (
    <>
      <Header
        showBack={!!path}
        onBack={goBack}
        onUploadFiles={uploadFiles}
        onUploadFolder={uploadFolder}
        onCreateFolder={createFolder}
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
            />
          ))}

          {data.files.map(file => (
            <FileItem
              key={file.path}
              item={file}
              isFolder={false}
              onOpen={() => setActiveFile(file)}
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
    </>
  );
}

export default FileExplorer;
