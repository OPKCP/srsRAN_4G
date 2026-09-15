#!/usr/bin/env bash
# =============================================================================
# run_grafana.sh — Grafana (визуализация метрик Open5GS из Prometheus).
#
# Мост (bridge), порт хоста 3000 (свободен). Дашборд и datasource подключаются
# через provisioning (каталоги grafana/provisioning, grafana/dashboards).
# В Prometheus (host-сеть) ходит по docker0-шлюзу 172.17.0.1:9090.
#
# Логин по умолчанию: admin / admin (Grafana попросит сменить при первом входе).
# =============================================================================
set -euo pipefail

NAME="grafana"
IMG="grafana/grafana:latest"
BASE="${OBS_DIR:-$HOME/observability}"

mkdir -p "$BASE/grafana/data"
#grafana — uid 472 в образе: дать права на каталог данных
chown -R 472:472 "$BASE/grafana/data" 2>/dev/null || true

docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d --name "$NAME" \
  -p 3000:3000 \
  --restart unless-stopped \
  -e "GF_SECURITY_ADMIN_USER=admin" \
  -e "GF_SECURITY_ADMIN_PASSWORD=admin" \
  -e "GF_USERS_ALLOW_ANONYMOUS_EDITING=false" \
  -v "$BASE/grafana/data:/var/lib/grafana" \
  -v "$BASE/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$BASE/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  "$IMG"

echo "[OK] Grafana запущена:  http://<pi5>:3000  (admin/admin)"
echo "[OK] Дашборд 'Open5GS EPC (LTE S1)' подключён автоматически."
sleep 3
docker ps --filter "name=$NAME" --format "{{.Names}}\t{{.Status}}"
