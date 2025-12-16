import { useState } from "react";
import "./NewItemModal.css";

function NewItemModal({ onCreate, onClose }) {
  const [name, setName] = useState("");

  function submit() {
    if (!name.trim()) return;
    onCreate(name.trim());
  }

  return (
    <div className="modal-overlay">
      <div className="modal">
        <h3>New Item</h3>

        <input
          autoFocus
          type="text"
          placeholder="Folder or file name (e.g. notes or test.txt)"
          value={name}
          onChange={e => setName(e.target.value)}
          onKeyDown={e => e.key === "Enter" && submit()}
        />

        <div className="modal-actions">
          <button className="btn secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn primary" onClick={submit}>
            Create
          </button>
        </div>
      </div>
    </div>
  );
}

export default NewItemModal;
