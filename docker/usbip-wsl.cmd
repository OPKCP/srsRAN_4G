@echo off
REM ============================================================
REM  usbip-wsl.cmd — запуск usbip-wsl.ps1 из PowerShell
REM ============================================================
REM
REM  Запускает PowerShell-скрипт автоматического подключения
REM  SDR-устройств (USRP B210, HackRF One) к WSL 2.
REM
REM  Использование:
REM    usbip-wsl.cmd
REM    usbip-wsl.cmd -BusId 2-14
REM    usbip-wsl.cmd -BusId 2-14 -SkipUhdInit
REM    usbip-wsl.cmd -VidPids @("1d50:6089")
REM
REM  ВАЖНО: для доступа к SDR из Docker-контейнеров Docker Desktop
REM  устройство нужно прикреплять к виртуалке docker-desktop:
REM    usbip-wsl.cmd -WslDistro docker-desktop
REM
REM  Все аргументы передаются напрямую в PowerShell-скрипт.
REM ============================================================

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%usbip-wsl.ps1"

REM Проверка существования PowerShell-скрипта
if not exist "%PS_SCRIPT%" (
    echo [ERROR] Не найден скрипт: %PS_SCRIPT%
    echo [ERROR] Убедитесь, что usbip-wsl.ps1 находится в той же папке.
    exit /b 1
)

REM Определяем политику выполнения
set "PS_EXEC_POLICY=-ExecutionPolicy Bypass"

REM Собираем аргументы
set "PS_ARGS=%*"

REM Запуск PowerShell
echo [INFO] Запуск usbip-wsl.ps1...
powershell.exe %PS_EXEC_POLICY% -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %PS_ARGS%

if %ERRORLEVEL% neq 0 (
    echo.
    echo [WARNING] Скрипт завершился с ошибкой. Код: %ERRORLEVEL%.
    exit /b %ERRORLEVEL%
)

echo.
echo [OK] Готово.
exit /b 0
