# Автозапуск стенда srsRAN (после подачи питания)

## Что решается

После длительного простоя достаточно **подать питание на малинки** — сеть поднимется
сама: ядро (Open5GS), веб-сервисы, мониторинг и базовые станции (если подключены SDR).
Ручной запуск скриптов `start-*.sh` не требуется.

## Как это устроено

Два уровня защиты:

| Уровень | Механизм | Что покрывает |
|---------|----------|---------------|
| 1 | `--restart unless-stopped` у контейнеров + systemd `enabled` | Подъём после ребута/подачи питания |
| 2 | systemd-таймер `srsran-stand-watchdog.timer` (каждые 2 мин) | Самовосстановление при падениях: умерший NF (HSS), упавший контейнер, «вставший» RF-поток БС |

Дополнительно внутри контейнера ядра работает **супервизор NF** из `run_open5gs.sh`:
он каждые 10 с проверяет наличие `mmed/hssd/pcrfd/sgwcd/sgwud/smfd/upfd` в `/proc`
и перезапускает отсутствующие. Это закрывает главную аварию — падение `hssd`
(телефоны получают `Attach reject` с cause 3002).

## Состав

```
experiment/stand/autostart/
├── stand-autostart.sh                  # логика (режимы: core|web|bs|watchdog)
├── install-autostart.sh                # установщик (sudo)
├── srsran-stand-core.service           # ядро MongoDB + Open5GS     (pi5-2)
├── srsran-stand-web.service            # webserve + дашборды + мониторинг
├── srsran-stand-bs.service             # своя БС (только если есть SDR)
├── srsran-stand-watchdog.service       # один проход сторожа
└── srsran-stand-watchdog.timer         # запуск сторожа каждые 2 минуты
```

На узле скрипт логики копируется в `/home/intsis/stand-autostart.sh`
(основной пользователь стенда — **intsis**; `infarh`/`shmac` — администрирование).

Порядок запуска: `docker` → `network-online` → **core** → **web** → **bs**,
сторож стартует через 3 минуты после загрузки.

## Установка (один раз на каждом узле)

```bash
# с рабочей станции
scp experiment/stand/autostart/* pi5:/tmp/autostart/
ssh pi5 'sudo bash /tmp/autostart/install-autostart.sh'

scp experiment/stand/autostart/* base5:/tmp/autostart/
ssh base5 'sudo bash /tmp/autostart/install-autostart.sh'
```

Установщик сам отключает неприменимые юниты через `ConditionPathExists`:

| Узел | core | web | bs |
|------|------|-----|----|
| **pi5-2** | да (`start-core.sh`) | да | да (`start-bs.sh` → eNB2) |
| **base5** | нет (нет `start-core.sh`) | да | да (`start-bs.sh` → eNB1) |

## Проверка

```bash
# состояние юнитов
ssh pi5 'systemctl is-enabled srsran-stand-{core,web,bs}.service srsran-stand-watchdog.timer'
ssh pi5 'systemctl list-timers srsran-stand-watchdog.timer'

# лог автоподъёма
ssh pi5 'tail -30 /home/intsis/.stand/autostart.log'

# журнал
ssh pi5 'journalctl -u srsran-stand-core.service -n 50 --no-pager'
```

## Ручное управление и приоритеты

Ручные действия **всегда главнее** автоматики:

* `~/stop-core.sh`, `~/stop-web.sh`, `~/stop-bs.sh` создают флаг
  `~/.stand/stop-<роль>` — сторож уважает его и **не поднимает** компонент.
* Обратный запуск `~/start-*.sh` снимает флаг — сторож снова следит.
* При **загрузке узла** флаги снимаются: после подачи питания стенд поднимается всегда.

## Особые случаи, которые обработаны

1. **HSS падает из-за неготовой MongoDB** — `run_open5gs.sh` ждёт TCP 27017 перед
   стартом NF; плюс супервизор перезапускает `hssd` через 2 промаха.
2. **webserve в «мёртвом» network namespace** — после пересоздания контейнера ядра
   `webserve` формально `running`, но сидит в старом netns и абонентам недоступен.
   Сторож сверяет `NetworkMode` с реально работающим контейнером ядра и пересоздаёт
   `webserve` через `start-web.sh`.
3. **Нет SDR** — БС **не запускается** (иначе eNB уходит в краш-цикл и каждые ~60 с
   дёргает MME). Проверка по USB Vendor ID: `2500`, `2505`, `3923`.
4. **Вторичный IP eNB2 (192.168.1.20)** — ждём до 90 с, пока NetworkManager его
   применит; IP сохранён в профиле `IS-1` (`ipv4.addresses`).
5. **RF-поток БС встал** — известная болезнь B210 (контейнер жив, CPU падает до
   ~0-3%): после 3 подряд замеров с низким CPU сторож перезапускает БС.
6. **NAT/SGi** — правила `MASQUERADE`/`FORWARD` для `10.0.0.0/24` ставятся и
   контейнером ядра (`run_open5gs.sh`), и `setup-ogstun.service`; повторное
   применение идемпотентно.

## Снятие автозапуска

```bash
ssh pi5 'sudo bash /tmp/autostart/install-autostart.sh --remove'
```

## Замечания по эксплуатации

* Логи автозапуска: `/home/intsis/.stand/autostart.log` (на каждом узле).
* Логи БС: `~/srsran/data/logs/enb.log` (крупные, с ротацией).
* Первый холодный старт БС после долгого простоя — до 3-5 минут (формирование
  FFT-плана), если каталог `~/srsran/data/fftw` пуст. Это норма.
* После ребута ядра телефону может понадобиться повторный attach — обычно
  происходит автоматически.
