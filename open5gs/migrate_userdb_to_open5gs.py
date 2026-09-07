#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
migrate_userdb_to_open5gs.py — перенос абонентов из user_db.csv (srsEPC HSS) в формат,
понятный для добавления в Open5GS (WebUI / mongodb).

Формат входного user_db.csv (srsEPC):
    Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc

Open5GS хранит субскрипции в MongoDB (коллекции subscriber), c полями:
    - imsi            (str, 15 цифр)
    - k               (str, hex ключ, 32 символа)
    - op / opc        (Operator Key / Ciphered Operator Key, 32 hex)
    - amf             (hex, 4 символа, по умолчанию "8000")
    - sqn             (hex-строка, начальный SQN)
    - apn_list        (список APN)
    - slice           (5GC, не обязателен для 4G EPC)
    - static ip при необходимости (UE IP)

Скрипт выдаёт:
  1) JSON-строки в формате Open5GS subscriber (можно вставить в WebUI или импортировать);
  2) опционально CSV для ручной сверки;
  3) предупреждение, если IMSI/ключи не соответствуют ожидаемому формату.

Использование:
    python3 migrate_userdb_to_open5gs.py path/to/user_db.csv [--out output.json] [--apn IS2026.net] [--print]
"""
import argparse
import csv
import json
import re
import sys

IMSI_RE = re.compile(r"^\d{15}$")
HEX32_RE = re.compile(r"^[0-9a-fA-F]{32}$")
AMF_RE = re.compile(r"^[0-9a-fA-F]{4}$")
SQN_RE = re.compile(r"^[0-9a-fA-F]+$")


def parse_sqn(raw: str) -> str:
    """Приводим SQN к 6-байтной hex-строке (12 hex-символов, как ожидает Open5GS при аутентификации).
    Если значение короче — дополняем слева нулями.
    """
    raw = raw.strip()
    # srsEPC пишет SQN как hex-число без ведущих нулей (например 0x1914 или "000000001914")
    val = raw[2:] if raw.lower().startswith(("0x", "0h")) else raw
    val = val.upper()
    # Оставляем только hex-символы
    val = re.sub(r"[^0-9A-F]", "", val)
    # Open5GS ожидает SQN обычно как hex-строку (не менее 6 байт у milenage)
    while len(val) < 12:
        val = "0" + val
    return val.upper()


# Порядок колонок в user_db.csv (srsEPC HSS):
#   Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc
# Индексы колонок (0-based).
COL = {
    "name": 0,
    "auth": 1,
    "imsi": 2,
    "key": 3,
    "op_type": 4,
    "op_c": 5,
    "amf": 6,
    "sqn": 7,
    "qci": 8,
    "ip_alloc": 9,
}


def _row_val(row, col_key):
    """Безопасно берём значение колонки из строки csv."""
    idx = COL[col_key]
    return (row[idx] if len(row) > idx else "").strip()


def convert_k_opc_to_open5gs(input_path: str, apn: str):
    rows_out = []
    warnings = []

    with open(input_path, "r", encoding="utf-8-sig", errors="replace") as f:
        reader = csv.reader(row for row in f if not row.lstrip().startswith("#"))

        for i, row in enumerate(reader, start=1):
            if not row:
                continue
            name = _row_val(row, "name")
            auth = _row_val(row, "auth").lower()
            imsi = _row_val(row, "imsi")
            key = _row_val(row, "key")
            op_type = _row_val(row, "op_type").lower()
            op_c = _row_val(row, "op_c")
            amf = _row_val(row, "amf")
            sqn = _row_val(row, "sqn")
            qci = _row_val(row, "qci")
            ip_alloc = _row_val(row, "ip_alloc")

            if not imsi:
                warnings.append(f"строка {i}: пропущена (пустой IMSI)")
                continue
            if not IMSI_RE.match(imsi):
                warnings.append(f"строка {i}: IMSI '{imsi}' не 15 цифр — пропущена")
                continue
            if not HEX32_RE.match(key):
                warnings.append(f"строка {i}: IMSI {imsi}: Key не 32 hex — пропущена")
                continue
            if not HEX32_RE.match(op_c):
                warnings.append(f"строка {i}: IMSI {imsi}: OP/OPc не 32 hex — пропущена")
                continue

            sub = {
                "imsi": imsi,
                "k": key.lower(),
                "amf": (amf if AMF_RE.match(amf) else "8000").lower(),
                "sqn": parse_sqn(sqn) if sqn else "000000000000",
                "apn_list": [{"apn": apn, "qci": int(qci) if qci.isdigit() else 9}],
            }
            # OP vs OPc: Open5GS поддерживает поля op и opc. Если используется opc — кладём в opc.
            if op_type in ("opc", "op"):
                sub["opc" if op_type == "opc" else "op"] = op_c.lower()
            else:
                # По умолчанию в стенде используется opc
                sub["opc"] = op_c.lower()

            # Статический IP (не 'dynamic')
            if ip_alloc and ip_alloc.lower() != "dynamic":
                # Open5GS поддерживает статический IP через поле '__scs' нестандартно;
                # в WebUI статический IP задаётся отдельно. Добавляем справочно.
                sub["static_ip"] = ip_alloc

            if name:
                sub["_comment"] = name  # служебное поле, не уходит в Open5GS как есть

            rows_out.append(sub)

    return rows_out, warnings


def main():
    ap = argparse.ArgumentParser(description="Перенос user_db.csv (srsEPC) → Open5GS subscribers")
    ap.add_argument("input", help="путь к user_db.csv")
    ap.add_argument("--out", help="выходной JSON-файл (иначе — stdout)")
    ap.add_argument("--apn", default="IS2026.net", help="APN для субскрипций")
    ap.add_argument("--print", action="store_true", help="печатать JSON в stdout")
    args = ap.parse_args()

    rows, warnings = convert_k_opc_to_open5gs(args.input, args.apn)

    for w in warnings:
        print(f"[WARN] {w}", file=sys.stderr)

    payload = {"subscribers": rows, "count": len(rows), "apn": args.apn}
    text = json.dumps(payload, ensure_ascii=False, indent=2)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"[OK] Записано {len(rows)} абонентов в {args.out}")
    else:
        print(text)

    print(f"[DONE] Всего обработано абонентов: {len(rows)}", file=sys.stderr)


if __name__ == "__main__":
    main()
