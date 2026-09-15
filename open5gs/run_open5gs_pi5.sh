#!/usr/bin/env bash
# ==============================================================================
# run_open5gs_pi5.sh — запуск ядра Open5GS (4G EPC) на pi5-2 (192.168.1.26).
#
# Заменяет srsepc. Обе БС (Base5=192.168.1.25, enb2-bind=192.168.1.20) ходят на
# 192.168.1.26:36412 (S1-MME/SCTP) и :2152 (GTP-U). mme_addr БС менять НЕ нужно.
#
# Образ open5gs-arm64:v2.7.2 имеет исправленный Entrypoint (open5gs-mmed),
# поэтому запускаем явно через --entrypoint /bin/bash (иначе Cmd «съедается»).
# Монтируем config (включая tls/) в /etc/open5gs и config/freeDiameter в
# /etc/freeDiameter (diam-конфиги ссылаются на /etc/freeDiameter/*.conf и
# /etc/open5gs/tls/*.crt). Абоненты — в MongoDB open5gs-mongodb (схема security:{}).
# ==============================================================================
set -euo pipefail

NAME="open5gs"
O5_DIR="${HOME}/open5gs"
CFG="${O5_DIR}/config"
LOGS="${O5_DIR}/logs"
IMG="open5gs-arm64:v2.7.2"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "[ERR] Образ $IMG не найден. docker load -i ${O5_DIR}/open5gs-arm64.tar"; exit 1
fi
[ -d "$CFG" ] || { echo "[ERR] нет каталога конфигов $CFG"; exit 1; }
[ -d "${CFG}/tls" ] || echo "[WARN] нет ${CFG}/tls — diameter TLS может упасть"
mkdir -p "$LOGS"

# --- MongoDB ---
if ! docker ps --format '{{.Names}}' | grep -qx 'open5gs-mongodb'; then
  echo "[OK] Запуск MongoDB"
  docker run -d --name open5gs-mongodb --restart unless-stopped \
    -v open5gs_mongo:/data/db --network host mongo:6 >/dev/null
  for i in $(seq 1 30); do
    docker exec open5gs-mongodb mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break
    sleep 1
  done
fi

# --- Open5GS (все NF в одном контейнере, network host) ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --restart unless-stopped \
  --entrypoint /bin/bash \
  -v "${CFG}:/etc/open5gs:ro" \
  -v "${CFG}/freeDiameter:/etc/freeDiameter:ro" \
  -v "${O5_DIR}:/opt/open5gs:ro" \
  -v "${LOGS}:/var/log/open5gs" \
  "$IMG" /opt/open5gs/run_open5gs.sh

echo "[OK] Open5GS запущен (контейнер $NAME, network host)"
echo "     S1-MME : 192.168.1.26:36412 (sctp)   GTP-U : 192.168.1.26:2152 (udp)"
sleep 8
echo "=== процессы NF ==="; docker exec "$NAME" sh -c 'ps -eo comm | grep -i "open5gs-" | sort' 2>&1
echo "=== listen 36412/2152 ==="; docker exec "$NAME" sh -c 'ss -lutnp 2>/dev/null | grep -E "36412|:2152"' 2>&1 || true
