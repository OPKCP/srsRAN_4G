#!/usr/bin/env bash
# ==============================================================================
# run_enb2_pi5-2.sh — Запуск второй базовой станции (eNB2) на pi5-2
#                      с устройством NI USRP-2901 (B210, serial=3150E8C).
#
# Архитектура:
#   - EPC (srsepc) уже работает на pi5-2 (192.168.1.16, network host,
#     слушает S1-MME/SCTP 36412 и GTP-U/UDP 2152 на 192.168.1.16).
#   - eNB2 тоже на хосте pi5-2, но использует СВОЙ вторичный IP 192.168.1.20
#     на eth0, чтобы его GTP-U bind (192.168.1.20:2152) не конфликтовал
#     с EPC (192.168.1.16:2152).
#   - Несущая eNB2: EARFCN 1260 = 1811.0 МГц (Band 3) — ниже первой БС
#     (1815 МГц) на 3 МГц (полоса) + 1 МГц (защитный интервал).
#
# Детерминированный запуск: docker rm -f enb2 + новый контейнер `enb2`.
# ==============================================================================
set -euo pipefail

NAME="enb2"
IMG="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
BASE="$HOME/srsran"
CONFIG="$BASE/enb2"
LOGS="$BASE/logs"
FFTW_DIR="$BASE/fftw"           # каталог для .srsran_fftwisdom (КОПЛЕН план FFT, ускоряет запуск)
UHD_IMAGES="$BASE/uhd_images"   # образы USRP (если есть локально)
SECONDARY_IP="192.168.1.20/24"
SECONDARY_IF="eth0"

# --- 1. Гарантируем наличие вторичного IP на eth0 (для GTP/S1C bind eNB2) ---
if ! ip addr show "$SECONDARY_IF" | grep -q "inet $SECONDARY_IP"; then
  sudo ip addr add "$SECONDARY_IP" dev "$SECONDARY_IF"
  echo "[OK] Добавлен вторичный IP $SECONDARY_IP на $SECONDARY_IF"
else
  echo "[OK] Вторичный IP $SECONDARY_IP уже присутствует на $SECONDARY_IF"
fi

# --- 2. Правовая/права на USB (USRP-2901) ---
sudo chmod -R a+rw /dev/bus/usb 2>/dev/null || true

# --- 3. Каталоги (FFTW wisdom сохраняется между запусками для быстрого старта) ---
mkdir -p "$LOGS"
mkdir -p "$FFTW_DIR"

# --- 4. Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- 5. Запуск eNB2 (network host + privileged для USB/USRP) ---
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --privileged \
  --restart unless-stopped \
  -e HOME=/var/srsran \
  -v "$CONFIG:/root/.config/srsran:ro" \
  -v "$CONFIG:/etc/srsran:ro" \
  -v "$LOGS:/var/log/srsran" \
  -v "$FFTW_DIR:/var/srsran" \
  -v "/dev/bus/usb:/dev/bus/usb" \
  "$IMG" srsenb /root/.config/srsran/enb.conf \
  >"$LOGS/enb2_console_return.log" 2>&1 &

echo "[OK] eNB2 запущен (контейнер $NAME), логи в $LOGS/enb2_console_return.log"
echo "mme_addr = $(grep -E '^mme_addr' "$CONFIG/enb.conf" | head -1)"
echo "dl_earfcn = $(grep -A3 'cell_list' "$CONFIG/rr.conf" | grep dl_earfcn | head -1)"
