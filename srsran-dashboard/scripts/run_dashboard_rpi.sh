#!/usr/bin/env bash
# ==============================================================================
# run_dashboard_rpi.sh — запуск дашборда стенда srsRAN 4G на Linux (RPi5).
#
# Режимы (--mode):
#   epc  — парсить лог ядра (srsepc). По умолчанию.
#   enb  — парсить лог eNB + метрики (enb_report.json).
#
# Примеры:
#   ./run_dashboard_rpi.sh --mode epc --logdir ~/srsran/logs_epc
#   ./run_dashboard_rpi.sh --mode enb --logdir ~/srsran/local/logs --port 5000
# ==============================================================================
set -euo pipefail

MODE="epc"
LOGDIR=""
PORT=5000
NAME="srsran-dashboard"
REBUILD=0

# --- разбор аргументов ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)  MODE="$2"; shift 2 ;;
    --logdir) LOGDIR="$2"; shift 2 ;;
    --port)  PORT="$2"; shift 2 ;;
    --name)  NAME="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

if [[ "$MODE" != "epc" && "$MODE" != "enb" ]]; then
  echo "Режим должен быть epc или enb (дано: $MODE)"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "$LOGDIR" ]]; then
  LOGDIR="$SCRIPT_DIR/logs_$MODE"
fi
mkdir -p "$LOGDIR"
echo "[OK] Режим: $MODE | Каталог логов: $LOGDIR | Порт: $PORT"

# --- сборка образа при необходимости ---
if [[ $REBUILD -eq 1 ]] || ! docker images -q srsran-dashboard:latest | grep -q .; then
  echo "[..] Сборка образа…"
  docker build -t srsran-dashboard:latest .
fi

# --- удаляем старый контейнер ---
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "[..] Запуск контейнера $NAME …"
# Монтируем docker.sock, чтобы дашборд мог управлять контейнерами на этом узле.
docker run -d --name "$NAME" --restart unless-stopped \
  -e DASH_MODE="$MODE" \
  -e DASH_LOG_DIR=/logs \
  -e DASH_PORT="$PORT" \
  -v "$LOGDIR:/logs" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p "${PORT}:${PORT}" \
  srsran-dashboard:latest

echo ""
echo "[OK] Дашборд запущен:  http://<host>:$PORT"
echo "[OK] Контейнер: $NAME (режим $MODE, логи $LOGDIR, управление Docker: вкл)"
docker ps --filter "name=$NAME" --format "{{.Names}}\t{{.Status}}"
