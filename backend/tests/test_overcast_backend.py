import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

# Set isolated test directories before importing backend modules
TEST_ROOT = Path(tempfile.mkdtemp(prefix="overcast_test_"))
os.environ["STORAGE"] = str(TEST_ROOT / "storage")
os.environ["PREVIEW_STORAGE"] = str(TEST_ROOT / "preview")
os.environ["TEMP_STORAGE"] = str(TEST_ROOT / "temp")
os.environ["DATABASE_PATH"] = str(TEST_ROOT / "database" / "database.db")
os.environ["CHUNK_UPLOAD_SIZE"] = str(256 * 1024)  # 256 KiB default for fast tests
os.environ["MIN_CHUNK_UPLOAD_SIZE"] = str(64 * 1024)  # 64 KiB min

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import main as overcast_main
import database.dbHandlers as dbHandlers


class OvercastBackendTestSuite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        overcast_main.initialise()
        cls.client = overcast_main.app.test_client()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(TEST_ROOT, ignore_errors=True)

    def setUp(self):
        # Reset tables and storage between tests
        conn = dbHandlers.getConnection()
        conn.execute("DELETE FROM UploadChunks")
        conn.execute("DELETE FROM UploadSessions")
        conn.execute("DELETE FROM Trash")
        conn.execute("DELETE FROM Files")
        conn.close()

        for folder in [
            overcast_main.STORAGE,
            overcast_main.TEMP_STORAGE,
            overcast_main.CHUNK_TEMP_STORAGE,
            overcast_main.ZIP_TEMP_STORAGE,
        ]:
            if folder.exists():
                shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True, exist_ok=True)

    def test_01_health_and_storage(self):
        res = self.client.get("/api/health")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertEqual(data["status"], "ok")
        self.assertTrue(data["database"])
        self.assertTrue(data["storage"])

        s_res = self.client.get("/api/storage")
        self.assertEqual(s_res.status_code, 200)
        s_data = s_res.get_json()
        self.assertGreater(s_data["total"], 0)
        self.assertGreater(s_data["free"], 0)

    def test_02_small_file_upload_and_download(self):
        payload = b"Hello Overcast small file upload test!\n" * 100
        expected_sha = hashlib.sha256(payload).hexdigest()

        res = self.client.post(
            "/api/files/upload",
            data={
                "path": "home/docs/",
                "file": (io.BytesIO(payload), "readme.txt"),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(res.status_code, 201)
        meta = res.get_json()
        self.assertEqual(meta["FileName"], "readme.txt")
        self.assertEqual(meta["FilePath"], "home/docs/")
        self.assertEqual(meta["Size"], len(payload))
        self.assertEqual(meta["SHA256"], expected_sha)

        dl = self.client.get(f"/api/files/{meta['UniqueID']}/download")
        self.assertEqual(dl.status_code, 200)
        self.assertEqual(dl.data, payload)
        dl.close()

    def test_03_chunked_upload_multi_chunk_and_integrity(self):
        # Create a 700 KiB payload divided into 256 KiB chunks (3 chunks: 256K, 256K, 188K)
        chunk_size = 256 * 1024
        total_size = 700 * 1024
        payload = os.urandom(total_size)
        expected_sha = hashlib.sha256(payload).hexdigest()

        init_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "large_video.mp4",
                "filePath": "home/videos/",
                "totalSize": total_size,
                "chunkSize": chunk_size,
                "totalChunks": 3,
                "sha256": expected_sha,
            },
        )
        self.assertEqual(init_res.status_code, 201)
        session = init_res.get_json()
        upload_id = session["uploadId"]
        self.assertEqual(session["totalChunks"], 3)

        # Upload chunks out of order (2, 0, 1) to verify proper ordered assembly
        for idx in [2, 0, 1]:
            start = idx * chunk_size
            end = min(total_size, start + chunk_size)
            chunk_bytes = payload[start:end]
            chunk_sha = hashlib.sha256(chunk_bytes).hexdigest()

            c_res = self.client.put(
                f"/api/uploads/{upload_id}/chunks/{idx}",
                data={
                    "chunk": (io.BytesIO(chunk_bytes), f"chunk_{idx}.part"),
                },
                headers={"X-Chunk-SHA256": chunk_sha},
                content_type="multipart/form-data",
            )
            self.assertEqual(c_res.status_code, 200, c_res.get_data(as_text=True))

        # Check status before finalizing
        st_res = self.client.get(f"/api/uploads/{upload_id}")
        self.assertEqual(st_res.status_code, 200)
        st_data = st_res.get_json()
        self.assertEqual(st_data["receivedChunks"], [0, 1, 2])
        self.assertEqual(st_data["missingChunks"], [])
        self.assertEqual(st_data["receivedBytes"], total_size)

        # Complete upload
        comp_res = self.client.post(f"/api/uploads/{upload_id}/complete")
        self.assertEqual(comp_res.status_code, 201, comp_res.get_data(as_text=True))
        file_meta = comp_res.get_json()
        self.assertEqual(file_meta["FileName"], "large_video.mp4")
        self.assertEqual(file_meta["FilePath"], "home/videos/")
        self.assertEqual(file_meta["Size"], total_size)
        self.assertEqual(file_meta["SHA256"], expected_sha)

        # Verify temporary chunk folder was cleaned up
        self.assertFalse((overcast_main.CHUNK_TEMP_STORAGE / upload_id).exists())

        # Verify downloaded content matches byte-for-byte
        dl_res = self.client.get(f"/api/files/{file_meta['UniqueID']}/download")
        self.assertEqual(dl_res.status_code, 200)
        self.assertEqual(dl_res.data, payload)
        dl_res.close()

    def test_04_missing_chunk_detection_and_duplicate_chunk_safety(self):
        chunk_size = 128 * 1024
        total_size = 300 * 1024
        payload = os.urandom(total_size)

        init_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "archive.bin",
                "filePath": "home/",
                "totalSize": total_size,
                "chunkSize": chunk_size,
                "totalChunks": 3,
            },
        )
        self.assertEqual(init_res.status_code, 201)
        upload_id = init_res.get_json()["uploadId"]

        # Upload chunk 0 twice (duplicate chunk retry simulation)
        chunk0 = payload[0:chunk_size]
        for _ in range(2):
            res0 = self.client.put(
                f"/api/uploads/{upload_id}/chunks/0",
                data={"chunk": (io.BytesIO(chunk0), "chunk_0.part")},
                content_type="multipart/form-data",
            )
            self.assertEqual(res0.status_code, 200)

        # Try completing while chunks 1 and 2 are missing -> must fail with 400
        early_complete = self.client.post(f"/api/uploads/{upload_id}/complete")
        self.assertEqual(early_complete.status_code, 400)
        err_data = early_complete.get_json()
        self.assertEqual(err_data["missingChunks"], [1, 2])

        # Test resuming session via init with resume=True
        resume_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "archive.bin",
                "filePath": "home/",
                "totalSize": total_size,
                "chunkSize": chunk_size,
                "resume": True,
            },
        )
        self.assertEqual(resume_res.status_code, 200)
        resumed_data = resume_res.get_json()
        self.assertTrue(resumed_data["resumed"])
        self.assertEqual(resumed_data["uploadId"], upload_id)
        self.assertEqual(resumed_data["receivedChunks"], [0])

        # Upload remaining chunks 1 and 2
        for idx in [1, 2]:
            start = idx * chunk_size
            end = min(total_size, start + chunk_size)
            c_res = self.client.put(
                f"/api/uploads/{upload_id}/chunks/{idx}",
                data={"chunk": (io.BytesIO(payload[start:end]), f"c_{idx}.part")},
                content_type="multipart/form-data",
            )
            self.assertEqual(c_res.status_code, 200)

        comp_res = self.client.post(f"/api/uploads/{upload_id}/complete")
        self.assertEqual(comp_res.status_code, 201)
        self.assertEqual(
            comp_res.get_json()["SHA256"],
            hashlib.sha256(payload).hexdigest(),
        )

    def test_05_upload_cancellation_cleans_up_and_prevents_partial_file(self):
        chunk_size = 128 * 1024
        total_size = 256 * 1024
        payload = os.urandom(total_size)

        init_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "cancelled_file.dat",
                "filePath": "home/",
                "totalSize": total_size,
                "chunkSize": chunk_size,
            },
        )
        upload_id = init_res.get_json()["uploadId"]

        # Upload first chunk
        r0 = self.client.put(
            f"/api/uploads/{upload_id}/chunks/0",
            data={"chunk": (io.BytesIO(payload[:chunk_size]), "c0.part")},
            content_type="multipart/form-data",
        )
        self.assertEqual(r0.status_code, 200)
        self.assertTrue((overcast_main.CHUNK_TEMP_STORAGE / upload_id).exists())

        # Cancel upload
        del_res = self.client.delete(f"/api/uploads/{upload_id}")
        self.assertEqual(del_res.status_code, 200)
        self.assertEqual(del_res.get_json()["status"], "cancelled")

        # Verify temporary chunks are deleted and file is not in storage or DB
        self.assertFalse((overcast_main.CHUNK_TEMP_STORAGE / upload_id).exists())
        self.assertEqual(len(list(overcast_main.STORAGE.iterdir())), 0)
        files_res = self.client.get("/api/files")
        self.assertEqual(files_res.get_json(), [])

        # Subsequent chunk upload to cancelled session returns 404
        r1 = self.client.put(
            f"/api/uploads/{upload_id}/chunks/1",
            data={"chunk": (io.BytesIO(payload[chunk_size:]), "c1.part")},
            content_type="multipart/form-data",
        )
        self.assertEqual(r1.status_code, 404)

    def test_06_security_validations(self):
        # 1. Path traversal in filePath
        res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "test.txt",
                "filePath": "home/../../etc/",
                "totalSize": 100,
                "chunkSize": 64 * 1024,
            },
        )
        self.assertEqual(res.status_code, 400)

        # 2. Invalid uploadId traversal attempt
        bad_status = self.client.get("/api/uploads/invalid_upload_id_123")
        self.assertIn(bad_status.status_code, (400, 404))
        bad_traversal = self.client.get("/api/uploads/..%2F..%2Fetc")
        self.assertIn(bad_traversal.status_code, (400, 404, 405))

        # 3. Invalid chunk size / corrupt chunk SHA-256
        init_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "sec.bin",
                "filePath": "home/",
                "totalSize": 1024,
                "chunkSize": 64 * 1024,
            },
        )
        self.assertEqual(init_res.status_code, 201)
        upload_id = init_res.get_json()["uploadId"]

        # Out of bounds chunk index
        oob_res = self.client.put(
            f"/api/uploads/{upload_id}/chunks/5",
            data={"chunk": (io.BytesIO(b"x" * 1024), "c5.part")},
            content_type="multipart/form-data",
        )
        self.assertEqual(oob_res.status_code, 400)

        # Wrong byte size for chunk 0
        wrong_size = self.client.put(
            f"/api/uploads/{upload_id}/chunks/0",
            data={"chunk": (io.BytesIO(b"too short"), "c0.part")},
            content_type="multipart/form-data",
        )
        self.assertEqual(wrong_size.status_code, 400)

        # Wrong SHA-256 for chunk 0
        wrong_sha = self.client.put(
            f"/api/uploads/{upload_id}/chunks/0",
            data={"chunk": (io.BytesIO(b"a" * 1024), "c0.part")},
            headers={"X-Chunk-SHA256": "0" * 64},
            content_type="multipart/form-data",
        )
        self.assertEqual(wrong_sha.status_code, 400)

    def test_07_bulk_download_zip_and_bulk_delete(self):
        # Upload 3 files across 2 directories
        files_to_create = [
            ("home/", "alpha.txt", b"Alpha file content"),
            ("home/", "beta.txt", b"Beta file content"),
            ("home/Projects/", "code.py", b"print('Overcast')\n"),
        ]
        created_ids = []
        for fpath, fname, content in files_to_create:
            r = self.client.post(
                "/api/files/upload",
                data={
                    "path": fpath,
                    "file": (io.BytesIO(content), fname),
                },
                content_type="multipart/form-data",
            )
            self.assertEqual(r.status_code, 201)
            created_ids.append(r.get_json()["UniqueID"])

        # Test bulk download of 2 files + 1 folder
        zip_res = self.client.post(
            "/api/files/bulk-download",
            json={
                "fileIds": [created_ids[0], created_ids[1]],
                "folderPaths": ["home/Projects/"],
                "basePath": "home/",
                "archiveName": "MySelection.zip",
            },
        )
        self.assertEqual(zip_res.status_code, 200)
        self.assertEqual(zip_res.mimetype, "application/zip")
        zip_bytes = zip_res.data

        with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
            names = set(zf.namelist())
            self.assertIn("alpha.txt", names)
            self.assertIn("beta.txt", names)
            self.assertIn("Projects/code.py", names)
            self.assertEqual(zf.read("alpha.txt"), b"Alpha file content")
            self.assertEqual(zf.read("Projects/code.py"), b"print('Overcast')\n")

        # Verify temporary ZIP file was cleaned up immediately after streaming
        remaining_zips = list(overcast_main.ZIP_TEMP_STORAGE.iterdir())
        self.assertEqual(remaining_zips, [])

        # Test bulk delete (move to Trash) of 1 file + 1 folder
        del_res = self.client.post(
            "/api/files/bulk-delete",
            json={
                "fileIds": [created_ids[0]],
                "folderPaths": ["home/Projects/"],
                "permanent": False,
            },
        )
        self.assertEqual(del_res.status_code, 200)
        del_data = del_res.get_json()
        self.assertEqual(del_data["deletedCount"], 2)
        self.assertEqual(del_data["failed"], [])

        # Only beta.txt should remain in active files
        active_files = self.client.get("/api/files").get_json()
        self.assertEqual(len(active_files), 1)
        self.assertEqual(active_files[0]["FileName"], "beta.txt")

        # Trash should have 2 files
        trash_files = self.client.get("/api/trash").get_json()
        self.assertEqual(len(trash_files), 2)

        # Bulk permanent delete from Trash
        perm_res = self.client.post(
            "/api/files/bulk-delete",
            json={
                "fileIds": [t["UniqueID"] for t in trash_files],
                "permanent": True,
            },
        )
        self.assertEqual(perm_res.status_code, 200)
        self.assertEqual(perm_res.get_json()["deletedCount"], 2)
        self.assertEqual(self.client.get("/api/trash").get_json(), [])

    def test_08_abandoned_upload_cleanup_policy(self):
        init_res = self.client.post(
            "/api/uploads/init",
            json={
                "fileName": "stale.bin",
                "filePath": "home/",
                "totalSize": 1024,
                "chunkSize": 64 * 1024,
            },
        )
        upload_id = init_res.get_json()["uploadId"]
        session_dir = overcast_main.CHUNK_TEMP_STORAGE / upload_id
        self.assertTrue(session_dir.exists())

        # Backdate UpdatedAt in DB beyond TTL
        old_time = (datetime.now() - timedelta(days=2)).isoformat(timespec="seconds")
        conn = dbHandlers.getConnection()
        conn.execute(
            "UPDATE UploadSessions SET UpdatedAt = ? WHERE UploadID = ?",
            (old_time, upload_id),
        )
        conn.close()

        overcast_main.cleanupAbandonedTempFiles()
        self.assertFalse(session_dir.exists())
        self.assertIsNone(dbHandlers.getUploadSession(upload_id))


if __name__ == "__main__":
    unittest.main(verbosity=2)
