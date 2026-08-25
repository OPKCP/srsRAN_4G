#!/usr/bin/env bash
# ==============================================================================
# run_asterisk_pi5-2.sh — запуск Asterisk-контейнера (SIP/VoIP-сервер) на pi5-2.
# Обеспечивает голосовые вызовы между абонентами LTE-пикосоты (srsRAN):
#   Телефон (10.0.0.x) →(SIP)→ Asterisk →(SIP)→ Другой телефон (10.0.0.x)
#
# Абоненты: 1001..100N (масштабируемо). Конфиги: pjsip.conf, extensions.conf.
# Пробрасываются наружу (на 192.168.1.16 / все интерфейсы):
#   SIP/UDP 5060, SIP/TCP 5060, RTP UDP 10000-10100.
# Детерминированный запуск: docker rm -f asterisk + запуск нового контейнера.
# ==============================================================================
set -euo pipefail

NAME="asterisk"
IMG="andrius/asterisk:latest"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Каталог, где лежат конфиги. Если скрипт лежит в том же каталоге, что и конфиги,
# то CONF=$DIR. Если конфиги в подкаталоге "asterisk" — CONF=$DIR/asterisk.
# Скрипт и конфиги кладём в один каталог (~/srsran/asterisk/).
CONF="$DIR"

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Развернуть default конфиги, если нет (первые запуск) ---
# (монтируем каталог с нашими pjsip.conf/extensions.conf)

# --- Запуск Asterisk-контейнера ---
# КЛЮЧЕВОЕ: Asterisk запускается в сетевом namespace контейнера EPC (`epc`),
# чтобы оказаться в подсети абонентов 10.0.0.0/24 (srs_spgw_sgi=10.0.0.1).
# Телефоны (шлюз 10.0.0.1) видят Asterisk на 10.0.0.1:5060 (SIP).
if ! docker ps --format '{{.Names}}' | grep -q '^epc$'; then
  echo "[ERROR] Контейнер epc не запущен! Asterisk должен работать в namespace epc (-network container:epc)."
  exit 1
fi

docker run -d --name "$NAME" \
  --network container:epc \
  -v "$CONF/pjsip.conf:/etc/asterisk/pjsip.conf:ro" \
  -v "$CONF/extensions.conf:/etc/asterisk/extensions.conf:ro" \
  "$IMG"

echo "[OK] Asterisk запущен (контейнер $NAME) в namespace EPC (10.0.0.0/24)"
echo "SIP-адрес для телефонов: 10.0.0.1:5060 (шлюз srs_spgw_sgi)"
sleep 4
docker ps --filter name="$NAME" --format "{{.Names}}\t{{.Status}}"
echo "=== Логи Asterisk (первые) ==="
docker logs "$NAME" 2>&1 | tail -12
