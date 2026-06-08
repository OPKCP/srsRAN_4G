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

echo "=============================================="
echo "  srsRAN_4G базовый Docker образ"
echo "=============================================="
echo "  Образ    : ${BASE_IMAGE}"
echo "  Контекст  : ${REPO_ROOT}"
echo "  Dockerfile: ${SCRIPT_DIR}/Dockerfile.base"
echo "=============================================="
echo ""

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
