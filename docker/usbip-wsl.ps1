<#
.SYNOPSIS
    Автоматическое подключение SDR-устройств (USRP, HackRF) к WSL 2 через usbipd-win.

.DESCRIPTION
    Скрипт выполняет полный цикл подключения:
    1. Поиск USB-устройств по списку VID:PID
    2. Запуск uhd_find_devices для инициализации/прошивки USRP (если найден)
    3. Привязка устройства (bind) — при необходимости запрашивает повышение привилегий
    4. Подключение устройства к WSL (attach)
    5. Проверка результата

.PARAMETER BusId
    BUSID устройства (например, 2-14). Если не указан, скрипт покажет список и попросит выбрать.

.PARAMETER VidPids
    Массив VID:PID для поиска. По умолчанию: @("2500:0020" (USRP B200/B210), "1d50:6089" (HackRF One))

.PARAMETER UhdImagesDir
    Путь к каталогу с UHD images. Если не указан, используется UHD_IMAGES_DIR или путь по умолчанию.

.PARAMETER RadiocondaBin
    Путь к каталогу с утилитами radioconda (uhd_find_devices.exe и т.д.).

.EXAMPLE
    # Запустить с выбором устройства из списка
    .\usbip-wsl.ps1

.EXAMPLE
    # Подключить USRP B210 с BUSID 2-14, пропуская uhd_find_devices
    .\usbip-wsl.ps1 -BusId 2-14 -SkipUhdInit

.EXAMPLE
    # Подключить HackRF One
    .\usbip-wsl.ps1 -VidPids @("1d50:6089")
#>

param(
    [string]$BusId,

    [string[]]$VidPids = @(
        "2500:0020",  # Ettus Research LLC B200/B210
        "1d50:6089"   # HackRF One
    ),

    [string]$UhdImagesDir,

    [string]$RadiocondaBin = "$env:LOCALAPPDATA\..\p.shmachilin\radioconda\Library\bin",

    [switch]$SkipUhdInit
)

# ──────────────────────────────────────────────────────
# Helper: цвета и форматирование
# ──────────────────────────────────────────────────────
$Host.UI.RawUI.ForegroundColor = "White"

function Write-Info  { Write-Host "ℹ️  $($args[0])" -ForegroundColor Cyan }
function Write-Ok   { Write-Host "✅ $($args[0])" -ForegroundColor Green }
function Write-Warn { Write-Host "⚠️  $($args[0])" -ForegroundColor Yellow }
function Write-Err  { Write-Host "❌ $($args[0])" -ForegroundColor Red }
function Write-Step { Write-Host "`n🚀 $($args[0])" -ForegroundColor Magenta }

# ──────────────────────────────────────────────────────
# Helper: проверка наличия команды
# ──────────────────────────────────────────────────────
function Test-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# ──────────────────────────────────────────────────────
# Helper: запуск с повышением привилегий
# ──────────────────────────────────────────────────────
function Invoke-Elevated($command, $arguments) {
    Write-Warn "Требуются права администратора для выполнения команды:"
    Write-Host "  $command $arguments" -ForegroundColor Gray
    Write-Host "`nОткроется окно UAC (User Account Control). Подтвердите повышение." -ForegroundColor Yellow

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $command
        $psi.Arguments = $arguments
        $psi.Verb = "runas"
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) {
            Write-Err "Не удалось запустить процесс с правами администратора."
            return $false
        }
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Write-Err "Команда завершилась с кодом $($proc.ExitCode)."
            return $false
        }
        Write-Ok "Команда выполнена."
        return $true
    } catch {
        Write-Err "Ошибка при запуске с повышением: $_"
        return $false
    }
}

# ──────────────────────────────────────────────────────
# Проверка usbipd
# ──────────────────────────────────────────────────────
if (-not (Test-Command "usbipd")) {
    Write-Step "Установка usbipd-win..."
    try {
        winget install usbipd
    } catch {
        Write-Err "Не удалось установить usbipd. Установите вручную: winget install usbipd"
        exit 1
    }
}
else {
    Write-Ok "usbipd найден"
}

# ──────────────────────────────────────────────────────
# Получение списка устройств
# ──────────────────────────────────────────────────────
Write-Step "Получение списка USB-устройств..."
$usbipdOutput = usbipd list
$usbipdOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

$lines = $usbipdOutput | Where-Object { $_ -match '^\s*\d+-\d+' }

# Парсим строки usbipd list
$devices = @()
foreach ($line in $lines) {
    if ($line -match '^\s*(\d+-\d+)\s+([0-9a-fA-F]+:[0-9a-fA-F]+)\s+(.+?)\s{2,}(.+)$') {
        $devices += [PSCustomObject]@{
            BusId = $matches[1]
            VidPid = $matches[2]
            Description = $matches[3].Trim()
            State = $matches[4].Trim()
        }
    }
}

if ($devices.Count -eq 0) {
    Write-Err "Не найдено ни одного USB-устройства. Проверьте подключение SDR."
    exit 1
}

# Фильтруем устройства по интересующим VID:PID
$targetDevices = $devices | Where-Object { $_.VidPid -in $VidPids }

if ($targetDevices.Count -eq 0) {
    Write-Warn "Устройства с VID:PID из списка ($($VidPids -join ', ')) не найдены."
    Write-Info "Доступные устройства:"
    $devices | Format-Table BusId, VidPid, Description, State | Out-String | Write-Host
    exit 0
}

# ──────────────────────────────────────────────────────
# Выбор устройства (если не указан BusId)
# ──────────────────────────────────────────────────────
if (-not $BusId) {
    if ($targetDevices.Count -eq 1) {
        $BusId = $targetDevices[0].BusId
        Write-Info "Найдено устройство: $($targetDevices[0].Description) (BUSID: $BusId)"
    }
    else {
        Write-Info "Найдено несколько устройств. Выберите нужное:"
        for ($i = 0; $i -lt $targetDevices.Count; $i++) {
            $d = $targetDevices[$i]
            $state = if ($d.State -eq "Attached") { " (уже подключено)" } else { "" }
            Write-Host "  [$i] BUSID $($d.BusId) — $($d.Description)$state" -ForegroundColor Yellow
        }
        $choice = Read-Host "`nВведите номер устройства (0..$($targetDevices.Count-1))"
        if ($choice -match '^\d+$' -and [int]$choice -lt $targetDevices.Count) {
            $BusId = $targetDevices[[int]$choice].BusId
        } else {
            Write-Err "Некорректный выбор."
            exit 1
        }
    }
}

$selectedDevice = $targetDevices | Where-Object { $_.BusId -eq $BusId }
if (-not $selectedDevice) {
    # Возможно устройство не из целевого списка, но пользователь указал вручную
    $selectedDevice = $devices | Where-Object { $_.BusId -eq $BusId }
}
if (-not $selectedDevice) {
    Write-Err "Устройство с BUSID $BusId не найдено."
    exit 1
}

Write-Info "Выбрано устройство: $($selectedDevice.Description) (BUSID: $BusId)"

# ──────────────────────────────────────────────────────
# Шаг 1: uhd_find_devices (только для USRP)
# ──────────────────────────────────────────────────────
$isUsrp = $selectedDevice.VidPid -eq "2500:0020"

if ($isUsrp -and -not $SkipUhdInit) {
    Write-Step "Инициализация USRP (uhd_find_devices)..."
    Write-Info "Это необходимо для первой загрузки прошивки в устройство."
    Write-Warn "После инициализации USRP может перезагрузиться и получить новый BUSID."

    # Нормализуем путь к radioconda\Library\bin
    $uhdBin = [System.Environment]::ExpandEnvironmentVariables($RadiocondaBin)
    $uhdFindDevices = Join-Path $uhdBin "uhd_find_devices.exe"

    if (-not (Test-Path $uhdFindDevices)) {
        Write-Warn "uhd_find_devices.exe не найден по пути: $uhdFindDevices"
        Write-Info "Ищем в PATH..."
        $uhdFindDevices = (Get-Command "uhd_find_devices" -ErrorAction SilentlyContinue).Source
        if (-not $uhdFindDevices) {
            Write-Warn "uhd_find_devices не найден. Пропускаем инициализацию."
            Write-Info "Убедитесь, что UHD установлен, или укажите -RadiocondaBin."
        }
    }

    if ($uhdFindDevices -and (Test-Path $uhdFindDevices)) {
        # Устанавливаем UHD_IMAGES_DIR, если передан
        $envBackup = $null
        if ($UhdImagesDir) {
            $envBackup = $env:UHD_IMAGES_DIR
            $env:UHD_IMAGES_DIR = [System.Environment]::ExpandEnvironmentVariables($UhdImagesDir)
            Write-Info "UHD_IMAGES_DIR = $env:UHD_IMAGES_DIR"
        }

        try {
            Write-Info "Запуск: $uhdFindDevices"
            & $uhdFindDevices 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

            Write-Ok "uhd_find_devices выполнен."

            # После инициализации USRP может перезагрузиться — ждём и обновляем список
            Write-Info "Ожидание перезагрузки USRP (5 секунд)..."
            Start-Sleep -Seconds 5

            # Перечитываем список устройств — BUSID мог измениться
            Write-Step "Обновление списка USB-устройств..."
            $usbipdOutput2 = usbipd list
            $lines2 = $usbipdOutput2 | Where-Object { $_ -match '^\s*\d+-\d+' }
            $updatedDevices = @()
            foreach ($line in $lines2) {
                if ($line -match '^\s*(\d+-\d+)\s+([0-9a-fA-F]+:[0-9a-fA-F]+)\s+(.+?)\s{2,}(.+)$') {
                    $updatedDevices += [PSCustomObject]@{
                        BusId = $matches[1]
                        VidPid = $matches[2]
                        Description = $matches[3].Trim()
                        State = $matches[4].Trim()
                    }
                }
            }
            $updatedTarget = $updatedDevices | Where-Object { $_.VidPid -eq "2500:0020" }
            if ($updatedTarget.Count -gt 0) {
                $BusId = $updatedTarget[0].BusId
                $selectedDevice = $updatedTarget[0]
                Write-Info "Новый BUSID после инициализации: $BusId"
            }
            else {
                Write-Warn "USRP не обнаружен после перезагрузки. Попробуйте запустить скрипт ещё раз."
            }
        }
        catch {
            Write-Err "Ошибка при выполнении uhd_find_devices: $_"
        }
        finally {
            if ($envBackup -ne $null) { $env:UHD_IMAGES_DIR = $envBackup }
        }
    }
}
elseif ($isUsrp -and $SkipUhdInit) {
    Write-Info "Пропуск uhd_find_devices (указан -SkipUhdInit)."
}

# ──────────────────────────────────────────────────────
# Шаг 2: bind (привязка устройства)
# ──────────────────────────────────────────────────────
if ($selectedDevice.State -eq "Not shared") {
    Write-Step "Привязка устройства (bind)..."
    Write-Warn "Для привязки требуются права администратора."

    $bindCommand = "usbipd"
    $bindArgs = "bind -b $BusId"

    $success = Invoke-Elevated $bindCommand $bindArgs
    if (-not $success) {
        Write-Err "Не удалось выполнить bind. Попробуйте запустить консоль от администратора и выполнить:"
        Write-Host "  usbipd bind -b $BusId" -ForegroundColor Yellow
        exit 1
    }
}
else {
    Write-Info "Устройство уже привязано (State: $($selectedDevice.State))."
}

# ──────────────────────────────────────────────────────
# Шаг 3: attach (подключение к WSL)
# ──────────────────────────────────────────────────────
if ($selectedDevice.State -ne "Attached") {
    Write-Step "Подключение устройства к WSL..."

    # Сначала проверяем, не привязано ли уже устройство после bind (перечитываем статус)
    Start-Sleep -Seconds 1
    $checkOutput = usbipd list
    $checkLine = $checkOutput | Where-Object { $_ -match "^\s*$BusId\s+" }
    if ($checkLine -match "Attached") {
        Write-Ok "Устройство уже подключено к WSL."
    }
    else {
        Write-Info "Запуск: usbipd attach --wsl -b $BusId"
        try {
            usbipd attach --wsl -b $BusId 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
            Write-Ok "Команда attach выполнена."
        }
        catch {
            Write-Err "Ошибка при attach: $_"
            exit 1
        }
    }
}
else {
    Write-Ok "Устройство уже подключено к WSL (State: Attached)."
}

# ──────────────────────────────────────────────────────
# Финальная проверка
# ──────────────────────────────────────────────────────
Write-Step "Финальная проверка..."
Start-Sleep -Seconds 2
$finalOutput = usbipd list
$finalLine = $finalOutput | Where-Object { $_ -match "^\s*$BusId\s+" }
if ($finalLine -match "Attached") {
    Write-Ok "Устройство $($selectedDevice.Description) (BUSID $BusId) успешно подключено к WSL!"
    Write-Info "Состояние:"
    $finalOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}
else {
    Write-Err "Устройство не в состоянии Attached."
    Write-Info "Текущее состояние:"
    $finalOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    exit 1
}

# ──────────────────────────────────────────────────────
# Дополнительная проверка видимости в WSL
# ──────────────────────────────────────────────────────
Write-Step "Проверка видимости устройства в WSL..."
try {
    $wslCheck = wsl lsusb 2>&1
    if ($wslCheck -match $selectedDevice.Description -or $wslCheck -match $selectedDevice.VidPid) {
        Write-Ok "Устройство видно внутри WSL:"
        $wslCheck | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
    else {
        Write-Warn "Устройство не найдено в выводе wsl lsusb."
        Write-Info "Вывод wsl lsusb:"
        $wslCheck | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Info "Проверьте модули ядра: sudo modprobe usbip-core usbip-host"
    }
}
catch {
    Write-Warn "Не удалось выполнить wsl lsusb (возможно, WSL не запущен)."
}

Write-Ok "Готово! 🎉"
