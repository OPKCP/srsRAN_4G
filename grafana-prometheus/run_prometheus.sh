#!/usr/bin/env bash
# =============================================================================
# run_prometheus.sh — Prometheus для сбора метрик NF ядра Open5GS на pi5-2.
#
# ВАЖНО: --network host. Метрики NF Open5GS слушают loopback-адреса
#   MME=127.0.0.2:9090, SMF/SGW-C=127.0.0.4:9090, UPF=127.0.0.7:9090
# (см. ~/open5gs/config/*.yaml). Из bridge-сети они НЕдоступны, поэтому
# Prometheus обязан быть в host-сети (внутренние адреса 127.0.0.x там видны).
#
# Порт 9090 на хосте ЗАНЯТ метриками UPF (open5gs-upfd слушает 0.0.0.0:9090),
# поэтому Prometheus поднят на 9091 (--web.listen-address=:9091).
# Grafana ходит в Prometheus по http://172.17.0.1:9091 (docker0).
# =============================================================================
set -euo pipefail

NAME="prometheus"
IMG="prom/prometheus:latest"
BASE="${OBS_DIR:-$HOME/observability}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d --name "$NAME" \
  --network host \
  --restart unless-stopped \
  -v "$BASE/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$BASE/prometheus/data:/prometheus" \
  "$IMG" \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=15d \
    --web.listen-address=:9091 \
    --web.enable-lifecycle

echo "[OK] Prometheus запущен (host-сеть):  http://<pi5>:9091"
echo "[OK] Targets: http://<pi5>:9091/targets"
sleep 3
docker ps --filter "name=$NAME" --format "{{.Names}}\t{{.Status}}"
