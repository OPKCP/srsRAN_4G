# Dockerfile — сборка Open5GS (4G EPC) под linux/arm64 из исходников.
#
# Сборка выполняется на компьютере через docker buildx --platform linux/arm64
# (QEMU-эмуляция), образ переносится на pi5 (aarch64) через docker save/load.
#
# Собранные демоны: mmed, hssd, sgwcd, sgwud, pgwcd, pgwud, pcrfd.
# Также в образе есть mongosh/mongoimport (из mongodb-clients) для загрузки абонентов.
#
# Метка версии Open5GS задаётся build-arg OPEN5GS_VERSION (tag/revision).

ARG OPEN5GS_VERSION=v2.7.2

# ---------- Builder ----------
FROM debian:bookworm-slim AS builder
ARG OPEN5GS_VERSION

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates git meson ninja-build gcc g++ pkg-config flex bison \
    curl python3-pip python3-setuptools cmake \
    libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libidn11-dev \
    libmongoc-dev libbson-dev libyaml-dev libmicrohttpd-dev \
    libcurl4-gnutls-dev libnghttp2-dev libtins-dev libtalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --recursive --depth 1 --branch ${OPEN5GS_VERSION} \
    https://github.com/open5gs/open5gs.git open5gs

WORKDIR /src/open5gs
RUN meson setup build --prefix=/usr \
    && ninja -C build \
    && ninja -C build install

# ---------- Runtime ----------
FROM debian:bookworm-slim AS runtime
ARG OPEN5GS_VERSION

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 \
    libmongoc-1.0-0 libbson-1.0-0 libyaml-0-2 libmicrohttpd12 \
    libcurl3-gnutls libnghttp2-14 libtalloc2 libtins4.0 \
    iproute2 iptables curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/open5gs /root/.cache/open5gs

# Копируем установленные бинарники Open5GS
COPY --from=builder /usr/bin/open5gs-* /usr/bin/
# Библиотеки Open5GS (meson --prefix=/usr ставит их в /usr/lib, а не в multiarch dir)
COPY --from=builder /usr/lib/libogs*.so* /usr/lib/
# Библиотеки freeDiameter (submodule) — нужны для S6a
COPY --from=builder /usr/lib/libfd*.so* /usr/lib/
# prometheus-client-c (metrics) — ставится в multiarch dir
COPY --from=builder /usr/lib/aarch64-linux-gnu/libprom*.so* /usr/lib/aarch64-linux-gnu/
# Конфиги freeDiameter (устанавливаются в /etc/freeDiameter)
COPY --from=builder /etc/freeDiameter /etc/freeDiameter
# Расширения freeDiameter (.fdx) — загружаются из /usr/lib/freeDiameter
COPY --from=builder /usr/lib/freeDiameter /usr/lib/freeDiameter
RUN ldconfig || true

# Конфиги по умолчанию монтируются как volume (--config).
# Точка входа — bash, чтобы можно было запускать любой демон (open5gs-mmed и т.д.).
ENTRYPOINT ["/usr/bin/open5gs-mmed"]
