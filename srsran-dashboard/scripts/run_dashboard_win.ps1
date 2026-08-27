# ==============================================================================
# run_dashboard_win.ps1 — запуск дашборда стенда srsRAN 4G на Windows/Docker.
#
# Режимы (параметр -Mode):
#   epc  — парсить лог ядра (srsepc). По умолчанию.
#   enb  — парсить лог eNB + метрики (enb_report.json).
#
# Пробрасываемый каталог логов задаётся параметром -LogDir (том /logs внутри).
# Примеры:
#   .\run_dashboard_win.ps1 -Mode epc -LogDir C:\src\intsis\srsRAN_4G\experiment\logs_epc
#   .\run_dashboard_win.ps1 -Mode epc -LogDir C:\src\intsis\srsRAN_4G\logs -Port 5000
# ==============================================================================
param(
    [ValidateSet("epc","enb")] [string]$Mode = "epc",
    [string]$LogDir = "",
    [int]$Port = 5000,
    [string]$ContainerName = "srsran-dashboard",
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $LogDir) {
    if ($Mode -eq "epc") {
        $LogDir = Join-Path $scriptDir "logs_epc"
    } else {
        $LogDir = Join-Path $scriptDir "logs_enb"
    }
}
Write-Host "[OK] Режим: $Mode  |  Каталог логов: $LogDir  |  Порт: $Port"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
    Write-Host "[OK] Создана папка логов: $LogDir"
}

Push-Location $scriptDir

try {
    if ($Rebuild) {
        Write-Host "[..] Сборка образа (docker build)…"
        docker build -t srsran-dashboard:latest .
        if ($LASTEXITCODE -ne 0) { throw "Сборка образа не удалась" }
    } else {
        $img = docker images -q srsran-dashboard:latest
        if (-not $img) {
            Write-Host "[..] Образ не найден — собираю…"
            docker build -t srsran-dashboard:latest .
            if ($LASTEXITCODE -ne 0) { throw "Сборка образа не удалась" }
        }
    }

    # удаляем старый контейнер с тем же именем
    docker rm -f $ContainerName 2>$null | Out-Null

    Write-Host "[..] Запуск контейнера $ContainerName …"
    docker run -d --name $ContainerName --restart unless-stopped `
        -e DASH_MODE=$Mode `
        -e DASH_LOG_DIR=/logs `
        -e DASH_PORT=$Port `
        -v "${LogDir}:/logs" `
        -p "${Port}:${Port}" `
        srsran-dashboard:latest

    if ($LASTEXITCODE -ne 0) { throw "Не удалось запустить контейнер" }

    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "[OK] Дашборд запущен:  http://localhost:$Port"
    Write-Host "[OK] Контейнер: $ContainerName (режим $Mode, логи $LogDir)"
    docker ps --filter "name=$ContainerName" --format "{{.Names}}`t{{.Status}}"
}
finally {
    Pop-Location
}
