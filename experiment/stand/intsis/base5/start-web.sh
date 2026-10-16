#!/usr/bin/env bash
# =============================================================================
# start-web.sh — запуск ВЕБ-СЕРВЕРОВ на base5 (узел БС1).
#
# Поднимает дашборд БС1: http://192.168.1.25:5000 (парсит лог eNB1).
# Ядро ядра сети и остальные сервисы живут на pi5-2.
# =============================================================================
set -euo pipefail

SRS="$HOME/srsran"
LOGS="$SRS/data/logs"

echo "===== ВЕБ-СЕРВЕРЫ base5 ($(hostname)) ====="
mkdir -p "$LOGS"

docker rm -f srsran-dashboard-enb >/dev/null 2>&1 || true
docker run -d --name srsran-dashboard-enb --restart unless-stopped \
  -e DASH_MODE=enb \
  -e DASH_LOG_DIR=/logs \
  -e DASH_PORT=5000 \
  -v "$LOGS:/logs" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 5000:5000 \
  srsran-dashboard:latest >/dev/null
echo "[OK] dashboard БС1 -> http://$(hostname -I | awk '{print $1}'):5000"

sleep 2
docker ps --filter name=srsran-dashboard-enb --format '{{.Names}}\t{{.Status}}'
echo "[OK] Веб-серверы base5 запущены."
