import "./FileItem.css"

function FileItem({ item, isFolder, onOpen }) {
  return (
    <div className="file-item" onClick={onOpen}>
      <div className="file-icon">
        {isFolder ? "📁" : "📄"}
      </div>
      <div className="file-name">{item.name}</div>
    </div>
  );
}

export default FileItem;
