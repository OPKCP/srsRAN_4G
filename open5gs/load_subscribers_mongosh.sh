#!/usr/bin/env bash
# ==============================================================================
# load_subscribers_mongosh.sh — загрузка абонентов srsEPC (user_db.csv) в
# MongoDB Open5GS с помощью mongosh (MongoDB 6.x).
#
# Использование:
#   MONGODB_URI=mongodb://127.0.0.1:27017/open5gs \
#     ./load_subscribers_mongosh.sh /path/to/user_db.csv
#
# Примечание: Open5GS хранит субскрипции в коллекции `subscribers` БД `open5gs`.
# Формат документа (схема) должен соответствовать открытому5GS (misc/db/open5gs-dbctl).
# Данные берутся из user_db.csv srsEPC: Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc.
# ==============================================================================
set -euo pipefail

MONGODB_URI="${MONGODB_URI:-mongodb://127.0.0.1:27017/open5gs}"
APN="${APN:-IS2026.net}"
CSV="${1:?укажите путь к user_db.csv}"

MONGOSH_BIN="${MONGOSH_BIN:-mongosh}"

# Генерируем JS-скрипт для mongosh
tmp_js="$(mktemp --suffix=.js)"

python3 - "$CSV" "$APN" "$tmp_js" <<'PYEOF'
import csv, sys, re, json

csv_path, apn, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

COL = {"imsi":2,"key":3,"op_c":5,"amf":6,"sqn":7,"qci":8,"ip":9}

def val(row,k):
    i=COL[k]
    return (row[i] if len(row)>i else "").strip()

lines = ["db = db.getSiblingDB('open5gs');"]
count = 0

with open(csv_path, "r", encoding="utf-8-sig", errors="replace") as f:
    reader = csv.reader(row for row in f if not row.lstrip().startswith("#"))
    for row in reader:
        if not row:
            continue
        imsi = val(row,"imsi")
        key  = val(row,"key")
        op_c = val(row,"op_c")
        if not (re.fullmatch(r"\d{15}", imsi) and re.fullmatch(r"[0-9a-fA-F]{32}", key) and re.fullmatch(r"[0-9a-fA-F]{32}", op_c)):
            print(f"[warn] skip invalid row: {imsi}", file=sys.stderr)
            continue
        amf = val(row,"amf") or "9000"
        if not re.fullmatch(r"[0-9a-fA-F]{4}", amf):
            amf = "9000"
        qci = val(row,"qci") or "9"
        ip  = val(row,"ip")
        static = {} if (not ip or ip.lower()=="dynamic") else {"static_ip": ip}
        # Документ в схеме Open5GS (как в open5gs-dbctl): slice/session
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
                            "qos": {"index": int(qci), "arp": {"priority_level": 8, "pre_emption_capability": 1, "pre_emption_vulnerability": 1}},
                            "ambr": {"downlink": {"value": 1000000000, "unit": 0}, "uplink": {"value": 1000000000, "unit": 0}},
                            "pcc_rule": [],
                            "_id": {"$oid": ""},   # будет заполнено ObjectId ниже
                        }
                    ],
                    "_id": {"$oid": ""},
                }
            ],
            **static,
        }
        # JSON -> JS: ObjectId
        js = json.dumps(doc, ensure_ascii=False)
        js = js.replace('"_id": {"$oid": ""}', "_id: ObjectId()")
        lines.append(f"db.subscribers.updateOne({{imsi:'{imsi}'}}, {{$set:{js}}}, {{upsert:true}});")
        count += 1

with open(out_path,"w",encoding="utf-8") as f:
    f.write("\n".join(lines)+"\n")

print(f"[info] prepared {count} subscribers -> {out_path}", file=sys.stderr)
PYEOF

echo "[run] $MONGOSH_BIN $MONGODB_URI $tmp_js"
"$MONGOSH_BIN" "$MONGODB_URI" "$tmp_js"
rm -f "$tmp_js"
echo "[done] абоненты загружены в Open5GS MongoDB"
