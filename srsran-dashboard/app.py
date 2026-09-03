"""srsran-dashboard — веб-дашборд мониторинга стенда srsRAN 4G.

Flask-приложение, которое парсит логи ядра (EPC) или базовой станции (eNB)
и отображает состояние в реальном времени:
- список абонентов (клиентов), подключённых/известных ядру;
- список базовых станций, видимых со стороны ядра;
- события (attach/detach/BS/системные);
- метрики активных UE со стороны eNB (для режима enb).

Запускается одним контейнером в двух режимах:
  DASH_MODE=epc  → парсит лог srsepc (epc.log)
  DASH_MODE=enb  → парсит лог srsenb + метрики (enb_report.json)

Каталог логов пробрасывается в контейнер через volume.
SSE-канал /api/stream для обновлений в реальном времени.
"""
import json
import threading
import time

from flask import Flask, Response, jsonify, render_template, request

import config
import control
import userdb
from parser import EpcParser, EnbParser
from state import Store

app = Flask(__name__)
app.config.from_object(config.Config)

store = Store(mode=config.Config.MODE, tail_lines=config.Config.TAIL_LINES)
parser_lock = threading.Lock()

# Флаг: user_db.csv был изменён через дашборд — требуется перезапуск ядра (HSS кеширует список).
userdb_pending_restart = {"flag": False}
_userdb_lock = threading.Lock()


def _make_parser():
    if config.Config.is_epc():
        log = config.Config.log_path(config.Config.EPC_LOG_FILE)
        return EpcParser(store, log)
    log = config.Config.log_path(config.Config.ENB_LOG_FILE)
    metrics = config.Config.log_path(config.Config.ENB_METRICS_FILE)
    return EnbParser(store, log, metrics)


parser = _make_parser()


def _load_user_db():
    """Прочитать user_db.csv ядра (если есть) для показа известных SIM/имён."""
    path = config.Config.log_path(config.Config.USER_DB_FILE)
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = [p.strip(' "') for p in line.split(",")]
                if not parts or not parts[0].isdigit():
                    continue
                imsi = parts[0]
                info = {"name": parts[1] if len(parts) > 1 and parts[1] else ""}
                # сохранение имени в store
                if info["name"]:
                    store.register_subscriber(imsi, extra=store.subscribers.get(imsi, {}).get("extra", {}))
    except OSError:
        pass


def _parse_loop():
    """Фоновый поток: периодически читает новые строки лога и метрики."""
    while True:
        try:
            with parser_lock:
                parser.read_new()
                if config.Config.is_enb():
                    parser.parse_metrics()
        except Exception as e:  # noqa: BLE001 — не ронять поток
            store.add_event("error", "system", "system", f"Ошибка парсера: {e}")
        time.sleep(config.Config.PARSE_INTERVAL)


# ---------------------------------------------------------------------------
# Маршруты
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html", mode=store.mode)


@app.route("/api/snapshot")
def api_snapshot():
    return jsonify(store.snapshot())


@app.route("/api/subscribers")
def api_subscribers():
    return jsonify(store.get_subscribers())


@app.route("/api/events")
def api_events():
    limit = request.args.get("limit", default=100, type=int)
    return jsonify(store.get_events(limit))


@app.route("/api/basestations")
def api_basestations():
    return jsonify(store.get_base_stations())


@app.route("/api/tail")
def api_tail():
    return jsonify(store.get_tail())


@app.route("/api/stream")
def api_stream():
    """Server-Sent Events: отправляет события и периодически снимок состояния."""
    def generate():
        last_event_ts = 0.0
        while True:
            with parser_lock:
                events = store.get_events(limit=50)
            new_events = [e for e in events if e["ts"] > last_event_ts]
            if new_events:
                last_event_ts = max(e["ts"] for e in new_events)
                payload = {"type": "events", "events": new_events}
                yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
            # периодический heartbeat со снимком
            snap = store.snapshot()
            yield f"data: {json.dumps({'type': 'snapshot', 'snapshot': snap}, ensure_ascii=False)}\n\n"
            time.sleep(1.0)

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"})


# ---------------------------------------------------------------------------
# Управление контейнерами (запуск/остановка/перезапуск через Docker API)
# ---------------------------------------------------------------------------
@app.route("/api/control")
def api_control():
    """Список управляемых контейнеров на этом узле."""
    return jsonify(control.list_control())


@app.route("/api/control/<name>/<action>", methods=["POST"])
def api_control_action(name, action):
    """Выполнить действие start|stop|restart над контейнером на этом узле."""
    res = control.action(name, action)
    status_code = 200 if res.get("ok") else 400
    return jsonify(res), status_code


# ---------------------------------------------------------------------------
# Редактор базы абонентов HSS (user_db.csv) — только в epc-режиме
# ---------------------------------------------------------------------------
def _userdb_call(fn, *args, **kwargs):
    """Выполнить операцию над user_db; при успехе устанавливает флаг restart."""
    with _userdb_lock:
        res = fn(*args, **kwargs)
        if res.get("ok"):
            userdb_pending_restart["flag"] = True
        return res


@app.route("/api/userdb")
def api_userdb():
    """Список записей + метаданные полей + статус pending-restart."""
    if not config.Config.is_epc():
        return jsonify({"ok": False, "error": "редактор доступен только в epc-режиме"}), 403
    data = userdb.list_records()
    return jsonify({**data,
                    "fields": userdb.FIELD_META,
                    "pending_restart": userdb_pending_restart["flag"],
                    "restart_target": "epc"})


@app.route("/api/userdb/fields")
def api_userdb_fields():
    """Метаданные полей (для построения формы)."""
    return jsonify({"ok": True, "fields": userdb.FIELD_META, "defaults": {
        f["key"]: f["default"] for f in userdb.FIELD_META}})


@app.route("/api/userdb/<imsi>")
def api_userdb_get(imsi):
    return jsonify(userdb.get_record(imsi))


@app.route("/api/userdb", methods=["POST"])
def api_userdb_create():
    """Создать новую запись."""
    res = _userdb_call(userdb.add_record, request.get_json(silent=True) or {})
    return jsonify(res), (200 if res.get("ok") else 400)


@app.route("/api/userdb/<imsi>", methods=["PUT"])
def api_userdb_update(imsi):
    """Обновить запись по IMSI."""
    res = _userdb_call(userdb.update_record, imsi, request.get_json(silent=True) or {})
    return jsonify(res), (200 if res.get("ok") else 400)


@app.route("/api/userdb/<imsi>", methods=["DELETE"])
def api_userdb_delete(imsi):
    """Удалить запись по IMSI."""
    res = _userdb_call(userdb.delete_record, imsi)
    return jsonify(res), (200 if res.get("ok") else 400)


@app.route("/api/userdb/<imsi>/<state>", methods=["POST"])
def api_userdb_setstate(imsi, state):
    """Включить/выключить запись (state = enable|disable)."""
    enabled = state == "enable"
    res = _userdb_call(userdb.set_enabled, imsi, enabled)
    return jsonify(res), (200 if res.get("ok") else 400)


@app.route("/api/userdb/restart/done", methods=["POST"])
def api_userdb_restart_done():
    """Сбросить флаг pending-restart (после перезапуска ядра)."""
    userdb_pending_restart["flag"] = False
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Запуск
# ---------------------------------------------------------------------------
def main():
    # стартовое событие
    store.add_event("info", "system", "system",
                    f"Запущен дашборд (режим: {'ядро EPC' if store.mode == 'epc' else 'БС eNB'})")
    if config.Config.is_epc():
        log = config.Config.log_path(config.Config.EPC_LOG_FILE)
        store.system_info["mode"] = "epc"
    else:
        log = config.Config.log_path(config.Config.ENB_LOG_FILE)
        store.system_info["mode"] = "enb"

    # фоновый парсер
    t = threading.Thread(target=_parse_loop, daemon=True)
    t.start()

    app.run(host=config.Config.HOST, port=config.Config.PORT, threaded=True)


if __name__ == "__main__":
    main()
