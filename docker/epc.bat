@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM Проверка наличия сети tr-network
docker network inspect tr-network >nul 2>&1
if errorlevel 1 (
    echo [INFO] Сеть tr-network не найдена. Создаю сеть...
    docker network create --driver bridge --subnet 172.18.0.0/24 tr-network
    if errorlevel 1 (
        echo [ERROR] Не удалось создать сеть tr-network
        exit /b 1
    )
    echo [OK] Сеть tr-network успешно создана
) else (
    echo [OK] Сеть tr-network уже существует
)

REM Пути относительно каталога скрипта (docker/)
set "CONFIG_DIR=%~dp0..\srsran_configs"
set "LOGS_DIR=%~dp0..\logs"

REM Проверка каталога конфигов
if not exist "%CONFIG_DIR%" (
    echo [ERROR] Каталог конфигурации не найден: "%CONFIG_DIR%"
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
    echo [OK] Каталог логов успешно создан: "%LOGS_DIR%"
) else (
    echo [OK] Каталог логов уже существует: "%LOGS_DIR%"
)

REM Запуск контейнера epc
docker run --rm -it ^
   --name epc ^
   --hostname epc ^
   -v "%CONFIG_DIR%:/root/.config/srsran:ro" ^
   -v "%LOGS_DIR%:/var/log/srsran" ^
    --network tr-network ^
   --cap-add=NET_ADMIN ^
   --device=/dev/net/tun ^
    --ip 172.18.0.2 ^
   ghcr.io/opkcp/srsran_4g:latest ^
   srsepc
