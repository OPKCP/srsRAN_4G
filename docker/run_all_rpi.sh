#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# run_all_rpi.sh — запуск EPC + eNB на одной малинке (RPi5)
# Внутренняя Docker-сеть: lte-net (172.20.0.0/24)
#   EPC: 172.20.0.2  (SRSEPC)
#   eNB: 172.20.0.3  (SRSENB, USRP B210)
# ==============================================================================

IMAGE="${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g/srsran_4g:ARM}"
NETWORK="lte-net"
SUBNET="172.20.0.0/24"
EPC_IP="172.20.0.2"
ENB_IP="172.20.0.3"

BASE_DIR="$HOME/srsran/local"
CONFIG_EPC="$BASE_DIR/config_epc"
CONFIG_ENB="$BASE_DIR/config_enb"
LOGS_DIR="$BASE_DIR/logs"
UHD_IMAGES_DIR="$HOME/srsran/uhd_images"
FFTW_DIR="$HOME/srsran/fftw"

# --- каталоги ---
mkdir -p "$CONFIG_EPC" "$CONFIG_ENB" "$LOGS_DIR" "$FFTW_DIR"

# --- сеть ---
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "[INFO] Создаю сеть $NETWORK ($SUBNET)..."
  docker network create --driver bridge --subnet "$SUBNET" "$NETWORK"
else
  echo "[OK] Сеть $NETWORK уже существует"
fi

# --- UHD images ---
if [ -z "$(ls -A "$UHD_IMAGES_DIR" 2>/dev/null)" ]; then
  echo "[INFO] Копирую UHD images из образа..."
  docker run --rm -v "$UHD_IMAGES_DIR:/out" "$IMAGE" bash -c "cp -r /usr/share/uhd/images/* /out/"
fi

echo "=== Запуск EPC (172.20.0.2) ==="
docker rm -f epc 2>/dev/null || true
docker run -d --name epc --hostname epc \
  --network "$NETWORK" --ip "$EPC_IP" \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$CONFIG_EPC:/root/.config/srsran:ro" \
  -v "$CONFIG_EPC:/etc/srsran:ro" \
  -v "$LOGS_DIR:/var/log/srsran" \
  "$IMAGE" srsepc

echo "=== Запуск eNB (172.20.0.3) ==="
docker rm -f enb 2>/dev/null || true
docker run -d --name enb --hostname enb \
  --network "$NETWORK" --ip "$ENB_IP" \
  --privileged \
  -e FFTW_WISDOM_FILE=/var/srsran/fftw/wisdom -e FFTW_PLAN_KEEP=1 \
  -v "$CONFIG_ENB:/root/.config/srsran:ro" \
  -v "$CONFIG_ENB:/etc/srsran:ro" \
  -v "$LOGS_DIR:/var/log/srsran" \
  -v "$UHD_IMAGES_DIR:/usr/share/uhd/images:ro" \
  -v "$FFTW_DIR:/var/srsran/fftw" \
  -v /dev/bus/usb:/dev/bus/usb \
  "$IMAGE" srsenb /root/.config/srsran/enb.conf

echo "=== Статус контейнеров ==="
docker ps --filter name=epc --filter name=enb --format "{{.Names}}\t{{.Status}}\t{{.Networks}}"
echo "=== Логи EPC (первые 20) ==="
sleep 8
docker logs epc 2>&1 | tail -20
