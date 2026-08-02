# syntax=docker/dockerfile:1.7
# ============================================================
# Многоэтапный Dockerfile для проекта srsRAN_4G
#
# Этап 1 (builder):  компиляция проекта в заранее подготовленной базе.
# Этап 2 (runtime):  итоговый образ на том же базовом слое с артефактами.
#
# Базовый образ ${BASE_IMAGE} должен быть собран заранее (build-base.*).
# Он собирается с --pull, гарантируя свежесть ubuntu:22.04.
# Основной образ НЕ требует --pull, так как стартует с локального/registry
# слоя ${BASE_IMAGE}, а не с публичного тега ubuntu:22.04.
# ============================================================

ARG BASE_IMAGE=ghcr.io/opkcp/srsran_4g/srsran_4g-base:base-amd64


# ============================================================
# ЭТАП 1: СБОРКА
# Базовый слой уже содержит зависимости и образы UHD.
# ============================================================
FROM ${BASE_IMAGE} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG GIT_BRANCH=unknown
ARG GIT_COMMIT_HASH=unknown
ENV GIT_BRANCH=${GIT_BRANCH}
ENV GIT_COMMIT_HASH=${GIT_COMMIT_HASH}

WORKDIR /src/srsRAN_4G

# Копируем исходный код проекта в образ.
# .dockerignore исключает build/, .git/ и прочие лишние файлы.
COPY . .

# Явно показываем build metadata, переданную с хоста, в логе сборки Docker.
RUN echo "[BUILD-INFO] GIT_BRANCH=${GIT_BRANCH}" \
 && echo "[BUILD-INFO] GIT_COMMIT_HASH=${GIT_COMMIT_HASH}"

# Собираем проект и устанавливаем артефакты в /usr/local:
# - CMAKE_INSTALL_PREFIX=/usr/local : путь установки исполняемых файлов
# - ENABLE_UHD=ON                  : поддержка SDR USRP
# - ENABLE_ZEROMQ=ON               : поддержка ZeroMQ (эмуляция без железа)
# - CMAKE_BUILD_TYPE=Release       : оптимизированная сборка
# - ENABLE_4G=ON                : 4G включён
#
# Cache mount используется ТОЛЬКО для ccache (кэш объектных файлов компилятора).
# Директория build/ создаётся заново в каждом слое — так cmake всегда
# перегенерарирует из актуальных исходников, избегая stale-артефактов.
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    mkdir -p build \
    && cd build \
    && cmake .. \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_UHD=ON \
        -DENABLE_ZEROMQ=ON \
        -DENABLE_4G=ON \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && ninja -j"$(nproc)" \
    && ninja install \
    && ldconfig


# ============================================================
# ЭТАП 2: RUNTIME
# Итоговый образ также стартует с базового слоя и получает только артефакты.
# ============================================================
FROM ${BASE_IMAGE} AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Копируем исполняемые файлы из сборочного образа:
# srsenb — eNodeB (базовая станция LTE)
# srsue  — UE (абонентское устройство)
# srsepc — EPC (ядро сети: MME, SGW, PGW, HSS)
# srsgnb — gNodeB (базовая станция NR/5G)
COPY --from=builder /usr/local/bin/srs*                /usr/local/bin/
COPY --from=builder /usr/local/bin/srsran_install_configs.sh /usr/local/bin/

# Копируем разделяемые библиотеки srsRAN из сборочного образа.
COPY --from=builder /usr/local/lib/libsrsran*          /usr/local/lib/

# Копируем шаблоны конфигурационных файлов и вспомогательные данные.
COPY --from=builder /usr/local/share/srsran/           /usr/local/share/srsran/

# Обновляем кэш динамического компоновщика после копирования библиотек.
RUN ldconfig

# Создаём директорию конфигурации и устанавливаем файлы по умолчанию.
# Шаблоны .conf.example копируются в /etc/srsran/ со снятием суффикса .example.
RUN mkdir -p /etc/srsran \
 && srsran_install_configs.sh service 2>/dev/null || true

# Объявляем том для конфигурационных файлов.
# Для изменения параметров с хоста монтируйте директорию:
#   docker run -v /path/to/host/configs:/etc/srsran ...
VOLUME ["/etc/srsran"]
VOLUME ["/var/log/srsran"]
VOLUME ["/usr/share/uhd/images"]

# Сетевые порты, используемые компонентами srsRAN:
# 36412/sctp — S1-MME (интерфейс eNodeB ↔ MME, S1AP)
# 36422/sctp — X2AP  (интерфейс eNodeB ↔ eNodeB, хэндовер)
# 2152/udp   — GTP-U  (пользовательские данные S1-U / X2-U)
# 36421/sctp — E2AP   (интерфейс RIC E2, O-RAN)
EXPOSE 36412/sctp 36422/sctp 2152/udp 36421/sctp

# HEALTHCHECK: srsenb слушает SCTP-порт 36412 (S1-MME).
# Проверяем, что процесс жив и порт открыт, используя ss + awk
# (SCTP-сокеты не видны через /proc/net/tcp).
# Интервал 30с, таймаут 10с, 3 попытки перед unhealthy, задержка 15с.
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD ss -lnp -S | awk '/srsenb/ && /36412/ {found=1} END {exit !found}' \
    || pgrep srsenb || exit 1

# Команда по умолчанию — запуск eNodeB с конфигурацией из тома.
# Для запуска ядра сети: docker run ... srsepc /etc/srsran/epc.conf
# Для запуска UE:        docker run ... srsue  /etc/srsran/ue.conf
CMD ["srsenb", "/etc/srsran/enb.conf"]
