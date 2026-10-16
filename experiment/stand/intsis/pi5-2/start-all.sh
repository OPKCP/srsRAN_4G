#!/usr/bin/env bash
# =============================================================================
# start-all.sh — запуск ВСЕГО стенда с pi5-2 (главный узел).
#
# Порядок:
#   1) Ядро сети (Open5GS + MongoDB)          — локально на pi5-2
#   2) Веб-серверы и мониторинг               — локально на pi5-2
#   3) БС2 (1811 МГц)                         — локально на pi5-2
#   4) БС1 (1815 МГц)                         — на base5 по ssh
#
# Запуск от пользователя intsis, sudo не требуется.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "########## 1/4. Ядро сети (pi5-2) ##########"
bash "$HERE/start-core.sh"; RC_CORE=$?

echo
echo "########## 2/4. Веб-серверы и мониторинг (pi5-2) ##########"
bash "$HERE/start-web.sh"; RC_WEB=$?

echo
echo "########## 3/4. БС2 (pi5-2, 1811 МГц) ##########"
bash "$HERE/start-bs.sh"; RC_BS2=$?

echo
echo "########## 4/4. БС1 и её дашборд (base5, 1815 МГц) ##########"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    base5 '~/start-all.sh'; RC_BS1=$?

echo
echo "=================== СВОДКА ==================="
printf "  ядро              : rc=%s\n" "$RC_CORE"
printf "  веб и мониторинг  : rc=%s\n" "$RC_WEB"
printf "  БС2 (pi5-2)       : rc=%s\n" "$RC_BS2"
printf "  БС1 (base5)       : rc=%s\n" "$RC_BS1"
echo "=============================================="
echo "Состояние контейнеров на $(hostname):"
docker ps --format '{{.Names}}\t{{.Status}}'
echo "(БС1 — на base5: ssh base5 'docker ps')"

if [ "$RC_CORE" -ne 0 ] || [ "$RC_WEB" -ne 0 ] || [ "$RC_BS2" -ne 0 ] || [ "$RC_BS1" -ne 0 ]; then
  echo "[ВНИМАНИЕ] не все компоненты поднялись — см. вывод выше."
  exit 1
fi
echo "[OK] Стенд запущен полностью."
