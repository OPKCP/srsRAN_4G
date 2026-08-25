#!/usr/bin/env bash
# ==============================================================================
# run_enb_rpi.sh — Запуск eNB (БС) на малинке для архитектуры "EPC на компьютере".
# eNB подключается к EPC на компьютере (192.168.1.10) по проброшенному порту.
# Конфиг: ~/srsran/experiment_enb/enb.conf (mme_addr=192.168.1.10,
#        gtp/s1c_bind_addr=192.168.1.15).
# Сеть: --network host (eNB использует IP малинки 192.168.1.15 для S1).
# Детерминированный запуск: docker rm -f enb + запуск нового контейнера `enb`.
# ==============================================================================
set -euo pipefail

NAME="enb"
IMG="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
CONFIG="$HOME/srsran/experiment_enb"
LOGS="$HOME/srsran/local/logs"
UHD_IMAGES="$HOME/srsran/uhd_images"
FFTW_DIR="$HOME/srsran/fftw"

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Запуск eNB ---
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --privileged \
  -e HOME=/var/srsran \
  -v "$CONFIG:/root/.config/srsran:ro" \
  -v "$CONFIG:/etc/srsran:ro" \
  -v "$LOGS:/var/log/srsran" \
  -v "$UHD_IMAGES:/usr/share/uhd/images:ro" \
  -v "$FFTW_DIR:/var/srsran" \
  -v /dev/bus/usb:/dev/bus/usb \
  "$IMG" srsenb /root/.config/srsran/enb.conf \
  >"$LOGS/enb_console_return.log" 2>&1 &

echo "[OK] eNB запущен (контейнер $NAME), логи в $LOGS/enb_console_return.log"
echo "mme_addr = $(grep -E '^mme_addr' "$CONFIG/enb.conf" | head -1)"
