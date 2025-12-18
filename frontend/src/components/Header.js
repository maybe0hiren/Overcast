import "./Header.css";

function Header({
  showBack,
  onBack,
  onUploadFiles,
  onUploadFolder,
  onCreateItem
}) {
  return (
    <div className="top-header">
      <div className="header-left">
        {showBack && (
          <button className="back-btn" onClick={onBack}>←</button>
        )}
      </div>

      <div className="header-center">☁ CLOUD</div>

      <div className="header-right upload-group">
        <button className="upload-btn" onClick={onCreateItem}>
          ➕ Item
        </button>

        <label className="upload-btn">
          📄 Files
          <input
            type="file"
            multiple
            hidden
            onChange={onUploadFiles}
          />
        </label>

        <label className="upload-btn">
          📁 Folder
          <input
            type="file"
            webkitdirectory="true"
            hidden
            onChange={onUploadFolder}
          />
        </label>
      </div>
    </div>
  );
}

export default Header;
