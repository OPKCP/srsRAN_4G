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

# --- Ожидание готовности MongoDB (КРИТИЧНО) ---
# hssd и pcrfd при старте подключаются к MongoDB. Если mongo ещё не готова,
# они печатают "Failed to connect to server [...]" -> "Failed to initialize HSS"
# и ЗАВЕРШАЮТСЯ, сами больше не поднимаются. Симптом: MME отвечает
# "Authentication Information failed [3002]" -> Attach reject (телефоны не входят).
# Поэтому ждём открытия TCP 27017 (JOURNAL/recv не требуется — достаточно, что
# сервер принимает соединения). Таймаут ~120с, дальше стартуем как есть,
# чтобы контейнер не висел молча.
MONGO_HOST=${OPEN5GS_MONGO_HOST:-127.0.0.1}
MONGO_PORT=${OPEN5GS_MONGO_PORT:-27017}
wait_for_mongo() {
    local i
    for i in $(seq 1 120); do
        if (exec 3<>"/dev/tcp/${MONGO_HOST}/${MONGO_PORT}") 2>/dev/null; then
            echo "[run_open5gs] MongoDB ${MONGO_HOST}:${MONGO_PORT} готова (${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "[run_open5gs] WARNING: MongoDB ${MONGO_HOST}:${MONGO_PORT} не ответила за 120с, продолжаю запуск"
    return 1
}

start_nf() {
    local bin="$1"
    echo "[run_open5gs] start: $bin"
    # Демоны сами демонизируются (fork), но для надёжности запускаем в фоне
    "$bin" &
    sleep "$DELAY"
}

# --- Проверка «NF-процесс жив» без ps/pgrep -----------------------------------
# В образе open5gs-arm64 нет procps (ps/pgrep отсутствуют), поэтому смотрим
# /proc/<pid>/comm. Возврат 0 = процесс есть.
nf_alive() {
    local want="open5gs-$1" d c
    for d in /proc/[0-9]*; do
        c=$(cat "$d/comm" 2>/dev/null) || continue
        [ "$c" = "$want" ] && return 0
    done
    return 1
}

# --- Супервизор NF ------------------------------------------------------------
# Контейнер держится живым через tail -f, поэтому если какой-то NF упадёт
# (например hssd не смог подключиться к Mongo), никто его не поднимет и
# телефоны перестанут аутентифицироваться. Супервизор каждые N секунд
# проверяет все NF и перезапускает отсутствующие (2 промаха подряд = мёртв).
SUPERVISE_INTERVAL=${OPEN5GS_SUPERVISE_INTERVAL:-10}
NF_ORDER="mmed hssd pcrfd sgwcd sgwud smfd upfd"

supervise_loop() {
    local nf
    declare -A miss
    while true; do
        sleep "$SUPERVISE_INTERVAL"
        for nf in $NF_ORDER; do
            if nf_alive "$nf"; then
                miss[$nf]=0
                continue
            fi
            miss[$nf]=$(( ${miss[$nf]:-0} + 1 ))
            [ "${miss[$nf]}" -lt 2 ] && continue
            miss[$nf]=0
            # hssd/pcrfd при старте требуют MongoDB — дождёмся её.
            case "$nf" in hssd|pcrfd) wait_for_mongo >/dev/null 2>&1 || true ;; esac
            echo "[run_open5gs] supervisor: open5gs-$nf отсутствует -> перезапуск"
            "/usr/bin/open5gs-$nf" &
            sleep "$DELAY"
        done
        # SGi мог остаться без адреса после пересоздания tun — страхуемся.
        bring_up_sgi >/dev/null 2>&1 || true
    done
}

wait_for_mongo

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

# --- NAT/FORWARD для абонентов (переживает пересоздание контейнера) ----------
# Правила MASQUERADE/FORWARD живут в netns хоста (network_mode: host), но при
# жёсткой перезагрузке узла iptables пуст, а setup-ogstun.service может
# отработать раньше, чем UPF создаст ogstun. Поэтому ставим правила здесь —
# идемпотентно, сразу после поднятия SGi.
setup_nat() {
    iptables -t nat -C POSTROUTING -s 10.0.0.0/24 ! -o ogstun -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.0.0.0/24 ! -o ogstun -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -i ogstun -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ogstun -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -o ogstun -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ogstun -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -s 10.0.0.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD -s 10.0.0.0/24 -j ACCEPT 2>/dev/null || true
    echo "[run_open5gs] NAT: $(iptables -t nat -S POSTROUTING | grep -c '10.0.0.0/24') правило(а) для 10.0.0.0/24"
}
setup_nat

# --- Супервизор NF в фоне (самовосстановление без участия человека) -----------
supervise_loop &

echo "[run_open5gs] Все NF запущены. Ожидание (Ctrl-C для остановки)..."
# Держим контейнер живым
tail -f /dev/null
