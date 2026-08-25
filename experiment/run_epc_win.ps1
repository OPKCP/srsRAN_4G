# ==============================================================================
# run_epc_win.ps1
# Запуск ядра сети (EPC / srsepc) на компьютере (Windows, Docker Desktop).
# Контейнер опубликовывает порты наружу: 36412 (S1AP/S1-MME), 2152 (GTP-U).
# eNB (малинка) будет ходить на 192.168.1.10 (хост Windows).
# Детерминированный запуск: docker rm -f epc + запуск нового контейнера `epc`.
# ==============================================================================
$ErrorActionPreference = "Stop"

$NAME = "epc"
$IMG  = "ghcr.io/opkcp/srsran_4g:latest"
$DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CONFIG = Join-Path $DIR "epc_config"
$LOGS  = Join-Path $DIR "logs_epc"
New-Item -ItemType Directory -Force -Path $LOGS | Out-Null

# --- Удаление старого контейнера ---
docker rm -f $NAME 2>$null | Out-Null
Write-Host "[OK] Удалён старый контейнер $NAME"

# --- Запуск EPC с пробросом портов ---
docker run -d --name $NAME --hostname $NAME `
  -p 0.0.0.0:36412:36412/tcp `
  -p 0.0.0.0:2152:2152/udp `
  --cap-add=NET_ADMIN --device=/dev/net/tun `
  -v "${CONFIG}:/root/.config/srsran:ro" `
  -v "${CONFIG}:/etc/srsran:ro" `
  -v "${LOGS}:/var/log/srsran" `
  $IMG srsepc

if ($LASTEXITCODE -ne 0) { Write-Error "Не удалось запустить EPC"; exit 1 }
Write-Host "[OK] EPC запущен (контейнер $NAME)"

# --- NAT для абонентов (10.0.0.0/24) ---
for ($i=1; $i -le 20; $i++) {
  docker exec $NAME ip addr show srs_spgw_sgi > $null 2>&1
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep 1
}
docker exec $NAME iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE 2>$null
if ($LASTEXITCODE -ne 0) {
  docker exec $NAME iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
}
Write-Host "[OK] NAT для абонентов настроен"

Write-Host "=== Статус EPC ==="
docker ps --filter name=$NAME --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"
Write-Host "=== Логи EPC (первые) ==="
Start-Sleep 6
docker logs $NAME 2>&1 | Select-Object -Last 15
