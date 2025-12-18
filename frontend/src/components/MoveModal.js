import { useEffect, useState } from "react";
import api from "../api";
import "./MoveModal.css";

function MoveModal({ onClose, onConfirm }) {
  const [path, setPath] = useState("");
  const [folders, setFolders] = useState([]);
  const [error, setError] = useState("");

  useEffect(() => {
    load();
  }, [path]);

  async function load() {
    try {
      const res = await api.get("/list", {
        params: { path }
      });
      setFolders(res.data.folders);
      setError("");
    } catch {
      setError("Failed to load folders");
    }
  }

  function openFolder(name) {
    setPath(path ? `${path}/${name}` : name);
  }

  function goBack() {
    if (!path) return;
    setPath(path.split("/").slice(0, -1).join("/"));
  }

  function confirm() {
    onConfirm(path);
  }

  return (
    <div className="modal-overlay">
      <div className="modal">
        <h3>Move to</h3>

        <div className="picker-path">
          📁 /{path || ""}
        </div>

        {path && (
          <button className="back-btn" onClick={goBack}>
            ← Back
          </button>
        )}

        <div className="folder-list">
          {folders.map(f => (
            <div
              key={f.path}
              className="folder-row"
              onClick={() => openFolder(f.name)}
            >
              📁 {f.name}
            </div>
          ))}
        </div>

        {error && <p className="error">{error}</p>}

        <div className="actions">
          <button onClick={onClose}>Cancel</button>
          <button className="primary" onClick={confirm}>
            Move Here
          </button>
        </div>
      </div>
    </div>
  );
}

export default MoveModal;
