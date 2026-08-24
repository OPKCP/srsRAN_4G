#!/usr/bin/env bash
set -euo pipefail
# Полное извлечение системных библиотек, нужных srsepc/srsenb runtime, из образа
IMG="ghcr.io/opkcp/srsran_4g:latest"
DEST="$HOME/srsran/epc/lib"
mkdir -p "$DEST"

docker run --rm -v "$DEST:/out" "$IMG" bash -c '
  patterns="libpcre*.so.* libgcrypt*.so.* libgpg-error*.so.* libmbedcrypto*.so.* libmbedx509*.so.* libmbedtls*.so.* libconfig.so.* libzmq.so.* libsctp.so.* libboost_*.so.1.74.0 libstdc++.so.* libgcc_s.so.*"
  for pat in $patterns; do
    f=$(find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name "$pat" 2>/dev/null | head -1)
    if [ -n "$f" ]; then cp -L "$f" /out/ 2>/dev/null && echo "copied $(basename $f)"; fi
  done
'
echo "=== итог ==="
ls "$DEST" | grep -E '\.so' | wc -l
