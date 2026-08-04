#!/usr/bin/env bash
set -euo pipefail

# Назначение: запуск EPC в host-сети для доступа eNB с других хостов LAN.
# EPC_HOST_IP: IPv4 адрес хоста с EPC (допустимо: x.x.x.x, октеты 0..255).
# CONFIG_DIR/LOGS_DIR: каталоги конфигов и логов на Linux-хосте.
# BASE_CFG: исходный epc.conf, TMP_CFG: временный конфиг с подстановкой сетевых адресов.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Профиль EPC для запуска на отдельном Linux-хосте в LAN
EPC_HOST_IP="${EPC_HOST_IP:-192.168.1.18}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/../srsran_configs}"
LOGS_DIR="${LOGS_DIR:-${SCRIPT_DIR}/../logs}"
BASE_CFG="${BASE_CFG:-${CONFIG_DIR}/epc.conf}"
TMP_CFG="$(mktemp /tmp/epc.net.XXXXXX.conf)"
IMAGE="${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g:latest}"

cleanup() {
  rm -f "${TMP_CFG}"
}
trap cleanup EXIT

# Проверка базового конфига
if [ ! -f "${BASE_CFG}" ]; then
  echo "[ERROR] Не найден файл конфигурации: ${BASE_CFG}"
  exit 1
fi

# Проверка каталога логов
if [ ! -d "${LOGS_DIR}" ]; then
  echo "[INFO] Каталог логов ${LOGS_DIR} не найден. Создаю..."
  mkdir -p "${LOGS_DIR}"
fi

# Генерация временного epc.conf c LAN-адресом EPC
# mme_bind_addr/gtpu_bind_addr: IPv4 адрес EPC (формат x.x.x.x).
# sgi_if_addr: адрес SGi интерфейса EPC (обычно приватная подсеть, например 172.16.0.1).
cp "${BASE_CFG}" "${TMP_CFG}"
sed -Ei "s|^[[:space:]]*mme_bind_addr[[:space:]]*=.*$|mme_bind_addr = ${EPC_HOST_IP}|" "${TMP_CFG}"
sed -Ei "s|^[[:space:]]*gtpu_bind_addr[[:space:]]*=.*$|gtpu_bind_addr   = ${EPC_HOST_IP}|" "${TMP_CFG}"
sed -Ei "s|^[[:space:]]*sgi_if_addr[[:space:]]*=.*$|sgi_if_addr      = 172.16.0.1|" "${TMP_CFG}"

echo "[OK] Временный конфиг EPC: ${TMP_CFG}"

# Запуск EPC в host-сети для доступа eNB с других хостов
docker run --rm -it \
  --name epc \
  --hostname epc \
  -v "${TMP_CFG}:/root/.config/srsran/epc.conf:ro" \
  -v "${CONFIG_DIR}:/root/.config/srsran:ro" \
  -v "${LOGS_DIR}:/var/log/srsran" \
  --network host \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  "${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g:latest}" \
  srsepc /root/.config/srsran/epc.conf
