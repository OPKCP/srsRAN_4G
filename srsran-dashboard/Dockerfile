# srsran-dashboard — веб-дашборд мониторинга стенда srsRAN 4G
# Один образ, два режима (EPC / eNB) через переменную окружения DASH_MODE.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DASH_MODE=epc \
    DASH_LOG_DIR=/logs \
    DASH_PORT=5000

WORKDIR /app

# Копируем зависимости и устанавливаем
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копируем приложение
COPY config.py app.py control.py state.py ./
COPY parser ./parser
COPY templates ./templates
COPY static ./static

# Каталог логов, монтируемый через volume на хосте
RUN mkdir -p /logs

EXPOSE 5000

# По умолчанию командой запускается app.py (режим задаётся через DASH_MODE)
CMD ["python", "app.py"]
