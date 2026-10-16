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

# --- Проверка битстрима FPGA для платы на этом узле ---
# На Base5 стоит клон LibreSDR B220mini (FPGA Artix-7 XC7A100T) — ему нужен
# свой usrp_b210_fpga.bin, иначе UHD падает с "fx3 is in state 5" и eNB
# уходит в цикл рестартов. После обновления UHD файл перезаписывается штатным.
CLONE_B210_MD5="216e64561bd63c6957942db7b7a9feea"
FPGA_IMG="$UHD_IMAGES/usrp_b210_fpga.bin"
if [ -e "$FPGA_IMG" ]; then
  img_md5="$(md5sum "$FPGA_IMG" | cut -d' ' -f1)"
  if [ "$img_md5" != "$CLONE_B210_MD5" ]; then
    echo "[ПРЕДУПРЕЖДЕНИЕ] $FPGA_IMG не является битстримом для клона LibreSDR"
    echo "                 (ожидается md5 $CLONE_B210_MD5, получен $img_md5)."
    echo "                 Штатный образ Ettus (Spartan-6) не подойдёт — srsenb"
    echo "                 будет падать с 'fx3 is in state 5'. См. 'Base5 (eNB1)'"
    echo "                 в srs-readme.md."
  fi
fi

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Запуск eNB ---
# --restart unless-stopped: авто-перезапуск при падении/перезагрузке, останавливается только явным docker stop.
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --privileged \
  --restart unless-stopped \
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
