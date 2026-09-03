"""control.py — управление контейнерами стенда через Docker Engine API.

Docker-сокет пробрасывается в контейнер дашборда (-v /var/run/docker.sock).
Взаимодействуем с Docker Engine API напрямую по HTTP поверх unix-socket
(стандартные http.client + socket) — без установки docker SDK.

Правила выбора управляемых контейнеров:
  - epc-режим: контейнер ядра "epc" (и любые srsran-контейнеры на узле).
  - enb-режим: контейнер базовой станции (enb, enb2, enb3, ...).
Управляем всеми контейнерами, чьё имя начинается с srs/enb/epc/dashboard-ctl,
чтобы дашборд на узле мог стартовать/останавливать релевантные контейнеры.
"""
import http.client
import json
import os
import socket

DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
MODE = os.environ.get("DASH_MODE", "epc").lower()


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTP-соединение поверх UNIX domain socket (docker.sock)."""

    def __init__(self, path, timeout=10):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def _request(method, path, body=None):
    """Выполнить запрос к Docker Engine API. Возвращает (status, json|text)."""
    conn = UnixHTTPConnection(DOCKER_SOCK)
    headers = {"Host": "localhost"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    else:
        data = None
    try:
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read().decode(errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = raw
        return resp.status, parsed
    except Exception as e:  # noqa: BLE001
        return -1, f"docker API недоступен: {e}"
    finally:
        conn.close()


def _is_ctrl_container(name):
    """Контейнер управляем, если имя попадает в relevant набор."""
    n = (name or "").lower()
    prefixes = ("srs", "enb", "epc", "dashboard")
    # игнорируем сам дашборд и dashboard-* (кроме dashboard-ctl)
    if n.startswith("srsran-dashboard"):
        return False
    for p in prefixes:
        if n.startswith(p):
            return True
    return False


def list_control():
    """Список управляемых контейнеров на узле: имя, статус, образ, режим."""
    status, data = _request("GET", "/containers/json?all=1")
    if status != 200:
        return {"ok": False, "error": data if isinstance(data, str) else str(data),
                "containers": []}
    containers = []
    for c in data or []:
        name = (c.get("Names") or [""])[0].lstrip("/")
        if not _is_ctrl_container(name):
            continue
        state = c.get("State", "unknown")  # running / exited / created / paused
        containers.append({
            "name": name,
            "state": state,
            "status": c.get("Status", ""),
            "image": (c.get("Image") or "").split("@")[0],
            "mode": MODE,
        })
    # сортировка: сначала ядро epc, потом enb по имени
    containers.sort(key=lambda x: (x["name"] != "epc", x["name"]))
    return {"ok": True, "containers": containers}


def action(name, action):
    """Выполнить start|stop|restart над контейнером. Возвращает {"ok": bool, "detail": ...}."""
    action = (action or "").lower()
    if action not in ("start", "stop", "restart"):
        return {"ok": False, "error": f"неизвестное действие: {action}"}

    # Пройтись по актуальным контейнерам, чтобы проверить их существование
    containers = list_control().get("containers", [])
    if not any(c["name"] == name for c in containers):
        return {"ok": False, "error": f"контейнер '{name}' не найден/не управляем на этом узле"}

    try:
        if action == "start":
            resp_status, resp = _request("POST", f"/containers/{name}/start")
        elif action == "stop":
            resp_status, resp = _request("POST", f"/containers/{name}/stop?t=10")
        else:  # restart
            resp_status, resp = _request("POST", f"/containers/{name}/restart?t=10")
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"ошибка запроса: {e}"}

    if resp_status in (204, 200):
        return {"ok": True, "action": action, "name": name,
                "detail": f"OK ({action})"}
    return {"ok": False, "action": action, "name": name,
            "error": f"статус {resp_status}: {resp}"}


def status(name):
    """Статус конкретного контейнера (или None, если нет/не управляем)."""
    for c in list_control().get("containers", []):
        if c["name"] == name:
            return c
    return None
