#!/usr/bin/env bash
set -euo pipefail

# Назначение: запуск EPC в bridge-сети Docker (локальный стенд).
# CONFIG_DIR: путь к конфигам srsRAN на хосте.
# LOGS_DIR: путь к логам srsRAN на хосте.
# SRSRAN_IMAGE: Docker-образ со сборкой srsRAN.

# Проверка наличия сети tr-network
if ! docker network inspect tr-network >/dev/null 2>&1; then
  echo "[INFO] Сеть tr-network не найдена. Создаю сеть..."
  docker network create --driver bridge --subnet 172.18.0.0/24 tr-network
  echo "[OK] Сеть tr-network успешно создана"
else
  echo "[OK] Сеть tr-network уже существует"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Пути на Linux-хосте (можно переопределить через переменные окружения)
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/../srsran_configs}"
LOGS_DIR="${LOGS_DIR:-${SCRIPT_DIR}/../logs}"
UHD_IMAGES_DIR="${UHD_IMAGES_DIR:-${SCRIPT_DIR}/../uhd_images}"
IMAGE="${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g:latest}"

# Проверка каталога логов
if [ ! -d "${LOGS_DIR}" ]; then
  echo "[INFO] Каталог логов ${LOGS_DIR} не найден. Создаю..."
  mkdir -p "${LOGS_DIR}"
  echo "[OK] Каталог логов успешно создан: ${LOGS_DIR}"
else
  echo "[OK] Каталог логов уже существует: ${LOGS_DIR}"
fi

# Запуск EPC в bridge-сети tr-network
# --ip 172.18.0.2: IPv4 адрес контейнера в подсети tr-network (допустимо: 172.18.0.0/24, кроме .0/.255).
# -v CONFIG_DIR:/etc/srsran:ro и UHD_IMAGES_DIR:/usr/share/uhd/images:ro перекрывают VOLUME
#   из образа, чтобы Docker не создавал анонимные тома (~0.5 ГБ за запуск).
docker run --rm -it \
  --name epc \
  --hostname epc \
  -v "${CONFIG_DIR}:/root/.config/srsran:ro" \
  -v "${CONFIG_DIR}:/etc/srsran:ro" \
  -v "${LOGS_DIR}:/var/log/srsran" \
  -v "${UHD_IMAGES_DIR}:/usr/share/uhd/images:ro" \
  --network tr-network \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --ip 172.18.0.2 \
  "${IMAGE}" \
  srsepc
