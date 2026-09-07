# =============================================================================
# srsRAN_4G quality-testing web server
# Образ: лёгкий python:3.12-slim + Flask + flask-sock (WebSocket).
# Код и статика монтируются из каталога quality-testing на хосте (см. run_webserver_quality.sh),
# поэтому изменения JS/CSS/HTML применяются без пересборки образа (нужен только reload клиента),
# а изменения app.py -- после перезапуска контейнера.
# =============================================================================
FROM python:3.12-slim

WORKDIR /app

# Минимизируем зависимости -- только Flask и WebSocket.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

EXPOSE 8080

CMD ["python", "/app/app.py"]
