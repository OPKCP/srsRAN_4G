#!/usr/bin/env bash
# =============================================================================
# qctl.sh — управление клиентами тестера через API веб-сервера качества.
#
# Использование (сервер доступен на pi5 по 192.168.1.26:8080, но API также
# доступен абонентам на 10.0.0.1:8080; для управления обычно ходят с ПК на
# внешний IP pi5):
#   ./qctl.sh clients                       # список клиентов и их состояние
#   ./qctl.sh reload <ip>                   # перезагрузить страницу клиента (обновить код)
#   ./qctl.sh reload-all                    # перезагрузить всех клиентов
#   ./qctl.sh speed <ip> start|stop         # запустить/остановить тест скорости
#   ./qctl.sh tail-history [-n 20]          # последние строки CSV-истории
#
# BASE — адрес сервера. По умолчанию внешний IP pi5 (доступен с ПК). Если
# запускать с самого pi5 — можно localhost:8080.
# =============================================================================
set -euo pipefail

BASE="${QCTL_BASE:-http://192.168.1.26:8080}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

[ "$#" -lt 1 ] && usage
cmd="$1"; shift

case "$cmd" in
  clients)
    curl -s "$BASE/api/clients" | python3 -m json.tool ;;
  reload)
    [ "$#" -ge 1 ] || usage
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"cmd\":\"reload\"}" "$BASE/api/clients/$1/cmd" | python3 -m json.tool ;;
  reload-all)
    curl -s -X POST "$BASE/api/reload-all" | python3 -m json.tool ;;
  speed)
    [ "$#" -ge 2 ] || usage
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"cmd\":\"speed\",\"data\":{\"action\":\"$2\"}}" \
      "$BASE/api/clients/$1/cmd" | python3 -m json.tool ;;
  tail-history)
    f="$(ls -t $HOME/srsran/quality-history/history-*.csv 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "нет файла истории"; exit 1; }
    tail -n "${1:-20}" "$f" ;;
  *)
    usage ;;
esac
