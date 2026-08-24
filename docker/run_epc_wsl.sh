#!/usr/bin/env bash
# ==============================================================================
# run_epc_wsl.sh
#
# Запуск ядра сети (EPC / srsepc) внутри WSL на компьютере Windows.
# Используется сетевой режим WSL "mirrored" — WSL получает тот же IP, что и
# физический адаптер Windows (например 192.168.1.10), что позволяет eNB на
# малинке (192.168.1.15) подключаться к EPC по S1 (SCTP 36412) напрямую через
# роутер.
#
# Требования:
#   - Windows + WSL2 с дистрибутивом Ubuntu (напр. Ubuntu-24.04)
#   - Docker в WSL (docker --version) ИЛИ Docker Desktop WSL-integration
#   - Сетевой режим WSL: mirrored (см. ниже)
#
# Запуск (из Windows PowerShell или git-bash):
#   wsl -e bash /mnt/c/.../docker/run_epc_wsl.sh
#
# Либо внутри WSL:
#   bash ~/srsran/run_epc_wsl.sh
# ==============================================================================
set -euo pipefail

# --- Параметры ---------------------------------------------------------------
# Образ с srsepc. Для WSL (amd64) используем собранный x86-образ.
IMAGE="${SRSRAN_IMAGE:-ghcr.io/opkcp/srsran_4g:latest}"
# Каталоги на Linux-стороне WSL. По умолчанию — в домашнем каталоге WSL.
BASE_DIR="${SRSRAN_BASE_DIR:-$HOME/srsran}"
CONFIG_DIR="${CONFIG_DIR:-$BASE_DIR/config_epc}"
LOGS_DIR="${LOGS_DIR:-$BASE_DIR/logs}"
UHD_IMAGES_DIR="${UHD_IMAGES_DIR:-$BASE_DIR/uhd_images}"

# IP, на котором должен слушать EPC (реальный IP Windows в сети роутера).
# При mirrored-режиме WSL разделяет этот IP с Windows.
EPC_BIND_IP="${EPC_BIND_IP:-0.0.0.0}"
EPC_MCC="${MCC:-250}"
EPC_MNC="${MNC:-63}"

# --- Проверка Docker ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker не найден в WSL. Установите Docker в WSL или включите WSL-integration в Docker Desktop." >&2
  echo "  Например: sudo apt-get install -y docker.io && sudo service docker start" >&2
  exit 1
fi

docker images "$IMAGE" >/dev/null 2>&1 || { echo "[INFO] Образ $IMAGE не найден, pull..."; docker pull "$IMAGE"; }

# --- Каталоги ----------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$UHD_IMAGES_DIR"

# Если нет конфигов EPC — скопировать из образа
if [ ! -f "$CONFIG_DIR/epc.conf" ]; then
  echo "[INFO] Копирую дефолтные конфиги EPC из образа..."
  docker run --rm -v "$CONFIG_DIR:/out" "$IMAGE" bash -c "cp /root/.config/srsran/epc.conf /root/.config/srsran/user_db.csv /out/ 2>/dev/null || cp /etc/srsran/epc.conf /etc/srsran/user_db.csv /out/"
fi

# Если UHD images пуст — заполнить
if [ -z "$(ls -A "$UHD_IMAGES_DIR" 2>/dev/null)" ]; then
  echo "[INFO] UHD images пуст, копирую из образа..."
  docker run --rm -v "$UHD_IMAGES_DIR:/out" "$IMAGE" bash -c "cp /usr/share/uhd/images/* /out/ 2>/dev/null || true"
fi

# --- Подсказка по mirrored-сетевому режиму WSL -------------------------------
# Чтобы WSL использовал IP Windows (важно для S1/SCTP), в %USERPROFILE%\.wslconfig:
#   [wsl2]
#   networkingMode=mirrored
# Затем: wsl --shutdown && wsl (из Windows PowerShell).

# --- Запуск EPC ---------------------------------------------------------------
# --network host внутри WSL (при mirrored) разделяет сетевой стек Windows,
# поэтому srsepc слушает на IP Windows (напр. 192.168.1.10) и SCTP-порт 36412.
# mme_bind_addr/gtpu_bind_addr берутся из epc.conf; при необходимости правятся ниже.
echo "[OK] Запуск EPC: MCC=$EPC_MCC MNC=$EPC_MNC bind=$EPC_BIND_IP (image=$IMAGE)"
echo "     Конфиги: $CONFIG_DIR | Логи: $LOGS_DIR"
docker run --rm -it \
  --name epc \
  --hostname epc \
  --network host \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -v "$CONFIG_DIR:/root/.config/srsran:ro" \
  -v "$CONFIG_DIR:/etc/srsran:ro" \
  -v "$LOGS_DIR:/var/log/srsran" \
  -v "$UHD_IMAGES_DIR:/usr/share/uhd/images:ro" \
  "$IMAGE" \
  srsepc
