# ==============================================================================
# run_sctp_server_win.ps1
# Поднимает SCTP-сервер в контейнере на компьютере для проверки прохождения
# SCTP-порта 36412 (S1AP/S1-MME) снаружи (с малинки).
# Использует Ubuntu + lksctp-tools (sctp_test в режиме сервера) на порту 36412.
# Детерминированный запуск: docker rm -f + запуск нового контейнера.
# ==============================================================================
$ErrorActionPreference = "Stop"

$NAME = "sctpsrv"
$PORT = 36412

# --- Удаление старого контейнера ---
docker rm -f $NAME 2>$null | Out-Null
Write-Host "[OK] Удалён старый контейнер $NAME"

# --- Запуск Ubuntu-контейнера с sctp_test сервером ---
# peer-window, оба реальных порта одинаковые (SCTP 1-to-1 не важно для теста).
# sctp_test server: -H привязка, -P порт.
docker run -d --name $NAME --hostname $NAME `
  -p 0.0.0.0:36412:36412/sctp `
  -p 0.0.0.0:36412:36412/tcp `
  ubuntu:24.04 sleep infinity

# --- Установка lksctp-tools в контейнере ---
Write-Host "Устанавливаю lksctp-tools в контейнере..."
docker exec $NAME bash -c "apt-get update >/dev/null 2>&1 && apt-get install -y lksctp-tools iproute2 >/dev/null 2>&1"
Write-Host "[OK] lksctp-tools установлены"

# --- Запуск SCTP-сервера в фоне ---
docker exec -d $NAME sctp_test -H 0.0.0.0 -P $PORT -l
Write-Host "[OK] SCTP-сервер запущен на порту $PORT в контейнере $NAME"
Write-Host "=== Проверка слушателя ==="
docker exec $NAME sh -c "cat /proc/net/sctp/eps 2>/dev/null || ss -Sln 2>/dev/null | grep 36412"
