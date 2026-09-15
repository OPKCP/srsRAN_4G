#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
open5gs/load_subscribers_security.py — загрузка абонентов user_db.csv (srsEPC)
в MongoDB Open5GS (v2.7.x) ПРАВИЛЬНОЙ схемой: ключи лежат во вложенном поле
  security: {k, opc, amf, sqn}
(плоский k/opc/amf на верхнем уровне HSS v2.7 НЕ читает -> "No 'security' field").

Запуск ВНУТРИ контейнера mongodb (там есть pymongo), csv примонтирован в /tmp/ud.csv.
Демо-ключи -> sqn=0. Иначе sqn из csv (hex -> int).
  docker exec -i open5gs-mongodb python3 /tmp/loader.py /tmp/ud.csv --apn IS2026.net
"""
import argparse
import csv
import re
import sys

import pymongo

COL = {"name": 0, "auth": 1, "imsi": 2, "key": 3, "op_type": 4,
       "op_c": 5, "amf": 6, "sqn": 7, "qci": 8, "ip_alloc": 9}

# набор тестовых ключей srsRAN (детеминированные) -> безопасный старт sqn=0
DEMO_KEYS = {
    "00112233445566778899aabbccddeeff",
    "a1b2c3d4e5f67890abcdef1234567890",
    "1234567890abcdef1234567890abcdef",
}


def val(row, k):
    i = COL[k]
    return (row[i] if len(row) > i else "").strip()


def build_doc(row, apn):
    imsi = val(row, "imsi")
    key = val(row, "key").lower()
    op_c = val(row, "op_c").lower()
    if not (re.fullmatch(r"\d{15}", imsi)
            and re.fullmatch(r"[0-9a-f]{32}", key)
            and re.fullmatch(r"[0-9a-f]{32}", op_c)):
        return None
    amf = val(row, "amf").lower() or "9000"
    if not re.fullmatch(r"[0-9a-f]{4}", amf):
        amf = "9000"
    qci = val(row, "qci") or "9"
    sqn_hex = val(row, "sqn").strip() or "0"
    sqn = 0 if key in DEMO_KEYS else int(sqn_hex, 16)
    ip = val(row, "ip_alloc")
    sec = {"k": key, "amf": amf, "opc": op_c, "sqn": sqn}
    doc = {
        "imsi": imsi,
        "msisdn": [],
        "mme_host": [],
        "mme_realm": [],
        "purge_flag": [],
        "security": sec,
        "slice": [{
            "sst": 1,
            "default_indicator": True,
            "session": [{
                "name": apn,
                "type": 3,
                "qos": {"index": int(qci) if qci.isdigit() else 9,
                        "arp": {"priority_level": 8,
                                "pre_emption_capability": 1,
                                "pre_emption_vulnerability": 1}},
                "ambr": {"downlink": {"value": 1000000000, "unit": 0},
                         "uplink": {"value": 1000000000, "unit": 0}},
                "pcc_rule": [],
            }],
        }],
    }
    if ip and ip.lower() != "dynamic":
        doc["slice"][0]["session"][0]["ue_ip"] = {"ipv4": ip}
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--mongodb", default="mongodb://127.0.0.1:27017/open5gs")
    ap.add_argument("--apn", default="IS2026.net")
    ap.add_argument("--drop", action="store_true")
    a = ap.parse_args()

    db = pymongo.MongoClient(a.mongodb).get_database()
    coll = db["subscribers"]
    if a.drop:
        coll.delete_many({})
        print("[info] subscribers очищена")
    n = 0
    with open(a.input, "r", encoding="utf-8-sig", errors="replace") as f:
        for row in csv.reader(r for r in f if not r.lstrip().startswith("#")):
            if not row:
                continue
            doc = build_doc(row, a.apn)
            if doc is None:
                print(f"[warn] пропуск: {row[:3]}")
                continue
            coll.update_one({"imsi": doc["imsi"]}, {"$set": doc}, upsert=True)
            n += 1
            print(f"  + {doc['imsi']} apn={a.apn} sec={doc['security']['k'][:6]}..")
    print(f"[done] {n}")


if __name__ == "__main__":
    main()
