# Dockerfile — сборка Open5GS (4G EPC) под linux/arm64 из исходников.
#
# Сборка выполняется на компьютере через docker buildx --platform linux/arm64
# (QEMU-эмуляция), образ переносится на pi5 (aarch64) через docker save/load.
#
# Собранные демоны: mmed, hssd, sgwcd, sgwud, pgwcd, pgwud, pcrfd.
#
# ВАЖНО про WebUI: в Open5GS v2.7.2 WebUI — это ОТДЕЛЬНОЕ Node.js/Next-приложение
# (каталог webui/ в исходниках), НЕ часть meson-сборки C-демонов. Официальный образ
# webui (docker/webui/Dockerfile) собирается на node:19 (npm ci + npm run build).
# Поэтому здесь мы: (1) собираем webui в builder-стейдже на Node 18, (2) кладём
# результат + Node в runtime-стейдж — так в ОДНОМ образе и ядро, и WebUI.
#
# Метка версии Open5GS задаётся build-arg OPEN5GS_VERSION (tag/revision).

ARG OPEN5GS_VERSION=v2.7.2

# ---------- Builder ----------
FROM debian:bookworm-slim AS builder
ARG OPEN5GS_VERSION

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates git meson ninja-build gcc g++ pkg-config flex bison \
    curl ca-certificates gnupg python3-pip python3-setuptools cmake \
    libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libidn11-dev \
    libmongoc-dev libbson-dev libyaml-dev libmicrohttpd-dev \
    libcurl4-gnutls-dev libnghttp2-dev libtins-dev libtalloc-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 18 (только для сборки WebUI в builder; в runtime ставится отдельно) ---
# v2.7.2 WebUI собран на Next/React и требует Node (18 LTS совместим). Ставим
# через NodeSource (арх-независимо: скрипт подставит нужную arm64 сборку).
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --recursive --depth 1 --branch ${OPEN5GS_VERSION} \
    https://github.com/open5gs/open5gs.git open5gs

WORKDIR /src/open5gs
# -Dtests=false: тесты не нужны в образе; при НАТИВНОЙ сборке на aarch64 (без cross)
# meson иначе собирает весь набор тестов (~120 таргетов) — лишнее время.
RUN meson setup build --prefix=/usr --libdir=lib -Dtests=false \
    && ninja -C build \
    && ninja -C build install \
    && mkdir -p /prom-copy \
    && find /usr/lib -name 'libprom*.so*' -exec cp -av {} /prom-copy/ \;

# --- WebUI (Node/Next приложение из webui/, НЕ часть meson-сборки) ---
# npm clean-install по package-lock.json + next build. Проверено на Node 18 (amd64):
# next 3.x собирается без --openssl-legacy-provider. Кладём результат в /webui,
# откуда runtime-стейдж копирует приложение целиком (node_modules нужны в рантайме).
WORKDIR /src/open5gs/webui
RUN npm clean-install --no-audit --no-fund \
    && NODE_ENV=production npm run build \
    && mkdir -p /webui \
    && cp -a .next package.json node_modules server pages src static /webui/

# ---------- Runtime ----------
FROM debian:bookworm-slim AS runtime
ARG OPEN5GS_VERSION

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 \
    libmongoc-1.0-0 libbson-1.0-0 libyaml-0-2 libmicrohttpd12 \
    libcurl3-gnutls libnghttp2-14 libtalloc2 libtins4.0 \
    iproute2 iptables curl ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/open5gs /root/.cache/open5gs

# --- Node.js 18 в runtime — для запуска WebUI ---
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Копируем установленные бинарники Open5GS
COPY --from=builder /usr/bin/open5gs-* /usr/bin/
# Библиотеки Open5GS (meson --prefix=/usr ставит их в /usr/lib, а не в multiarch dir)
COPY --from=builder /usr/lib/libogs*.so* /usr/lib/
# Библиотеки freeDiameter (submodule) — нужны для S6a
COPY --from=builder /usr/lib/libfd*.so* /usr/lib/
# prometheus-client-c (metrics) — кладётся в архитектурный multiarch-каталог
# (/usr/lib/<triplet>); в builder собраны в /prom-copy. Копируем оттуда в /usr/lib.
COPY --from=builder /prom-copy/ /usr/lib/
# Конфиги freeDiameter (устанавливаются в /etc/freeDiameter)
COPY --from=builder /etc/freeDiameter /etc/freeDiameter
# Расширения freeDiameter (.fdx) — загружаются из /usr/lib/freeDiameter
COPY --from=builder /usr/lib/freeDiameter /usr/lib/freeDiameter
RUN ldconfig || true

# --- WebUI: собранное Node/Next приложение (без пересборки в рантайме) ---
COPY --from=builder /webui /opt/open5gs/webui
# Стартовый скрипт WebUI (ожидание Mongo + seed админа + запуск сервера)
COPY webui/start-webui.sh /opt/open5gs/start-webui.sh
RUN chmod +x /opt/open5gs/start-webui.sh

# Конфиги по умолчанию монтируются как volume (--config).
# Точка входа — bash, чтобы можно было запускать любой демон (open5gs-mmed и т.д.).
ENTRYPOINT ["/usr/bin/open5gs-mmed"]
