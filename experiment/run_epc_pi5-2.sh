#!/usr/bin/env bash
# ==============================================================================
# run_epc_pi5-2.sh — Запуск ядра сети (EPC / srsepc) на второй малинке (pi5-2).
# Хост: 192.168.1.16 (Linux, нативный SCTP). eNB (малинка1 192.168.1.15) будет
# ходить на 192.168.1.16:36412 (S1AP/SCTP) и 192.168.1.16:2152 (GTP-U/UDP).
# --network host: контейнер разделяет сетевой стек малинки → SCTP слушается
# напрямую на физическом IP (не нужен проброс портов, SCTP доступен нативно).
# Детерминированный запуск: docker rm -f epc + запуск нового контейнера `epc`.
# ==============================================================================
set -euo pipefail

NAME="epc"
IMG="ghcr.io/opkcp/srsran_4g/srsran_4g:ARM"
BASE="$HOME/srsran"
CONFIG="$BASE/config_epc"
LOGS="$BASE/logs"

# --- Удаление старого контейнера ---
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[OK] Удалён старый контейнер $NAME"

# --- Запуск EPC (network host) ---
docker run -d --name "$NAME" --hostname "$NAME" \
  --network host \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -v "$CONFIG:/root/.config/srsran:ro" \
  -v "$CONFIG:/etc/srsran:ro" \
  -v "$LOGS:/var/log/srsran" \
  "$IMG" srsepc

echo "[OK] EPC запущен (контейнер $NAME, network host)"
echo "mme_bind/gtpu_bind: $(grep -E 'mme_bind_addr|gtpu_bind_addr' "$CONFIG/epc.conf" | tr '\n' ' ')"

# --- NAT и форвардинг для абонентов (10.0.0.0/24) ---
for i in $(seq 1 20); do
  docker exec "$NAME" ip addr show srs_spgw_sgi >/dev/null 2>&1 && break
  sleep 1
done
# NAT (MASQUERADE) для выхода в интернет через eth0
o=$(ip route 2>/dev/null | awk '/default/{print $NF;exit}')
[ -z "$o" ] && o="eth0"
docker exec "$NAME" iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o "$o" -j MASQUERADE 2>/dev/null || \
  docker exec "$NAME" iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$o" -j MASQUERADE
# ВАЖНО: контейнер в --network host наследует docker iptables с FORWARD policy DROP.
# Без разрешения форвардинга абонентские пакеты (srs_spgw_sgi -> eth0) сбрасываются,
# интернет не работает (MASQUERADE счётчик 0). Разрешаем FORWARD для 10.0.0.0/24.
docker exec "$NAME" iptables -C FORWARD -s 10.0.0.0/24 -j ACCEPT 2>/dev/null || \
  docker exec "$NAME" iptables -I FORWARD 1 -s 10.0.0.0/24 -j ACCEPT
docker exec "$NAME" iptables -C FORWARD -d 10.0.0.0/24 -j ACCEPT 2>/dev/null || \
  docker exec "$NAME" iptables -I FORWARD 2 -d 10.0.0.0/24 -j ACCEPT
echo "[OK] NAT + FORWARD для абонентов 10.0.0.0/24 настроены (интернет)"
