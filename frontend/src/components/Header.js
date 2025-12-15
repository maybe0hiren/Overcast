import "./Header.css";

function Header({ showBack, onBack }) {
  return (
    <div className="top-header">
      <div className="header-left">
        {showBack && (
          <button className="back-btn" onClick={onBack}>
            ←
          </button>
        )}
      </div>

      <div className="header-center">
        ☁ CLOUD
      </div>

      <div className="header-right" />
    </div>
  );
}

export default Header;
