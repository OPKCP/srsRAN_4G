#!/usr/bin/env bash
# =============================================================================
# logs.sh — ПОКАЗАТЬ КЛЮЧЕВЫЕ ЛОГИ СТЕНДА (только чтение).
#
# Запуск (на pi5-2):   ./logs.sh
# Показывает самое важное: стартовало ли ядро, подключились ли базовые станции,
# регистрируются ли абоненты, живы ли веб-сервисы. Полные логи — в конце скрипта.
# =============================================================================
set -uo pipefail

# Печатает последние совпадения из лога контейнера. Никаких сложных кавычек —
# весь разбор делается здесь, на малинке, студенту не нужно ничего экранировать.
show() {  # show <заголовок> <контейнер> <шаблон grep -E> <сколько строк> [<исключить>]
  local title="$1" cont="$2" pat="$3" n="${4:-5}" skip="${5:-}" out
  echo "--- ${title} ---"
  out="$(docker logs --since 24h "$cont" 2>&1 | grep -E "$pat" || true)"
  [ -n "$skip" ] && out="$(grep -vE "$skip" <<<"$out" || true)"
  out="$(tail -n "$n" <<<"$out" || true)"
  if [ -n "$out" ]; then echo "$out"; else echo "  (записей нет)"; fi
  echo
}

echo "################################################################"
echo "#  ЛОГИ СТЕНДА srsRAN 4G"
echo "#  Узел: $(hostname)     $(date '+%d.%m.%Y %H:%M')"
echo "################################################################"
echo

echo "========= ЯДРО СЕТИ (Open5GS) ========="
echo
show "Подключение базовых станций (ожидаем 'Number of eNBs is now 2')" \
     open5gs 'eNB-S1 accepted|Number of eNBs is now' 6
show "Абоненты: подключение и выдача адреса (ожидаем IPv4[10.0.0.x])" \
     open5gs 'Attach request|Attach complete|IPv4\[10\.0\.0' 6
# ВНИМАНИЕ: часть записей с уровнем ERROR — штатные для этого стенда:
#   «No IPv6 subnet ... only IPv4 assigned» — стенд работает только по IPv4;
#   «GTP transaction(NOTIFY) has already been removed» — служебная гонка при
#   отключении абонента;   «Small GTPU packet» — отбрасывание служебных пакетов.
# Их не показываем, чтобы не создавать ложной тревоги.
show "Ошибки ядра (если пусто — всё хорошо)" \
     open5gs 'ERROR|FATAL' 5 \
     'Small GTPU packet|No IPv6 subnet|GTP transaction\(NOTIFY\) has already been removed'

echo "========= БАЗОВАЯ СТАНЦИЯ БС2 (pi5-2) ========="
echo
if [ "$(docker inspect -f '{{.State.Status}}' enb2 2>/dev/null || echo absent)" = "absent" ]; then
  echo "  (контейнера БС2 нет)"
else
  show "Радио и старт (ожидаем 'eNodeB started' и 'DL=1811.0 Mhz')" \
       enb2 'Detected Device|eNodeB started|Setting frequency' 4
  echo "  ошибок радио (Fatal radio error): $(docker logs enb2 2>&1 | grep -c 'Fatal radio error' || true)"
  echo
fi

echo "========= БАЗОВАЯ СТАНЦИЯ БС1 (base5, по сети) ========="
echo
ssh -o BatchMode=yes -o ConnectTimeout=8 base5 '
  echo "--- Радио и старт (ожидаем eNodeB started и DL=1815.0 Mhz) ---"
  docker logs enb 2>&1 | grep -E "Detected Device|eNodeB started|Setting frequency" | tail -4 || true
  echo "  ошибок радио (Fatal radio error): $(docker logs enb 2>&1 | grep -c "Fatal radio error" || true)"
' 2>/dev/null || echo "  [ОШИБКА] нет связи с base5"
echo

echo "========= ВЕБ-СЕРВЕРЫ ========="
echo
for c in webserve srsran-dashboard-epc srsran-dashboard-enb2 prometheus grafana; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo absent)"
  printf '  %-24s %s\n' "$c" "$st"
done
echo
echo "  веб-сервер стенда для телефона (10.0.0.1:8080), код ответа:"
echo "    $(docker exec open5gs curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://10.0.0.1:8080/ 2>/dev/null || echo 'нет ответа')"
echo
echo "################################################################"
echo "#  Полные логи (если нужно посмотреть подробнее):              #"
echo "#    docker logs --tail 100 open5gs      — логи ядра           #"
echo "#    docker logs --tail 100 enb2         — логи БС2            #"
echo "#    ssh base5 'docker logs --tail 100 enb'  — логи БС1        #"
echo "################################################################"
