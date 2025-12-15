import "./FileItem.css"

import api from "../api";

function FileItem({ item, isFolder, onOpen }) {
  function download(e) {
    e.stopPropagation();
    const url = isFolder
      ? `/downloadFolder?path=${encodeURIComponent(item.path)}`
      : `/download?path=${encodeURIComponent(item.path)}`;
    window.open(api.defaults.baseURL + url);
  }
  return (
    <div className="file-item" onClick={onOpen}>
      <div className="file-icon">
        {isFolder ? "📁" : "📄"}
      </div>
      <div className="file-name">{item.name}</div>
      <button className="download-btn" onClick={download}>
        ⬇
      </button>
    </div>
  );
}

export default FileItem;
