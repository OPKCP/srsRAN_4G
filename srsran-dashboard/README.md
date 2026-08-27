# srsran-dashboard — веб-дашборд мониторинга стенда srsRAN 4G

Докер-контейнер с Flask-приложением, которое парсит логи **базовой станции (eNB)** и
**ядра сети (EPC)** и отображает в реальном времени удобную сводку:
абонентов, базовые станции, события, метрики радио.

Один и тот же образ работает в **двух режимах** — задаётся переменной `DASH_MODE`:

| Режим | Что парсит | Что показывает |
|-------|-----------|----------------|
| `epc` (ядро) | лог `srsepc` (`epc.log`) | подключившиеся БС, attach-запросы, успешные подключения абонентов (IMSI→IP), detach, ошибки аутентификации |
| `enb` (БС) | лог `srsenb` (`enb.log`) + метрики `enb_report.json` | старт БС, RF, S1-соединение, активные UE и их радио-метрики (CQI, MCS, скорости, BLER, SNR) |

Каталог логов пробрасывается внутрь контейнера через **volume** (точка монтирования `/logs`).
Внутри приложение хранит состояние (список абонентов, БС, события), обновляемое парсером
в реальном времени.

---

## Структура

```
srsran-dashboard/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── config.py              # настройки через переменные окружения
├── app.py                 # Flask + API + SSE
├── state.py               # потокобезопасное хранилище состояния
├── parser/
│   ├── __init__.py
│   ├── epc_parser.py      # парсер лога ядра (srsepc)
│   └── enb_parser.py      # парсер лога eNB + метрик
├── templates/index.html   # интерфейс (русский)
├── static/                # style.css, app.js
└── scripts/
    ├── run_dashboard_win.ps1   # Windows/Docker
    └── run_dashboard_rpi.sh    # Linux/RPi5
```

---

## Быстрый старт (Windows)

У вас есть Docker Desktop. Из папки `srsran-dashboard`:

```powershell
# Режим EPC — логи ядра (например уже имеющиеся experiment/logs_epc)
.\scripts\run_dashboard_win.ps1 -Mode epc -LogDir C:\src\intsis\srsRAN_4G\experiment\logs_epc
```
Откройте в браузере `http://localhost:5000`.

Если нужен режим eNB (где-то лежит `enb.log` и, желательно, `enb_report.json`):
```powershell
.\scripts\run_dashboard_win.ps1 -Mode enb -LogDir D:\logs\enb
```

> Параметр `-Rebuild` принудительно пересобирает образ.

---

## Быстрый старт (Linux / RPi5)

```bash
chmod +x scripts/run_dashboard_rpi.sh
./scripts/run_dashboard_rpi.sh --mode epc --logdir ~/srsran/logs_epc
# или
./scripts/run_dashboard_rpi.sh --mode enb --logdir ~/srsran/local/logs --port 5000
```

---

## docker compose

Удобно для постоянной работы (в `srsran-dashboard/`):

```bash
# режим EPC, логи из ./logs_epc
DASH_MODE=epc DASH_LOG_HOST=./logs_epc docker compose up -d --build

# режим eNB, логи из ./logs_enb
DASH_MODE=enb DASH_LOG_HOST=./logs_enb docker compose up -d --build
```

---

## Настройка (переменные окружения)

| Переменная | По умолч. | Описание |
|-----------|-----------|----------|
| `DASH_MODE` | `epc` | режим: `epc` или `enb` |
| `DASH_LOG_DIR` | `/logs` | каталог логов внутри контейнера (точка volume) |
| `DASH_EPC_LOG` | `epc.log` | имя файла лога ядра внутри каталога логов |
| `DASH_ENB_LOG` | `enb.log` | имя файла лога eNB |
| `DASH_ENB_METRICS` | `enb_report.json` | файл метрик eNB (JSON) |
| `DASH_USER_DB` | `user_db.csv` | опционально: база SIM ядра (для имён/сводки) |
| `DASH_PARSE_INTERVAL` | `2` | период чтения лога, сек |
| `DASH_TAIL_LINES` | `200` | сколько последних строк лога держать в буфере |
| `DASH_HOST` / `DASH_PORT` | `0.0.0.0` / `5000` | адрес/порт Flask |

---

## Как это устроено внутри

- **Фоновый поток** каждые `DASH_PARSE_INTERVAL` сек читает новые строки лога
  (с отслеживанием смещения — устойчиво к пересозданию файла при перезапуске srsepc/srsenb).
- **EPC-парсер** ловит: `S1 Setup Request` (БС), `Attach request -- IMSI` (подключение),
  `IMSI: ..., UE IP: ...` (успешный attach → запись IP), `Detach` / `UE Context Release`,
  `User not found` (ошибка аутентификации).
- **eNB-парсер** ловит старт eNB, открытие RF, S1-соединение; метрики активных UE берёт
  из `enb_report.json` (JSON, формируемый `srsenb` через `metrics_json`).
- **Состояние** (абоненты, БС, события) хранится потокобезопасно и отдаётся через
  REST-эндпоинты `/api/*` и поток SSE `/api/stream` для обновления в браузере в реальном времени.

---

## API

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/` | интерфейс |
| GET | `/api/snapshot` | сводка (счётчики, БС, метрики, аптайм) |
| GET | `/api/subscribers` | список абонентов |
| GET | `/api/events?limit=N` | список событий |
| GET | `/api/basestations` | список БС |
| GET | `/api/tail` | последние строки лога |
| GET | `/api/stream` | SSE-поток обновлений в реальном времени |
