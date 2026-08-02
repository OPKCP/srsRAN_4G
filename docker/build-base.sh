#!/usr/bin/env bash
# ==============================================================================
# Скрипт предварительной сборки базового Docker образа srsRAN_4G для Linux / macOS
#
# Использование:
#   ./docker/build-base.sh [ТЕГ]
#
# Примеры:
#   ./docker/build-base.sh              # сборка базового образа для amd64
#   ./docker/build-base.sh base-amd64   # явное указание тега
#
# Переменные окружения:
#   REGISTRY   — адрес реестра образов (по умолчанию ghcr.io)
#   OWNER      — владелец репозитория  (по умолчанию opkcp)
#   REPO       — имя образа            (по умолчанию srsran_4g)
# ==============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-opkcp}"
REPO_PATH="${REPO_PATH:-srsran_4g}"
REPO="${REPO:-srsran_4g}"
BASE_REPO="${BASE_REPO:-${REPO}-base}"
BASE_TAG="${1:-${BASE_TAG:-base-amd64}}"
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/${OWNER}/${REPO_PATH}/${BASE_REPO}:${BASE_TAG}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/imgs"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_COMMIT_HASH="$(git -C "${REPO_ROOT}" log -1 --format=%h 2>/dev/null || echo unknown)"

# --------------------------------------------------------------------------
# Проверка наличия UHD images на хосте перед сборкой
# --------------------------------------------------------------------------
check_uhd_images() {
    # uhd_images_downloader — часть пакета uhd-host.
    # Если его нет, сборка образа пройдёт, но в runtime образы будут
    # отсутствовать. При использовании SDR через ZeroMQ это не критично.
    if command -v uhd_images_downloader &>/dev/null; then
        echo "[OK] uhd_images_downloader найден"
        # Пробуем получить список уже скачанных образов
        local images_list
        images_list="$(uhd_images_downloader -l 2>/dev/null)" || true
        if [ -n "${images_list}" ]; then
            echo "[OK] Список UHD images на хосте:"
            echo "${images_list}" | head -20
        fi
    else
        echo "[WARN] uhd_images_downloader не найден на хосте."
        echo "[WARN] UHD images НЕ будут загружены в базовый образ."
        echo "[WARN] Если требуется поддержка USRP, установи uhd-host:"
        echo "[WARN]   sudo apt install uhd-host"
        echo "[WARN] или монтируй host-путь с образами в runtime:"
        echo "[WARN]   -v /path/to/uhd_images:/usr/share/uhd/images"
    fi
}

check_uhd_images

echo "=============================================="
echo "  srsRAN_4G базовый Docker образ"
echo "=============================================="
echo "  Образ    : ${BASE_IMAGE}"
echo "  Контекст  : ${REPO_ROOT}"
echo "  Dockerfile: ${SCRIPT_DIR}/Dockerfile.base"
echo "=============================================="
echo ""

# Сборка базового образа.
# --pull гарантирует, что ubuntu:22.04 обновлён до последних патчей.
# Для основного образа (Dockerfile) --pull не нужен: он стартует
# с уже собранного локального/registry-образа ${BASE_IMAGE}.
docker build \
    --pull \
    --file "${SCRIPT_DIR}/Dockerfile.base" \
    --build-arg GIT_BRANCH="${GIT_BRANCH}" \
    --build-arg GIT_COMMIT_HASH="${GIT_COMMIT_HASH}" \
    --tag "${BASE_IMAGE}" \
    --progress=plain \
    "${REPO_ROOT}"

echo ""
echo "[OK] Базовый образ успешно собран: ${BASE_IMAGE}"
mkdir -p "${IMAGES_DIR}"
IMAGE_TAR="${IMAGES_DIR}/${BASE_REPO}_${BASE_TAG}.tar"
docker save -o "${IMAGE_TAR}" "${BASE_IMAGE}"
echo "[OK] Базовый образ экспортирован: ${IMAGE_TAR}"
