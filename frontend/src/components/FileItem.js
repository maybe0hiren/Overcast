import { useState } from "react";
import "./FileItem.css";

function FileItem({
  item,
  isFolder,
  onOpen,
  onDownload,
  onRename,
  onMove,
  onDelete
}) {
  const [menuOpen, setMenuOpen] = useState(false);

  function toggleMenu(e) {
    e.stopPropagation();
    setMenuOpen(v => !v);
  }

  function handle(action, e) {
    e.stopPropagation();
    setMenuOpen(false);
    action(item);
  }

  return (
    <div className="file-item" onClick={onOpen}>
      <button className="menu-btn" onClick={toggleMenu}>⋮</button>

      {menuOpen && (
        <div className="file-menu">
          <div onClick={(e) => handle(onDownload, e)}>⬇ Download</div>
          <div onClick={(e) => handle(onRename, e)}>✏ Rename</div>
          <div onClick={(e) => handle(onMove, e)}>📁 Move</div>
          <div className="danger" onClick={(e) => handle(onDelete, e)}>🗑 Delete</div>
        </div>
      )}

      <div className="file-icon">
        {isFolder ? "📁" : "📄"}
      </div>

      <div className="file-name">{item.name}</div>
    </div>
  );
}

export default FileItem;
