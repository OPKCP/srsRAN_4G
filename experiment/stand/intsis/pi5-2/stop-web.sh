#!/usr/bin/env bash
# =============================================================================
# stop-web.sh — остановка ВЕБ-СЕРВЕРОВ и мониторинга на pi5-2.
# Останавливает: webserve, дашборды ядра и БС2, Prometheus, Grafana.
# =============================================================================
set -uo pipefail

echo "===== Остановка веб-серверов ($(hostname)) ====="
for c in webserve srsran-dashboard-epc srsran-dashboard-enb2 prometheus grafana; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    if docker stop "$c" >/dev/null 2>&1; then echo "[OK] остановлен $c"; else echo "[ВНИМАНИЕ] не удалось остановить $c"; fi
  else
    echo "[i] контейнер $c не найден"
  fi
done
echo "[OK] Веб-серверы и мониторинг остановлены."
