#!/usr/bin/env bash
# =============================================================================
# stop-bs.sh — остановка БАЗОВОЙ СТАНЦИИ №2 (eNB2) на pi5-2.
# =============================================================================
set -uo pipefail

echo "===== Остановка БС2 ($(hostname)) ====="
if docker ps -a --format '{{.Names}}' | grep -qx 'enb2'; then
  # Если контейнер на паузе, docker stop его не возьмёт — сначала снимаем паузу.
  if [ "$(docker inspect -f '{{.State.Paused}}' enb2 2>/dev/null)" = "true" ]; then
    docker unpause enb2 >/dev/null 2>&1 || true
  fi
  if docker stop enb2 >/dev/null 2>&1; then echo "[OK] остановлен enb2"; else echo "[ВНИМАНИЕ] не удалось остановить enb2"; fi
else
  echo "[i] контейнер enb2 не найден"
fi
echo "[OK] БС2 остановлена."
