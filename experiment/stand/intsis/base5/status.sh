#!/usr/bin/env bash
# =============================================================================
# status.sh — ПОКАЗАТЬ СОСТОЯНИЕ СТЕНДА на узле base5 (БС1 и её дашборд).
#
# Запуск (на base5, из домашнего каталога):
#     ./status.sh
#
# Скрипт ничего не меняет — только показывает состояние.
# =============================================================================
set -uo pipefail

# Основной IP узла (первый IPv4 на wlan0).
IP="$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
[ -z "$IP" ] && IP="$(hostname -I | awk '{print $1}')"

line() {
  local title="$1" c="$2" st
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" || st="absent"
  case "$st" in
    running)
      if [ "$(docker inspect -f '{{.State.Paused}}' "$c" 2>/dev/null)" = "true" ]; then
        echo "  [ПАУЗА]      ${title}  (контейнер ${c})"
      else
        echo "  [РАБОТАЕТ]   ${title}  (контейнер ${c})"
      fi ;;
    paused)  echo "  [ПАУЗА]      ${title}  (контейнер ${c})" ;;
    exited)  echo "  [ОСТАНОВЛЕН] ${title}  (контейнер ${c})" ;;
    absent)  echo "  [НЕТ]        ${title}  (контейнера ${c} нет)" ;;
    *)       echo "  [${st}] ${title}  (контейнер ${c})" ;;
  esac
}

echo "################################################################"
echo "#  СОСТОЯНИЕ УЗЛА base5 (БАЗОВАЯ СТАНЦИЯ №1)"
echo "#  Узел: $(hostname) (${IP})"
echo "#  Время: $(date '+%d.%m.%Y %H:%M')"
echo "################################################################"
echo

echo "=== 1. БАЗОВАЯ СТАНЦИЯ №1 (eNB1, 1815 МГц) ==="
line "БС1 / eNB1" enb
if lsusb 2>/dev/null | grep -qiE '2500:|2505:|3923:'; then
  echo "  [OK] SDR-плата обнаружена: $(lsusb | grep -iE '2500:|2505:|3923:' | sed 's/^Bus [0-9]* Device [0-9]*: ID //')"
else
  echo "  [ВНИМАНИЕ] SDR-плата НЕ обнаружена — БС1 не запустится"
fi
echo "  --- признаки работы радио (из лога контейнера) ---"
# Лог снимаем в переменную: при `set -o pipefail` конструкция `docker logs | grep -q`
# может «упасть» из-за SIGPIPE (grep выходит раньше docker).
ENB_LOG="$(docker logs enb 2>&1 || true)"
if grep -q 'eNodeB started' <<<"$ENB_LOG"; then
  echo "  [OK] ${_started:-}$(grep -m1 'eNodeB started' <<<"$ENB_LOG")"
  echo "  [OK] $(grep -m1 'Setting frequency' <<<"$ENB_LOG")"
else
  echo "  [ВНИМАНИЕ] в логе нет строки 'eNodeB started' — БС ещё не стартовала"
fi
errs="$(grep -c 'Fatal radio error' <<<"$ENB_LOG" || true)"
echo "  [i] ошибок радио (Fatal radio error): ${errs:-0}"
echo

echo "=== 2. ВЕБ-СЕРВЕРЫ (дашборд БС1) ==="
line "дашборд БС1" srsran-dashboard-enb
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$IP:5000/" 2>/dev/null)"
echo "  http://$IP:5000/  код ${code:-нет ответа}   (200 — открывается)"
echo

echo "=== 3. СВЯЗЬ С ЯДРОМ СЕТИ (pi5-2) ==="
echo "  mme_addr в конфиге БС1: $(grep -m1 '^mme_addr' "$HOME/srsran/enb1/enb.conf" 2>/dev/null | sed 's/ *#.*//')"
if ssh -o BatchMode=yes -o ConnectTimeout=8 pi5 \
     'docker inspect -f "{{.State.Running}}" open5gs 2>/dev/null | grep -qx true' 2>/dev/null; then
  echo "  [OK] на pi5-2 ядро (open5gs) запущено, БС1 подключена к нему"
else
  echo "  [ВНИМАНИЕ] ядро на pi5-2 не запущено или нет связи по ssh — S1 не поднимется"
fi
echo

echo "################################################################"
echo "#  ЧТО ДАЛЬШЕ:  ./start-all.sh | ./stop-all.sh | ./status.sh   #"
echo "################################################################"
