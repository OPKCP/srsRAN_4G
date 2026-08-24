#!/usr/bin/env bash
set -euo pipefail
# Извлечение системных библиотек, требуемых srsepc, из образа (boost 1.74, sctp)
IMG="ghcr.io/opkcp/srsran_4g:latest"
DEST="$HOME/srsran/epc/lib"
mkdir -p "$DEST"

# найти и скопировать нужные .so в /lib/x86_64-linux-gnu
docker run --rm "$IMG" bash -c '
  for lib in libboost_program_options.so.1.74.0 libboost_system.so.1.74.0 libsctp.so.1 libzmq.so.5; do
    find / -name "$lib" 2>/dev/null | head -1
  done
' | tee /tmp/libpaths.txt

echo "=== копирую в DEST ==="
# используем volume-монтирование чтобы забрать файлы
docker run --rm -v "$DEST:/out" "$IMG" bash -c '
  for pat in libboost_program_options.so.1.74.0 libboost_system.so.1.74.0 libsctp.so.1 libzmq.so.5 libconfig.so.9; do
    f=$(find / -name "$pat" 2>/dev/null | head -1)
    if [ -n "$f" ]; then cp -L "$f" /out/ && echo "copied $f"; fi
  done
'

echo "=== итог в DEST ==="
ls "$DEST" | grep -E '\.so' | head -20
