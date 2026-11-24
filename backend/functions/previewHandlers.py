import os
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

BASE_PATH = Path(__file__).resolve().parents[1]


def getPreview(uniqueID: str, fileName: str, fileFormat: str):
    previewStorage = Path(
        os.getenv("PREVIEW_STORAGE", "preview/")
    )

    if not previewStorage.is_absolute():
        previewStorage = BASE_PATH / previewStorage

    previewPath = previewStorage / f"{uniqueID}.{fileFormat.lower()}"

    if previewPath.exists():
        return str(previewPath)

    return None
