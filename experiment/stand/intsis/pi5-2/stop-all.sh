#!/usr/bin/env bash
# =============================================================================
# stop-all.sh — остановка ВСЕГО стенда с pi5-2.
# Порядок обратный запуску: БС -> веб/мониторинг -> ядро.
# Данные (том абонентов, конфиги, история измерений) НЕ удаляются.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "########## 1/4. БС1 и её дашборд (base5) ##########"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    base5 '~/stop-all.sh'; RC_BS1=$?

echo
echo "########## 2/4. БС2 (pi5-2) ##########"
bash "$HERE/stop-bs.sh"; RC_BS2=$?

echo
echo "########## 3/4. Веб-серверы и мониторинг ##########"
bash "$HERE/stop-web.sh"; RC_WEB=$?

echo
echo "########## 4/4. Ядро сети ##########"
bash "$HERE/stop-core.sh"; RC_CORE=$?

echo
echo "=================== СВОДКА ==================="
printf "  БС1 (base5)       : rc=%s\n" "$RC_BS1"
printf "  БС2 (pi5-2)       : rc=%s\n" "$RC_BS2"
printf "  веб и мониторинг  : rc=%s\n" "$RC_WEB"
printf "  ядро              : rc=%s\n" "$RC_CORE"
echo "=============================================="
echo "Оставшиеся запущенные контейнеры на $(hostname):"
docker ps --format '{{.Names}}\t{{.Status}}' || true
echo "[OK] Стенд остановлен."
