#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse, csv, datetime, re, subprocess, time

ENB1_PAUSE   = ["ssh","-i","/home/infarh/.ssh/id_ed25519","-o","BatchMode=yes","-o","ConnectTimeout=15","shmac@192.168.1.25","docker","pause","enb"]
ENB1_UNPAUSE = ["ssh","-i","/home/infarh/.ssh/id_ed25519","-o","BatchMode=yes","-o","ConnectTimeout=15","shmac@192.168.1.25","docker","unpause","enb"]
ENB2_PAUSE   = ["docker","pause","enb2"]
ENB2_UNPAUSE = ["docker","unpause","enb2"]

IMSI_RE = re.compile(r"IMSI:\[(\d{15})\]")
GUTI_RE = re.compile(r"IMSI\[(\d{15})\]")
CELL_RE = re.compile(r"CellID\[(0x[0-9a-fA-F]+)\]")

def run_cmd(cmd, descr=""):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        ok = r.returncode == 0
        print(f"[{descr}] {'OK' if ok else 'FAIL'}", flush=True); return ok
    except Exception as e:
        print(f"[{descr}] EXC: {e}", flush=True); return False

def read_log(path, start=0):
    try:
        with open(path) as f: lines = f.read().splitlines()
        return lines[start:]
    except Exception: return []

def current_ue_ip(smf_log, imsi):
    """Извлекает последний актуальный IPv4 для IMSI из лога SMF."""
    last = None
    pat = re.compile(r"UE IMSI\[" + imsi + r"\].*?IPv4\[([0-9.]+)\]")
    for ln in read_log(smf_log, 0):
        m = pat.search(ln)
        if m:
            last = m.group(1)
    return last

def split_cell(lines):
    """Возвращает список (imsi, cell) по строкам лога (последнее состояние)."""
    out=[]; cur=None
    for ln in lines:
        mi = GUTI_RE.search(ln) or IMSI_RE.search(ln)
        if mi: cur = mi.group(1)
        mc = CELL_RE.search(ln)
        if mc and cur: out.append((cur, mc.group(1)))
    return out

def next_reg_cell(lines):
    """Последовательность (imsi, cell) событий в порядке строк."""
    return split_cell(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iter", type=int, default=10)
    ap.add_argument("--stab", type=float, default=15.0)
    ap.add_argument("--wait", type=float, default=45.0)
    ap.add_argument("--mme-log", default="/home/infarh/open5gs/logs/mme.log")
    ap.add_argument("--smf-log", default="/home/infarh/open5gs/logs/smf.log")
    ap.add_argument("--out", default="/home/infarh/reho_result.csv")
    ap.add_argument("--imsi", nargs="+", default=["250630000000004","250630000000005"])
    a = ap.parse_args()
    # Автоопределение актуальных IP телефонов из лога SMF
    ip2imsi = {}
    for imsi in a.imsi:
        ip = current_ue_ip(a.smf_log, imsi)
        if ip:
            ip2imsi[ip] = imsi
            print(f"[*] Определён IP для IMSI {imsi}: {ip}", flush=True)
        else:
            print(f"[!] Не найден IP для IMSI {imsi} в {a.smf_log}", flush=True)
    print("=== Замер времени переключения UE (MME-лог) ===", flush=True)
    print(f"IMSI {a.imsi} IP {list(ip2imsi.keys())} итераций {a.iter} stab {a.stab}s", flush=True)

    header = ["iter","paused_enb","ue_ip","switch_s","src_sota","note"]
    rows=[]

    try:
        for it in range(1, a.iter+1):
            print(f"\n=== Итерация {it}/{a.iter} ===", flush=True)
            time.sleep(a.stab)
            # позиция в логе (количество строк)
            try:
                pos = sum(1 for _ in open(a.mme_log))
            except Exception: pos=0

            for pcmd, ucmd, name, target_cell in (
                    (ENB1_PAUSE, ENB1_UNPAUSE, "eNB1(base5)", "0x19f01"),
                    (ENB2_PAUSE, ENB2_UNPAUSE, "eNB2(pi5-2)", "0x19b01")):
                print(f"[*] ПАУЗА {name} (жду регистрацию UE на {target_cell}) ...", flush=True)
                if not run_cmd(pcmd, "pause "+name): continue
                t_pause = time.time()
                switched = {}   # imsi -> time_since_pause
                t0 = time.time()
                while (time.time()-t0) < a.wait:
                    time.sleep(0.3)
                    for imsi, cell in next_reg_cell(read_log(a.mme_log, pos)):
                        if cell == target_cell and imsi not in switched:
                            switched[imsi] = round(time.time() - t_pause, 2)
                            print(f"    UE {imsi} -> {target_cell} +{switched[imsi]} с", flush=True)
                    if len(switched) >= len(a.imsi):
                        break
                for imsi in a.imsi:
                    iplist = [k for k,v in ip2imsi.items() if v==imsi]
                    ip = iplist[0] if iplist else imsi
                    s = switched.get(imsi)
                    val = s if isinstance(s,(int,float)) else "NO_REG"
                    rows.append([it, name, ip, val, target_cell, ""])
                    print(f"  >> {ip} ({imsi}): {val} с", flush=True)
                print(f"[*] ВОЗВРАТ {name} ...", flush=True)
                run_cmd(ucmd, "unpause "+name)
                time.sleep(a.stab)
    finally:
        run_cmd(ENB1_UNPAUSE, "unpause eNB1 финал")
        run_cmd(ENB2_UNPAUSE, "unpause eNB2 финал")
        with open(a.out, "w", newline="") as f:
            w=csv.writer(f); w.writerow(header)
            for r in rows: w.writerow(r)
        print(f"\nРезультат: {a.out}", flush=True)
    print("\n=== СВОДКА ===", flush=True)
    val=[r[3] for r in rows if isinstance(r[3],(int,float))]
    if val:
        print(f"  Измерений: {len(val)}  Среднее: {sum(val)/len(val):.2f} с  Мин: {min(val):.2f}  Макс: {max(val):.2f}", flush=True)
        for r in rows:
            if isinstance(r[3],(int,float)):
                print(f"  iter{r[0]} {r[1]} {r[2]}: {r[3]} с", flush=True)
    else:
        print("  Нет измерений.", flush=True)

if __name__=="__main__": main()