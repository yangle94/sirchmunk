# =============================================================================
# Sirchmunk Docker Image — Full Format Support
# Multi-stage build: Node.js (frontend) → Python (backend + runtime)
# Supports: PDF, DOCX, PPTX, XLSX/XLS, ODT/ODS/ODP, RTF, EPUB, CSV, HTML,
#           images (OCR), audio/video, plain text, code files, etc.
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build WebUI static assets
# ---------------------------------------------------------------------------
FROM node:20-slim AS frontend-builder

WORKDIR /build/web
COPY web/package.json web/package-lock.json* ./
RUN npm ci --prefer-offline

COPY web/ ./

ENV NEXT_BUILD_STATIC=true
ENV NEXT_PUBLIC_API_BASE=""
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: Python runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# System dependencies for all supported file formats:
#   - poppler-utils: pdftotext (PDF text extraction via rga)
#   - pandoc: DOCX, RTF, EPUB, ODT, HTML, LaTeX, RST, etc. (rga + kreuzberg)
#   - tesseract-ocr + tesseract-ocr-eng + tesseract-ocr-chi-sim: OCR for images
#   - ffmpeg + ffprobe: audio/video metadata and transcription
#   - catdoc: legacy .doc (Word 97-2003) text extraction
#   - antiword: alternative .doc extraction fallback
#   - unrtf: RTF to text conversion
#   - djvulibre-bin: DjVu text extraction
#   - build-essential: needed for Python C extensions (python-calamine, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        git \
        poppler-utils \
        pandoc \
        tesseract-ocr \
        tesseract-ocr-eng \
        tesseract-ocr-chi-sim \
        ffmpeg \
        catdoc \
        antiword \
        unrtf \
        djvulibre-bin \
        vim \
        less \
        procps \
        net-tools \
        htop \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'alias ll="ls -alF"' >> /etc/bash.bashrc \
    && echo 'alias la="ls -A"' >> /etc/bash.bashrc \
    && echo 'alias l="ls -CF"' >> /etc/bash.bashrc

# Install ripgrep and ripgrep-all (architecture-aware)
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) \
            curl -fsSL https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep_14.1.1-1_amd64.deb \
                -o /tmp/rg.deb && dpkg -i /tmp/rg.deb && rm /tmp/rg.deb; \
            RGA_ARCH="x86_64-unknown-linux-musl" ;; \
        arm64) \
            curl -fsSL https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz \
                -o /tmp/rg.tar.gz \
            && tar -xzf /tmp/rg.tar.gz -C /tmp \
            && cp /tmp/ripgrep-14.1.1-aarch64-unknown-linux-gnu/rg /usr/local/bin/ \
            && rm -rf /tmp/rg*; \
            RGA_ARCH="aarch64-unknown-linux-gnu" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL https://github.com/phiresky/ripgrep-all/releases/download/v0.10.10/ripgrep_all-v0.10.10-${RGA_ARCH}.tar.gz \
        -o /tmp/rga.tar.gz \
    && tar -xzf /tmp/rga.tar.gz -C /tmp \
    && cp /tmp/ripgrep_all-*/rga /usr/local/bin/ \
    && cp /tmp/ripgrep_all-*/rga-preproc /usr/local/bin/ \
    && rm -rf /tmp/rga* /tmp/ripgrep_all*

WORKDIR /app

# Install Python dependencies (core + web + mcp — no docs/tests in production)
# Pre-install PyTorch CPU-only to avoid pulling ~2GB CUDA packages
COPY requirements/ requirements/
RUN pip install --no-cache-dir \
    --index-url https://download.pytorch.org/whl/cpu \
    torch
RUN pip install --no-cache-dir \
    -r requirements/core.txt \
    -r requirements/web.txt \
    -r requirements/mcp.txt

# Copy source code and install
COPY src/ src/
COPY pyproject.toml setup.cfg* README.md ./
RUN pip install --no-cache-dir -e ".[mcp,web]"

# Verify critical format-support tools are available
RUN python -c "import shutil; tools=['rg','rga','pandoc','pdftotext','ffmpeg','tesseract','xlsx2csv']; missing=[t for t in tools if not shutil.which(t)]; print(f'WARNING: Missing tools: {missing}', __import__('sys').stderr) if missing else print('All format-support tools verified OK')" \
    && python -c "from kreuzberg._extractors._spread_sheet import SpreadSheetExtractor; print('kreuzberg Excel extractor available')"

# Copy config
COPY config/ config/

# Copy pre-built frontend assets
COPY --from=frontend-builder /build/web/out /app/web_static

# ---------------------------------------------------------------------------
# Pre-download embedding model into /app (not under /data/sirchmunk).
# When users mount -v host:/data/sirchmunk, the mount overrides the image's
# /data/sirchmunk, so the model must live under /app to survive. Runtime
# uses EMBEDDING_CACHE_DIR=/app/.cache/models so the app finds it.
# ---------------------------------------------------------------------------
ENV SIRCHMUNK_WORK_PATH=/data/sirchmunk
ENV EMBEDDING_CACHE_DIR=/app/.cache/models

RUN mkdir -p /app/.cache/models

RUN MODELSCOPE_CACHE=/app/.cache/models \
    python -c "\
from sirchmunk.utils.embedding_util import EmbeddingUtil; \
EmbeddingUtil.preload_model(cache_dir='/app/.cache/models')"

# Entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8584

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sirchmunk", "web", "serve", "--host", "0.0.0.0", "--port", "8584"]
