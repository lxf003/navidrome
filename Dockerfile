FROM --platform=$BUILDPLATFORM ghcr.io/crazy-max/osxcross:14.5-debian AS osxcross

########################################################################################################################
### Build xx (original image: tonistiigi/xx)
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/alpine:3.19 AS xx-build

# v1.5.0
ENV XX_VERSION=b4e4c451c778822e6742bfc9d9a91d7c7d885c8a

RUN apk add -U --no-cache git
RUN git clone https://github.com/tonistiigi/xx && \
    cd xx && \
    git checkout ${XX_VERSION} && \
    mkdir -p /out && \
    cp src/xx-* /out/

RUN cd /out && \
    ln -s xx-cc /out/xx-clang && \
    ln -s xx-cc /out/xx-clang++ && \
    ln -s xx-cc /out/xx-c++ && \
    ln -s xx-apt /out/xx-apt-get

# xx mimics the original tonistiigi/xx image
FROM scratch AS xx
COPY --from=xx-build /out/ /usr/bin/

########################################################################################################################
### Get TagLib
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/alpine:3.19 AS taglib-build
ARG TARGETPLATFORM
ARG CROSS_TAGLIB_VERSION=2.1.1-1
ENV CROSS_TAGLIB_RELEASES_URL=https://github.com/navidrome/cross-taglib/releases/download/v${CROSS_TAGLIB_VERSION}/

# wget in busybox can't follow redirects
RUN <<EOT
    apk add --no-cache wget
    PLATFORM=$(echo ${TARGETPLATFORM} | tr '/' '-')
    FILE=taglib-${PLATFORM}.tar.gz

    DOWNLOAD_URL=${CROSS_TAGLIB_RELEASES_URL}${FILE}
    wget ${DOWNLOAD_URL}

    mkdir /taglib
    tar -xzf ${FILE} -C /taglib
EOT

########################################################################################################################
### Build Navidrome UI
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/node:lts-alpine AS ui
WORKDIR /app

# Install node dependencies
COPY ui/package.json ui/package-lock.json ./
COPY ui/bin/ ./bin/
RUN npm ci

# Build bundle
COPY ui/ ./

# 1. 修改 PWA 应用名称 (vite.config.js)
RUN sed -i "s/name: 'Navidrome'/name: 'TinglePulse-Asmr'/g" vite.config.js && \
    sed -i "s/short_name: 'Navidrome'/short_name: 'TinglePulse'/g" vite.config.js

# 2. 修改浏览器标签页标题 (index.html)
#    ✅ 路径已修正为 index.html (Vite 项目根目录)
RUN sed -i 's/<title>Navidrome<\/title>/<title>TinglePulse-Asmr<\/title>/g' index.html

# 3. 修改登录页大标题 (Login.jsx)
#    注意：替换双引号包裹的字符串和标签内容
RUN sed -i 's/"Navidrome"/"TinglePulse-Asmr"/g' src/layout/Login.jsx && \
    sed -i 's/>Navidrome</>TinglePulse-Asmr</g' src/layout/Login.jsx

# 4. 修改页面顶部标题组件 (Title.jsx)
#    这是控制进入首页后左上角显示名称的关键
#    第一条命令替换带单引号的 'Navidrome' (用于代码逻辑)
#    第二条命令替换纯文本 Navidrome (用于显示)
RUN sed -i "s/'Navidrome'/'TinglePulse-Asmr'/g" src/common/Title.jsx && \
    sed -i 's/Navidrome/TinglePulse-Asmr/g' src/common/Title.jsx
# ============================================================

# ============================================================
# 💡【新增加】禁用 PWA 缓存逻辑
# 将 Service Worker 替换为一个“空”版本，只负责立即更新，不缓存任何文件。
# 这能确保所有请求都经过您的 .NET 网关，避免缓存导致 SSO 失效。
# ============================================================
RUN echo "self.addEventListener('install', () => self.skipWaiting()); self.addEventListener('activate', () => self.clients.claim());" > src/sw.js

# ============================================================

RUN npm run build -- --outDir=/build

FROM scratch AS ui-bundle
COPY --from=ui /build /build

########################################################################################################################
### Build Navidrome binary
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/golang:1.25-bookworm AS base
RUN apt-get update && apt-get install -y clang lld
COPY --from=xx / /
WORKDIR /workspace

FROM --platform=$BUILDPLATFORM base AS build

# Install build dependencies for the target platform
ARG TARGETPLATFORM

RUN xx-apt install -y binutils gcc g++ libc6-dev zlib1g-dev
RUN xx-verify --setup

RUN --mount=type=bind,source=. \
    --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download

ARG GIT_SHA
ARG GIT_TAG

RUN --mount=type=bind,source=. \
    --mount=from=ui,source=/build,target=./ui/build,ro \
    --mount=from=osxcross,src=/osxcross/SDK,target=/xx-sdk,ro \
    --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=from=taglib-build,target=/taglib,src=/taglib,ro <<EOT

    # Setup CGO cross-compilation environment
    xx-go --wrap
    export CGO_ENABLED=1
    export PKG_CONFIG_PATH=/taglib/lib/pkgconfig
    cat $(go env GOENV)

    # Only Darwin (macOS) requires clang (default), Windows requires gcc, everything else can use any compiler.
    # So let's use gcc for everything except Darwin.
    if [ "$(xx-info os)" != "darwin" ]; then
        export CC=$(xx-info)-gcc
        export CXX=$(xx-info)-g++
        export LD_EXTRA="-extldflags '-static -latomic'"
    fi
    if [ "$(xx-info os)" = "windows" ]; then
        export EXT=".exe"
    fi

    go build -tags=netgo -ldflags="${LD_EXTRA} -w -s \
        -X github.com/navidrome/navidrome/consts.gitSha=${GIT_SHA} \
        -X github.com/navidrome/navidrome/consts.gitTag=${GIT_TAG}" \
        -o /out/navidrome${EXT} .
EOT

# Verify if the binary was built for the correct platform and it is statically linked
RUN xx-verify --static /out/navidrome*

FROM scratch AS binary
COPY --from=build /out /

########################################################################################################################
### Build Final Image
FROM public.ecr.aws/docker/library/alpine:3.19 AS final
LABEL maintainer="deluan@navidrome.org"
LABEL org.opencontainers.image.source="https://github.com/navidrome/navidrome"

# Install ffmpeg and mpv
RUN apk add -U --no-cache ffmpeg mpv sqlite

# Copy navidrome binary
COPY --from=build /out/navidrome /app/

VOLUME ["/data", "/music"]
ENV ND_MUSICFOLDER=/music
ENV ND_DATAFOLDER=/data
ENV ND_CONFIGFILE=/data/navidrome.toml
ENV ND_PORT=4533
ENV GODEBUG="asyncpreemptoff=1"
RUN touch /.nddockerenv

EXPOSE ${ND_PORT}
WORKDIR /app

ENTRYPOINT ["/app/navidrome"]

