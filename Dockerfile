# =============================================================================
# Sirchmunk Docker Image — Full Format Support
# Multi-stage build: Node.js (frontend) → Python (backend + runtime)
# Supports: PDF, DOCX, PPTX, XLSX/XLS, ODT/ODS/ODP, RTF, EPUB, CSV, HTML,
#           images (OCR), audio/video, plain text, code files, etc.
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build WebUI static assets
# ---------------------------------------------------------------------------
FROM docker.m.daocloud.io/library/node:20-slim AS frontend-builder

WORKDIR /build/web
COPY web/package.json web/package-lock.json* ./
RUN npm config set registry https://registry.npmmirror.com
RUN npm ci --prefer-offline

COPY web/ ./

ENV NEXT_BUILD_STATIC=true
ENV NEXT_PUBLIC_API_BASE=""
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: Python runtime
# ---------------------------------------------------------------------------
FROM docker.m.daocloud.io/library/python:3.12-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Use Alibaba Cloud mirror for Debian apt (faster in China)
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
    && sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true

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
            curl -fsSL https://ghfast.top/https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep_14.1.1-1_amd64.deb \
                -o /tmp/rg.deb && dpkg -i /tmp/rg.deb && rm /tmp/rg.deb; \
            RGA_ARCH="x86_64-unknown-linux-musl" ;; \
        arm64) \
            curl -fsSL https://ghfast.top/https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz \
                -o /tmp/rg.tar.gz \
            && tar -xzf /tmp/rg.tar.gz -C /tmp \
            && cp /tmp/ripgrep-14.1.1-aarch64-unknown-linux-gnu/rg /usr/local/bin/ \
            && rm -rf /tmp/rg*; \
            RGA_ARCH="aarch64-unknown-linux-gnu" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL https://ghfast.top/https://github.com/phiresky/ripgrep-all/releases/download/v0.10.10/ripgrep_all-v0.10.10-${RGA_ARCH}.tar.gz \
        -o /tmp/rga.tar.gz \
    && tar -xzf /tmp/rga.tar.gz -C /tmp \
    && cp /tmp/ripgrep_all-*/rga /usr/local/bin/ \
    && cp /tmp/ripgrep_all-*/rga-preproc /usr/local/bin/ \
    && rm -rf /tmp/rga* /tmp/ripgrep_all*

WORKDIR /app

# Install Python dependencies (core + web + mcp — no docs/tests in production)
COPY requirements/ requirements/
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com \
    -r requirements/core.txt \
    -r requirements/web.txt \
    -r requirements/mcp.txt

# Copy source code and install
COPY src/ src/
COPY pyproject.toml setup.cfg* README.md ./
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -e ".[mcp,web]"

# Verify critical format-support tools are available
RUN python -c "\
import shutil, sys\n\
tools = ['rg', 'rga', 'pandoc', 'pdftotext', 'ffmpeg', 'tesseract']\n\
missing = [t for t in tools if not shutil.which(t)]\n\
if missing:\n\
    print(f'WARNING: Missing tools: {missing}', file=sys.stderr)\n\
else:\n\
    print('All format-support tools verified OK')\n\
" && python -c "\
import shutil, sys\n\
py_tools = ['xlsx2csv']\n\
missing = [t for t in py_tools if not shutil.which(t)]\n\
if missing:\n\
    print(f'WARNING: Missing Python CLI tools: {missing}', file=sys.stderr)\n\
else:\n\
    print('All Python CLI tools verified OK')\n\
" && python -c "\
# Verify kreuzberg can extract Excel files\n\
import sys\n\
try:\n\
    from kreuzberg._extractors._spread_sheet import SpreadSheetExtractor\n\
    print('kreuzberg Excel extractor available')\n\
except Exception as e:\n\
    print(f'WARNING: kreuzberg Excel extractor failed: {e}', file=sys.stderr)\n\
    sys.exit(1)\n\
"

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
