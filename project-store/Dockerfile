# Small on purpose: Python and FastAPI only, no OCCT and no Chromium, so rebuilding it never rebuilds the backend and it fits
# beside the backend on a 4 GB Pi. ONE worker (writes are serialised by a lock inside the process): never raise --workers.
FROM python:3.11-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY tests ./tests

# The projects live in a mounted volume (see docker-compose.example.yml); PROJECT_STORE_API_KEY must be set, or the service refuses to start.
ENV PROJECT_STORE_ROOT=/data
VOLUME /data

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8200", "--workers", "1"]
