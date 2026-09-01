#!/usr/bin/env bash
# ==============================================================================
# run_webserver_pi5-2.sh — постоянный контейнер веб-сервера для раздачи файлов
# абонентам LTE-пикосоты. Файлы берутся из примонтированного каталога
# ~/srsran/apk-serving/ (просто кинь файл — и его можно скачать на телефоне).
#
# Контейнер работает в network namespace контейнера EPC ("epc"), поэтому доступен
# телефонам по адресу http://10.0.0.1:8080/ (шлюз srs_spgw_sgi).
# HTTP-сервер: python3 -m http.server (лёгкий, статичный).
# Детерминированный запуск: docker rm -f webserve + запуск нового контейнера.
# ==============================================================================
set -euo pipefail

NAME="webserve"
IMG="python:3.12-slim"
BASE="$HOME/srsran"
SERVE_DIR="$BASE/apk-serving"
PORT="${WEB_PORT:-8080}"

# --- Каталог раздачи (создать если нет) ---
mkdir -p "$SERVE_DIR"
echo "[OK] Каталог раздачи: $SERVE_DIR"

# --- Проверка namespace epc ---
if ! docker ps --format '{{.Names}}' | grep -q '^epc$'; then
  echo "[ERROR] Контейнер epc не запущен! webserve должен работать в namespace epc."
  exit 1
fi

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Запуск веб-сервера в namespace epc с монтированием каталога ---
# --restart unless-stopped: авто-перезапуск при падении/перезагрузке докера,
# останавливается только при явном ручном `docker stop`/`docker rm`.
docker run -d --name "$NAME" \
  --network container:epc \
  --restart unless-stopped \
  -v "$SERVE_DIR:/serve:ro" \
  -w /serve \
  "$IMG" python3 -m http.server "$PORT" --bind 0.0.0.0

echo "[OK] Веб-сервер запущен (контейнер $NAME) в namespace EPC"
echo "Адрес для телефонов: http://10.0.0.1:${PORT}/"
echo "Файлы из: $SERVE_DIR (положены - доступны сразу)"
sleep 3
docker ps --filter name="$NAME" --format "{{.Names}}\t{{.Status}}"
echo "=== Логи (первые) ==="
docker logs "$NAME" 2>&1 | tail -8
