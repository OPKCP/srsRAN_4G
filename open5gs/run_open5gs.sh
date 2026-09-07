#!/usr/bin/env bash
# ==============================================================================
# run_open5gs.sh — запуск всех NF Open5GS (4G EPC) внутри контейнера.
# Используется как command для контейнера open5gs (network host).
#
# Последовательность запуска (порядок важен):
#   mmed -> hssd -> pcrfd -> sgwcd -> sgwud -> smfd -> upfd
# (mme выше всех, чтобы поднял S1AP; остальные после).
#
# Логи пишутся в /var/log/open5gs/ (см. конфиги).
# ==============================================================================
set -e

LOGDIR=/var/log/open5gs
mkdir -p "$LOGDIR"

# Задержка между запусками NF (сек)
DELAY=${OPEN5GS_START_DELAY:-1}

start_nf() {
    local bin="$1"
    echo "[run_open5gs] start: $bin"
    # Демоны сами демонизируются (fork), но для надёжности запускаем в фоне
    "$bin" &
    sleep "$DELAY"
}

start_nf /usr/bin/open5gs-mmed
start_nf /usr/bin/open5gs-hssd
start_nf /usr/bin/open5gs-pcrfd
start_nf /usr/bin/open5gs-sgwcd
start_nf /usr/bin/open5gs-sgwud
start_nf /usr/bin/open5gs-smfd
start_nf /usr/bin/open5gs-upfd

echo "[run_open5gs] Все NF запущены. Ожидание (Ctrl-C для остановки)..."
# Держим контейнер живым
tail -f /dev/null
