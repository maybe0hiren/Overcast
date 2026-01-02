import "./FileViewer.css";
import api from "../api";
import { useEffect, useState } from "react";

function FileViewer({ file, onClose }) {
  const [text, setText] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);

  const streamURL = `${api.defaults.baseURL}/stream?path=${encodeURIComponent(file.path)}`;

  useEffect(() => {
    if (isText(file)) loadText();
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

  async function saveText() {
    setSaving(true);
    try {
      const blob = new Blob([text], { type: "text/plain" });
      const fd = new FormData();

      fd.append("files", new File([blob], file.name));
      fd.append("relative_path", file.path);

      await api.post("/upload", fd);
    } catch {
      setError("Failed to save file");
    } finally {
      setSaving(false);
    }
  }

  /* ========= TYPE CHECKS ========= */

  function isImage() {
    return file.mime?.startsWith("image/");
  }

  function isVideo() {
    return file.mime?.startsWith("video/");
  }

  function isAudio() {
    return file.mime?.startsWith("audio/");
  }

  function isPDF() {
    return file.mime === "application/pdf" || /\.pdf$/i.test(file.name);
  }

  function isPPT() {
    return (
      file.mime?.includes("powerpoint") ||
      /\.(ppt|pptx)$/i.test(file.name)
    );
  }

  function isText(f) {
    if (f.mime?.startsWith("text/")) return true;
    return /\.(txt|md|json|js|py|cpp|c|java|html|css)$/i.test(f.name);
  }

  /* ========= RENDER ========= */

  return (
    <div className="viewer-overlay">
      <div className="viewer">

        <div className="viewer-header">
          <button className="close-btn" onClick={onClose}>✕</button>

          <button
            className="download-btn"
            onClick={() =>
              window.open(
                api.defaults.baseURL +
                  `/download?path=${encodeURIComponent(file.path)}`
              )
            }
          >
            ⬇
          </button>
        </div>

        {/* IMAGE */}
        {isImage() && (
          <div className="viewer-media">
            <img src={streamURL} alt={file.name} />
          </div>
        )}

        {/* VIDEO */}
        {isVideo() && (
          <div className="viewer-media">
            <video controls autoPlay>
              <source src={streamURL} />
            </video>
          </div>
        )}

        {/* AUDIO */}
        {isAudio() && (
          <div className="viewer-media">
            <audio controls autoPlay src={streamURL} />
          </div>
        )}

        {/* PDF */}
        {isPDF() && (
          <iframe
            className="pdf-frame"
            src={streamURL}
            title={file.name}
          />
        )}

        {/* POWERPOINT (Office Viewer) */}
        {isPPT() && (
          <iframe
            className="pdf-frame"
            src={`https://view.officeapps.live.com/op/embed.aspx?src=${encodeURIComponent(streamURL)}`}
            title={file.name}
          />
        )}

        {/* TEXT EDITOR */}
        {isText(file) && (
          <textarea
            value={text}
            onChange={e => setText(e.target.value)}
          />
        )}

        {/* FALLBACK */}
        {!isImage() &&
         !isVideo() &&
         !isAudio() &&
         !isPDF() &&
         !isPPT() &&
         !isText(file) && (
          <div className="not-supported">
            File not previewable
          </div>
        )}

        {/* SAVE BUTTON */}
        {isText(file) && (
          <button
            className="save-btn"
            onClick={saveText}
            disabled={saving}
          >
            💾 {saving ? "Saving..." : "Save"}
          </button>
        )}

        {error && <p className="error">{error}</p>}
      </div>
    </div>
  );
}

export default FileViewer;
