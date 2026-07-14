###############################################################################
# Stage 1: Builder
###############################################################################
FROM node:24-slim AS builder

WORKDIR /usr/src/microsoft-rewards-script

ENV PLAYWRIGHT_BROWSERS_PATH=0

# Copy package files
COPY package.json package-lock.json tsconfig.json ./

# Install all dependencies required to build the script
RUN npm ci --ignore-scripts

# Copy source and build
COPY . .
RUN npm run build

# Remove build dependencies, and reinstall only runtime dependencies
RUN rm -rf node_modules \
    && npm ci --omit=dev --ignore-scripts \
    && npm cache clean --force

###############################################################################
# Stage 2: Runtime
###############################################################################
FROM node:24-slim AS runtime

WORKDIR /usr/src/microsoft-rewards-script

# === 国内构建加速（fork 维护者添加）===
# 在中国大陆构建时，官方 deb.debian.org 与 playwright CDN 速度极慢（实测约 200KB/s，
# 完整构建需 1 小时以上）。切换到清华 apt 镜像 + npmmirror 二进制镜像可大幅提速。
# 如需回退官方源，删除下面 2 段（sed 行与 ENV 下载 host）即可，不影响运行期逻辑。
RUN sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g; s|http://security.debian.org|https://mirrors.tuna.tsinghua.edu.cn/debian-security|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g; s|security.debian.org|mirrors.tuna.tsinghua.edu.cn/debian-security|g' /etc/apt/sources.list 2>/dev/null || true
ENV PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright \
    PATCHRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright
# === 国内构建加速结束 ===

# Set production environment variables
ENV NODE_ENV=production \
    TZ=UTC \
    PLAYWRIGHT_BROWSERS_PATH=0 \
    FORCE_HEADLESS=1 \
    NODE_OPTIONS=--disable-warning=ExperimentalWarning

# Install minimal system libraries required for Chromium headless to run,
# plus jq (for config generation/patching) and gettext-base (for envsubst)
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    gettext-base \
    jq \
    tzdata \
    ca-certificates \
    libglib2.0-0 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libasound2 \
    libflac12 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libdrm2 \
    libgbm1 \
    libdav1d6 \
    libx11-6 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    libdouble-conversion3 \
    fonts-liberation \
    fonts-noto-core \
    fonts-noto-color-emoji \
    fonts-freefont-ttf \
    fonts-droid-fallback \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy compiled application and dependencies from builder stage
COPY --from=builder /usr/src/microsoft-rewards-script/dist ./dist
COPY --from=builder /usr/src/microsoft-rewards-script/package*.json ./
COPY --from=builder /usr/src/microsoft-rewards-script/node_modules ./node_modules

# Install patchright's stealth-patched Chromium headless shell.
# The container is headless-only so the full browser isn't needed; then clean up
RUN set -eux; \
    npx patchright install --with-deps --only-shell chromium; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy config example into the image so entrypoint can use it as a fallback
# when the user hasn't mounted their own config.json
COPY config.example.json ./config.example.json

# config.json is managed via the ./config bind mount (compose.yaml mounts
# ./config to /usr/src/microsoft-rewards-script/config). On first run the
# entrypoint generates config/config.json from this example if none exists,
# then symlinks it to the project root where the script expects it.
# Accounts come from ACCOUNT_N_* env vars, so no accounts.json is needed.

# Copy runtime scripts with proper permissions from the start
COPY --chmod=755 scripts/docker/run_daily.sh ./scripts/docker/run_daily.sh
COPY --chmod=644 src/crontab.template /etc/cron.d/microsoft-rewards-cron.template
COPY --chmod=755 scripts/docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Entrypoint handles TZ, accounts/config generation, initial run toggle,
# cron templating & launch
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sh", "-c", "echo 'Container started; cron is running.'"]