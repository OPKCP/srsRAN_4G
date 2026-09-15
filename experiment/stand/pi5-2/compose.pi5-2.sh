#!/usr/bin/env bash
# =============================================================================
# compose.pi5-2.sh — управление стеком ядра pi5-2 через docker compose.
# Покрывает: mongodb, open5gs, webserver (и опционально asterisk).
# НЕ трогает БС (enb2) и мониторинг (dashboard/grafana/prometheus).
#
# Команды:
#   up        docker compose up -d (с ожиданием healthy mongodb благодаря depends_on)
#   down      docker compose down (остановить/удалить контейнеры compose, тома целы)
#   restart   docker compose restart
#   status    docker compose ps + быстрый взгляд на ключевые healthcheck-и
#   logs [svc] logs (по умолчанию open5gs)
#   recreate  ПОЛНОЕ ЧИСТОЕ пересоздание всего стека через compose: снимает ВСЕ
#             контейнеры ядра (в т.ч. залипшие неcompose-контейнеры) и поднимает
#             зановоcompose up -d. Данные (том open5gs_mongo) и конфиги НЕ трогает.
#   migrate   то же, что recreate (алиас, историческое имя).
#
# Перед recreate/migrate: проверяется валидность compose config, иначе ничего не трогаем.
#
# Опциональные профили/переменные:
#   COMPOSE_PROFILES=asterisk   -> добавить сервис asterisk
#   COMPOSE_PROFILES=webui      -> добавить сервис open5gs-webui (порт 9999)
#   IMG_OPEN5GS=<tag>           -> образ ядра (напр. open5gs-arm64:v2.7.2-webui)
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# Имя проекта = имя каталога (pi5-2) — так же docker compose выводит по умолчанию.
# Задавай COMPOSE_PROJECT_NAME явно, если переносишь каталог.
COMPOSE="docker compose"

dc() { $COMPOSE "$@"; }

cmd="${1:-status}"; shift || true

case "$cmd" in
  up)
    dc config -q            # не запускать при невалидном файле
    dc up -d "$@"
    echo; echo "=== ps ==="; dc ps
    echo "=== ждём healthy open5gs-mongodb ==="
    for i in $(seq 1 40); do
      st=$(docker inspect -f '{{.State.Health.Status}}' open5gs-mongodb 2>/dev/null || echo starting)
      [ "$st" = healthy ] && { echo "mongodb: healthy"; break; }
      sleep 1
    done
    echo "=== открытые eNB в MME (через 8с) ==="; sleep 8
    docker logs --since 30s open5gs 2>&1 | grep -iE "Number of eNBs is now|CONNECTED TO 'hss" | tail -6 || true
    ;;

  down)    dc down "$@" ;;
  restart) dc restart "$@" ;;
  logs)    dc logs -f --tail=100 "${1:-open5gs}" ;;

  status)
    dc ps
    echo "=== mongodb health ==="; docker inspect -f '{{.State.Health.Status}}' open5gs-mongodb 2>/dev/null || echo "(нет)"
    echo "=== open5gs NF ==="; docker exec open5gs sh -c 'ps -eo comm | grep open5gs- | sort' 2>/dev/null || true
    echo "=== diam/HSS связь (последняя) ==="; docker logs --since 10m open5gs 2>&1 | grep -iE "CONNECTED TO 'hss|Failed to initialize HSS|3002" | tail -4 || true
    ;;

  recreate|migrate)
    echo "### 1. Валидация compose-файла ###"
    dc config -q
    echo "### 2. Текущие живые контейнеры ядра ###"
    docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E '^(open5gs|open5gs-mongodb|webserve|asterisk)(\s|$)' || true
    # Запоминаем, какие были реально запущены (Up), чтобы восстановить тот же набор.
    UP="$(docker ps --format '{{.Names}}' | grep -E '^(open5gs|open5gs-mongodb|webserve|asterisk)$' || true)"
    echo "Запущено сейчас: ${UP:-<ничего>}"
    # asterisk включаем в профиль compose только если он был Up ранее.
    PROFILE_ARGS=()
    if echo "$UP" | grep -qx 'asterisk'; then
      export COMPOSE_PROFILES=asterisk
      PROFILE_ARGS=(--profile asterisk)
      echo "asterisk был запущен -> включаем профиль asterisk"
    fi
    echo "### 3. Снятие ВСЕХ контейнеров ядра (compose down + принудительно по именам) ###"
    # docker compose down уберёт только СВОИ контейнеры; залипшие неcompose (без
    # label проекта)compose не может пересоздать из-за конфликта имён — снимаем их вручную.
    $COMPOSE "${PROFILE_ARGS[@]}" down --remove-orphans >/dev/null 2>&1 || true
    for c in open5gs-mongodb open5gs webserve asterisk; do
      docker rm -f "$c" >/dev/null 2>&1 && echo "removed $c" || true
    done
    echo "### 4. Проверка переиспользования тома open5gs_mongo ###"
    docker volume ls | grep -E 'open5gs_mongo' || echo "!! том open5gs_mongo не найден — ПРОВЕРЬ данные абонентов"
    echo "### 5. docker compose up -d (пересоздание начисто) ###"
    $COMPOSE "${PROFILE_ARGS[@]}" up -d --force-recreate --remove-orphans
    echo "### 6. Ожидание mongo healthy + подъёма open5gs ###"
    for i in $(seq 1 40); do
      st=$(docker inspect -f '{{.State.Health.Status}}' open5gs-mongodb 2>/dev/null || echo starting)
      [ "$st" = healthy ] && { echo "mongodb: healthy"; break; }
      sleep 1
    done
    sleep 10
    echo "### 7. Пост-проверка ###"
    dc ps
    echo "--- SGi ogstun (должен быть UP с 10.0.0.1) ---"
    ip -4 addr show ogstun 2>/dev/null | grep -E 'inet ' || echo "!! ogstun без адреса"
    ip link show ogstun 2>/dev/null | head -1
    echo "--- HSS/eNB ---"
    docker logs --since 40s open5gs 2>&1 | grep -iE "HSS initialize|CONNECTED TO 'hss|Failed to initialize HSS|Number of eNBs" | tail -8 || true
    echo "### ГОТОВО. Дальше: 'compose.pi5-2.sh status'; логи БС: docker logs enb2/enb ==="
    ;;

  *)
    echo "Неизвестная команда: $cmd"; echo "Команды: up|down|restart|status|logs|recreate"; exit 1 ;;
esac
