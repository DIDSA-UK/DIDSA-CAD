# Debian (not Ubuntu): Debian's apt "chromium" package is a real binary on
# both amd64 and arm64, unlike Ubuntu 24.04+'s "chromium-browser", which is
# a thin wrapper that shells out to `snap install chromium` at first run -
# confirmed the hard way (in this project's own dev sandbox: the package
# installs but the binary refuses to run with "requires the chromium snap
# to be installed", and snapd doesn't work in a plain container). Debian
# still ships a real, apt-installable Chromium, which is what makes this
# whole architecture buildable in a Docker container at all - including on
# the arm64 Raspberry Pi 5 this is meant to run on, alongside the existing
# OCCT backend (see docs/vr-recon-*.md).
FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

ENV BROWSER_RELAY_CHROME_BINARY=chromium

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY tests ./tests

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8100"]
