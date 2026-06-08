#!/usr/bin/env bash
# ==============================================================================
# docker/build-4g-arm.sh
# Сборка Docker образа srsRAN_4G (включая srs4g) для ARM64 (RPi5).
#
# Использование:
#   ./docker/build-4g-arm.sh [ТЕГ]
#
# Примеры:
#   ./docker/build-4g-arm.sh              # сборка с тегом ARM
#   ./docker/build-4g-arm.sh v2.0.0       # сборка с конкретной версией
#
# Переменные окружения:
#   REGISTRY — реестр образов (по умолчанию ghcr.io)
#   OWNER    — владелец репозитория (по умолчанию opkcp)
#   REPO     — имя образа (по умолчанию srsran_4g)
#   PUSH     — если "true", отправить образ в реестр после сборки
#
# Требования:
#   - Docker с buildx для кросс-компиляции (linux/arm64)
#   - Активный buildx builder с поддержкой ARM64
#     Создание: docker buildx create --name arm64-builder --use
#
# Примечание по сборке:
#   Dockerfile собирает оба бинарника: srsenb и srs4g.
#   Образ готов для использования как ENB, так и 4G контейнером.
# ==============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-opkcp}"
REPO_PATH="${REPO_PATH:-srsran_4g}"
REPO="${REPO:-srsran_4g}"
BASE_REPO="${BASE_REPO:-${REPO}-base}"
TAG="${1:-ARM}"
IMAGE="${REGISTRY}/${OWNER}/${REPO_PATH}/${REPO}:${TAG}"
PUSH="${PUSH:-false}"
BASE_TAG="${BASE_TAG:-base-arm64}"
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/${OWNER}/${REPO_PATH}/${BASE_REPO}:${BASE_TAG}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/imgs"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.buildx-cache-arm64}"
CACHE_DIR_NEW="${CACHE_DIR_NEW:-${SCRIPT_DIR}/.buildx-cache-arm64-new}"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_COMMIT_HASH="$(git -C "${REPO_ROOT}" log -1 --format=%h 2>/dev/null || echo unknown)"

echo "=============================================="
echo "  srsRAN_4G ARM64 Docker сборка (с srs4g)"
echo "=============================================="
echo "  Образ:       ${IMAGE}"
echo "  База:        ${BASE_IMAGE}"
echo "  Платформа:   linux/arm64"
echo "  Ветка:       ${GIT_BRANCH}"
echo "  Коммит:      ${GIT_COMMIT_HASH}"
echo "  Push:        ${PUSH}"
echo "  Кэш buildx:  ${CACHE_DIR}"
echo "=============================================="
echo ""
echo "Включённые бинарники:"
echo "  srsenb   — базовая станция LTE"
echo "  srs4g — автономный 4G модуль"
echo ""

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "[INFO] Базовый образ не найден. Запускаем предварительную сборку."
  "${SCRIPT_DIR}/build-base-arm.sh" "${BASE_TAG}"
fi

BUILD_ARGS=(
  "--file" "${SCRIPT_DIR}/Dockerfile"
  "--platform" "linux/arm64"
  "--cache-from" "type=local,src=${CACHE_DIR}"
  "--cache-to" "type=local,dest=${CACHE_DIR_NEW},mode=max"
  "--build-arg" "GIT_BRANCH=${GIT_BRANCH}"
  "--build-arg" "GIT_COMMIT_HASH=${GIT_COMMIT_HASH}"
  "--build-arg" "BASE_IMAGE=${BASE_IMAGE}"
  "--tag" "${IMAGE}"
  "--progress=plain"
)

if [[ "${PUSH}" == "true" ]]; then
  BUILD_ARGS+=("--push")
else
  BUILD_ARGS+=("--load")
fi

docker buildx build "${BUILD_ARGS[@]}" "${REPO_ROOT}"

rm -rf "${CACHE_DIR}"
mv "${CACHE_DIR_NEW}" "${CACHE_DIR}"

echo ""
echo "[OK] Образ ARM64 собран: ${IMAGE}"
if [[ "${PUSH}" == "true" ]]; then
  docker pull "${IMAGE}"
fi
mkdir -p "${IMAGES_DIR}"
IMAGE_TAR="${IMAGES_DIR}/${REPO}_${TAG}.tar"
docker save -o "${IMAGE_TAR}" "${IMAGE}"
echo "[OK] Образ ARM64 экспортирован: ${IMAGE_TAR}"
if [[ "${PUSH}" == "true" ]]; then
  echo "[OK] Образ отправлен в реестр."
fi
echo ""
echo "Запуск ENB:"
echo "  docker run --rm --privileged --ipc shareable -v /etc/srsran:/etc/srsran ${IMAGE} \\"
echo "    srsenb /etc/srsran/enb.conf"
echo ""
