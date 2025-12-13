import axios from "axios";
import { NGROK_URL, ACCESS_TOKEN } from "./config";

const api = axios.create({
    baseURL : NGROK_URL,
    headers : {
        "X-Auth-Token" : ACCESS_TOKEN,
        "ngrok-skip-browser-warning" : "true"
    }
});

export default api;