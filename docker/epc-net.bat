@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM Сетевой профиль EPC для запуска на отдельном хосте в LAN
set "EPC_HOST_IP=192.168.1.18"
set "CONFIG_DIR=%~dp0..\srsran_configs"
set "LOGS_DIR=%~dp0..\logs"
set "BASE_CFG=%CONFIG_DIR%\epc.conf"
set "TMP_CFG=%TEMP%\epc.net.conf"

REM Проверка базового конфига
if not exist "%BASE_CFG%" (
    echo [ERROR] Не найден файл конфигурации: "%BASE_CFG%"
    exit /b 1
)

REM Проверка каталога логов
if not exist "%LOGS_DIR%" (
    echo [INFO] Каталог логов "%LOGS_DIR%" не найден. Создаю...
    mkdir "%LOGS_DIR%"
    if errorlevel 1 (
        echo [ERROR] Не удалось создать каталог логов "%LOGS_DIR%"
        exit /b 1
    )
)

REM Генерация временного epc.conf c LAN-адресом EPC
powershell -NoProfile -Command ^
  "$cfg = Get-Content '%BASE_CFG%';" ^
  "$cfg = $cfg -replace '^\s*mme_bind_addr\s*=.*$', 'mme_bind_addr = %EPC_HOST_IP%';" ^
  "$cfg = $cfg -replace '^\s*gtpu_bind_addr\s*=.*$', 'gtpu_bind_addr   = %EPC_HOST_IP%';" ^
  "$cfg = $cfg -replace '^\s*sgi_if_addr\s*=.*$', 'sgi_if_addr      = 172.16.0.1';" ^
  "Set-Content -Path '%TMP_CFG%' -Value $cfg -Encoding Ascii"
if errorlevel 1 (
    echo [ERROR] Не удалось подготовить временный epc.conf
    exit /b 1
)

echo [OK] Временный конфиг EPC: %TMP_CFG%

REM Запуск EPC в host-сети для доступа eNB с других хостов
docker run --rm -it ^
   --name epc ^
   --hostname epc ^
   -v "%TMP_CFG%":/root/.config/srsran/epc.conf:ro ^
   -v "%CONFIG_DIR%:/root/.config/srsran:ro" ^
   -v "%LOGS_DIR%:/var/log/srsran" ^
   --network host ^
   --cap-add=NET_ADMIN ^
   --device=/dev/net/tun ^
   ghcr.io/opkcp/srsran_4g:latest ^
   srsepc /root/.config/srsran/epc.conf

set "RC=%ERRORLEVEL%"
if exist "%TMP_CFG%" del /q "%TMP_CFG%" >nul 2>&1
exit /b %RC%
