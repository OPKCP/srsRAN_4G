# ==============================================================================
# run_python_epc_win.ps1
# Синтетический тест: python-контейнер на компьютере (Windows), имитирующий ядро EPC.
# Пробрасывает наружу порты, соответствующие EPC: S1AP/SCTP 36412, GTP-U/UDP 2152.
# Детерминированный запуск: docker rm -f старого + запуск нового контейнера `epc`.
#
# eNB (малинка) будет ходить на 192.168.1.10 (хост Windows) на эти порты.
# ==============================================================================
$ErrorActionPreference = "Stop"

$NAME = "epc"
$IMG  = "python:3.12-slim"
$HOST_IP = "0.0.0.0"        # публикуем на все интерфейсы (доступно снаружи на 192.168.1.10)
$S1AP_PORT = 36412          # SCTP/S1AP
$GTP_PORT  = 2152           # UDP/GTP-U

# --- Удаление старого контейнера ---
docker rm -f $NAME 2>$null | Out-Null
Write-Host "[OK] Удалён старый контейнер $NAME (если был)"

# --- Запуск нового контейнера с пробросом портов ---
# Порты пробрасываются на все интерфейсы хоста (0.0.0.0): доступны снаружи на 192.168.1.10.
# После реконфигурации Docker на хосте это работает (порт контейнера доступен с малинки).
docker run -d --name $NAME --hostname $NAME `
  --publish "${HOST_IP}:36412:36412" `
  --publish "${HOST_IP}:2152:2152/udp" `
  $IMG sleep infinity

if ($LASTEXITCODE -ne 0) { Write-Error "Не удалось запустить контейнер $NAME"; exit 1 }
Write-Host "[OK] Контейнер $NAME запущен (python, sleep infinity)"

# --- Проверка ---
docker exec $NAME python3 -c "print('python OK:', __import__('sys').version)"
Write-Host "=== Контейнер $NAME (python/EPC-test) готов ==="
