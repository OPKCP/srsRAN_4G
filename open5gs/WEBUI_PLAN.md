# WebUI для Open5GS — сборка ядра со встроенным WebUI

## Ключевой факт
В Open5GS v2.7.2 **WebUI — это ОТДЕЛЬНОЕ Node.js/Next-приложение** в каталоге
`webui/` исходников, а **НЕ** часть meson-сборки C-демонов. Поэтому:
- ❌ «meson `-Dwebui=true`» — НЕВЕРНО (такой опции нет; webui к meson не относится);
- ✅ правильно: собрать `webui` через npm (`npm clean-install && npm run build`, как в
  официальном `docker/webui/Dockerfile` на `node:19`) и положить рядом с ядром.

## Что сделано (2026-09-15)
`open5gs/docker/Dockerfile` доработан так, что в **одном образе** и ядро, и WebUI:
- builder: ставит Node 18, собирает NF (meson `--prefix=/usr --libdir=lib`) и `webui`
  (`npm clean-install` + `NODE_ENV=production npm run build`) → `/webui`;
- runtime: ставит Node 18, копирует NF-бинарники/библиотеки + `/webui` в `/opt/open5gs/webui`,
  плюс `start-webui.sh` в `/opt/open5gs/start-webui.sh`.
- `--libdir=lib` — важно: иначе meson на некоторых хостах ставит libogs/freeDiameter
  в `/usr/lib64`, и прежние `COPY /usr/lib/libogs*.so*` падают («not found»).
- prometheus-libs собираются в `/prom-copy` (find) и копируются архитектурно-нейтрально.

Проверено: сборка на **amd64** (smoke, ~1 мин) и на **arm64** (целевая, QEMU).

## Тег и сборка
```
# РЕКОМЕНДУЕТСЯ — нативная сборка НА pi5-2 (arm64, без QEMU):
ssh pi5 'mkdir -p ~/open5gs-build/webui'
scp open5gs/docker/Dockerfile           pi5:~/open5gs-build/Dockerfile
scp open5gs/docker/webui/start-webui.sh pi5:~/open5gs-build/webui/
ssh pi5 'cd ~/open5gs-build && docker build -t open5gs-arm64:v2.7.2-webui -f Dockerfile .'
# -> образ open5gs-arm64:v2.7.2-webui (~5 мин на Pi5)

# Альтернатива (x86-хост): buildx/QEMU
bash open5gs/docker/build-webui-arm64.sh
```

> ⚠️ **НЕ переносить образ через `docker save` → `scp` → `docker load`!** Проверено 2026-09-15:
> образ, сохранённый Docker Desktop 29 и загруженный на pi5-2, распаковывается с массовыми
> пустыми файлами (22016 нулевых, включая `package.json`/`node_modules`) — «Loaded image» есть,
> а контейнер падает (`exec format error`/`readPackage`). Сам tar корректен; виноват `docker load`
> на узле (containerd image store). Поэтому собираем **нативно на малине**.
> Проверка целостности после сборки:
> `docker run --rm --entrypoint sh <img> -c "wc -c /opt/open5gs/webui/package.json; wc -c /opt/open5gs/start-webui.sh"`
> (ожидаемо 1594 и 3444).

## Перенос и запуск на pi5-2
```
# Образ уже собран НАТИВНО на pi5-2 (см. выше) — перенос не нужен.
# Достаточно выложить скрипты запуска:
scp open5gs/run_webui.sh                pi5:~/srsran/scripts/run_webui.sh
scp open5gs/docker/webui/start-webui.sh pi5:~/srsran/scripts/start-webui.sh
ssh pi5 'chmod +x ~/srsran/scripts/start-webui.sh'

# Вариант А — отдельным контейнером:
ssh pi5 'cd ~/srsran/scripts && WEBUI_IMG=open5gs-arm64:v2.7.2-webui bash run_webui.sh'

# Вариант Б — через compose pi5-2 (профиль webui):
#   IMG_OPEN5GS=open5gs-arm64:v2.7.2-webui COMPOSE_PROFILES=webui ./compose.pi5-2.sh up
```
> `run_webui.sh` монтирует `start-webui.sh` с ХОСТА (`~/srsran/scripts/start-webui.sh`) и запускает
> через `--entrypoint /bin/bash` — на случай, если файл внутри образа окажется пустым.

## Доступ
- Порт **9999** (дефолт webui; 3000 занят Grafana).
- URL: `http://192.168.1.16:9999`
- Логин по умолчанию: **admin / 1423** (создаётся `start-webui.sh`; сменить после входа!).

## Env WebUI (webui/server/index.js v2.7.2)
| Переменная | Назначение | По умолчанию |
|-----------|-----------|--------------|
| `DB_URI` | Mongo-строка | `mongodb://127.0.0.1/open5gs` |
| `HOSTNAME` | адрес прослушивания | `localhost` (в host-сети: `0.0.0.0`) |
| `PORT` | порт | `9999` |
| `JWT_SECRET_KEY` / `SECRET_KEY` | секреты сессий/JWT | `change-me`/random |
| `WEBUI_ADMIN_USER` / `WEBUI_ADMIN_PASS` | seed-админ (наш скрипт) | `admin`/`1423` |

> ⚠️ В production-режиме Open5GS WebUI НЕ создаёт админа сам (авто-создание — только
> в dev). Наш `start-webui.sh` идемпотентно создаёт `admin/1423` (через модель Account
> с `passport-local-mongoose`), затем стартует сервер.

## Прочее (мониторинг, актуально)
- **Prometheus** (host, порт **9091**): метрики NF, все цели `up`.
- **Grafana** (bridge, порт **3000**, admin/admin): дашборд «Open5GS EPC (LTE S1)».
- ⚠️ IP pi5-2 сменился на **192.168.1.16** (кабель) — старые ссылки на .26 неактуальны.
