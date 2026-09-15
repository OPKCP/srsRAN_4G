#!/usr/bin/env bash
# =============================================================================
# run_webui.sh — Open5GS WebUI (веб-панель: абоненты/SIM, сессии).
#
# КОНТЕКСТ: WebUI — ОТДЕЛЬНОЕ Node.js/Next-приложение (open5gs/webui), НЕ часть
# meson-сборки C-демонов. Официальный образ собирают на node (npm ci + next build).
# См. open5gs/docker/Dockerfile — там webui встроен в образ ядра (тег -webui).
#
# ЭТОТ образ уже содержит и ядро, и webui. WebUI запускается ИЗ ТОГО ЖЕ образа
# отдельным контейнером (обёртка /opt/open5gs/start-webui.sh: ждёт Mongo, сеет
# админа, стартует сервер). NF-контейнер при этом не затрагивается.
#
# Реальные env WebUI (webui/server/index.js v2.7.2):
#   DB_URI   — строка Mongo (по умолчанию mongodb://127.0.0.1/open5gs)
#   HOSTNAME — адрес прослушивания (по умолчанию localhost; в host-сети ставим 0.0.0.0)
#   PORT     — порт (по умолчанию 9999; НЕ 3000)
#   JWT_SECRET_KEY / SECRET_KEY — секреты (иначе создаются/случайны)
# Порт 3000 занят Grafana → используем 9999 (дефолт webui) или 3080.
# Логин по умолчанию admin / 1423 (сид создаётся start-webui.sh; сменить после входа!).
#
# Запуск после сборки образа ядра с webui:
#   WEBUI_IMG=open5gs-arm64:v2.7.2-webui bash run_webui.sh
# =============================================================================
set -euo pipefail

NAME="open5gs-webui"
IMG="${WEBUI_IMG:-open5gs-arm64:v2.7.2-webui}"   # <<< образ ядра, собранный с webui
DB_URI="${DB_URI:-mongodb://127.0.0.1:27017/open5gs}"
PORT="${WEB_PORT:-9999}"
ADMIN_USER="${WEBUI_ADMIN_USER:-admin}"
ADMIN_PASS="${WEBUI_ADMIN_PASS:-1423}"
# Скрипт запуска. Монтируем с ХОСТА (bind) и запускаем через `bash`:
# в некоторых сборках docker save/load файл /opt/open5gs/start-webui.sh из образа
# распаковывается пустым (артефакт формата), а бинарь node/приложение при этом целы.
# Поэтому берём проверенный скрипт с хоста, а не из образа.
START_SH="${WEBUI_START_SH:-$HOME/srsran/scripts/start-webui.sh}"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "[ОЖИДАНИЕ] Образ '$IMG' (ядро, собранное с webui) ещё не собран."
  echo "  Соберите его: open5gs/docker/Dockerfile (см. README/комментарии), затем:"
  echo "  WEBUI_IMG=<образ:тег> bash run_webui.sh"
  exit 2
fi
if [ ! -f "$START_SH" ]; then
  echo "[ОШИБКА] Не найден стартовый скрипт WebUI: $START_SH"
  echo "  Положите его (из репо open5gs/docker/webui/start-webui.sh) или задайте WEBUI_START_SH=<путь>."
  exit 3
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

# --network host: webui слушает на физическом IP pi5-2.
# DB берётся как DB_URI (по умолчанию mongo на localhost:27017 того же узла).
# Стартовый скрипт монтируем с хоста и запускаем через bash (не как exec-бинарь).
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --restart unless-stopped \
  -e "DB_URI=$DB_URI" \
  -e "HOSTNAME=0.0.0.0" \
  -e "PORT=$PORT" \
  -e "WEBUI_ADMIN_USER=$ADMIN_USER" \
  -e "WEBUI_ADMIN_PASS=$ADMIN_PASS" \
  -e "WEBUI_APP_DIR=/opt/open5gs/webui" \
  -e "TZ=${TZ_NAME:-Europe/Moscow}" \
  -v "$START_SH:/opt/open5gs/start-webui-host.sh:ro" \
  --entrypoint /bin/bash \
  "$IMG" /opt/open5gs/start-webui-host.sh

echo "[OK] WebUI запущен:  http://<pi5>:${PORT}   (${ADMIN_USER} / ${ADMIN_PASS} — сменить!)"
sleep 4
docker ps --filter "name=$NAME" --format "{{.Names}}\t{{.Status}}"
echo "=== логи (tail) ==="
docker logs "$NAME" 2>&1 | tail -15
