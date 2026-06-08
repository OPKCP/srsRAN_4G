#!/usr/bin/env bash
set -euo pipefail

# Назначение: запуск eNB в bridge-сети Docker (локальный стенд).
# CONFIG_DIR: путь к конфигам srsRAN на хосте.
# LOGS_DIR: путь к логам srsRAN на хосте.
# UHD_IMAGES_DIR: путь к UHD images на хосте.
# SRSRAN_IMAGE: Docker-образ со сборкой srsRAN.

# Проверка наличия сети tr-network
if ! docker network inspect tr-network >/dev/null 2>&1; then
  echo "[INFO] Сеть tr-network не найдена. Создаю сеть..."
  docker network create --driver bridge --subnet 172.18.0.0/24 tr-network
  echo "[OK] Сеть tr-network успешно создана"
else
  echo "[OK] Сеть tr-network уже существует"
fi

# Пути на Linux-хосте (можно переопределить через переменные окружения)
CONFIG_DIR="${CONFIG_DIR:-/opt/opkcp/srsran_configs}"
LOGS_DIR="${LOGS_DIR:-/opt/opkcp/srsran_logs}"
UHD_IMAGES_DIR="${UHD_IMAGES_DIR:-/opt/opkcp/uhd_images}"
IMAGE="${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g:latest}"

# Проверка каталога логов
if [ ! -d "${LOGS_DIR}" ]; then
  echo "[INFO] Каталог логов ${LOGS_DIR} не найден. Создаю..."
  mkdir -p "${LOGS_DIR}"
  echo "[OK] Каталог логов успешно создан: ${LOGS_DIR}"
else
  echo "[OK] Каталог логов уже существует: ${LOGS_DIR}"
fi

# Запуск eNB в bridge-сети tr-network
docker run --rm -it \
  --name enb \
  --hostname enb \
  -v "${CONFIG_DIR}:/root/.config/srsran:ro" \
  -v "${LOGS_DIR}:/var/log/srsran" \
  -v "${UHD_IMAGES_DIR}:/usr/share/uhd/images" \
  --privileged \
  --network tr-network \
  --ip 172.18.0.3 \
  "${IMAGE}" \
  srsenb /root/.config/srsran/enb.conf
