#!/usr/bin/env bash
# =============================================================================
# run_webserver_quality.sh — запуск веб-сервера качества (quality-testing) на pi5.
# Заменяет старый python3 -m http.server.
#
# Требования:
#   - контейнер epc запущен (webserve работает в его network namespace, доступен
#     телефонам как http://10.0.0.1:8080/)
#   - каталоги этого проекта (quality-testing) существуют на хосте
#
# Что монтируется:
#   $REPO_QUALITY/server   -> /app/server        (серверный код app.py)
#   $REPO_QUALITY/static   -> /app/static        (HTML/JS/CSS тестера)
#   $SERVE_DIR (apk-serving) -> /serve           (раздаваемые файлы; ro)
#   $HISTORY_DIR             -> /app/history     (CSV-журнал замеров; rw)
#   Как правило весь quality-testing монтируется целиком на /app, а /serve и
#   каталог истории — отдельно. Ниже — надёжный вариант.
# =============================================================================
set -euo pipefail

NAME="webserve"
IMG="quality-testing:latest"

# --- Пути на хосте (pi5) ---
QUALITY_DIR="${QUALITY_DIR:-$HOME/srsran/quality-testing}"   # проект на малинке
SERVE_DIR="${SERVE_DIR:-$HOME/srsran/apk-serving}"            # файлы для абонентов
HISTORY_DIR="${HISTORY_DIR:-$HOME/srsran/quality-history}"    # журнал замеров
EPC_LOGS_DIR="${EPC_LOGS_DIR:-$HOME/srsran/logs}"             # каталог с epc.log (ядра)
PORT="${WEB_PORT:-8080}"

# --- Проверка namespace epc ---
if ! docker ps --format '{{.Names}}' | grep -q '^epc$'; then
  echo "[ERROR] Контейнер epc не запущен! webserve должен работать в namespace epc." >&2
  exit 1
fi

# --- Каталоги ---
mkdir -p "$SERVE_DIR" "$HISTORY_DIR"

# --- Сборка образа (если ещё не собран) ---
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "[..] Сборка образа $IMG ..."
  docker build -t "$IMG" "$QUALITY_DIR"
fi
echo "[OK] Образ: $IMG"

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Запуск в namespace epc ---
# Серверный код app.py монтируем в /app; при изменении app.py нужно
# docker restart webserve. Статика /app/static -- живая (без пересборки).
docker run -d --name "$NAME" \
  --network container:epc \
  --restart unless-stopped \
  -e SERVE_DIR=/serve \
  -e STATIC_DIR=/app/static \
  -e HISTORY_DIR=/app/history \
  -e EPC_LOG=/app/epclogs/epc.log \
  -e GATEWAY_IP=10.0.0.1 \
  -e LISTEN_HOST=0.0.0.0 \
  -e LISTEN_PORT="$PORT" \
  -v "$QUALITY_DIR/server:/app/server:ro" \
  -v "$QUALITY_DIR/static:/app/static:ro" \
  -v "$HISTORY_DIR:/app/history" \
  -v "$SERVE_DIR:/serve:ro" \
  -v "$EPC_LOGS_DIR:/app/epclogs:ro" \
  -w /app/server \
  "$IMG" python /app/server/app.py

echo "[OK] quality-testing веб-сервер запущен (контейнер $NAME) в namespace EPC"
echo "Адрес для телефонов: http://10.0.0.1:${PORT}/"
echo "Тестер:              http://10.0.0.1:${PORT}/tester.html"
echo "Состояние клиентов:  http://10.0.0.1:${PORT}/api/clients"
echo "История (CSV):       $HISTORY_DIR"
sleep 3
docker ps --filter name="$NAME" --format "{{.Names}}\t{{.Status}}"
echo "=== Логи (первые) ==="
docker logs "$NAME" 2>&1 | tail -8
