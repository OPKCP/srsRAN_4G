"""Конфигурация srsran-dashboard.

Все пути задаются через переменные окружения, чтобы один и тот же образ
можно было запускать и на EPC, и на eNB, просто меняя переменные окружения.
"""
import os


def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


class Config:
    # Режим работы: "epc" (ядро сети) или "enb" (базовая станция)
    MODE = os.environ.get("DASH_MODE", "epc").lower()

    # Каталог логов, пробрасываемый внутрь контейнера через volume
    LOG_DIR = os.environ.get("DASH_LOG_DIR", "/logs")

    # Имя файла лога ядра (srsepc)
    EPC_LOG_FILE = os.environ.get("DASH_EPC_LOG", "epc.log")

    # Имя файла журнала eNB (srsenb консоль/лог)
    ENB_LOG_FILE = os.environ.get("DASH_ENB_LOG", "enb.log")

    # Файл метрик eNB (JSON). Если задан и существует — парсим его.
    # srsenb пишет его в report_json_filename (по умолчанию /tmp/enb_report.json)
    ENB_METRICS_FILE = os.environ.get("DASH_ENB_METRICS", "enb_report.json")

    # user_db.csv ядра — список известных SIM. Опционально, для показа "всех SIM".
    USER_DB_FILE = os.environ.get("DASH_USER_DB", "user_db.csv")

    # Каталог с user_db.csv на хосте (пробрасывается в контейнер в epc-режиме
    # для редактирования списка абонентов). Пустой → редактирование отключено.
    USERDB_DIR = os.environ.get("DASH_USERDB_DIR", "/userdb")

    # Как часто парсер обновляет состояние (сек)
    PARSE_INTERVAL = _int("DASH_PARSE_INTERVAL", 2)

    # Сколько строк держать в буфере недавних логов для отображения
    TAIL_LINES = _int("DASH_TAIL_LINES", 200)

    # Хост/порт Flask
    HOST = os.environ.get("DASH_HOST", "0.0.0.0")
    PORT = _int("DASH_PORT", 5000)

    @classmethod
    def log_path(cls, filename):
        """Полный путь к файлу лога внутри каталога логов."""
        return os.path.join(cls.LOG_DIR, filename)

    @classmethod
    def is_enb(cls):
        return cls.MODE == "enb"

    @classmethod
    def is_epc(cls):
        return cls.MODE == "epc"
