#!/usr/bin/env bash
# =============================================================================
# stop-core.sh — остановка ЯДРА СЕТИ (Open5GS + MongoDB) на pi5-2.
# Данные абонентов (том open5gs_mongo) НЕ удаляются.
# =============================================================================
set -uo pipefail

echo "===== Остановка ядра сети ($(hostname)) ====="
for c in open5gs open5gs-mongodb; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    if docker stop "$c" >/dev/null 2>&1; then echo "[OK] остановлен $c"; else echo "[ВНИМАНИЕ] не удалось остановить $c"; fi
  else
    echo "[i] контейнер $c не найден"
  fi
done
echo "[OK] Ядро сети остановлено."
