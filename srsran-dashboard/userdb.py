"""userdb.py — редактирование пользовательской БД HSS (user_db.csv).

Предоставляет CRUD над записями LTE-абонентов файла user_db.csv ядра.
Используется дашбордом в epc-режиме. Файл лежит в каталоге config_epc
и пробрасывается в контейнер дашборда (DASH_USERDB_DIR).

Формат строки:
  Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc

Описание полей (на русском, для отображения в форме редактора):
  Name     — понятное имя абонента (HSS не использует)
  Auth     — алгоритм аутентификации: mil (MILENAGE) или xor
  IMSI     — IMSI абонента
  Key      — ключ абонента (hex)
  OP_Type  — тип операторского кода: op или opc
  OP/OPc   — операторский код/зашифрованный код (hex)
  AMF      — поле управления аутентификацией (hex)
  SQN      — счётчик последовательности
  QCI      — класс QoS для default-носителя
  IP_alloc — 'dynamic' либо статический IPv4
"""
import os
import re

# Каталог, где лежит user_db.csv (пробрасывается как volume)
USERDB_DIR = os.environ.get("DASH_USERDB_DIR", "/userdb")
USERDB_FILE = os.environ.get("DASH_USERDB_FILE", "user_db.csv")

# Метаописание полей для форм редактора
FIELD_META = [
    {"key": "name", "label": "Имя (Name)", "desc": "Понятное имя абонента. HSS игнорирует — только для удобства.",
     "default": "ue_new"},
    {"key": "auth", "label": "Алгоритм (Auth)", "desc": "Алгоритм аутентификации: mil — MILENAGE, xor — XOR.",
     "default": "mil"},
    {"key": "imsi", "label": "IMSI", "desc": "IMEI абонента (15 цифр). Уникален для каждой SIM.",
     "default": "250630000000006"},
    {"key": "key", "label": "Ключ (Key)", "desc": "Ключ абонента, из которого выводятся остальные ключи (hex).",
     "default": "1234567890abcdef1234567890abcdef"},
    {"key": "op_type", "label": "Тип кода (OP_Type)", "desc": "Тип операторского кода: op или opc.",
     "default": "opc"},
    {"key": "op", "label": "Операторский код (OP/OPc)", "desc": "Операторский код или зашифрованный код (hex).",
     "default": "fedcba9876543210fedcba9876543210"},
    {"key": "amf", "label": "AMF", "desc": "Поле управления аутентификацией (hex, 4 символа).",
     "default": "9000"},
    {"key": "sqn", "label": "Счётчик (SQN)", "desc": "Счётчик последовательности для свежести аутентификации (hex).",
     "default": "000000004936"},
    {"key": "qci", "label": "QCI", "desc": "Класс QoS для default-носителя (обычно 9).",
     "default": "9"},
    {"key": "ip", "label": "IP-адрес (IP_alloc)", "desc": "'dynamic' — SPGW сам выдаст IP, либо статический IPv4 (напр. 10.0.0.16).",
     "default": "10.0.0.16"},
]

_HEADER = """#
# .csv to store UE's information in HSS
# Kept in the following format: \"Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc\"
#
# Name:     Human readable name to help distinguish UE's. Ignored by the HSS
# Auth:     Authentication algorithm used by the UE. Valid algorithms are XOR
#           (xor) and MILENAGE (mil)
# IMSI:     UE's IMSI value
# Key:      UE's key, where other keys are derived from. Stored in hexadecimal
# OP_Type:  Operator's code type, either OP or OPc
# OP/OPc:   Operator Code/Cyphered Operator Code, stored in hexadecimal
# AMF:      Authentication management field, stored in hexadecimal
# SQN:      UE's Sequence number for freshness of the authentication
# QCI:      QoS Class Identifier for the UE's default bearer.
# IP_alloc: IP allocation stratagy for the SPGW.
#           With 'dynamic' the SPGW will automatically allocate IPs
#           With a valid IPv4 (e.g. '172.16.0.2') the UE will have a statically assigned IP.
#
# Note: Lines starting by '#' are ignored and will be overwritten
"""

_FIELDS = ["name", "auth", "imsi", "key", "op_type", "op", "amf", "sqn", "qci", "ip"]


class UserDbError(Exception):
    pass


def _path():
    return os.path.join(USERDB_DIR, USERDB_FILE)


def _disabled_prefix(record):
    """Если запись 'выключена', помечаем спецпрефиксом в начале имени."""
    return record.get("_disabled", False)


_DIS_PREFIX = "#DISABLED:"  # префикс выключенной записи (строка-комментарий для HSS)


def _record_from_line(line):
    """Разобрать строку CSV в dict. Строки-комментарии -> None."""
    line = line.rstrip("\n")
    disabled = False
    if line.startswith("#DISABLED:"):
        disabled = True
        line = line[len("#DISABLED:"):]
    elif not line.strip() or line.strip().startswith("#"):
        return None
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 10:
        parts += [""] * (10 - len(parts))
    rec = {
        "name": parts[0],
        "auth": parts[1],
        "imsi": parts[2],
        "key": parts[3],
        "op_type": parts[4],
        "op": parts[5],
        "amf": parts[6],
        "sqn": parts[7],
        "qci": parts[8],
        "ip": parts[9],
        "_disabled": disabled,
    }
    return rec


def _line_from_record(rec):
    return ",".join([
        rec["name"], rec["auth"], rec["imsi"], rec["key"], rec["op_type"],
        rec["op"], rec["amf"], rec["sqn"], rec["qci"], rec["ip"],
    ])


def list_records():
    """Список записей из файла. {ok, records:[{...поля, enabled, disabled}], error?}"""
    path = _path()
    if not os.path.exists(path):
        return {"ok": False, "records": [], "error": f"файл {path} не найден"}
    records = []
    with open(path, "r", errors="replace") as f:
        for line in f:
            rec = _record_from_line(line)
            if rec is None:
                continue
            rec["enabled"] = not rec["_disabled"]
            records.append(rec)
    return {"ok": True, "records": records}


def _write_all(records):
    """Записать список записей в файл (с шапкой)."""
    path = _path()
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(_HEADER)
        for rec in records:
            prefix = _DIS_PREFIX if rec.get("_disabled") else ""
            line = _line_from_record(rec)
            f.write(prefix + line + "\n")
    os.replace(tmp, path)


def get_record(imsi):
    data = list_records()
    for rec in data.get("records", []):
        if rec["imsi"] == imsi:
            return {"ok": True, "record": rec}
    return {"ok": False, "error": f"запись с IMSI {imsi} не найдена"}


def _normalize(payload):
    """Вытащить поля из payload с дефолтами."""
    rec = {}
    for f in _FIELDS:
        meta = FIELD_META[_FIELDS.index(f)]
        rec[f] = (payload.get(f) or meta["default"]).strip()
    return rec


def _validate(rec):
    """Минимальная валидация. Возвращает None или строку ошибки."""
    if not re.fullmatch(r"\d{15}", rec["imsi"]):
        return "IMSI должен быть 15 цифр"
    if rec["auth"] not in ("mil", "xor"):
        return "Auth должен быть 'mil' или 'xor'"
    if rec["op_type"] not in ("op", "opc"):
        return "OP_Type должен быть 'op' или 'opc'"
    if not re.fullmatch(r"[0-9a-fA-F]{32}", rec["key"]):
        return "Key должен быть 32 hex-символа"
    if not re.fullmatch(r"[0-9a-fA-F]{32}", rec["op"]):
        return "OP/OPc должен быть 32 hex-символа"
    if not re.fullmatch(r"[0-9a-fA-F]{4}", rec["amf"]):
        return "AMF должен быть 4 hex-символа"
    if not re.fullmatch(r"[0-9a-fA-F]{8,16}", rec["sqn"]):
        return "SQN должен быть hex (от 8 символов)"
    if rec["ip"] not in ("dynamic",) and not re.fullmatch(
            r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}", rec["ip"]):
        return "IP_alloc должен быть 'dynamic' или IPv4"
    return None


def add_record(payload):
    """Добавить новую запись. {ok, error?}"""
    rec = _normalize(payload)
    err = _validate(rec)
    if err:
        return {"ok": False, "error": err}
    data = list_records()
    for r in data.get("records", []):
        if r["imsi"] == rec["imsi"]:
            return {"ok": False, "error": f"IMSI {rec['imsi']} уже существует"}
    data["records"].append(rec)
    _write_all(data["records"])
    return {"ok": True, "record": rec}


def update_record(imsi, payload):
    """Обновить существующую запись по IMSI. {ok, error?}"""
    data = list_records()
    found = None
    for idx, r in enumerate(data.get("records", [])):
        if r["imsi"] == imsi:
            found = idx
            break
    if found is None:
        return {"ok": False, "error": f"запись с IMSI {imsi} не найдена"}
    updated = _normalize(payload)
    err = _validate(updated)
    if err:
        return {"ok": False, "error": err}
    # Проверка на дубликат IMSI (если сменили на существующий другой)
    for idx, r in enumerate(data["records"]):
        if r["imsi"] == updated["imsi"] and idx != found:
            return {"ok": False, "error": f"IMSI {updated['imsi']} уже используется другой записью"}
    updated["_disabled"] = data["records"][found].get("_disabled", False)
    data["records"][found] = updated
    _write_all(data["records"])
    return {"ok": True, "record": updated}


def delete_record(imsi):
    """Удалить запись по IMSI. {ok, error?}"""
    data = list_records()
    new_records = [r for r in data.get("records", []) if r["imsi"] != imsi]
    if len(new_records) == len(data.get("records", [])):
        return {"ok": False, "error": f"запись с IMSI {imsi} не найдена"}
    _write_all(new_records)
    return {"ok": True, "imsi": imsi}


def set_enabled(imsi, enabled):
    """Включить/выключить запись. {ok, error?}"""
    data = list_records()
    found = None
    for idx, r in enumerate(data.get("records", [])):
        if r["imsi"] == imsi:
            found = idx
            break
    if found is None:
        return {"ok": False, "error": f"запись с IMSI {imsi} не найдена"}
    data["records"][found]["_disabled"] = not enabled
    _write_all(data["records"])
    return {"ok": True, "imsi": imsi, "enabled": enabled}
