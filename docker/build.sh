#!/usr/bin/env bash
# ==============================================================================
# Скрипт локальной сборки Docker образа srsRAN_4G для Linux / macOS
#
# Использование:
#   ./docker/build.sh [ТЕГ]
#
# Примеры:
#   ./docker/build.sh              # сборка с тегом latest
#   ./docker/build.sh v1.0.0       # сборка с конкретной версией
#   ./docker/build.sh dev          # сборка образа для разработки
#
# Переменные окружения (можно переопределить перед запуском):
#   REGISTRY   — адрес реестра образов (по умолчанию ghcr.io)
#   OWNER      — владелец репозитория  (по умолчанию opkcp)
#   REPO       — имя образа            (по умолчанию srsran_4g)
# ==============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Настройки образа (можно переопределить через переменные окружения)
# --------------------------------------------------------------------------
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-opkcp}"
REPO_PATH="${REPO_PATH:-srsran_4g}"
REPO="${REPO:-srsran_4g}"
BASE_REPO="${BASE_REPO:-${REPO}-base}"
TAG="${1:-latest}"
IMAGE="${REGISTRY}/${OWNER}/${REPO_PATH}/${REPO}:${TAG}"
BASE_TAG="${BASE_TAG:-base-amd64}"
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/${OWNER}/${REPO_PATH}/${BASE_REPO}:${BASE_TAG}}"

# --------------------------------------------------------------------------
# Определяем корневую директорию репозитория (родитель папки docker/)
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/imgs"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_COMMIT_HASH="$(git -C "${REPO_ROOT}" log -1 --format=%h 2>/dev/null || echo unknown)"

ensure_base_image() {
    if docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
        echo "[OK] Базовый образ уже присутствует: ${BASE_IMAGE}"
        return 0
    fi

    echo "[INFO] Базовый образ не найден. Запускаем предварительную сборку."
    "${SCRIPT_DIR}/build-base.sh" "${BASE_TAG}"
}

echo "=============================================="
echo "  srsRAN_4G Docker сборка"
echo "=============================================="
echo "  Образ    : ${IMAGE}"
echo "  База     : ${BASE_IMAGE}"
echo "  Контекст : ${REPO_ROOT}"
echo "  Dockerfile: ${SCRIPT_DIR}/Dockerfile"
echo "=============================================="
echo ""

ensure_base_image

# --------------------------------------------------------------------------
# Сборка образа из корня репозитория с указанием пути к Dockerfile
# --------------------------------------------------------------------------
docker build \
    --file "${SCRIPT_DIR}/Dockerfile" \
    --build-arg GIT_BRANCH="${GIT_BRANCH}" \
    --build-arg GIT_COMMIT_HASH="${GIT_COMMIT_HASH}" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --tag  "${IMAGE}" \
    --progress=plain \
    "${REPO_ROOT}"

echo ""
echo "[OK] Образ успешно собран: ${IMAGE}"
mkdir -p "${IMAGES_DIR}"
IMAGE_TAR="${IMAGES_DIR}/${REPO}_${TAG}.tar"
docker save -o "${IMAGE_TAR}" "${IMAGE}"
echo "[OK] Образ экспортирован: ${IMAGE_TAR}"
echo ""
echo "Запуск eNodeB:"
echo "  docker run --rm -v /etc/srsran:/etc/srsran ${IMAGE}"
echo ""
echo "Запуск ядра сети EPC:"
echo "  docker run --rm -v /etc/srsran:/etc/srsran ${IMAGE} srsepc /etc/srsran/epc.conf"
echo ""
echo "Публикация в реестр:"
echo "  docker push ${IMAGE}"
