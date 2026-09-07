#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
load_subscribers_pymongo.py — загрузка абонентов из user_db.csv (srsEPC HSS)
в MongoDB Open5GS через pymongo (для pi5, где удобнее python, чем mongosh).

Поля документа соответствуют схеме Open5GS (см. open5gs/misc/db/open5gs-dbctl):

    db = mongodb://127.0.0.1:27017/open5gs
    collection = subscribers

Использование:
    pip3 install pymongo
    python3 load_subscribers_pymongo.py /path/user_db.csv \
        --mongodb mongodb://127.0.0.1:27017/open5gs --apn IS2026.net

Входной CSV (srsEPC): Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc
"""
import argparse
import csv
import re
import sys

import pymongo


COL = {
    "name": 0, "auth": 1, "imsi": 2, "key": 3, "op_type": 4,
    "op_c": 5, "amf": 6, "sqn": 7, "qci": 8, "ip_alloc": 9,
}


def val(row, k):
    i = COL[k]
    return (row[i] if len(row) > i else "").strip()


def build_doc(row, apn):
    imsi = val(row, "imsi")
    key = val(row, "key")
    op_c = val(row, "op_c")
    if not (re.fullmatch(r"\d{15}", imsi) and re.fullmatch(r"[0-9a-fA-F]{32}", key)
            and re.fullmatch(r"[0-9a-fA-F]{32}", op_c)):
        return None
    amf = val(row, "amf") or "9000"
    if not re.fullmatch(r"[0-9a-fA-F]{4}", amf):
        amf = "9000"
    qci = val(row, "qci") or "9"
    ip = val(row, "ip_alloc")
    doc = {
        "schema_version": 1,
        "imsi": imsi,
        "msisdn": [],
        "imeisv": [],
        "mme_host": [],
        "mm_realm": [],
        "purge_flag": [],
        "k": key.lower(),
        "opc": op_c.lower(),
        "amf": amf.lower(),
        "sqn": 0,
        "slice": [
            {
                "sst": 1,
                "default_indicator": True,
                "session": [
                    {
                        "name": apn,
                        "type": 3,
                        "qos": {
                            "index": int(qci) if qci.isdigit() else 9,
                            "arp": {"priority_level": 8, "pre_emption_capability": 1, "pre_emption_vulnerability": 1},
                        },
                        "ambr": {
                            "downlink": {"value": 1000000000, "unit": 0},
                            "uplink": {"value": 1000000000, "unit": 0},
                        },
                        "pcc_rule": [],
                    }
                ],
            }
        ],
    }
    if ip and ip.lower() != "dynamic":
        doc["static_ip"] = ip
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="путь к user_db.csv")
    ap.add_argument("--mongodb", default="mongodb://127.0.0.1:27017/open5gs")
    ap.add_argument("--apn", default="IS2026.net")
    ap.add_argument("--drop", action="store_true", help="очистить коллекцию subscribers перед загрузкой")
    args = ap.parse_args()

    client = pymongo.MongoClient(args.mongodb)
    db = client.get_database()
    coll = db["subscribers"]
    if args.drop:
        coll.delete_many({})
        print("[info] коллекция subscribers очищена")

    count = 0
    with open(args.input, "r", encoding="utf-8-sig", errors="replace") as f:
        reader = csv.reader(row for row in f if not row.lstrip().startswith("#"))
        for row in reader:
            if not row:
                continue
            doc = build_doc(row, args.apn)
            if doc is None:
                print(f"[warn] пропуск строки: {row[COL['imsi']] if len(row) > COL['imsi'] else ''}")
                continue
            coll.update_one({"imsi": doc["imsi"]}, {"$set": doc}, upsert=True)
            count += 1
            print(f"  + {doc['imsi']} ({doc['k'][:8]}...) apn={args.apn}")

    print(f"[done] загружено/обновлено абонентов: {count}")


if __name__ == "__main__":
    main()
