# open5gs/ — задел по переходу ядра сети на Open5GS

Этот каталог содержит подготовительные артефакты для замены `srsepc` на **Open5GS**
с целью получения рабочего **S1-хендовера** между БС1 (Base5) и БС2 (pi5-2).

> ⚠️ **ВНИМАНИЕ (2026-09-07):** pi4 вышло из строя. Ядро планируется разворачивать
> на **pi5-2 (192.168.1.26)**. Итоговые значения IP/PLMN/TAC сверяйте с фактической
> конфигурацией БС перед запуском.

## Содержимое

| Файл | Назначение |
|------|-----------|
| `docker-compose.yml` | Запуск Open5GS (MongoDB + все NF + WebUI) |
| `config/mme.yaml` | Шаблон конфигурации MME (S1-MME, PLMN, TAC, security order) |
| `config/sgwu.yaml` | Шаблон SGW-U (GTP-U, PFCP) |
| `config/pgwu.yaml` | Шаблон PGW-U/UPF (GTP-U, SGi, UE IP-пул) |
| `migrate_userdb_to_open5gs.py` | Перенос абонентов из `user_db.csv` (srsEPC) → JSON Open5GS |

> Примечание: Open5GS использует разделение CUPS. Полный 4G-набор конфигов —
> `mme.yaml, hss.yaml, pcrf.yaml, sgwc.yaml, sgwu.yaml, smf.yaml(pgwc), upf.yaml(pgwu)`.
> Шаблоны `mme/sgwu/pgwu` даны как стартовая точка; недостающие (`hss`, `sgwc`, `pcrf`,
> `smf`) дополнить по образцу Open5GS при развёртывании.

---

## Перенос абонентов (user_db.csv → Open5GS)

Open5GS хранит субскрипции в **MongoDB**. Скрипт преобразует `user_db.csv` srsEPC
в JSON, понятный для загрузки в Open5GS (WebUI или напрямую в MongoDB).

```bash
# Сгенерировать JSON (по умолчанию APN = IS2026.net)
python3 open5gs/migrate_userdb_to_open5gs.py srsran_configs/user_db.csv \
    --apn IS2026.net --out open5gs_subscribers.json

# Посмотреть без записи в файл
python3 open5gs/migrate_userdb_to_open5gs.py srsran_configs/user_db.csv --print
```

Формат входного `user_db.csv` (srsEPC):
```
Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc
ue2,mil,250010000000001,001122...ff,opc,63bfa5...,9000,000000001914,9,dynamic
```

### Загрузка в Open5GS

1. **Через WebUI (проще):**
   - Запустить `webui`, открыть `http://<ip>:3000`, логин `admin` / пароль `1423`.
   - Раздел **Subscribers → Add** — ввести IMSI, Key (K), OPc/OP, AMF, SQN, APN (IS2026.net), QCI.

2. **Напрямую в MongoDB (скриптом):**
   - Коллекция `subscribers` в БД `open5gs`.
   - Поля: `imsi`, `k`, `opc`/`op`, `amf`, `sqn`, `apn_list`, `slice` (для 4G не обязателен).
   - Пример документа — в выводе `migrate_userdb_to_open5gs.py`.

---

## Схема адресации (ФАКТ 2026-09-08, ядро работает на pi5-2)

Все NF сидят на одном хосте pi5-2 (192.168.1.26), поэтому внутренние интерфейсы
разнесены по **loopback-адресам** (канон Open5GS), чтобы не конфликтовать за порты
2123/8805/9090/3868. Наружу (к БС) — S1AP и GTP-U S1-U на реальном IP.

| NF | loopback/IP | Роль наружу |
|----|-------------|-------------|
| MME | 127.0.0.2 | S1AP **192.168.1.26:36412** (SCTP, к БС), GTP-C S11, S6a 3868 |
| SGWC | 127.0.0.3 | GTP-C 2123, PFCP 8805 |
| SGWU | 127.0.0.6 | GTP-U **192.168.1.26:2152** (S1-U, к БС), PFCP 8805 |
| SMF (PGW-C) | 127.0.0.4 | GTP-C 2123, GTP-U 2152, PFCP 8805 (sbi отключён — нет NRF) |
| UPF (PGW-U) | 127.0.0.7 | PFCP 8805, GTP-U 2152 |
| HSS | 127.0.0.8 | S6a 3868 |
| PCRF | 127.0.0.9 | Gx 3868 |

Ключевые моменты:
- **MME S1AP и SGWU GTP-U слушают на 192.168.1.26** (к ним подключаются внешние БС
  Base5=192.168.1.25 и enb2=192.168.1.20).
- **SMF должен работать БЕЗ `sbi`** в smf.yaml — иначе smfd пытается зарегистрироваться
  в NRF (`nnrf-nfm`) и падает с `No-CLIENT:No-SCP` (в чистом 4G EPC NRF нет).
- **Entrypoint образа исправлен**: контейнер запускается с `--entrypoint /bin/bash /start.sh`
  (образ по умолчанию имеет Entrypoint `open5gs-mmed`, который «съедал» Cmd как аргумент).
- **Gx (SMF↔PCRF) — по TCP**: PCRF на loopback-адресе нестабилен при диаметре по SCTP.
  freeDiameter-конфиги вынесены в `config/freeDiameter/` и монтируются в `/etc/freeDiameter`.
  В `smf.conf`/`pcrf.conf` у Gx ConnectPeer добавлено `No_SCTP;` → Gx ходит по TCP.
  ⚠️ При монтировании freeDiameter копировать ВСЕ 4 конфига (mme, hss, pcrf, smf) —
  иначе MME/HSS падают с `fd_core_parseconf` (не находят свои .conf).
- **Абоненты в MongoDB должны иметь поле `security`** (k/opc/amf/sqn внутри `security:{}`),
  а не на верхнем уровне — иначе HSS: "No 'security' field in this document" и attach
  отклоняется. При переносе из user_db.csv проверять структуру документа.

---

## Развёртывание на pi5-2

1. Установить Docker (обычно уже есть).
2. Скорректировать `config/mme.yaml`, `config/sgwu.yaml`, `config/pgwu.yaml`:
   - `mcc`/`mnc` и `tac` — сверить с `enb.conf` обеих БС.
   - IP-адреса bind (S1-MME, GTP-U) — указать 192.168.1.26 (или фактический IP pi5-2).
   - UE-пул и шлюз SGi — согласовать с подсетью 10.0.0.0/24.
3. Запустить:
   ```bash
   docker compose up -d
   ```
4. Добавить абонентов (см. выше).
5. Проверить подключение обеих БС:
   ```bash
   docker logs open5gs | grep -i s1   # S1 Setup от Base5 и pi5-2
   ```
   БС подключаются к MME по **192.168.1.26:36412** (SCTP) и GTP-U **192.168.1.26:2152** (UDP).

---

## Что уточнить на стенде (чек-лист)

- [ ] ММЕ/GTP-U bind адреса (192.168.1.26 для pi5-2).
- [ ] PLMN (mcc/mnc): в `epc.conf` 250/01, в `prod/readme.md` 250/63.
- [ ] APN: `IS2026.net` или `internet.mts.ru`.
- [ ] TAC (0x0007) и LAC (0x0006).
- [ ] UE IP-пул и шлюз SGi (10.0.0.0/24, шлюз 10.0.0.1).
- [ ] Перенос Asterisk/веб-сервера/дашборда на pi5-2 (сервисы ядра).
- [ ] NAT/MASQUERADE для 10.0.0.0/24 (интернет абонентам) на pi5-2.
