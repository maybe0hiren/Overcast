FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOST=0.0.0.0 \
    PORT=8000 \
    STORAGE=/data/storage \
    PREVIEW_STORAGE=/data/preview \
    TEMP_STORAGE=/data/temp \
    DATABASE_PATH=/data/database/database.db \
    CHUNK_SIZE=8388608 \
    CHUNK_UPLOAD_SIZE=4194304 \
    MAX_UPLOAD_SIZE=21474836480 \
    UPLOAD_SESSION_TTL_SECONDS=86400 \
    GUNICORN_WORKERS=2 \
    GUNICORN_THREADS=8 \
    GUNICORN_TIMEOUT=600

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates sqlite3 && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app

RUN mkdir -p /data/storage /data/preview /data/temp /data/database

EXPOSE 8000

HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/api/health || exit 1

CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT:-8000} --workers ${GUNICORN_WORKERS:-2} --threads ${GUNICORN_THREADS:-8} --timeout ${GUNICORN_TIMEOUT:-600} --access-logfile - --error-logfile - main:app"]

