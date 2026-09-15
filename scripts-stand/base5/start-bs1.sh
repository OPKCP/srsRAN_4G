#!/usr/bin/env bash
# =============================================================================
# start-bs1.sh — запуск базовой станции №1 (eNB1, 1815 МГц) НА base5 (локально).
# Вызывается и вручную на base5, и удалённо с pi5 (pi5:~/start-bs1.sh remote
# → ssh base5 'bash ~/start-bs1.sh').
#
# Проверяет наличие подлючённого USRP (по USB Vendor ID); запускает БС только
# если устройство найдено, иначе — сообщение об ошибке и ненулевой код возврата.
# Запуск детерминированный: штатный run_enb_rpi.sh делает docker rm -f + run.
# =============================================================================
set -uo pipefail

USRP_VIDS="2500 2505 3923"          # Ettus B2xx (2500/2505), NI USRP-2901 (3923)

found=""
for f in /sys/bus/usb/devices/*/idVendor; do
  [ -e "$f" ] || continue
  v="$(cat "$f" 2>/dev/null)"
  case " ${USRP_VIDS} " in
    *" ${v} "*) d="$(dirname "$f")"; found="${found} $(cat "$d/idProduct" 2>/dev/null)@${v}" ;;
  esac
done

if [ -z "${found}" ]; then
  echo "[ОШИБКА] USRP не обнаружен (VID ${USRP_VIDS}) — БС1 НЕ запускается."
  echo "         Проверьте физическое подключение платы (USB порт/кабель)."
  exit 2
fi
echo "[OK] Обнаружен USRP:${found}"

bash "${HOME}/srsran/scripts/run_enb_rpi.sh"

echo "[OK] БС1 запущена: $(docker ps --filter name=enb --format '{{.Status}}')"
