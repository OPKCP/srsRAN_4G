#!/usr/bin/env bash
# =============================================================================
# start-bs.sh — запуск БАЗОВОЙ СТАНЦИИ №1 (eNB1, 1815 МГц) на base5.
#
# Плата: клон LibreSDR B220mini (USB 2.0), serial M0M84A5, FPGA Artix-7 XC7A100T.
# ВАЖНО: этой плате нужен СВОЙ битстрим usrp_b210_fpga.bin (лежит в
#        ~/srsran/uhd_images) — штатный образ Ettus даёт "fx3 is in state 5".
# Конфиг: ~/srsran/enb1/enb.conf (mme_addr = 192.168.1.26 — ядро на pi5-2).
# Проверяется наличие платы по USB Vendor ID — без платы БС не стартует.
# sudo НЕ нужен: udev-правило даёт доступ к USB на запись всем.
# =============================================================================
set -euo pipefail

SRS="$HOME/srsran"
CFG="$SRS/enb1"
LOGS="$SRS/data/logs"
FFTW="$SRS/data/fftw"
UHD_IMAGES="$SRS/uhd_images"
IMG="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
CLONE_B210_MD5="216e64561bd63c6957942db7b7a9feea"

echo "===== БАЗОВАЯ СТАНЦИЯ №1 (eNB1) на $(hostname) ====="

# --- 1. Плата подключена? ---
USRP_VIDS="2500 2505 3923"
found=""
for f in /sys/bus/usb/devices/*/idVendor; do
  [ -e "$f" ] || continue
  v="$(cat "$f" 2>/dev/null)"
  case " ${USRP_VIDS} " in
    *" ${v} "*) d="$(dirname "$f")"; found="${found} $(cat "$d/idProduct" 2>/dev/null)@${v}" ;;
  esac
done
if [ -z "$found" ]; then
  echo "[ОШИБКА] USRP не обнаружен (VID ${USRP_VIDS}) — БС1 НЕ запускается." >&2
  echo "         Проверьте подключение платы (USB-порт/кабель)." >&2
  exit 2
fi
echo "[OK] Обнаружен USRP:${found}"

# --- 2. Проверка битстрима для клона LibreSDR ---
FPGA_IMG="$UHD_IMAGES/usrp_b210_fpga.bin"
if [ -e "$FPGA_IMG" ]; then
  img_md5="$(md5sum "$FPGA_IMG" | cut -d' ' -f1)"
  if [ "$img_md5" = "$CLONE_B210_MD5" ]; then
    echo "[OK] Битстрим LibreSDR (Artix-7) на месте"
  else
    echo "[ВНИМАНИЕ] $FPGA_IMG не похож на битстрим клона LibreSDR" >&2
    echo "           (md5 $img_md5). Штатный образ Ettus даст 'fx3 is in state 5'." >&2
    echo "           См. srs-readme.md, раздел Base5." >&2
  fi
fi

# --- 3. Каталоги ---
mkdir -p "$LOGS" "$FFTW"

# --- 4. Запуск (детерминированный: rm -f + run) ---
docker rm -f enb >/dev/null 2>&1 || true
docker run -d --name enb --hostname enb \
  --network host \
  --privileged \
  --restart unless-stopped \
  -e HOME=/var/srsran \
  -v "$CFG:/root/.config/srsran:ro" \
  -v "$CFG:/etc/srsran:ro" \
  -v "$LOGS:/var/log/srsran" \
  -v "$FFTW:/var/srsran" \
  -v "$UHD_IMAGES:/usr/share/uhd/images:ro" \
  -v /dev/bus/usb:/dev/bus/usb \
  "$IMG" srsenb /root/.config/srsran/enb.conf >/dev/null

echo "[..] Ожидание инициализации RF"
for _ in $(seq 1 60); do
  docker logs enb 2>&1 | grep -q 'eNodeB started' && break
  if ! docker ps --format '{{.Names}}' | grep -qx enb; then
    echo "[ОШИБКА] контейнер enb упал. Логи:" >&2
    docker logs --tail 20 enb 2>&1 >&2
    exit 4
  fi
  sleep 1
done

echo "--- Радио ---"
docker logs enb 2>&1 | grep -E 'Detected Device|Operating over USB|Register loopback test passed|clock rate' | tail -5 || true
echo "--- Старт и частота ---"
docker logs enb 2>&1 | grep -E 'eNodeB started|Setting frequency' | tail -3 || true
echo "--- S1 ---"
docker logs enb 2>&1 | grep -iE 'S1|MME' | tail -3 || true
echo
echo "[OK] БС1 запущена: $(docker ps --filter name=enb --format '{{.Status}}')"
