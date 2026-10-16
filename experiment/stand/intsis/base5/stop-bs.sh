#!/usr/bin/env bash
# =============================================================================
# stop-bs.sh — остановка БАЗОВОЙ СТАНЦИИ №1 (eNB1) на base5.
# =============================================================================
set -uo pipefail

echo "===== Остановка БС1 ($(hostname)) ====="
if docker ps -a --format '{{.Names}}' | grep -qx 'enb'; then
  if docker stop enb >/dev/null 2>&1; then echo "[OK] остановлен enb"; else echo "[ВНИМАНИЕ] не удалось остановить enb"; fi
else
  echo "[i] контейнер enb не найден"
fi
echo "[OK] БС1 остановлена."
