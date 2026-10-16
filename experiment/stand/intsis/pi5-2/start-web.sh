#!/usr/bin/env bash
# =============================================================================
# start-web.sh — запуск ВЕБ-СЕРВЕРОВ и мониторинга стенда на pi5-2.
#
# Поднимает:
#   webserve       — раздача файлов абонентам http://10.0.0.1:8080 (в namespace ядра)
#   dashboard ядра — http://192.168.1.26:5001 (парсит лог MME)
#   dashboard БС2  — http://192.168.1.26:5000 (парсит лог eNB2)
#   prometheus     — сбор метрик NF ядра http://192.168.1.26:9091 (host-сеть)
#   grafana        — визуализация http://192.168.1.26:3000 (admin/admin)
#
# Требует запущенного ядра (webserve сидит в его network namespace) —
# поэтому сначала выполните ./start-core.sh.
# sudo НЕ нужен: права на USB и каталоги данных настроены заранее.
# =============================================================================
set -euo pipefail

SRS="$HOME/srsran"
LOGS="$SRS/data/logs"
HISTORY="$SRS/data/quality-history"

# Основной IP узла (на wlan0 есть и вторичный .20 — его не берём).
IP="$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' \
      | grep -v '^192\.168\.1\.20$' | head -1)"
[ -z "$IP" ] && IP="$(hostname -I | awk '{print $1}')"

echo "===== ВЕБ-СЕРВЕРЫ СТЕНДА на $(hostname) ====="

# --- Определяем контейнер ядра: webserve живёт в его namespace ---
CORE=""
for c in open5gs epc; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then CORE="$c"; break; fi
done
if [ -z "$CORE" ]; then
  echo "[ОШИБКА] ядро (open5gs) не запущено — сначала ./start-core.sh" >&2
  exit 1
fi
echo "[OK] Ядро-хост namespace: $CORE"

mkdir -p "$LOGS" "$HISTORY"

# --- 1. webserve: раздача файлов абонентам (в namespace ядра) ---
docker rm -f webserve >/dev/null 2>&1 || true
docker run -d --name webserve \
  --network "container:${CORE}" \
  --restart unless-stopped \
  -e SERVE_DIR=/serve \
  -e STATIC_DIR=/app/static \
  -e HISTORY_DIR=/app/history \
  -e EPC_LOG=/app/epclogs/epc.log \
  -e GATEWAY_IP=10.0.0.1 \
  -e LISTEN_HOST=0.0.0.0 \
  -e LISTEN_PORT=8080 \
  -v "$SRS/quality-testing/server:/app/server:ro" \
  -v "$SRS/quality-testing/static:/app/static:ro" \
  -v "$HISTORY:/app/history" \
  -v "$SRS/apk-serving:/serve:ro" \
  -v "$SRS/open5gs/logs:/app/epclogs:ro" \
  -w /app/server \
  quality-testing:latest python /app/server/app.py >/dev/null
echo "[OK] webserve   -> http://10.0.0.1:8080 (для абонентов)"

# --- 2. dashboard ядра (:5001) ---
docker rm -f srsran-dashboard-epc >/dev/null 2>&1 || true
docker run -d --name srsran-dashboard-epc --restart unless-stopped \
  -e DASH_MODE=epc \
  -e DASH_LOG_DIR=/logs \
  -e DASH_PORT=5001 \
  -v "$SRS/open5gs/logs:/logs" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DASH_USERDB_DIR=/userdb \
  -v "$SRS/config_epc:/userdb:rw" \
  -p 5001:5001 \
  srsran-dashboard:latest >/dev/null
echo "[OK] dashboard  -> http://${IP}:5001 (ядро)"

# --- 2b. dashboard БС2 (:5000) ---
docker rm -f srsran-dashboard-enb2 >/dev/null 2>&1 || true
docker run -d --name srsran-dashboard-enb2 --restart unless-stopped \
  -e DASH_MODE=enb \
  -e DASH_LOG_DIR=/logs \
  -e DASH_PORT=5000 \
  -v "$LOGS:/logs" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 5000:5000 \
  srsran-dashboard:latest >/dev/null
echo "[OK] dashboard  -> http://${IP}:5000 (БС2)"

# --- 3. Prometheus (:9091, host-сеть: видит loopback-метрики NF) ---
docker rm -f prometheus >/dev/null 2>&1 || true
docker run -d --name prometheus --restart unless-stopped \
  --network host \
  -v "$SRS/observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$SRS/observability/prometheus/data:/prometheus" \
  prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=15d \
    --web.listen-address=:9091 \
    --web.enable-lifecycle >/dev/null
echo "[OK] prometheus -> http://${IP}:9091"

# --- 4. Grafana (:3000) ---
docker rm -f grafana >/dev/null 2>&1 || true
docker run -d --name grafana --restart unless-stopped \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -e GF_USERS_ALLOW_ANONYMOUS_EDITING=false \
  -v "$SRS/observability/grafana/data:/var/lib/grafana" \
  -v "$SRS/observability/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$SRS/observability/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana:latest >/dev/null
echo "[OK] grafana    -> http://${IP}:3000 (admin/admin)"

sleep 3
echo
echo "--- Контейнеры ---"
docker ps --filter name=webserve --filter name=srsran-dashboard \
  --filter name=prometheus --filter name=grafana \
  --format '{{.Names}}\t{{.Status}}'
echo "[OK] Веб-серверы и мониторинг запущены."
