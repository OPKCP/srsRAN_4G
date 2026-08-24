#!/usr/bin/env bash
set -euo pipefail
# Извлечение srsepc и библиотек srsran из образа в домашний каталог WSL
IMG="ghcr.io/opkcp/srsran_4g:latest"
DEST="$HOME/srsran/epc"
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/config"

echo "=== извлекаю бинарник srsepc ==="
CID=$(docker create "$IMG")
docker cp "$CID:/usr/local/bin/srsepc" "$DEST/bin/srsepc"

echo "=== извлекаю динамические библиотеки srsran (.so) ==="
docker run --rm -v "$DEST/lib:/out" "$IMG" bash -c 'cp /usr/local/lib/*.so* /out/ 2>/dev/null || true'
docker rm -f "$CID" >/dev/null 2>&1 || true

echo "=== результат bin ==="
ls -la "$DEST/bin"
echo "=== libs (.so) ==="
ls "$DEST/lib" | grep -E '\.so' | head -40
