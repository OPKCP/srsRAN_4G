#!/usr/bin/env bash
# =============================================================================
# start-bs1.sh — запуск базовой станции №1 (eNB1, 1815 МГц) на base5.
# Использование:
#   bash start-bs1.sh           # на pi5: авто → запуск БС1 на base5 по ssh
#   bash start-bs1.sh remote    # то же (явный удалённый запуск на base5)
#   bash start-bs1.sh local     # исполнить локально (на base5)
# Проверяет наличие подлючённого USRP (по USB Vendor ID); запускает БС только
# если устройство найдено, иначе — ошибка и ненулевой код возврата.
# На base5 этот же скрипт лежит в ~/start-bs1.sh и вызывается удалённо.
# =============================================================================
set -uo pipefail

TARGET="${BASE5_TARGET:-base5}"     # алиас из ~/.ssh/config pi5 (или shmac@192.168.1.25)
USRP_VIDS="2500 2505 3923"          # Ettus B2xx (2500/2505), NI USRP-2901 (3923)

# --- Режим "remote": запустить БС1 НА base5 по ssh, используя base5:~/start-bs1.sh.
if [ "${1:-}" = "remote" ]; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${TARGET}" 'bash ~/start-bs1.sh'
  rc=$?
  [ "${rc}" -ne 0 ] && echo "[ОШИБКА] Запуск БС1 на ${TARGET} завершился с кодом ${rc}." >&2
  exit "${rc}"
fi

# --- Авто-режим (без аргумента) при запуске НЕ на base5 → делегируем base5 ----
if [ "$(hostname)" != "Base5" ] && [ "${1:-}" != "local" ]; then
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
       "${TARGET}" 'bash ~/start-bs1.sh'
fi

# --- Ниже: исполнение НА base5 (локально или из stdin по ssh) -----------------
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

# --- Детерминированный запуск (rm -f + run) через штатный скрипт base5 --------
bash "${HOME}/srsran/scripts/run_enb_rpi.sh"

echo "[OK] БС1 запущена: $(docker ps --filter name=enb --format '{{.Status}}')"
