#!/usr/bin/env bash
# =============================================================================
# stop-web.sh — остановка ВЕБ-СЕРВЕРОВ на base5 (дашборд БС1).
# =============================================================================
set -uo pipefail

echo "===== Остановка веб-серверов base5 ($(hostname)) ====="
if docker ps -a --format '{{.Names}}' | grep -qx 'srsran-dashboard-enb'; then
  docker stop srsran-dashboard-enb >/dev/null 2>&1 && echo "[OK] остановлен srsran-dashboard-enb" || echo "[ВНИМАНИЕ] не удалось остановить"
else
  echo "[i] контейнер srsran-dashboard-enb не найден"
fi
echo "[OK] Веб-серверы base5 остановлены."
