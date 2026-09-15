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

# --- Поднятие SGi-интерфейса абонентов (tun ogstun) ---
# UPF (v2.7.2) СОЗДАЁТ tun-устройство ogstun, но НЕ поднимает его (нет IFF_UP)
# и НЕ вешает на него адрес шлюза из upf.yaml (gateway: 10.0.0.1). Без этого
# интерфейс остаётся DOWN без адреса: абоненты получают IP из пула, маршрут до
# них уходит в дефолт вместо dev ogstun, трафик не терминируется -> NAT не
# срабатывает -> НЕТ ИНТЕРНЕТА (хотя attach/сигнализация в порядке).
# Исправляем: поднимаем ogstun и вешаем 10.0.0.1/24 (идемпотентно). Контейнеру
# это разрешает CAP_NET_ADMIN.
OGSTUN_DEV=ogstun
OGSTUN_GW=10.0.0.1/24
bring_up_sgi() {
  for _i in $(seq 1 15); do
    ip link show "$OGSTUN_DEV" >/dev/null 2>&1 && break
    sleep 1
  done
  ip link set "$OGSTUN_DEV" up 2>/dev/null || true
  ip -4 addr show dev "$OGSTUN_DEV" | grep -q "inet ${OGSTUN_GW%/*}/" \
    || ip addr add "$OGSTUN_GW" dev "$OGSTUN_DEV" 2>/dev/null || true
  echo "[run_open5gs] SGi $OGSTUN_DEV: $(ip -4 addr show dev "$OGSTUN_DEV" 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ')"
}
bring_up_sgi
# Повторно убедимся через паузу (tun мог пересоздаться позже старта upfd).
sleep 3
bring_up_sgi

echo "[run_open5gs] Все NF запущены. Ожидание (Ctrl-C для остановки)..."
# Держим контейнер живым
tail -f /dev/null
