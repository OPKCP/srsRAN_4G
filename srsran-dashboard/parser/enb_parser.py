"""Парсер логов базовой станции (srsenb) и файла метрик eNB.

Два источника:
1. Журнал консоли/файла srsenb (log.file / stdout). Парсит старт eNB,
   статус радио, подключение к ядру (S1), сообщения об абонентах (RNTI).
2. Файл метрик eNB (metrics_json → report_json_filename, по умолчанию
   /tmp/enb_report.json). Содержит по каждому UE: rnti, dl_cqi, dl/ul_mcs,
   dl/ul_bitrate, dl/ul_bler, ul_snr и т.п. Обновляется ядром eNB периодически.

Основная ценность для дашборда — метрики в реальном времени (активные
абоненты, их мощность/скорости/ошибки) — приходят именно из JSON-метрик.
"""
import glob
import json
import os
import re

RE_LINE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:.]+)\s+\[(?P<mod>[A-Za-z0-9]+)\s*\]\s+\[(?P<lvl>[IDWE])\]\s+(?P<msg>.*)$"
)
RE_STARTED = re.compile(r"eNodeB started|SRS eNodeB started", re.IGNORECASE)
RE_RF_OPEN = re.compile(r"RF device successfully opened|RF device opened", re.IGNORECASE)
RE_S1_CONN = re.compile(r"S1 (Setup|connection) (request|success|established)", re.IGNORECASE)
RE_UE_ATTACH = re.compile(r"(?:RRC connection|UE.*attach|new UE|UE.*connected)", re.IGNORECASE)
RE_UE_RNTI = re.compile(r"RNTI:\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]+)", re.IGNORECASE)
# S1-U: видна активность абонента по IP (GTP-U SDU).
# "Tx S1-U SDU, UL > 192.168.1.16:0x5, rnti=0x4a, ... IPv4 10.0.0.15 > 87.250.251.15"
RE_GTPU1 = re.compile(r"(?:Tx|Rx)\s+S1-U SDU[^\n]*?IPv4\s+([\d.]+)", re.IGNORECASE)
RE_GTPU_DL = re.compile(r"Rx S1-U SDU[^\n]*?IPv4\s+[\d.]+\s*>\s*([\d.]+)", re.IGNORECASE)


class EnbParser:
    def __init__(self, store, log_path, metrics_path):
        self.store = store
        self.log_path = log_path
        self.metrics_path = metrics_path
        self._last_offset = 0
        self._active_path = None
        self._metrics_offset = 0

    # ---------------- лог srsenb ----------------
    def handle_line(self, line):
        if line.strip():
            self.store.add_tail(line)
        m = RE_LINE.match(line)
        if not m:
            return False
        msg = m.group("msg")

        if RE_STARTED.search(msg):
            self.store.add_event("success", "enb", "system", "Базовая станция запущена (eNodeB started)")
            return True
        if RE_RF_OPEN.search(msg):
            self.store.add_event("info", "enb", "system", "Радиоинтерфейс (RF) открыт")
            return True
        if RE_S1_CONN.search(msg):
            self.store.add_event("info", "enb", "bs", "Установлено S1-соединение с ядром")
            return True
        if RE_UE_ATTACH.search(msg):
            rnti = ""
            mm = RE_UE_RNTI.search(msg)
            if mm:
                rnti = mm.group(1)
            self.store.add_event("info", "enb", "attach",
                                 f"Попытка подключения абонента на стороне БС (RNTI {rnti})")
            return True

        # Активность абонента по S1-U (UL/DL трафик). На стороне eNB IMSI
        # неизвестен, известен только абонентский IP (из пула 10.0.0.0/24).
        gtpu_m = RE_GTPU1.search(msg)
        if gtpu_m:
            ip = gtpu_m.group(1)
            if ip.startswith(("10.", "192.168.")):
                # отмечаем активного абонента (ключ = IP, IMSI не известна)
                if ip not in self.store.subscribers or self.store.subscribers[ip].state != "attached":
                    self.store.add_event("info", "enb", "attach",
                                         f"Активность абонента по IP {ip} (трафик S1-U)")
                self.store.mark_attach(imsi=ip, ip=ip, enb_ue_s1ap_id="eNB")
            return True
        return False
# ---------------- выбор активного файла ----------------
    def _resolve_log_path(self):
        """Вернуть активный файл лога.

        srsenb ротирует лог в enb.N.log (при достижении file_max_size),
        а enb.log может остаться от прошлого запуска. Чтобы дашборд всегда
        показывал текущий поток, среди ротируемых 'enb*.log' выбираем самый
        свежий по времени изменения.
        """
        if not self.log_path:
            return None
        # если это ротируемый лог eNB — всегда берём самый свежий enb.*.log в каталоге
        base = os.path.basename(self.log_path)
        if re.match(r'^enb.*\.log$', base):
            d = os.path.dirname(self.log_path)
            pattern = os.path.join(d, 'enb*.log')
            candidates = glob.glob(pattern)
            if candidates:
                return max(candidates, key=os.path.getmtime)
        return self.log_path if os.path.exists(self.log_path) else None

    def read_new(self):
        path = self._resolve_log_path()
        if not path or not os.path.exists(path):
            return 0
        size = os.path.getsize(path)
        if path != self._active_path:
            # сменился активный файл (ротация/старт) — читаем с начала
            self._active_path = path
            self._last_offset = 0
        if size < self._last_offset:
            self._last_offset = 0
        with open(path, "r", errors="replace") as f:
            f.seek(self._last_offset)
            data = f.read()
            self._last_offset = f.tell()
        if not data:
            return 0
        self.store.update_log_state(path,
                                    os.path.getmtime(path),
                                    self._last_offset,
                                    True)
        handled = 0
        for line in data.splitlines():
            if self.handle_line(line):
                handled += 1
        return handled

    # ---------------- метрики eNB (JSON) ----------------
    def parse_metrics(self):
        """Прочитать файл метрик eNB (JSON-список UE) и сохранить в store.

        Возможные структуры файла (в зависимости от версии srsenb):
        - список UE: [ {ue_rnti, dl_cqi, dl_bitrate, dl_bler, ul_snr, ...}, ... ]
        - объект { "ams" : [...] } и т.п.
        Здесь производим мягкое приведение.
        """
        if not self.metrics_path or not os.path.exists(self.metrics_path):
            return None
        try:
            with open(self.metrics_path, "r", errors="replace") as f:
                raw = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            self.store.add_event("warn", "enb", "metric", f"Не удалось прочитать метрики eNB: {e}")
            return None

        # приведём к списку UE
        ue_list = _extract_ue_list(raw)
        snapshot = {
            "ts": os.path.getmtime(self.metrics_path),
            "ues": ue_list,
            "ue_count": len(ue_list),
        }
        self.store.set_enb_metrics(snapshot)
        return snapshot


def _extract_ue_list(raw):
    """Найти список UE в произвольной структуре JSON."""
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        # частые ключи контейнеров UE
        for key in ("ue_list", "ues", "UE", "ues_container", "mq"):
            v = raw.get(key)
            if isinstance(v, list):
                return v
        # иначе: первый найденный список, состоящий из dict
        for v in raw.values():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                return v
    return []
