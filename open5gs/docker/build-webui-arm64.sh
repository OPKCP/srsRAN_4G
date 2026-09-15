#!/usr/bin/env bash
# =============================================================================
# build-webui-arm64.sh — собрать образ ядра Open5GS (arm64) СО встроенным WebUI
# и экспортировать в tar для переноса на pi5-2.
#
# Что делает:
#   1) ставит QEMU/binfmt (для сборки arm64 на x86-хосте через buildx);
#   2) собирает open5gs/docker/Dockerfile --platform linux/arm64
#      (билд-арг OPEN5GS_VERSION, по умолчанию v2.7.2) -> тег open5gs-arm64:v2.7.2-webui;
#   3) docker save -> open5gs-arm64-v2.7.2-webui.tar (для scp на pi5-2).
#
# Перенос на pi5-2:
#   scp open5gs-arm64-v2.7.2-webui.tar infarh@<pi5>:
#   ssh infarh@<pi5> 'docker load -i ~/open5gs-arm64-v2.7.2-webui.tar'
#   WEBUI_IMG=open5gs-arm64:v2.7.2-webui bash run_webui.sh   # поднять WebUI
#
# ВНИМАНИЕ: QEMU-эмуляция arm64 медленная (сборка ~30-60 мин). Кеш слоёв сохраняется.
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # open5gs/docker

VERSION="${OPEN5GS_VERSION:-v2.7.2}"
TAG="${IMAGE_TAG:-open5gs-arm64:${VERSION}-webui}"
OUT="${OUT_TAR:-open5gs-arm64-${VERSION}-webui.tar}"

echo "### 1. QEMU/binfmt ###"
docker run --privileged --rm tonistiigi/binfmt --install all

echo "### 2. buildx build linux/arm64 -> $TAG ###"
docker buildx build \
  --platform linux/arm64 \
  --build-arg "OPEN5GS_VERSION=$VERSION" \
  -t "$TAG" \
  -f Dockerfile . \
  --load --progress=plain

echo "### 3. docker save -> $OUT ###"
docker save -o "$OUT" "$TAG"
ls -lh "$OUT"
echo "### ГОТОВО. Тег: $TAG, tar: $OUT ###"
