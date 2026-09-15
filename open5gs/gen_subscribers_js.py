#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генератор open5gs_subs.js из user_db.csv со СХЕМОЙ security:{} для Open5GS 2.7.x.
Чистый вывод (без '$set', без bash-подстановок): использует db.subscribers.save(doc).
KOPC плоский НЕ делаем — HSS 2.7 читает security:{k,opc,amf,sqn}.
"""
import csv, sys, re, json

COL = {"imsi": 2, "key": 3, "op_c": 5, "amf": 6, "sqn": 7, "qci": 8, "ip": 9}
DEMO = {"00112233445566778899aabbccddeeff",
        "a1b2c3d4e5f67890abcdef1234567890",
        "1234567890abcdef1234567890abcdef"}


def v(r, k):
    i = COL[k]
    return (r[i] if len(r) > i else "").strip()


def main():
    csv_path = sys.argv[1]
    apn = "IS2026.net"
    out = []
    out.append("var d = db.getSiblingDB('open5gs');")
    out.append("d.subscribers.deleteMany({});")
    n = 0
    with open(csv_path, encoding="utf-8-sig", errors="replace") as f:
        for r in csv.reader(x for x in f if not x.lstrip().startswith("#")):
            if not r:
                continue
            imsi = v(r, "imsi"); k = v(r, "key").lower(); opc = v(r, "op_c").lower()
            if not (re.fullmatch(r"\d{15}", imsi)
                    and re.fullmatch(r"[0-9a-f]{32}", k)
                    and re.fullmatch(r"[0-9a-f]{32}", opc)):
                out.append("print('skip %s');" % imsi)
                continue
            amf = v(r, "amf").lower() or "9000"
            if not re.fullmatch(r"[0-9a-f]{4}", amf):
                amf = "9000"
            qci = v(r, "qci") or "9"
            sqn = 0 if k in DEMO else int(v(r, "sqn") or "0", 16)
            ip = v(r, "ip")
            sess = {"name": apn, "type": 3,
                    "qos": {"index": int(qci) if qci.isdigit() else 9,
                            "arp": {"priority_level": 8,
                                    "pre_emption_capability": 1,
                                    "pre_emption_vulnerability": 1}},
                    "ambr": {"downlink": {"value": 1000000000, "unit": 0},
                             "uplink": {"value": 1000000000, "unit": 0}},
                    "pcc_rule": []}
            if ip and ip.lower() != "dynamic":
                sess["ue_ip"] = {"ipv4": ip}
            doc = {"imsi": imsi, "msisdn": [], "mme_host": [], "mme_realm": [],
                   "purge_flag": [],
                   "security": {"k": k, "amf": amf, "opc": opc, "sqn": sqn},
                   "slice": [{"sst": 1, "default_indicator": True, "session": [sess]}]}
            out.append("d.subscribers.replaceOne({imsi:%s}, %s, {upsert:true});"
                       % (json.dumps(imsi), json.dumps(doc)))
            n += 1
    out.append("print('loaded %d');" % n)
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
