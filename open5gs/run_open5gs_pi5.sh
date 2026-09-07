#!/usr/bin/env bash
# ==============================================================================
# run_open5gs_pi5.sh — запуск ядра сети Open5GS (4G EPC) на pi5-2.
#
# Хост: pi5-2 (192.168.1.26). Обе БС (Base5=192.168.1.25 и enb2=192.168.1.20)
# подключаются к 192.168.1.26:36412 (S1-MME/SCTP) и 192.168.1.26:2152 (GTP-U).
#
# Работает с образом open5gs-arm64:v2.7.2 (переносится с ПК через docker load).
# Детерминированный запуск: docker compose up -d --build / вручную.
# ==============================================================================
set -euo pipefail

NAME="open5gs"
COMPOSE_DIR="${HOME}/srsran/open5gs"     # где лежит docker-compose.yml + config/
# Если compose-файла нет на хосте — скопировать из репозитория проекта.

# --- 1. Проверка: образ Open5GS загружен ---
if ! docker image inspect open5gs-arm64:v2.7.2 >/dev/null 2>&1; then
  echo "[ERR] Образ open5gs-arm64:v2.7.2 не найден. Сначала: docker load -i open5gs-arm64.tar"
  exit 1
fi

# --- 2. Запуск mongodb (если не запущен) ---
if ! docker ps --format '{{.Names}}' | grep -qx 'open5gs-mongodb'; then
  echo "[OK] Запуск MongoDB"
  docker run -d --name open5gs-mongodb --restart unless-stopped \
    -v open5gs_mongo:/data/db --network host mongo:6
  # дожидаемся готовности
  for i in $(seq 1 30); do
    docker exec open5gs-mongodb mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break
    sleep 1
  done
fi

# --- 3. Запуск Open5GS (network host) ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --restart unless-stopped \
  -v "${HOME}/srsran/open5gs/config:/etc/open5gs:ro" \
  -v "${HOME}/srsran/open5gs/logs:/var/log/open5gs" \
  open5gs-arm64:v2.7.2 \
  /bin/bash -c "for nf in mmed hssd pcrfd sgwcd sgwud smfd upfd; do /usr/bin/open5gs-\$nf & sleep 1; done; tail -f /dev/null"

echo "[OK] Open5GS запущен (контейнер $NAME, network host)"
echo "     S1-MME : 192.168.1.26:36412 (sctp)"
echo "     GTP-U  : 192.168.1.26:2152 (udp)"
