#!/usr/bin/env bash
set -euo pipefail
echo "=== srsepc ==="
docker run --rm ghcr.io/opkcp/srsran_4g:latest bash -c 'which srsepc; ls -la /usr/local/bin/srsepc'
echo "=== libsrsran_epc/библиотеки ==="
docker run --rm ghcr.io/opkcp/srsran_4g:latest bash -c 'ls /usr/local/lib/ | grep -E "libsrsran"'
echo "=== недостающие зависимости srsepc ==="
docker run --rm ghcr.io/opkcp/srsran_4g:latest bash -c 'ldd /usr/local/bin/srsepc 2>&1 | grep -i "not found" || echo "все зависимости ok"'
