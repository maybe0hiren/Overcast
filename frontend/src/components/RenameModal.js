import { useState } from "react";
import "./RenameModal.css";

function RenameModal({ item, onClose, onConfirm }) {
  const [name, setName] = useState(item.name);

  return (
    <div className="modal-overlay">
      <div className="modal">
        <h3>Rename</h3>

        <input
          value={name}
          onChange={e => setName(e.target.value)}
          autoFocus
        />

        <div className="actions">
          <button onClick={onClose}>Cancel</button>
          <button
            className="primary"
            onClick={() => onConfirm(name)}
          >
            Rename
          </button>
        </div>
      </div>
    </div>
  );
}

export default RenameModal;
