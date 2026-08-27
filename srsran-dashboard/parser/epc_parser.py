"""Парсер логов ядра сети (srsepc).

Разбирает построчно файл лога EPC (обычно epc.log), извлекая значимые
события для дашборда:

- Подключение базовой станции (S1 Setup Request) → регистрация БС.
- Attach request (IMSI / M-TMSI) → абонент в состоянии "connecting".
- Успешный attach: "IMSI: <...>, UE IP: <...>" → абонент подключён (+IP).
- Удаление сессии / release / нет контекста → пометка отключения.
- Ошибки аутентификации (User not found / Authentication failure).

Устойчив к росту файла: отслеживает смещение (offset) и положение в файле,
чтобы при перезапуске srsepc (файл пересоздаётся) обрабатывать заново.
"""
import os
import re
import time

# ---------------------------------------------------------------------------
# Регулярные выражения для ключевых сообщений srsepc
# ---------------------------------------------------------------------------

# 2026-08-25T11:10:27.279950 [EPC    ] [I] ...
RE_LINE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T[\d:.]+)\s+\[(?P<mod>[A-Z0-9]+)\s*\]\s+\[(?P<lvl>[IDWE])\]\s+(?P<msg>.*)$"
)

# S1 Setup Request (подключилась базовая станция)
RE_S1_SETUP = re.compile(r"Received S1 Setup Request", re.IGNORECASE)
RE_S1_SETUP_DETAIL = re.compile(
    r"(?:Global eNB ID|eNB ID|gNB ID|eNB Name|PLMN|MCC|MNC|TAC)[ :]*(\S+)", re.IGNORECASE
)

# Attach request -- IMSI: 250630000000004
RE_ATTACH_IMSI = re.compile(r"Attach request[^\n]*?IMSI:\s*(\d{15})", re.IGNORECASE)
# Attach request -- M-TMSI: 0x...
RE_ATTACH_MTMSI = re.compile(r"Attach request[^\n]*?M-TMSI:\s*(0x[0-9a-fA-F]+)", re.IGNORECASE)

# Начало attach (Initial UE message -- Attach Request)
RE_INITIAL_ATTACH = re.compile(r"Initial UE message[^\n]*?Attach Request", re.IGNORECASE)

# Успешный attach: "IMSI: 250630000000004, UE IP: 10.0.0.14"
RE_UE_IP = re.compile(r"IMSI:\s*(\d{15})\s*,\s*UE IP:\s*([\d.]+)", re.IGNORECASE)

# GTP-C создание контекста / модификация bearer
RE_CREATE_SESSION = re.compile(r"SPGW Received Create Session Request", re.IGNORECASE)

# Detach
RE_DETACH = re.compile(r"(?:Detach Request|Detach Accept|detach)", re.IGNORECASE)
# Release UE context
RE_RELEASE_CONTEXT = re.compile(r"UE Context Release Request", re.IGNORECASE)
RE_DELETE_SESSION = re.compile(r"Delete Session|delete session", re.IGNORECASE)

# Ошибки аутентификации
RE_USER_NOT_FOUND = re.compile(r"User not found\.?\s*IMSI:\s*(\d{15})", re.IGNORECASE)
RE_AUTH_FAIL = re.compile(r"(Authentication failure|Sync failure|Auth.*fail)", re.IGNORECASE)

# Failed attach (Attach reject)
RE_ATTACH_REJECT = re.compile(r"Attach (reject|Reject)", re.IGNORECASE)

# eNB прислал S1AP UE context setup / Initial Context Setup
RE_CTX_SETUP = re.compile(r"Initial Context Setup Request", re.IGNORECASE)

# HSS: добавление пользователя из БД (известные SIM ядра).
#   "Added user from DB, IMSI: 250630000000001"
RE_HSS_ADD = re.compile(r"Added user from DB,?\s*IMSI:\s*(\d{15})", re.IGNORECASE)
# HSS: статический IP абонента (следующая строка после добавления).
#   "static ip addr 10.0.0.11"
RE_HSS_IP = re.compile(r"static ip addr\s+([\d.]+)", re.IGNORECASE)


class EpcParser:
    def __init__(self, store, log_path):
        self.store = store
        self.log_path = log_path
        self._last_offset = 0
        self._known_imsi_seen = False
        self._imsi_names = {}   # imsi -> имя/коммент из user_db (опционально)
        self._last_hss_imsi = None
        self._pending_hss_ip = None

    def _log(self, line):
        self.store.add_tail(line)

    def _parse_kv(self, re_match, re_detail, line):
        """Попытка вытащить детали (enb id/assoc) из контекста."""
        return {}

    def handle_line(self, line):
        """Разобрать одну строку лога EPC. Возвращает True, если событие обработано."""
        # сохраняем строку для просмотра
        if line.strip():
            self._log(line)

        m = RE_LINE.match(line)
        if not m:
            return False
        msg = m.group("msg")
        lvl = m.group("lvl")

        # --- Подключение базовой станции ---
        if RE_S1_SETUP.search(msg):
            key = "s1"
            self.store.register_basestation("default", name="eNB (S1)")
            self.store.add_event("success", "epc", "bs",
                                 "Базовая станция подключилась (S1 Setup Request)")
            return True

        # --- HSS: известные абоненты из БД ядра ---
        hss_m = RE_HSS_ADD.search(msg)
        if hss_m:
            imsi = hss_m.group(1)
            self._last_hss_imsi = imsi
            self.store.register_subscriber(imsi, state="unknown")
            # статический IP идёт следующей строкой — запомним как "ожидаемый"
            return True

        hss_ip_m = RE_HSS_IP.search(msg)
        if hss_ip_m:
            # сопоставляем статический IP с последним добавленным абонентом
            if self._last_hss_imsi:
                self.store.register_subscriber(self._last_hss_imsi,
                                               ip=hss_ip_m.group(1),
                                               extra={**self.store.subscribers.get(self._last_hss_imsi, {}).extra,
                                                      "static_ip": hss_ip_m.group(1)})
            return True

        # --- Attach request ---
        imsi_m = RE_ATTACH_IMSI.search(msg)
        if imsi_m:
            imsi = imsi_m.group(1)
            self.store.register_subscriber(imsi)
            self.store.mark_connecting(imsi)
            self.store.add_event("info", "epc", "attach",
                                 f"Запрос подключения (attach) от IMSI {imsi}")
            return True

        mtmsi_m = RE_ATTACH_MTMSI.search(msg)
        if mtmsi_m:
            self.store.add_event("info", "epc", "attach",
                                 f"Запрос подключения по GUTI (M-TMSI {mtmsi_m.group(1)})")
            return True

        # --- Успешный attach: выдан IP ---
        ip_m = RE_UE_IP.search(msg)
        if ip_m:
            imsi = ip_m.group(1)
            ip = ip_m.group(2)
            self.store.mark_attach(imsi, ip=ip)
            self.store.add_event("success", "epc", "attach",
                                 f"Абонент подключён: IMSI {imsi}, IP {ip}")
            return True

        # --- Создание сессии (начало) ---
        if RE_CREATE_SESSION.search(msg) or RE_CTX_SETUP.search(msg):
            self.store.add_event("info", "epc", "attach",
                                 "Создание сессии (bearer) для абонента")
            return True

        # --- Ошибки аутентификации ---
        unf_m = RE_USER_NOT_FOUND.search(msg)
        if unf_m:
            self.store.register_subscriber(unf_m.group(1))
            self.store.mark_detached(unf_m.group(1), reason="пользователь не найден в БД")
            self.store.add_event("error", "epc", "attach",
                                 f"Аутентификация не удалась: IMSI {unf_m.group(1)} не найден в БД")
            return True

        if RE_AUTH_FAIL.search(msg):
            self.store.add_event("warn", "epc", "attach",
                                 "Ошибка аутентификации (возможен Sync failure)")
            return True

        # --- Detach / release ---
        if RE_DETACH.search(msg):
            self.store.add_event("info", "epc", "detach", "Запрос на отключение (detach)")
            return True
        if RE_RELEASE_CONTEXT.search(msg):
            self.store.add_event("info", "epc", "detach",
                                 "Ядро освободило контекст абонента (UE Context Release)")
            return True
        if RE_DELETE_SESSION.search(msg):
            self.store.add_event("info", "epc", "detach", "Сессия абонента удалена")
            return True

        return False

    def parse_tail(self, text):
        """Разобрать весь кусок текста построчно."""
        handled = 0
        for line in text.splitlines(keepends=True):
            if self.handle_line(line):
                handled += 1
        return handled

    def read_new(self):
        """Прочитать новые строки с конца файла. Возвращает число обработанных событий."""
        if not os.path.exists(self.log_path):
            return 0
        size = os.path.getsize(self.log_path)
        if size < self._last_offset:
            # файл обрезан/пересоздан — начинаем сначала
            self._last_offset = 0
        with open(self.log_path, "r", errors="replace") as f:
            f.seek(self._last_offset)
            data = f.read()
            self._last_offset = f.tell()
        if not data:
            return 0
        self.store.update_log_state(self.log_path,
                                    os.path.getmtime(self.log_path),
                                    self._last_offset,
                                    True)
        return self.parse_tail(data)

    def set_imsi_name(self, imsi, name):
        self._imsi_names[imsi] = name
