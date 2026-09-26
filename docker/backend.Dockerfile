# syntax=docker/dockerfile:1.7
# Terra-Cogitia Back-End (FastAPI / uvicorn on :8201).
#
# Build context : ../terracogitia_backend
# - torch is installed from the CPU-only index (the default PyPI wheel pulls ~4 GB of CUDA).
# - The Whisper "base" model is downloaded at build time, so transcription needs no runtime download.
# - Test-only packages (pytest*) are excluded from the runtime image.
# - triton (GPU kernel compiler pulled in by openai-whisper, ~900 MB) is removed: CPU-only server.

FROM python:3.12-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt /tmp/requirements.txt
RUN TORCH_VERSION="$(grep -E '^torch==' /tmp/requirements.txt | cut -d= -f3)" \
 && test -n "$TORCH_VERSION" \
 && pip install --index-url https://download.pytorch.org/whl/cpu "torch==${TORCH_VERSION}" \
 && grep -viE '^(pytest|pytest-asyncio)==' /tmp/requirements.txt > /tmp/requirements.runtime.txt \
 && pip install -r /tmp/requirements.runtime.txt \
 && pip uninstall -y triton
ENV XDG_CACHE_HOME=/opt/cache
RUN python -c "import whisper; whisper.load_model('base')"

FROM python:3.12-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home --home-dir /home/app --shell /usr/sbin/nologin app \
 && mkdir -p /app /data \
 && chown app:app /app /data
COPY --from=build /opt/venv /opt/venv
COPY --from=build /opt/cache /opt/cache
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    XDG_CACHE_HOME=/opt/cache \
    APP_DATA_DIR=/data
WORKDIR /app
COPY --chown=app:app . .
USER app
EXPOSE 8201
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8201/openapi.json', timeout=8)" || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8201", "--proxy-headers", "--forwarded-allow-ips", "*"]
