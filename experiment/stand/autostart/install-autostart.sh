#!/usr/bin/env bash
# =============================================================================
# install-autostart.sh — установка автозапуска стенда (выполнять с sudo)
# =============================================================================
# Ставит на узел:
#   /home/intsis/stand-autostart.sh                  — логика подъёма/починки
#   /etc/systemd/system/srsran-stand-core.service    — ядро (только узел ядра)
#   /etc/systemd/system/srsran-stand-web.service     — веб и мониторинг
#   /etc/systemd/system/srsran-stand-bs.service      — БС (только при наличии SDR)
#   /etc/systemd/system/srsran-stand-watchdog.{service,timer} — сторож
#
# Юниты, для которых нет соответствующего start-*.sh, отключаются автоматически
# (ConditionPathExists), поэтому один и тот же набор подходит и для pi5-2, и для
# base5: на base5 нет start-core.sh -> ядро не запускается.
#
# Использование:
#   sudo bash install-autostart.sh            # установить и включить
#   sudo bash install-autostart.sh --dry-run  # только показать, что будет сделано
#   sudo bash install-autostart.sh --remove   # снять автозапуск
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST_USER=intsis
DEST_HOME=/home/$DEST_USER
DEST_SCRIPT="$DEST_HOME/stand-autostart.sh"
SYSTEMD_DIR=/etc/systemd/system
UNITS=(srsran-stand-core.service srsran-stand-web.service
       srsran-stand-bs.service srsran-stand-watchdog.service
       srsran-stand-watchdog.timer)
ENABLE=(srsran-stand-core.service srsran-stand-web.service
        srsran-stand-bs.service srsran-stand-watchdog.timer)

DRY=0
REMOVE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --remove)  REMOVE=1 ;;
    *) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

echo "=== автозапуск стенда srsRAN на $(hostname) ==="

if [ "$REMOVE" = 1 ]; then
  for u in "${UNITS[@]}"; do
    run systemctl disable --now "$u" 2>/dev/null || true
    run rm -f "$SYSTEMD_DIR/$u"
  done
  run systemctl daemon-reload
  run rm -f "$DEST_SCRIPT"
  echo "[OK] автозапуск снят"
  exit 0
fi

# --- 1. Скрипт логики в домашний каталог intsis ---
run install -o "$DEST_USER" -g "$DEST_USER" -m 0755 \
    "$SRC/stand-autostart.sh" "$DEST_SCRIPT"

# --- 2. Юниты ---
for u in "${UNITS[@]}"; do
  run install -o root -g root -m 0644 "$SRC/$u" "$SYSTEMD_DIR/$u"
done
run systemctl daemon-reload

# --- 3. Включение (что применимо на этом узле) ---
for u in "${ENABLE[@]}"; do
  run systemctl enable --now "$u"
done
# Сторож: сервис включён через таймер, отдельный enable не нужен.
run systemctl start srsran-stand-watchdog.timer 2>/dev/null || true

echo
echo "--- состояние ---"
for u in srsran-stand-core.service srsran-stand-web.service \
         srsran-stand-bs.service srsran-stand-watchdog.timer; do
  printf '%-34s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo n/a)/$(systemctl is-active "$u" 2>/dev/null || echo n/a)"
done
echo "[OK] автозапуск установлен. Лог: $DEST_HOME/.stand/autostart.log"
echo "     После подачи питания стенд поднимется сам."
