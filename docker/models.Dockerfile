# syntax=docker/dockerfile:1.7
# Terra-Cogitia Models (Cogitia-Models, FastAPI on :8300, internal network only).
#
# Build context : ../terracogitia_backend/model_server
# Hosts the open-weight models used by the Back-End through HTTP:
#   - Laya (decision model, Apache-2.0)  -> POST /v1/decide
#   - Whisper (speech-to-text, MIT)       -> POST /v1/audio/transcriptions (OpenAI-compatible)
#   - Piper voices (text-to-speech)       -> POST /v1/audio/speech (OpenAI-compatible)
#     Engine piper-tts (GPL-3.0, server-side use). Voices from rhasspy/piper-voices at a pinned revision;
#     PIPER_VOICES lists them (path in the repository, without extension). Allowed voice licences only:
#     fr_FR-siwis-medium CC BY 4.0, fr_FR-gilles-low CC0, en_US-ljspeech-medium public domain,
#     en_GB-alba-medium CC BY 4.0 (non-commercial / AGPL voices such as en_US-ryan or fr_FR-tom excluded).
# - torch is installed from the CPU-only index (no CUDA).
# - Weights are downloaded at BUILD time at a pinned revision; the runtime is offline
#   (HF_HUB_OFFLINE=1), so a running container never downloads model files.
# - triton (GPU kernel compiler pulled in by openai-whisper) is removed: CPU-only server.

ARG LAYA_REVISION=55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851
ARG LAYA_MODELS=multilingual
ARG WHISPER_MODELS=base
ARG PIPER_VOICES_REVISION=c10ece1aade47bb51c153c893d14e5bf8e5b7117
ARG PIPER_VOICES=fr/fr_FR/siwis/medium/fr_FR-siwis-medium,fr/fr_FR/gilles/low/fr_FR-gilles-low,en/en_US/ljspeech/medium/en_US-ljspeech-medium,en/en_GB/alba/medium/en_GB-alba-medium

FROM python:3.12-slim-bookworm AS build
ARG LAYA_REVISION
ARG LAYA_MODELS
ARG WHISPER_MODELS
ARG PIPER_VOICES_REVISION
ARG PIPER_VOICES
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt /tmp/requirements.txt
RUN TORCH_VERSION="$(grep -E '^torch==' /tmp/requirements.txt | cut -d= -f3)" \
 && test -n "$TORCH_VERSION" \
 && pip install --index-url https://download.pytorch.org/whl/cpu "torch==${TORCH_VERSION}" \
 && grep -vE '^torch==' /tmp/requirements.txt > /tmp/requirements.models.txt \
 && pip install -r /tmp/requirements.models.txt \
 && (pip uninstall -y triton || true)
ENV XDG_CACHE_HOME=/opt/cache \
    HF_HOME=/opt/cache/huggingface
# Weights baked into the image (pinned Laya commit; Whisper sizes from WHISPER_MODELS).
RUN python -c "import os, whisper; [whisper.load_model(m) for m in os.environ['WHISPER_MODELS'].split(',')]"
RUN python -c "import os; from laya import Router; r = Router(device='cpu', revision=os.environ['LAYA_REVISION'], max_loaded=4); [r.load(m) for m in os.environ['LAYA_MODELS'].split(',')]"
# Piper voices (.onnx + .onnx.json) at the pinned revision of rhasspy/piper-voices.
RUN mkdir -p /opt/voices && python -c "import os, shutil; from huggingface_hub import hf_hub_download; rev=os.environ['PIPER_VOICES_REVISION']; [shutil.copy(hf_hub_download('rhasspy/piper-voices', p + ext, revision=rev), '/opt/voices/' + p.rsplit('/', 1)[1] + ext) for p in os.environ['PIPER_VOICES'].split(',') if p for ext in ('.onnx', '.onnx.json')]" && ls -la /opt/voices

FROM python:3.12-slim-bookworm
ARG LAYA_REVISION
ARG LAYA_MODELS
ARG WHISPER_MODELS
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10002 --create-home --home-dir /home/models --shell /usr/sbin/nologin models \
 && mkdir -p /app
COPY --from=build /opt/venv /opt/venv
# The Hugging Face cache stays writable for the runtime user (lock files, even offline).
COPY --from=build --chown=models:models /opt/cache /opt/cache
COPY --from=build --chown=models:models /opt/voices /opt/voices
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    XDG_CACHE_HOME=/opt/cache \
    HF_HOME=/opt/cache/huggingface \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    LAYA_REVISION=${LAYA_REVISION} \
    LAYA_MODELS=${LAYA_MODELS} \
    WHISPER_MODELS=${WHISPER_MODELS}
WORKDIR /app
COPY --chown=models:models app.py ./
USER models
EXPOSE 8300
# Models are preloaded at startup (MODELS_PRELOAD=1): allow time before the first health check.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8300/health', timeout=8)" || exit 1
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8300"]
