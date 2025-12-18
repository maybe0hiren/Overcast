# ☁️ Personal Cloud Storage

A full-stack cloud storage system built using a spare laptop as the server.  
The project mimics core features of Google Drive while keeping **full control over storage, backend logic, and data ownership**.

Users can browse folders, upload files and directories, stream media, edit and save text/code files, and perform file operations such as rename, move, delete, and download — all through a modern web UI.

---

## 🚀 Features

- Folder-based navigation with unique URLs
- Upload files and entire folders
- Edit and save text / code files in browser
- Download files or zip entire folders
- Rename, move, and delete files/folders
- Secure filesystem access (path traversal protection)
- Self-hosted backend exposed using ngrok

---

## 🧠 Architecture Overview

- **Backend:** Flask server that manages the filesystem safely and exposes REST APIs
- **Frontend:** React app hosted by Netlify that mirrors directory structure and handles routing per folder
- **Storage:** Local filesystem on the host machine
- **Networking:** ngrok tunnel to expose backend publicly

The frontend dynamically decides how to render each file (stream, preview, edit, or download) based on MIME type and extension.

---

## 🛠 Tech Stack

### Backend
- Python
- Flask
- Werkzeug
- Flask-CORS

### Frontend
- React
- React Router
- Axios
- CSS (custom dark theme)

### Other
- ngrok (public exposure)
- Local filesystem storage

---

## 📂 Project Structure
cloud-storage/
│
├── backend/
│ ├── app.py
│ ├── requirements.txt
│ └── storage/ # Created automatically
│
├── frontend/
│ ├── src/
│ ├── public/
│ └── package.json
│
├── storage/
└── README.md



