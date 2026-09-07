# =============================================================================
# srsRAN_4G -- качество-test сервер (quality-testing).
# Заменяет python3 -m http.server: раздаёт файлы абонентам И предоставляет
# инструмент тестирования канала со стороны абонентских устройств.
#
# Модель: pull + WebSocket. Клиент (браузер телефона) сам устанавливает WS и
# шлёт heartbeat/состояние; сервер по этому каналу шлёт команды (reload, speed start/stop).
# Клиент идентифицируется по IP, который видит сервер (10.0.0.x).
#
# Endpoints:
#   GET  /                      -> index.html (список файлов из SERVE_DIR + ссылка на тестер)
#   GET  /tester.html           -> страница тестера канала
#   GET  /static/<f>            -> статика (tester.js/css), без кеша (Cache-Control: no-store)
#   GET  /api/stream            -> бесконечный поток случайных данных (замер скорости)
#   WS   /ws                    -> heartbeat клиентов + команды сервер->клиент
#   GET  /api/clients           -> состояние всех подключённых клиентов
#   POST /api/clients/<ip>/cmd  -> отправить команду конкретному клиенту
#
# История измерений пишется в HISTORY_DIR (CSV по датам) для отслеживания
# временных изменений характеристик (перемещение клиентов, положение и т.п.).
# =============================================================================
import csv
import io
import json
import os
import re
import socket
import threading
import time
import uuid
from datetime import datetime

from flask import Flask, Response, jsonify, request, send_from_directory
from flask_sock import Sock

# ---------------------------------------------------------------------------
# Конфигурация (из env с разумными дефолтами)
# ---------------------------------------------------------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.environ.get("STATIC_DIR", os.path.join(BASE_DIR, "static"))
SERVE_DIR = os.environ.get("SERVE_DIR", "/serve")          # каталог раздаваемых файлов
HISTORY_DIR = os.environ.get("HISTORY_DIR", os.path.join(BASE_DIR, "history"))
GATEWAY_IP = os.environ.get("GATEWAY_IP", "10.0.0.1")       # "шлюз" для пинга (ядра сети)
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
HISTORY_CSV_TIME = int(os.environ.get("HISTORY_CSV_TIME", "60"))  # сек между замерами в логе

# Параметры определения БС по логам ядра (EPC).
# webserve должен иметь доступ к epc.log через mount (RO). См. run_webserver_quality.sh.
EPC_LOG = os.environ.get("EPC_LOG", "/app/epclogs/epc.log")
ENB_BY_ADDR = {  # GTP-U адрес eNB -> читаемое имя БС
    "192.168.1.25": "eNB1 (1815 МГц)",
    "192.168.1.26": "eNB2 (1811 МГц)",
    # "192.168.1.20" пока неизвестна; fallback покажет "eNB (192.168.1.20)"
}


def _format_enb(addr):
    """Читаемое имя БС по GTP-U адресу. Если адрес не в карте — 'eNB (x.x.x.x)'."""
    if addr in ENB_BY_ADDR:
        return ENB_BY_ADDR[addr]
    return f"eNB ({addr})"

# Параметры активного пинга клиентов сервером (через WS).
SERVER_PING_INTERVAL = float(os.environ.get("SERVER_PING_INTERVAL", "5"))  # сек
SERVER_PING_TIMEOUT = float(os.environ.get("SERVER_PING_TIMEOUT", "12"))  # сек без ответа -> считаем отключённым

os.makedirs(HISTORY_DIR, exist_ok=True)
os.makedirs(STATIC_DIR, exist_ok=True)

app = Flask(__name__, static_folder=None)
sock = Sock(app)

# ---------------------------------------------------------------------------
# Хранилище клиентов: ip -> {last_seen, ws, state}
# Защита threading.Lock т.к. Flask/WS могут трогать из разных потоков.
# ---------------------------------------------------------------------------
_clients = {}
_clients_lock = threading.Lock()

# Доп. поля состояния каждого клиента (инициализация при подключении):
_DEFAULT_STATE = {
    "ping_ms": "", "ping_avg_ms": "", "lost_last100": 0,
    "speed_mbps": "", "speed_state": "idle", "src_ts": "",
    "enb": "",                     # имя БС, к которой подключён клиент (из логов ядра)
    "srv_ping_ms": "",             # RTT, замеренный сервером через WS
    "online": True,                # живость по серверному пингу
}


# ---------------------------------------------------------------------------
# Определение БС по логам ядра (EPC).
# Ищем пары "IMSI ... <-> 10.0.0.x" и последние "eNB GTP-U Address <IP>".
# На выходе: dict ip -> имя eNB.
# ---------------------------------------------------------------------------
_epc_log_pos = 0          # позиция чтения epc.log (incremental)
_ue_ip_by_imsi = {}       # IMSI -> последний выданный IP (10.0.0.x)
_ue_enb_by_imsi = {}      # IMSI -> последний eNB (адрес или имя)
_current_enb_map_cache = {}   # ip -> enb (последняя известная карта)
_last_broadcast_enb_map = {}  # последняя рассланная карта


def _parse_epc_log():
    """Читает новые строки epc.log и обновляет словари соответствия IMSI->IP->eNB.

    Реальный формат srsepc (проверено на логе):
      - "[SPGW GTPC] [I] IMSI: 250630000000005, UE IP: 10.0.0.15"   -> IMSI<->IP
      - "[S1AP   ] [I] E-RAB Context -- eNB TEID 0x1c, eNB Address 192.168.1.25"
        (без IMSI; привязываем к последнему IMSI из предыдущей строки IMSI/UE IP)
    Храним последний IMSI, виденный в строке IMSI/UE IP, и привязываем к нему
    следующий eNB Address.
    Вызывать без удержания _clients_lock (файловый ввод/вывод)."""
    global _epc_log_pos
    last_imsi = None
    try:
        with open(EPC_LOG, "r", errors="replace") as f:
            f.seek(_epc_log_pos)
            for line in f:
                # IMSI<->IP: "IMSI: X, UE IP: Y"
                m = re.search(r"IMSI:\s*(\d+),\s*UE IP:\s*(\S+)", line)
                if m:
                    imsi, ip = m.group(1), m.group(2)
                    _ue_ip_by_imsi[imsi] = ip
                    last_imsi = imsi   # строки E-RAB Context идут сразу после
                    continue
                # eNB: "E-RAB Context -- eNB TEID ..., eNB Address Z"
                m = re.search(r"eNB Address\s+(\S+)", line)
                if m and last_imsi:
                    addr = m.group(1)
                    _ue_enb_by_imsi[last_imsi] = _format_enb(addr)
            _epc_log_pos = f.tell()
    except FileNotFoundError:
        pass
    except Exception as e:
        app.logger.warning("epc log parse error: %s", e)


def _current_enb_map():
    """Возвращает dict ip -> имя БС по текущему знанию из логов ядра."""
    _parse_epc_log()
    out = {}
    # для каждого IMSI с известным IP и eNB
    for imsi, ip in _ue_ip_by_imsi.items():
        enb = _ue_enb_by_imsi.get(imsi)
        if enb:
            out[ip] = enb
    return out


# ---------------------------------------------------------------------------
# Вспомогательные
# ---------------------------------------------------------------------------
def _client_ip():
    """Реальный IP клиента. Смотрим X-Forwarded-For (если есть прокси), иначе REMOTE_ADDR."""
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.remote_addr or "unknown"


def _now():
    return datetime.now().isoformat(timespec="milliseconds")


def _history_csv_path():
    return os.path.join(HISTORY_DIR, f"history-{datetime.now().strftime('%Y-%m-%d')}.csv")


def _append_history(client_ip, state):
    """Логируем замер в CSV-файл (одна строка на замер, без кеширования в памяти)."""
    try:
        path = _history_csv_path()
        new_file = not os.path.exists(path)
        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if new_file:
                w.writerow(["time", "client_ip", "ping_ms", "ping_avg_ms", "lost_last100",
                            "speed_mbps", "speed_state", "src_ts"])
            w.writerow([
                _now(),
                client_ip,
                state.get("ping_ms", ""),
                state.get("ping_avg_ms", ""),
                state.get("lost_last100", ""),
                state.get("speed_mbps", ""),
                state.get("speed_state", ""),
                state.get("src_ts", ""),
            ])
    except Exception as e:  # никогда не роняем сервер из-за проблем с логом
        app.logger.warning("history append error: %s", e)


def _update_history_loop():
    """Каждые HISTORY_CSV_TIME сек снимаем снапшот состояния всех клиентов в CSV."""
    while True:
        time.sleep(HISTORY_CSV_TIME)
        with _clients_lock:
            snapshot = {ip: dict(c["state"]) for ip, c in list(_clients.items())}
        for ip, st in snapshot.items():
            _append_history(ip, st)


# ---------------------------------------------------------------------------
# Обмен по WebSocket: heartbeat клиента + очереди команд server->client
# ---------------------------------------------------------------------------
def _broadcast(payload):
    """Разослать сообщение всем подключённым клиентам."""
    with _clients_lock:
        for c in list(_clients.values()):
            ws = c.get("ws")
            if ws is not None:
                try:
                    ws.send(json.dumps(payload))
                except Exception:
                    pass  # сломавшийся канал уберём по heartbeat/ошибке


def _send_to_client(ip, payload):
    """Отправить команду конкретному клиенту. Возвращает True, если клиент найден."""
    with _clients_lock:
        c = _clients.get(ip)
        ws = c["ws"] if c else None
    if ws is None:
        return False
    try:
        ws.send(json.dumps(payload))
        return True
    except Exception:
        return False


@sock.route("/ws")
def ws_route(ws):
    client_ip = _client_ip()
    # Регистрируем/освежаем запись клиента
    with _clients_lock:
        _clients[client_ip] = {"ip": client_ip, "ws": ws, "state": dict(_DEFAULT_STATE)}
    try:
        while True:
            raw = ws.receive(timeout=30)
            if raw is None:
                break
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if msg.get("type") == "status":
                with _clients_lock:
                    st = _clients[client_ip]["state"]
                    st.update(msg.get("data", {}))
                    st["_last_alive"] = time.time()
                    st["src_ts"] = _now()
                # периодически логируем замеры клиента в историю (по факту heartbeat)
            elif msg.get("type") == "hello":
                with _clients_lock:
                    _clients[client_ip]["state"]["src_ts"] = _now()
                    _clients[client_ip]["state"]["_last_alive"] = time.time()
                # подтверждаем клиенту его идентификацию (IP) и текущую БС (если известна)
                enb = _current_enb_map().get(client_ip, "")
                ws.send(json.dumps({"type": "welcome", "ip": client_ip, "enb": enb}))
            elif msg.get("type") == "pong":
                # ответ клиента на серверный ping (замер RTT на стороне сервера)
                with _clients_lock:
                    st = _clients[client_ip]["state"]
                    st["online"] = True
                    st["_last_alive"] = time.time()
                    if isinstance(msg.get("ts"), (int, float)):
                        st["srv_ping_ms"] = round((time.time() - msg["ts"]) * 1000, 1)
                    st["src_ts"] = _now()
            elif msg.get("type") == "page-state":
                # отладочный канал: клиент прислал состояние своей страницы
                with _clients_lock:
                    _clients[client_ip]["state"]["page"] = msg.get("data", {})
                    _clients[client_ip]["state"]["src_ts"] = _now()
    finally:
        with _clients_lock:
            _clients.pop(client_ip, None)


def _server_ping_loop():
    """Фоновая задача: каждые SERVER_PING_INTERVAL сек шлёт клиентам ping по WS
    (с временной меткой) и помечает offline тех, кто не ответил за SERVER_PING_TIMEOUT.
    Также обновляет карту 'клиент -> БС' из логов ядра и рассылает её клиентам."""
    global _current_enb_map_cache, _last_broadcast_enb_map
    while True:
        time.sleep(SERVER_PING_INTERVAL)
        now = time.time()
        with _clients_lock:
            for ip, c in list(_clients.items()):
                ws = c.get("ws")
                st = c["state"]
                last_seen = st.get("_last_alive", 0)
                if now - last_seen > SERVER_PING_TIMEOUT and last_seen > 0:
                    st["online"] = False
                if ws is not None:
                    try:
                        ws.send(json.dumps({"type": "srv-ping", "ts": now}))
                    except Exception:
                        st["online"] = False
                # обновляем поле enb из карты (на случай, что карта уже известна)
                if ip in _current_enb_map_cache:
                    st["enb"] = _current_enb_map_cache[ip]
        # читаем лог ядра вне блокировки (файловый ввод/вывод)
        try:
            new_map = _current_enb_map()
            _current_enb_map_cache.update(new_map)
            changed = new_map != _last_broadcast_enb_map
            if changed:
                _last_broadcast_enb_map = new_map
            with _clients_lock:
                for ip, c in list(_clients.items()):
                    my_enb = new_map.get(ip, c["state"].get("enb", ""))
                    if my_enb != c["state"].get("enb", ""):
                        c["state"]["enb"] = my_enb
                    # Персонально доставляем текущую БС клиенту (не только при
                    # изменении всей карты) -- надёжнее, чем broadcast enb-map.
                    if c.get("ws") is not None:
                        try:
                            c["ws"].send(json.dumps({"type": "enb", "enb": my_enb, "ip": ip}))
                        except Exception:
                            pass
            if changed:
                _broadcast({"type": "enb-map", "map": new_map})
        except Exception as e:
            app.logger.warning("enb map update error: %s", e)


# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    try:
        files = sorted(
            f for f in os.listdir(SERVE_DIR)
            if os.path.isfile(os.path.join(SERVE_DIR, f)) and not f.startswith(".")
        )
    except FileNotFoundError:
        files = []
    html = _render_index(files)
    return Response(html, mimetype="text/html")


def _render_index(files):
    rows = "".join(
        f'<li><a href="/files/{_quote(f)}">{_esc(f)}</a></li>' for f in files
    )
    client_ip = _client_ip()
    return f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Файловый сервер srsRAN</title>
<style>
 body{{font-family:system-ui,sans-serif;margin:2em;max-width:700px}}
 a{{color:#0a58ca}}
 .tester{{display:inline-block;margin-top:1.5em;padding:.7em 1.2em;background:#198754;color:#fff;
         text-decoration:none;border-radius:.5em;font-weight:600}}
 .tester:hover{{background:#157347}}
 .files li{{margin:.3em 0}}
 .ip{{color:#666;font-size:.9em;margin-top:2em}}
</style>
</head>
<body>
<h1>Сервер файлов srsRAN-4G</h1>
<p>Ваш адрес (IP): <b>{_esc(client_ip)}</b></p>
<p>Доступные файлы:</p>
<ul class="files">{rows or '<li><i>нет файлов</i></li>'}</ul>
<a class="tester" href="/tester.html">📶 Тестер канала</a>
<p class="ip">host {_esc(socket.gethostname() or '')}</p>
</body>
</html>"""


# Раздача файлов отдаётся по /files/<name> (пробел и спецсимволы -- закодированы)
@app.route("/files/<path:name>")
def file_download(name):
    return send_from_directory(SERVE_DIR, name)


@app.route("/tester.html")
def tester():
    """Страница тестера. Подставляем IP клиента, который видит сервер, чтобы
    клиент знал свой идентификатор и использовал его в heartbeat/командах."""
    with open(os.path.join(STATIC_DIR, "tester.html"), "r", encoding="utf-8") as f:
        html = f.read()
    html = html.replace("{{CLIENT_IP}}", _esc(_client_ip()))
    resp = Response(html, mimetype="text/html")
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/static/<path:fname>")
def static_file(fname):
    resp = send_from_directory(STATIC_DIR, fname)
    # НЕ кешировать JS/HTML, чтобы после reload клиент всегда брал свежий код
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/stream")
def api_stream():
    """Бесконечный поток случайных данных для замера скорости (TCP/HTTP throughput).
    Данные генерируются блоками и отдаются по мере чтения; клиент их выбрасывает."""
    chunk_size = 64 * 1024
    def gen():
        # псевдослучайные байты (дешёво генерировать), заполняем буфер
        buf = bytearray(chunk_size)
        import os as _os
        try:
            while True:
                # Случайные данные; OSRandom — блокируется редко, но для скорости
                # дешевле сгенерировать один буфер и крутить по кругу.
                buf = bytearray(_os.urandom(chunk_size))
                yield bytes(buf)
        except GeneratorExit:
            return
    return Response(gen(), mimetype="application/octet-stream",
                    headers={"Cache-Control": "no-store"})


@app.route("/api/clients")
def api_clients():
    with _clients_lock:
        out = {
            ip: {
                "ip": ip,
                "state": dict(c["state"]),
                "connected": c["ws"] is not None,
            }
            for ip, c in _clients.items()
        }
    return jsonify(out)


@app.route("/api/clients/<ip>/cmd", methods=["POST"])
def api_client_cmd(ip):
    payload = request.get_json(silent=True) or {}
    cmd = payload.get("cmd")
    if not cmd:
        return jsonify({"ok": False, "error": "missing cmd"}), 400
    ok = _send_to_client(ip, {"type": "cmd", "cmd": cmd, "data": payload.get("data", {})})
    return jsonify({"ok": ok, "ip": ip, "cmd": cmd, "delivered": ok})


@app.route("/api/clients/<ip>/page-state", methods=["POST"])
def api_client_page_state(ip):
    """Отладочный канал: просим указанного клиента прислать текущее состояние
    его веб-странички (что отображается на экране). Ответ подтягиваем из state.
    Возвращает 'delivered' (команда отправлена) и, если клиент уже присылал
    состояние недавно, — последний известный page-state."""
    delivered = _send_to_client(ip, {"type": "cmd", "cmd": "page-state"})
    with _clients_lock:
        c = _clients.get(ip)
        page = c["state"].get("page", {}) if c else {}
    return jsonify({"ok": delivered, "ip": ip, "delivered": delivered, "page": page})


@app.route("/api/reload-all", methods=["POST"])
def api_reload_all():
    """Удобно: разослать reload всем клиентам (обновление кода после правок)."""
    _broadcast({"type": "cmd", "cmd": "reload"})
    return jsonify({"ok": True, "sent": True})


# ---------------------------------------------------------------------------
# Эскейпинг (минимум, без лишних зависимостей)
# ---------------------------------------------------------------------------
def _esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _quote(s):
    from urllib.parse import quote
    return quote(str(s))


# ---------------------------------------------------------------------------
# Старт
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    threading.Thread(target=_update_history_loop, daemon=True).start()
    threading.Thread(target=_server_ping_loop, daemon=True).start()
    app.logger.info("quality-testing server on %s:%s (serve=%s, static=%s, gateway=%s)",
                    LISTEN_HOST, LISTEN_PORT, SERVE_DIR, STATIC_DIR, GATEWAY_IP)
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, threaded=True, debug=False)
