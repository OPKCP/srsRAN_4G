#!/usr/bin/env bash
set -euo pipefail
# Извлечение недостающих системных библиотек (boost 1.74 и др.) из образа
IMG="ghcr.io/opkcp/srsran_4g:latest"
DEST="$HOME/srsran/epc/lib"
mkdir -p "$DEST"

echo "=== ldd srsepc в образе (недостающие для WSL) ==="
docker run --rm "$IMG" bash -c 'ldd /usr/local/bin/srsepc | grep -iE "boost|mbedtls|fftw|config|sctp|zmq|pcsclite" | awk "{print \$3}"'
