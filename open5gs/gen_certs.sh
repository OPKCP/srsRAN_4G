#!/bin/bash
# Генерация самоподписанных сертификатов TLS для freeDiameter Open5GS.
set -euo pipefail
cd "$HOME/open5gs/config/tls" 2>/dev/null || { mkdir -p "$HOME/open5gs/config/tls"; cd "$HOME/open5gs/config/tls"; }

umask 077

# --- CA ---
[ -f ca.key ] || openssl genrsa -out ca.key 2048
[ -f ca.crt ] || openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=open5gs-ca"

gen_cert() {
  local name="$1"
  [ -f "$name.crt" ] && return
  openssl genrsa -out "$name.key" 2048
  openssl req -new -key "$name.key" -out "$name.csr" -subj "/CN=$name.localdomain"
  cat > "$name.ext" <<EOF
subjectAltName=DNS:$name.localdomain
EOF
  openssl x509 -req -days 3650 -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -extfile "$name.ext" -out "$name.crt"
  rm -f "$name.csr" "$name.ext"
}

for nf in mme hss smf pcrf; do
  gen_cert "$nf"
done

chmod 644 *.crt 2>/dev/null || true
echo "[OK] certs в $HOME/open5gs/config/tls:"
ls -la
