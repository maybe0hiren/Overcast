import { useEffect, useState } from "react";
import api from "../api";


function FileExplorer(){
    const [path, setPath] = useState("");
    const [data, setData] = useState({ folders: [], files: []});
    const [error, setError] = useState("");
    console.log(data);

    useEffect(() => {
        load();
    }, [path]);


    async function load() {
        try{
            const res = await api.get("/list", {
                params: { path }
            });
            setData(res.data);
            setError("");
        } catch (err){
            console.error("API ERROR: " + err.response?.data || err.message);
            setError("Failed to load the Cloud");
            setData({ folders: [], files: []})
        }
    }

    function openFolder(name){
        setPath(path ? `${path}/${name}` : name);
    }
    function goBack(){
        if (!path) return;
        setPath(path.split("/").slice(0, -1).join("/"));
    }


    return(
        <>
        <h3>📁 /{path || ""}</h3>
        {path && <button onClick={goBack}> Back </button>}
        {error && <p style={{ color : "red"}}> {error} </p>}

        <ul>
            {Array.isArray(data.folders) && data.folders.map(f => (
                <li key={f.path}>
                    📁{" "}
                    <button onClick={() => openFolder(f.name)}>
                        {f.name}
                    </button>
                </li>
            ))}

            {Array.isArray(data.folders) && data.files.map(file => (
                <li key={file.path}>
                    📃 {file.name}
                </li>
            ))}
        </ul>
        </>
    )
}


export default FileExplorer;