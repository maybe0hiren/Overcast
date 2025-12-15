import { Routes, Route } from "react-router-dom";
import FileExplorer from "./pages/FileExplorer";
import "./styles/theme.css";

function App() {
  return (
    <>
    <Routes>
      <Route path="/" element={<FileExplorer />} />
      <Route path="/*" element={<FileExplorer />} />
    </Routes>
    </>
  );
}

export default App;
