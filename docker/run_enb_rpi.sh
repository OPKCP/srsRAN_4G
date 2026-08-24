#!/usr/bin/env bash
set -euo pipefail

# Запуск srsenb в Docker-контейнере на RPi5 с пробросом USRP B210.
# Малинка (eNB): 192.168.1.15 · EPC (компьютер): 192.168.1.10

IMAGE="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
CONFIG_DIR="${CONFIG_DIR:-$HOME/srsran/config}"
LOGS_DIR="${LOGS_DIR:-$HOME/srsran/logs}"
UHD_IMAGES_DIR="${UHD_IMAGES_DIR:-$HOME/srsran/uhd_images}"
FFTW_DIR="${FFTW_DIR:-$HOME/srsran/fftw}"   # кэш FFT-плана (ускоряет старт eNB)

# Каталог кэша FFT (wisdom-файл FFTW) — иначе srsenb перегенерирует план FFT при каждом старте
mkdir -p "$FFTW_DIR"

# Если каталог UHD images пуст — заполнить из образа
if [ -z "$(ls -A "$UHD_IMAGES_DIR" 2>/dev/null)" ]; then
  echo "[INFO] UHD images каталог пуст, копирую из образа..."
  docker run --rm -v "$UHD_IMAGES_DIR:/out" "$IMAGE" bash -c "cp /usr/share/uhd/images/* /out/"
fi

echo "[OK] Запуск eNB (DL=1815 МГц, 6 PRB) на RPi5, EPC 192.168.1.10"
docker run --rm -it \
  --name enb \
  --hostname enb \
  --privileged \
  --network host \
  -e FFTW_WISDOM_FILE=/var/srsran/fftw/wisdom \
  -e FFTW_PLAN_KEEP=1 \
  -v "$CONFIG_DIR:/etc/srsran:ro" \
  -v "$LOGS_DIR:/var/log/srsran" \
  -v "$UHD_IMAGES_DIR:/usr/share/uhd/images:ro" \
  -v "$FFTW_DIR:/var/srsran/fftw" \
  -v /dev/bus/usb:/dev/bus/usb \
  "$IMAGE" \
  srsenb /etc/srsran/enb.conf
