# srsRAN_4G — Docker образ

Этот каталог содержит файлы для сборки и запуска компонентов srsRAN_4G
в Docker-контейнерах на основе **Ubuntu 22.04 LTS**.

## Содержимое

| Файл | Описание |
|------|---------|
| `Dockerfile.base` | Базовый образ с обновлённой ОС, инструментами и UHD images |
| `Dockerfile` | Итоговый многоэтапный Dockerfile (сборка + runtime) |
| `build-base.sh` | Скрипт локальной сборки базового образа для **Linux / macOS** |
| `build-base.cmd` | Скрипт локальной сборки базового образа для **Windows 11 CMD** |
| `build-base-arm.sh` | Скрипт локальной сборки базового образа для **ARM64 Linux / macOS** |
| `build-base-arm.cmd` | Скрипт локальной сборки базового образа для **ARM64 Windows CMD** |
| `build.sh` | Скрипт локальной сборки итогового образа для **Linux / macOS** |
| `build.cmd` | Скрипт локальной сборки итогового образа для **Windows 11 CMD** |

## Образ в реестре

Образ автоматически публикуется в **GitHub Container Registry (GHCR)**:

```
ghcr.io/opkcp/srsran_4g/srsran_4g:latest
```

Для двухэтапной схемы дополнительно используется базовый образ:

```text
ghcr.io/opkcp/srsran_4g/srsran_4g-base:base-amd64
ghcr.io/opkcp/srsran_4g/srsran_4g-base:base-arm64
```

CI/CD запускается **вручную** через вкладку
**Actions → Сборка и публикация Docker образа → Run workflow**.

## Локальная сборка

### Linux / macOS

```bash
# Клонировать репозиторий
git clone https://github.com/OPKCP/srsRAN_4G.git
cd srsRAN_4G

# Собрать образ с тегом latest
./docker/build.sh

# Или с конкретным тегом
./docker/build.sh v1.0.0

# При необходимости собрать базовый образ вручную
./docker/build-base.sh
```

### Windows 11 (CMD)

```cmd
rem Клонировать репозиторий
git clone https://github.com/OPKCP/srsRAN_4G.git
cd srsRAN_4G

rem Собрать образ с тегом latest
docker\build.cmd

rem Или с конкретным тегом
docker\build.cmd v1.0.0

rem При необходимости собрать базовый образ вручную
docker\build-base.cmd
```

> **Требование для Windows**: Docker Desktop с включённым режимом
> Linux containers и WSL 2.

## Двухэтапная сборка

Сборка теперь разделена на два слоя:

1. Базовый образ `Dockerfile.base` устанавливает обновлённую Ubuntu 22.04, набор инструментов, runtime-зависимости и заранее скачивает UHD images.
2. Итоговый образ `Dockerfile` использует этот базовый слой, компилирует проект и копирует только артефакты сборки.

Скрипты `build.sh`, `build.cmd`, `build-4g-arm.sh` и `build-arm.cmd` автоматически проверяют наличие базового образа и запускают соответствующий `build-base*` скрипт, если его нет.

Если базовый образ нужно перенести на изолированную машину, его можно экспортировать:

```bash
docker save ghcr.io/opkcp/srsran_4g/srsran_4g-base:base-amd64 | gzip > srsran_4g_base_amd64.tar.gz
```

## Запуск контейнеров

## Скрипты запуска 4G (Linux .sh)

В каталоге `docker/` добавлены готовые Linux-скрипты для запуска ядра и базовых станций:

| Скрипт | Назначение |
|------|---------|
| `epc.sh` | Запуск EPC в bridge-сети `tr-network` |
| `epc-net.sh` | Запуск EPC в host-сети для LAN-сценария |
| `enb.sh` | Запуск eNB в bridge-сети `tr-network` |

Подготовка:

```bash
chmod +x docker/epc.sh docker/epc-net.sh docker/enb.sh
```

Примеры запуска:

```bash
# EPC (bridge)
./docker/epc.sh

# EPC (LAN/host)
EPC_HOST_IP=192.168.1.18 ./docker/epc-net.sh

```

## Шпаргалка по параметрам

Ниже краткая таблица по переменным и ключевым 4G-аргументам, которые чаще всего меняют в Linux-скриптах.

| Параметр | Что делает | Допустимые значения | Типичные значения |
|------|---------|---------|---------|
| `EPC_HOST_IP` | IP хоста с EPC (для host/LAN сценария) | IPv4 `x.x.x.x` (октеты 0..255) | `192.168.1.18` |
| `ENB_HOST_IP` | IP локального eNB-хоста | IPv4 `x.x.x.x` (октеты 0..255) | `192.168.1.32`..`192.168.1.35` |
| `LOCAL_ENB_ID` | Локальный ID eNB | `0..nof_enodebs-1` | `0..3` |
| `ENB_HEX_ID` | eNB ID в `enb.conf` | `0x1..0xFFFFFF` | `0x19B`..`0x19E` |

### eNodeB (базовая станция)

```bash
docker run -it --rm \
    --net=host \
    --privileged \
    -v /etc/srsran:/etc/srsran \
    -v /tmp:/tmp \
    ghcr.io/opkcp/srsran_4g/srsran_4g:latest \
    srsenb /etc/srsran/enb.conf
```

### EPC (ядро сети)

```bash
docker run -it --rm \
    --net=host \
    --privileged \
    --cap-add=NET_ADMIN \
    -v /etc/srsran:/etc/srsran \
    -v /tmp:/tmp \
    ghcr.io/opkcp/srsran_4g/srsran_4g:latest \
    srsepc /etc/srsran/epc.conf
```

### UE (абонентское устройство, только для тестирования)

```bash
docker run -it --rm \
    --net=host \
    --privileged \
    -v /etc/srsran:/etc/srsran \
    ghcr.io/opkcp/srsran_4g/srsran_4g:latest \
    srsue /etc/srsran/ue.conf
```

## Конфигурационные файлы

Образ содержит конфигурации по умолчанию в `/etc/srsran/`.
Для изменения параметров с хоста монтируйте директорию через том:

```bash
# Создать директорию конфигурации на хосте
mkdir -p ~/srsran_configs

# Скопировать дефолтные конфиги из контейнера
docker run --rm \
    -v ~/srsran_configs:/out \
    ghcr.io/opkcp/srsran_4g/srsran_4g:latest \
    bash -c "cp /etc/srsran/* /out/"

# Отредактировать файлы
nano ~/srsran_configs/enb.conf

# Запустить с кастомными конфигами
docker run -it --rm \
    --net=host \
    --privileged \
    -v ~/srsran_configs:/etc/srsran \
    ghcr.io/opkcp/srsran_4g/srsran_4g:latest
```

## Проброс USB-устройств USRP (Windows + WSL)

Для работы с реальным SDR USRP через Docker на Windows требуется:

### 1. На хосте Windows (PowerShell / winget)

```powershell
# Установить usbipd-win
winget install usbipd

# Перезапустить консоль и найти BUSID устройства USRP
usbipd list

# Привязать устройство (одноразово после перезагрузки)
usbipd bind -b <BUSID>

# Пробросить устройство в WSL
usbipd attach --wsl -b <BUSID>
```

### 2. В WSL (Ubuntu)

```bash
# Проверить видимость устройства
lsusb

# Убедиться, что usbip-модули ядра загружены
sudo modprobe usbip-core usbip-host
```

### 3. В Docker (Linux containers)

```bash
docker run -it --rm \
    --privileged \
    --net=host \
    -v /dev/bus/usb:/dev/bus/usb \
    -v /etc/srsran:/etc/srsran \
    ghcr.io/opkcp/srsran_4g:latest \
    srsenb /etc/srsran/enb.conf
```

> **Примечание**: `--privileged` и монтирование `/dev/bus/usb` необходимы
> для доступа к USB-устройству USRP внутри контейнера.

## Структура многоэтапной сборки

```
┌─────────────────────────────────────────────┐
│  БАЗА: ubuntu:22.04 + toolchain + UHD       │
│  ─────────────────────────────────          │
│  + обновлённая ОС, инструменты, UHD images   │
│  → docker/build-base.sh                      │
└──────────────────┬──────────────────────────┘
                   │  COPY --from=builder
                   ▼
┌─────────────────────────────────────────────┐
│  ЭТАП 1: builder (на базе base-образа)      │
│  ─────────────────────────────────          │
│  → cmake .. && ninja && ninja install       │
│  → /usr/local/bin/srsenb, srsue, srsepc    │
└──────────────────┬──────────────────────────┘
                   │  COPY --from=builder
                   ▼
┌─────────────────────────────────────────────┐
│  ЭТАП 2: runtime (тот же base-слой)         │
│  ─────────────────────────────────          │
│  → /usr/local/bin/srs*  (только бинарники)   │
│  → /etc/srsran/          (конфиги, VOLUME)   │
│  Размер итогового образа зависит от базы     │
│  Проверить размер: docker images srsran_4g │
└─────────────────────────────────────────────┘
```
