#!/usr/bin/env bash
# =============================================================================
# stand-autostart.sh — единая точка автоподъёма/самовосстановления стенда srsRAN
# =============================================================================
# Вызывается systemd-юнитами (см. *.service рядом) и вручную.
# Работает от пользователя intsis (основной пользователь стенда), sudo НЕ нужен:
# доступ к docker даёт группа docker, каталоги/udev настроены администратором.
#
# Режимы (первый аргумент):
#   core [--boot]   ядро: MongoDB -> Open5GS (все NF). На pi5-2.
#   web  [--boot]   webserve (в netns ядра) + дашборды + Prometheus + Grafana.
#   bs   [--boot]   своя БС (base5 -> eNB1, иначе -> eNB2) ТОЛЬКО при наличии SDR.
#   watchdog        периодическая проверка и починка (вызывается таймером).
#
# Флаги ручной остановки: ~/.stand/stop-core, stop-web, stop-bs.
# Их создают stop-*.sh, а start-*.sh удаляют. watchdog уважает флаги,
# при загрузке узла (--boot) флаги снимаются — после подачи питания стенд
# поднимается всегда.
#
# Лог: ~/.stand/autostart.log
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.stand"
mkdir -p "$STATE"
LOG="$STATE/autostart.log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

MODE="${1:-watchdog}"
BOOT=0
[ "${2:-}" = "--boot" ] && BOOT=1

USRP_VIDS="2500 2505 3923"     # Ettus B2xx (2500/2505), NI USRP-2901 (3923)
SECONDARY_IP="192.168.1.20"
CORE_WAIT=150

# --- Вспомогательные функции -------------------------------------------------
wait_docker() {
    local i
    for i in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 2; done
    return 1
}

sdr_present() {
    local f v
    for f in /sys/bus/usb/devices/*/idVendor; do
        [ -e "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case " $USRP_VIDS " in *" $v "*) return 0;; esac
    done
    return 1
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

exists()  { docker inspect "$1" >/dev/null 2>&1; }

# NF жив внутри контейнера ядра (в образе нет ps/pgrep — читаем /proc/*/comm)
nf_alive() {
    docker exec open5gs sh -c \
      "for d in /proc/[0-9]*; do c=\$(cat \$d/comm 2>/dev/null); [ \"\$c\" = \"open5gs-$1\" ] && exit 0; done; exit 1" \
      2>/dev/null
}

# --- CORE (pi5-2) -------------------------------------------------------------
do_core() {
    log "=== CORE: подъём ядра ==="
    if [ ! -x "$HOME/start-core.sh" ]; then
        log "на этом узле нет start-core.sh (не узел ядра) — пропускаю"
        return 0
    fi
    wait_docker || { log "!! docker недоступен"; return 1; }

    # При загрузке docker с --restart unless-stopped поднимает контейнеры сам,
    # но не мгновенно. Даём ему шанс, чтобы не делать лишнее пересоздание
    # (оно рвёт netns webserve и перезапускает БС).
    local g
    for g in $(seq 1 30); do running open5gs && running open5gs-mongodb && break; sleep 2; done

    # start-core.sh делает детерминированное пересоздание и САМ ждёт Mongo,
    # поэтому запускаем его только если ядро реально не в строю.
    local need=0
    running open5gs-mongodb || need=1
    running open5gs || need=1
    if [ "$need" = 0 ]; then
        # Ядро поднято — проверим ключевые NF (их мог убить сбой).
        nf_alive mmed || need=1
        nf_alive hssd || need=1
        nf_alive upfd || need=1
    fi

    if [ "$need" = 1 ]; then
        log "ядро не в строю -> запуск start-core.sh"
        ( cd "$HOME" && bash ./start-core.sh ) >>"$LOG" 2>&1
        local rc=$?
        log "start-core.sh rc=$rc"
        # ВАЖНО: start-core.sh пересоздаёт контейнер open5gs (новый netns),
        # поэтому webserve, сидящий в старом namespace, больше не работает —
        # его нужно пересоздать (иначе 10.0.0.1:8080 недоступен абонентам).
        rm -f "$STATE/force-web-recreate"
        touch "$STATE/force-web-recreate"
    else
        log "ядро уже работает"
    fi

    # Ждём HSS (без него телефоны получают Attach reject 3002).
    local i
    for i in $(seq 1 $((CORE_WAIT / 3))); do nf_alive hssd && break; sleep 3; done
    if nf_alive hssd; then log "HSS: OK"; else log "!! HSS не поднялся (супервизор повторит)"; fi
    return 0
}

# --- WEB (pi5-2 и base5) ------------------------------------------------------
# Нужно ли пересоздавать веб-сервисы? (0 = всё в порядке)
# Причины: контейнер не running; либо webserve «running», но сидит в network
# namespace уже удалённого контейнера ядра (тогда его процесс фактически мёртв
# и 10.0.0.1:8080 недоступен абонентам).
web_needs_recreate() {
    [ -f "$STATE/force-web-recreate" ] && return 0
    local c
    for c in $(grep -oE -- '--name [A-Za-z0-9_-]+' "$HOME/start-web.sh" | awk '{print $2}'); do
        running "$c" || return 0
    done
    if running webserve; then
        local ns parent
        ns=$(docker inspect -f '{{.HostConfig.NetworkMode}}' webserve 2>/dev/null)
        case "$ns" in
            container:*)
                parent="${ns#container:}"
                docker inspect -f '{{.State.Running}}' "$parent" 2>/dev/null | grep -qx true || {
                    log "webserve в netns несуществующего контейнера ${parent:0:12} -> нужен пересоздание"
                    return 0
                }
                ;;
        esac
    fi
    return 1
}

do_web() {
    log "=== WEB: веб-сервисы и мониторинг ==="
    wait_docker || { log "!! docker недоступен"; return 1; }

    # На base5 свой набор (только дашборд БС1).
    local rc=0
    # webserve живёт в netns ядра: если ядро не поднято — сначала core.
    if ! running open5gs && [ -x "$HOME/start-core.sh" ]; then
        do_core
    fi

    if [ ! -x "$HOME/start-web.sh" ]; then
        log "на этом узле нет start-web.sh — пропускаю"
        return 0
    fi

    if web_needs_recreate; then
        rm -f "$STATE/force-web-recreate"
        log "веб-сервисы неполны -> start-web.sh"
        ( cd "$HOME" && bash ./start-web.sh ) >>"$LOG" 2>&1
        rc=$?
        log "start-web.sh rc=$rc"
    else
        log "веб-сервисы уже работают"
    fi
    return "$rc"
}

# --- BS (своя базовая станция) ------------------------------------------------
do_bs() {
    local name
    if [ "$(hostname)" = "Base5" ]; then name=enb; else name=enb2; fi
    log "=== BS: базовая станция ($name) ==="
    if [ ! -x "$HOME/start-bs.sh" ]; then
        log "на этом узле нет start-bs.sh — пропускаю"
        return 0
    fi

    if [ -f "$STATE/stop-bs" ]; then
        log "стоит флаг ручной остановки -> БС не поднимаю"
        return 0
    fi
    wait_docker || { log "!! docker недоступен"; return 1; }

    if ! sdr_present; then
        log "SDR не обнаружен (VID $USRP_VIDS) -> БС не запускаю (это норма без платы)"
        # Без платы контейнер ушёл бы в краш-цикл и шумел в логах MME.
        if exists "$name"; then
            running "$name" && docker stop "$name" >/dev/null 2>&1
            docker update --restart=no "$name" >/dev/null 2>&1
        fi
        return 0
    fi
    log "SDR обнаружен"

    # eNB2 обязан сидеть на вторичном IP .20 (иначе конфликт портов с ядром).
    if [ "$name" = enb2 ]; then
        local i
        for i in $(seq 1 45); do
            ip addr show wlan0 2>/dev/null | grep -q "inet $SECONDARY_IP/" && break
            sleep 2
        done
        ip addr show wlan0 2>/dev/null | grep -q "inet $SECONDARY_IP/" \
            || log "!! нет вторичного IP $SECONDARY_IP (NM применит позже; повторю в watchdog)"
    fi

    if running "$name"; then
        log "контейнер $name уже работает"
        return 0
    fi
    log "запуск $HOME/start-bs.sh"
    ( cd "$HOME" && bash ./start-bs.sh ) >>"$LOG" 2>&1
    local rc=$?
    log "start-bs.sh rc=$rc"
    return 0
}

# --- WATCHDOG -----------------------------------------------------------------
do_watchdog() {
    wait_docker || { log "watchdog: docker недоступен"; return 0; }

    # 1) Ядро (только на узле, где есть start-core.sh)
    if [ -x "$HOME/start-core.sh" ] && [ ! -f "$STATE/stop-core" ]; then
        if ! running open5gs || ! nf_alive hssd || ! nf_alive mmed || ! nf_alive upfd; then
            log "watchdog: ядро/HSS не в строю -> восстановление"
            do_core
        fi
    fi

    # 2) Веб-сервисы и мониторинг
    if [ -x "$HOME/start-web.sh" ] && [ ! -f "$STATE/stop-web" ]; then
        web_needs_recreate && { log "watchdog: веб-сервисы неполны -> восстановление"; do_web; }
    fi

    # 3) Базовая станция: контейнер упал ИЛИ поток встал (известная болезнь B210)
    if [ -x "$HOME/start-bs.sh" ] && [ ! -f "$STATE/stop-bs" ]; then
        local name; if [ "$(hostname)" = "Base5" ]; then name=enb; else name=enb2; fi
        if sdr_present; then
            local restart=0 state="$STATE/wd-$name"
            if ! running "$name"; then
                log "watchdog: $name не запущен -> запуск"
                restart=1
            else
                # CPU ~0-3% при живом контейнере = поток TXRX встал (см. заметки).
                local cpu
                cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$name" 2>/dev/null \
                      | tr -d '%' | cut -d. -f1)
                cpu=${cpu:-100}
                local low=0
                [ "$cpu" -lt 8 ] 2>/dev/null && low=1
                local n=0; [ -f "$state" ] && n=$(cat "$state" 2>/dev/null || echo 0)
                if [ "$low" = 1 ]; then n=$((n + 1)); else n=0; fi
                echo "$n" > "$state" 2>/dev/null || true
                if [ "$n" -ge 3 ]; then
                    log "watchdog: $name CPU ${cpu}% трижды -> поток встал, перезапуск"
                    echo 0 > "$state" 2>/dev/null || true
                    restart=1
                fi
            fi
            [ "$restart" = 1 ] && do_bs
        elif running "$name"; then
            log "watchdog: SDR пропал -> останавливаю $name"
            docker stop "$name" >/dev/null 2>&1
        fi
    fi
    return 0
}

case "$MODE" in
    core) [ "$BOOT" = 1 ] && rm -f "$STATE/stop-core" "$STATE/stop-web"; do_core ;;
    web)  [ "$BOOT" = 1 ] && rm -f "$STATE/stop-web";                  do_web ;;
    bs)   [ "$BOOT" = 1 ] && rm -f "$STATE/stop-bs";                    do_bs ;;
    watchdog) do_watchdog ;;
    *) echo "Использование: $0 {core|web|bs|watchdog} [--boot]" >&2; exit 2 ;;
esac
