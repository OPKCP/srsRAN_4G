"""Центральное хранилище состояния стенда.

Содержит списки абонентов (клиентов), базовых станций и событий.
Обновляется парсерами (epc_parser / enb_parser) из логов и читается
маршрутами Flask + транслируется в браузер через SSE.
Реализация потокобезопасна (threading.Lock).
"""
import threading
import time
from collections import deque
from dataclasses import dataclass, field, asdict


@dataclass
class Subscriber:
    """Абонент (клиент) LTE-сети."""
    imsi: str = ""
    ip: str = ""
    state: str = "unknown"          # unknown | attached | detached | connecting
    enb_ue_s1ap_id: str = ""
    mme_ue_s1ap_id: str = ""
    last_attach: float = 0.0
    last_seen: float = 0.0
    extra: dict = field(default_factory=dict)

    def as_dict(self, now=None):
        d = asdict(self)
        now = now if now is not None else time.time()
        d["last_attach_ago"] = round(now - self.last_attach, 1) if self.last_attach else None
        d["last_seen_ago"] = round(now - self.last_seen, 1) if self.last_seen else None
        return d


@dataclass
class BaseStation:
    """Базовая станция (eNB), видимая со стороны ядра."""
    name: str = ""
    enb_id: str = ""
    assoc_id: str = ""
    tx: str = ""
    mcc: str = ""
    mnc: str = ""
    connected_at: float = 0.0
    last_seen: float = 0.0

    def as_dict(self, now=None):
        d = asdict(self)
        now = now if now is not None else time.time()
        d["connected_ago"] = round(now - self.connected_at, 1) if self.connected_at else None
        d["last_seen_ago"] = round(now - self.last_seen, 1) if self.last_seen else None
        return d


@dataclass
class Event:
    ts: float
    level: str          # info | warn | error | success
    source: str         # epc | enb | system
    category: str       # attach | detach | bs | metric | system
    message: str

    def as_dict(self):
        d = asdict(self)
        d["ts_str"] = time.strftime("%H:%M:%S", time.localtime(self.ts))
        return d


class Store:
    """Потокобезопасное хранилище состояния + очередь событий для SSE."""

    def __init__(self, mode="epc", tail_lines=200):
        self.mode = mode
        # RLock: допускает вложенный захват (snapshot вызывает get_subscribers и т.д.)
        self._lock = threading.RLock()
        self.subscribers = {}          # key: imsi
        self.by_ip = {}                # key: ip -> imsi
        self.base_stations = {}        # key: name or assoc_id
        self.events = deque(maxlen=1000)
        self.system_info = {
            "mode": mode,
            "started_at": time.time(),
            "epc_running": False,
            "enb_running": False,
            "log_file": "",
            "log_mtime": 0.0,
            "bytes_parsed": 0,
        }
        self.enb_metrics = {}          # последний снимок метрик eNB (UE list)
        self._subscribers_waiters = [] # очередь ожидающих пустых подписчиков (для SSE)
        self._tail = deque(maxlen=tail_lines)  # последние строки лога для просмотра

    # ---------- вспомогательное ----------
    def update_log_state(self, log_file, mtime, bytes_parsed, running):
        with self._lock:
            self.system_info["log_file"] = log_file
            self.system_info["log_mtime"] = mtime
            self.system_info["bytes_parsed"] = bytes_parsed
            if running:
                self.system_info["epc_running"] = running
                self.system_info["enb_running"] = running

    def add_tail(self, line):
        with self._lock:
            self._tail.append(line)

    def get_tail(self):
        with self._lock:
            return list(self._tail)

    def add_event(self, level, source, category, message):
        ev = Event(ts=time.time(), level=level, source=source, category=category, message=message)
        with self._lock:
            self.events.appendleft(ev)
        return ev

    # ---------- абоненты ----------
    def register_subscriber(self, imsi, **fields):
        """Зарегистрировать абонента/обновить известные поля."""
        with self._lock:
            if imsi not in self.subscribers:
                self.subscribers[imsi] = Subscriber(imsi=imsi)
            sub = self.subscribers[imsi]
            for k, v in fields.items():
                if v is not None and hasattr(sub, k):
                    setattr(sub, k, v)
            sub.last_seen = time.time()
        return sub

    def mark_attach(self, imsi, ip=None, enb_ue_s1ap_id=None, mme_ue_s1ap_id=None):
        """Отметить успешное подключение абонента (выдан IP)."""
        with self._lock:
            if imsi not in self.subscribers:
                self.subscribers[imsi] = Subscriber(imsi=imsi)
            sub = self.subscribers[imsi]
            if ip:
                # убрать старую привязку ip
                for old_ip, old_imsi in list(self.by_ip.items()):
                    if old_imsi == imsi:
                        del self.by_ip[old_ip]
                self.by_ip[ip] = imsi
                sub.ip = ip
            if enb_ue_s1ap_id is not None:
                sub.enb_ue_s1ap_id = str(enb_ue_s1ap_id)
            if mme_ue_s1ap_id is not None:
                sub.mme_ue_s1ap_id = str(mme_ue_s1ap_id)
            sub.state = "attached"
            sub.last_attach = time.time()
            sub.last_seen = time.time()
        return sub

    def mark_detached(self, imsi, reason=""):
        with self._lock:
            sub = self.subscribers.get(imsi)
            if sub is None:
                return
            sub.state = "detached"
            sub.extra["reason"] = reason
            sub.last_seen = time.time()
            # не удаляем ip, но помечаем
        return sub

    def mark_connecting(self, imsi):
        with self._lock:
            if imsi in self.subscribers:
                self.subscribers[imsi].state = "connecting"
                self.subscribers[imsi].last_seen = time.time()
        return True

    def get_subscribers(self):
        now = time.time()
        with self._lock:
            subs = [s.as_dict(now) for s in self.subscribers.values()]
            subs.sort(key=lambda x: x["state"] != "attached")  # подключённые выше
        return subs

    # ---------- базовые станции ----------
    def register_basestation(self, key, **fields):
        with self._lock:
            if key not in self.base_stations:
                self.base_stations[key] = BaseStation()
            bs = self.base_stations[key]
            for k, v in fields.items():
                if v is not None and hasattr(bs, k):
                    setattr(bs, k, v)
            if not bs.connected_at:
                bs.connected_at = time.time()
            bs.last_seen = time.time()
        return bs

    def get_base_stations(self):
        now = time.time()
        with self._lock:
            return [bs.as_dict(now) for bs in self.base_stations.values()]

    # ---------- события ----------
    def get_events(self, limit=100):
        with self._lock:
            return [e.as_dict() for e in list(self.events)[:limit]]

    def get_enb_metrics(self):
        with self._lock:
            return self.enb_metrics

    def set_enb_metrics(self, val):
        with self._lock:
            self.enb_metrics = val

    # ---------- сводка для дашборда ----------
    def snapshot(self):
        now = time.time()
        with self._lock:
            subs = self.get_subscribers()
            attached = sum(1 for s in subs if s["state"] == "attached")
            return {
                "mode": self.mode,
                "system": dict(self.system_info),
                "subscribers_count": len(subs),
                "attached_count": attached,
                "base_stations_count": len(self.base_stations),
                "base_stations": self.get_base_stations(),
                "metrics": self.enb_metrics,
                "uptime": round(now - self.system_info["started_at"], 1),
            }


    # ---------- SSE ----------
    def iter_events(self, last_event_ts=0.0, timeout=25):
        """Генератор событий для SSE. Возвращает события новее last_event_ts."""
        deadline = time.time() + timeout
        last_emit = last_event_ts
        while time.time() < deadline:
            with self._lock:
                events = [e for e in self.events if e.ts > last_emit]
                if events:
                    last_emit = max(e.ts for e in events)
                    yield events
                    continue
            # снимок состояния тоже отправляем периодически (heartbeat)
            yield None
            time.sleep(1.0)
