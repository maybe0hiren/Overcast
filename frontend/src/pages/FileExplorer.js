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

  return (
    <>
    <Header showBack={!!path} onBack={goBack} />
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
