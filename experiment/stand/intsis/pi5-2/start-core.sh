#!/usr/bin/env bash
# =============================================================================
# start-core.sh — запуск ЯДРА СЕТИ (MongoDB + Open5GS) на pi5-2 (192.168.1.26).
#
# Для пользователя intsis (sudo НЕ нужен). Конфиги и логи берутся из ~/srsran.
# Запуск детерминированный: контейнеры пересоздаются (docker rm -f + docker run).
#
# Слушает (network host):
#   S1-MME : 192.168.1.26:36412 (SCTP) — сюда подключаются обе БС стенда
#   GTP-U  : 192.168.1.26:2152  (UDP)
# SGi-интерфейс абонентов (ogstun, 10.0.0.1/24) поднимается внутри контейнера.
# =============================================================================
set -euo pipefail

SRS="$HOME/srsran"
O5="$SRS/open5gs"
CFG="$O5/config"
LOGS="$O5/logs"
IMG="open5gs-arm64:v2.7.2"

echo "===== ЯДРО СЕТИ (Open5GS) на $(hostname) ====="

docker image inspect "$IMG" >/dev/null 2>&1 || {
  echo "[ОШИБКА] образ $IMG не найден в docker." >&2; exit 1; }
[ -d "$CFG" ] || { echo "[ОШИБКА] нет каталога конфигов $CFG" >&2; exit 1; }
[ -d "$CFG/tls" ] || echo "[ВНИМАНИЕ] нет $CFG/tls — diameter TLS может не подняться"

# --- MongoDB (том с абонентами open5gs_mongo сохраняется между запусками) ---
docker rm -f open5gs-mongodb >/dev/null 2>&1 || true
docker run -d --name open5gs-mongodb --hostname open5gs-mongodb \
  --network host --restart unless-stopped \
  -v open5gs_mongo:/data/db mongo:6 >/dev/null

printf '[..] MongoDB запущена, ждём готовности'
for _ in $(seq 1 40); do
  docker exec open5gs-mongodb mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break
  printf '.'; sleep 1
done
echo
echo "[OK] MongoDB готова"

# --- Open5GS: все NF в одном контейнере ---
# --entrypoint /bin/bash обязателен: у образа свой entrypoint, иначе команда теряется.
docker rm -f open5gs >/dev/null 2>&1 || true
docker run -d --name open5gs --hostname open5gs \
  --network host --restart unless-stopped \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --entrypoint /bin/bash \
  -v "$CFG:/etc/open5gs:ro" \
  -v "$CFG/freeDiameter:/etc/freeDiameter:ro" \
  -v "$O5:/opt/open5gs:ro" \
  -v "$LOGS:/var/log/open5gs" \
  "$IMG" /opt/open5gs/run_open5gs.sh >/dev/null

printf '[..] Open5GS запущен, ждём NF'
for _ in $(seq 1 30); do
  docker exec open5gs sh -c 'ss -l -A sctp -n 2>/dev/null | grep -q 36412' && break
  printf '.'; sleep 1
done
echo

echo "--- NF-процессы ---"
docker exec open5gs sh -c 'ps -eo comm | grep -i "^open5gs-" | sort' 2>/dev/null || true
echo "--- S1-MME (SCTP 36412) / GTP-U (UDP 2152) ---"
docker exec open5gs sh -c 'ss -l -A sctp -n 2>/dev/null | grep 36412' || true
docker exec open5gs sh -c 'ss -lun 2>/dev/null | grep ":2152"' || true
echo "--- SGi-интерфейс абонентов (ogstun) ---"
docker exec open5gs sh -c 'ip -4 addr show ogstun 2>/dev/null | grep inet' || true

# --- NAT и форвардинг для абонентов (10.0.0.0/24) ---
# Правила ставятся ИЗНУТРИ контейнера open5gs (--network host => тот же netns,
# что и хост; контейнер имеет CAP_NET_ADMIN). Без них абонент получает адрес,
# но интернет и адрес ядра (10.0.0.1) не работают: docker-овский FORWARD имеет
# policy DROP, а без MASQUERADE пакеты не уходят наружу.
# Ждём появления ogstun внутри контейнера.
for _ in $(seq 1 20); do
  docker exec open5gs sh -c 'ip link show ogstun >/dev/null 2>&1' && break
  sleep 1
done

# Внешний интерфейс определяем по маршруту по умолчанию.
OUT_IF=$(docker exec open5gs sh -c "ip route 2>/dev/null | awk '/^default/{print \$5;exit}'" | tr -d '\r\n')
case "$OUT_IF" in
  ''|*[!a-zA-Z]*) OUT_IF="wlan0" ;;
esac

docker exec open5gs sh -c "iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o $OUT_IF -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $OUT_IF -j MASQUERADE"
for rule in "-s 10.0.0.0/24" "-d 10.0.0.0/24" "-i ogstun" "-o ogstun"; do
  docker exec open5gs sh -c "iptables -C FORWARD $rule -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 $rule -j ACCEPT"
done
# Резервное правило на случай динамического внешнего интерфейса.
docker exec open5gs sh -c "iptables -t nat -C POSTROUTING -s 10.0.0.0/24 ! -o ogstun -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.0.0.0/24 ! -o ogstun -j MASQUERADE"

echo "--- NAT/FORWARD для абонентов (интернет) ---"
docker exec open5gs sh -c 'iptables -t nat -S POSTROUTING | grep 10.0.0.0/24' || true
docker exec open5gs sh -c 'iptables -S FORWARD | grep -E "10.0.0.0/24|ogstun"' || true
echo "[OK] Ядро сети запущено."
