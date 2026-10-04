# syntax=docker/dockerfile:1.7
# Terra-Cogitia Voice (Cogitia-Voice, FastAPI on :8400, internal network only). OPTIONAL service:
# built and started only in the environments listing "voice" in optional_services (cogitia-registry.json).
#
# Build context : ../terracogitia_backend/voice_server
# Text-to-speech with voice cloning, VibeVoice-1.5B (Microsoft, MIT):
#   POST /v1/audio/speech (OpenAI-compatible + reference_audio for cloned voices), GET /v1/audio/voices.
# - Model code: vibevoice-community/VibeVoice at a pinned commit, installed WITHOUT its demo extras
#   (gradio, aiortc, datasets…); runtime dependencies are pinned in requirements.txt.
# - Weights (microsoft/VibeVoice-1.5B) and the Qwen2.5-1.5B tokenizer are downloaded at BUILD time at
#   pinned revisions; the runtime is offline (HF_HUB_OFFLINE=1). The model directory's
#   preprocessor_config.json is pointed at the baked tokenizer so nothing is fetched at start-up.
# - CPU by default (torch from the CPU index). On a GPU host:
#     --build-arg TORCH_INDEX=https://download.pytorch.org/whl/cu128   and run with GPU access.
# - The tokenizer directory name must contain "qwen" (VibeVoiceProcessor picks the tokenizer class from it).
# - Sample voices of the repository (demo/voices, MIT) are baked for tests without a cloned voice.

ARG VIBEVOICE_COMMIT=952326ddb264062466a888cf32a5b2f4e803e16e
ARG VIBEVOICE_REPO=microsoft/VibeVoice-1.5B
ARG VIBEVOICE_REVISION=c00898d257e6b46004e3e2866a47534085fb685a
ARG QWEN_TOKENIZER_REPO=Qwen/Qwen2.5-1.5B
ARG QWEN_TOKENIZER_REVISION=8faed761d45a263340a0528343f099c05c9a4323
ARG TORCH_INDEX=https://download.pytorch.org/whl/cpu

FROM python:3.12-slim-bookworm AS build
ARG VIBEVOICE_COMMIT
ARG VIBEVOICE_REPO
ARG VIBEVOICE_REVISION
ARG QWEN_TOKENIZER_REPO
ARG QWEN_TOKENIZER_REVISION
ARG TORCH_INDEX
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt /tmp/requirements.txt
RUN TORCH_VERSION="$(grep -E '^torch==' /tmp/requirements.txt | cut -d= -f3)" \
 && test -n "$TORCH_VERSION" \
 && pip install --index-url "$TORCH_INDEX" "torch==${TORCH_VERSION}" \
 && grep -vE '^torch==' /tmp/requirements.txt > /tmp/requirements.voice.txt \
 && pip install -r /tmp/requirements.voice.txt
# Model code at the pinned commit (no dependency resolution: the runtime set is pinned above).
RUN mkdir -p /opt/src /opt/vibevoice/voices \
 && curl -fsSL "https://codeload.github.com/vibevoice-community/VibeVoice/tar.gz/${VIBEVOICE_COMMIT}" | tar -xz -C /opt/src \
 && mv /opt/src/VibeVoice-* /opt/src/VibeVoice \
 && pip install --no-deps /opt/src/VibeVoice \
 && cp /opt/src/VibeVoice/demo/voices/*.wav /opt/vibevoice/voices/ \
 && cp /opt/src/VibeVoice/LICENSE /opt/vibevoice/LICENSE-VibeVoice \
 && rm -rf /opt/src
# Weights + tokenizer at pinned revisions; the processor is pointed at the local tokenizer.
RUN python - <<'PY'
import json, os
from huggingface_hub import snapshot_download
model = "/opt/vibevoice/model"
snapshot_download(os.environ["VIBEVOICE_REPO"], revision=os.environ["VIBEVOICE_REVISION"], local_dir=model,
                  allow_patterns=["*.json", "*.safetensors"])
snapshot_download(os.environ["QWEN_TOKENIZER_REPO"], revision=os.environ["QWEN_TOKENIZER_REVISION"],
                  local_dir="/opt/vibevoice/qwen2.5-tokenizer",
                  allow_patterns=["tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "LICENSE"])
cfg_path = os.path.join(model, "preprocessor_config.json")
cfg = json.load(open(cfg_path, encoding="utf-8"))
cfg["language_model_pretrained_name"] = "/opt/vibevoice/qwen2.5-tokenizer"
json.dump(cfg, open(cfg_path, "w", encoding="utf-8"), indent=2)
print("model files:", sorted(os.listdir(model)))
PY
# Import check at build time: a missing dependency fails the build, not the first narration.
RUN python -c "from vibevoice.modular.modeling_vibevoice_inference import VibeVoiceForConditionalGenerationInference; from vibevoice.processor.vibevoice_processor import VibeVoiceProcessor; VibeVoiceProcessor.from_pretrained('/opt/vibevoice/model'); print('vibevoice import OK')"

FROM python:3.12-slim-bookworm
ARG VIBEVOICE_REVISION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10003 --create-home --home-dir /home/cogvoice --shell /usr/sbin/nologin cogvoice \
 && mkdir -p /app
COPY --from=build /opt/venv /opt/venv
COPY --from=build --chown=cogvoice:cogvoice /opt/vibevoice /opt/vibevoice
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/home/cogvoice/.cache/huggingface \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    VIBEVOICE_MODEL_DIR=/opt/vibevoice/model \
    VIBEVOICE_VOICES_DIR=/opt/vibevoice/voices \
    VIBEVOICE_REVISION=${VIBEVOICE_REVISION}
WORKDIR /app
COPY --chown=cogvoice:cogvoice app.py ./
USER cogvoice
EXPOSE 8400
# /health answers while the model loads in the background (several minutes on CPU).
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8400/health', timeout=8)" || exit 1
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8400"]
