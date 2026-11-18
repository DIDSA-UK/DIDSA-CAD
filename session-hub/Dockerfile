# Small on purpose: Python and FastAPI only (no OCCT, no Chromium), so rebuilding it never rebuilds the backend. ONE worker: rooms
# live in this process's memory (never raise --workers).
FROM python:3.11-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY tests ./tests

# SESSION_HUB_API_KEY must be set, or the service refuses to start.
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8300", "--workers", "1"]
