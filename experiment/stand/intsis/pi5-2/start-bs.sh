#!/usr/bin/env bash
# =============================================================================
# start-bs.sh — запуск БАЗОВОЙ СТАНЦИИ №2 (eNB2, 1811 МГц) на pi5-2.
#
# Плата: Ettus/NI USRP B210 (USB 3.0), serial 34ZK29C.
# Конфиг: ~/srsran/enb2/enb.conf; eNB2 привязывается к ВТОРИЧНОМУ IP 192.168.1.20,
# чтобы его GTP-U/S1C не конфликтовали с ядром на 192.168.1.26.
# Проверяется наличие платы по USB Vendor ID — без платы БС не стартует.
# sudo НЕ нужен: udev-правило 99-usrp.rules даёт доступ к USB на запись всем.
# =============================================================================
set -euo pipefail

SRS="$HOME/srsran"
CFG="$SRS/enb2"
LOGS="$SRS/data/logs"
FFTW="$SRS/data/fftw"
UHD_IMAGES="$SRS/uhd_images"
IMG="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
SECONDARY_IP="192.168.1.20/24"
SECONDARY_IF="wlan0"

echo "===== БАЗОВАЯ СТАНЦИЯ №2 (eNB2) на $(hostname) ====="

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
  echo "[ОШИБКА] USRP не обнаружен (VID ${USRP_VIDS}) — БС2 НЕ запускается." >&2
  echo "         Проверьте подключение платы (USB-порт/кабель)." >&2
  exit 2
fi
echo "[OK] Обнаружен USRP:${found}"

# --- 2. Вторичный IP для bind eNB2 (персистентен через NetworkManager) ---
if ! ip addr show "$SECONDARY_IF" | grep -q "inet ${SECONDARY_IP%/*}"; then
  echo "[ВНИМАНИЕ] на $SECONDARY_IF нет $SECONDARY_IP." >&2
  echo "           Добавьте его администратором:" >&2
  echo "           sudo nmcli con mod IS-1 +ipv4.addresses $SECONDARY_IP && sudo nmcli con up IS-1" >&2
  exit 3
fi
echo "[OK] Вторичный IP $SECONDARY_IP на $SECONDARY_IF присутствует"

# --- 3. Ядро запущено? (иначе eNB будет висеть без S1) ---
if ! docker ps --format '{{.Names}}' | grep -qx 'open5gs'; then
  echo "[ВНИМАНИЕ] контейнер open5gs (ядро) не запущен — S1 не поднимется."
  echo "           Сначала выполните ./start-core.sh"
fi

# --- 4. Каталоги ---
mkdir -p "$LOGS" "$FFTW"

# --- 5. Запуск (детерминированный: rm -f + run) ---
docker rm -f enb2 >/dev/null 2>&1 || true
docker run -d --name enb2 --hostname enb2 \
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
  docker logs enb2 2>&1 | grep -q 'eNodeB started' && break
  if ! docker ps --format '{{.Names}}' | grep -qx enb2; then
    echo "[ОШИБКА] контейнер enb2 упал. Логи:" >&2
    docker logs --tail 20 enb2 2>&1 >&2
    exit 4
  fi
  sleep 1
done

echo "--- Радио ---"
docker logs enb2 2>&1 | grep -E 'Detected Device|Operating over USB|Register loopback test passed|clock rate' | tail -5 || true
echo "--- Старт и частота ---"
docker logs enb2 2>&1 | grep -E 'eNodeB started|Setting frequency' | tail -3 || true
echo "--- S1 ---"
docker logs enb2 2>&1 | grep -iE 'S1|MME' | tail -3 || true
echo
echo "[OK] БС2 запущена: $(docker ps --filter name=enb2 --format '{{.Status}}')"
