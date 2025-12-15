import "./FileViewer.css";
import api from "../api";
import { useEffect, useState } from "react";

function FileViewer({ file, onClose }) {
  const [text, setText] = useState("");
  const [error, setError] = useState("");

  const streamURL = `${api.defaults.baseURL}/stream?path=${encodeURIComponent(file.path)}`;

  useEffect(() => {
    if (isTextFile(file)) {
      loadText();
    }
  }, [file]);

  async function loadText() {
    try {
      const res = await api.get("/download", {
        params: { path: file.path },
        responseType: "text"
      });
      setText(res.data);
    } catch {
      setError("Failed to load text file");
    }
  }

  function isVideo() {
    return file.mime.startsWith("video/");
  }

  function isImage() {
    return file.mime.startsWith("image/");
  }

  function isTextFile(file) {
    if (file.mime.startsWith("text/")) return true;
    return /\.(c|cpp|py|js|json|md|txt)$/i.test(file.name);
  }

  return (
    <div className="viewer-overlay">
      <div className="viewer">
        <div className="viewer-header">
            <button className="close-btn" onClick={onClose}>✕</button>
        </div>

        {isVideo() && (
            <div className="viewer-media">
                <video controls autoPlay>
                <source src={streamURL} />
                </video>
            </div>
        )}

        {isImage() && (
            <div className="viewer-media">
                <img src={streamURL} alt={file.name} />
            </div>
        )}

        {isTextFile(file) && (
          <textarea
            value={text}
            onChange={e => setText(e.target.value)}
          />
        )}

        {!isVideo() && !isImage() && !isTextFile(file) && (
          <div className="not-supported">
            File not displayable
          </div>
        )}

        {error && <p className="error">{error}</p>}
      </div>
    </div>
  );
}

export default FileViewer;
