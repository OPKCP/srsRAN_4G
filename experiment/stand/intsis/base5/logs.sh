#!/usr/bin/env bash
# =============================================================================
# logs.sh — ПОКАЗАТЬ КЛЮЧЕВЫЕ ЛОГИ БАЗОВОЙ СТАНЦИИ №1 (base5), только чтение.
#
# Запуск (на base5):   ./logs.sh
# =============================================================================
set -uo pipefail

show() {  # show <заголовок> <контейнер> <шаблон grep -E> <сколько строк>
  local title="$1" cont="$2" pat="$3" n="${4:-5}" out
  echo "--- ${title} ---"
  out="$(docker logs --since 24h "$cont" 2>&1 | grep -E "$pat" | tail -n "$n" || true)"
  if [ -n "$out" ]; then echo "$out"; else echo "  (записей нет)"; fi
  echo
}

echo "################################################################"
echo "#  ЛОГИ БАЗОВОЙ СТАНЦИИ №1 (base5)"
echo "#  Узел: $(hostname)     $(date '+%d.%m.%Y %H:%M')"
echo "################################################################"
echo

echo "========= БС1 (eNB1, 1815 МГц) ========="
echo
show "Радио и старт (ожидаем 'eNodeB started' и 'DL=1815.0 Mhz')" \
     enb 'Detected Device|eNodeB started|Setting frequency' 5
echo "  ошибок радио (Fatal radio error): $(docker logs enb 2>&1 | grep -c 'Fatal radio error' || true)"
echo

echo "========= ДАШБОРД БС1 ========="
echo
st="$(docker inspect -f '{{.State.Status}}' srsran-dashboard-enb 2>/dev/null || echo absent)"
echo "  srsran-dashboard-enb: ${st}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://192.168.1.25:5000/" 2>/dev/null)"
echo "  http://192.168.1.25:5000/  код ${code:-нет ответа}"
echo

echo "################################################################"
echo "#  Полный лог БС1:  docker logs --tail 100 enb                 #"
echo "################################################################"
