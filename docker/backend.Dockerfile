# syntax=docker/dockerfile:1.7
# Terra-Cogitia Back-End code, two targets:
#   --target api     Cogitia-BackEnd  (FastAPI / uvicorn on :8201)
#   --target worker  Cogitia-Worker   (media jobs: python -m media.worker; adds ffmpeg)
#
# Build context : ../terracogitia_backend
# - No model runs here: Whisper and Laya are served by the Cogitia-Models container
#   (docker/models.Dockerfile), reached over NetCogitia by the AI layer (AI_MODELS_URL).
# - ffmpeg is installed only in the worker target, so the API image stays slim.
# - Test-only packages (pytest*) are excluded from the runtime images.

FROM python:3.12-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt /tmp/requirements.txt
RUN grep -viE '^(pytest|pytest-asyncio)==' /tmp/requirements.txt > /tmp/requirements.runtime.txt \
 && pip install -r /tmp/requirements.runtime.txt

FROM python:3.12-slim-bookworm AS api
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home --home-dir /home/app --shell /usr/sbin/nologin app \
 && mkdir -p /app /data \
 && chown app:app /app /data
COPY --from=build /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_DATA_DIR=/data
WORKDIR /app
COPY --chown=app:app . .
USER app
EXPOSE 8201
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8201/openapi.json', timeout=8)" || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8201", "--proxy-headers", "--forwarded-allow-ips", "*"]

# --- Media worker: same code + ffmpeg (Debian bookworm package; recipe verified in the media plan §2.3).
FROM api AS worker
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
USER app
ENV MEDIA_WORKER_ALIVE_FILE=/tmp/media-worker.alive
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import os, sys, time; f = os.environ['MEDIA_WORKER_ALIVE_FILE']; sys.exit(0 if os.path.exists(f) and time.time() - os.path.getmtime(f) < 60 else 1)"
CMD ["python", "-m", "media.worker"]
