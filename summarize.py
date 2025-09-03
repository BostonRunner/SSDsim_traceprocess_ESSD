#!/usr/bin/env python3
# Summarize per-container fio JSON outputs (read + write) and include workload type when available.
import json, sys, os, glob, csv, re
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "./results_all")
rows = []
result_dirs = sorted([p for p in root.glob("result*") if p.is_dir()],
                     key=lambda p: int(''.join(filter(str.isdigit, p.name)) or 0))

wl_regex = re.compile(r'fio_c(\d+)_(\w+)\.json$')

def parse_one_json(jf: Path):
    try:
        data = json.load(open(jf, "r"))
        job = data["jobs"][0]
        rd = job.get("read", {}) or {}
        wr = job.get("write", {}) or {}
        bw = float(rd.get("bw_bytes", 0.0)) + float(wr.get("bw_bytes", 0.0))  # bytes/s
        iops = float(rd.get("iops", 0.0)) + float(wr.get("iops", 0.0))
        return bw, iops
    except Exception:
        return 0.0, 0.0

for rdir in result_dirs:
    N = int(''.join(filter(str.isdigit, rdir.name)) or 0)
    # workload mapping file (optional)
    wl_map = {}
    wl_file = rdir / "workloads.json"
    if wl_file.exists():
        try:
            wl_map = json.load(open(wl_file, "r"))
        except Exception:
            wl_map = {}

    for cdir in sorted(rdir.glob("c*"), key=lambda p: int(p.name[1:])):
        cid = int(cdir.name[1:])
        jsons = sorted(cdir.glob("fio_*.json"))
        if not jsons:
            # also try pattern with explicit name
            jsons = sorted(cdir.glob("fio_c*.json"))
        total_bw = 0.0
        total_iops = 0.0
        n = 0
        workload = wl_map.get(f"c{cid}", "")
        for jf in jsons:
            bw, iops = parse_one_json(jf)
            total_bw += bw
            total_iops += iops
            n += 1
            if not workload:
                m = wl_regex.search(jf.name)
                if m:
                    workload = m.group(2)
        if n == 0:
            continue
        rows.append({
            "result_dir": rdir.name,
            "N": N,
            "container": cid,
            "workload": workload,
            "bw_MBps": total_bw / n / (1024*1024),
            "iops": total_iops / n,
            "jobs_count": n
        })

out_csv = root / "summary.csv"
with open(out_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["result_dir","N","container","workload","bw_MBps","iops","jobs_count"])
    w.writeheader()
    for row in sorted(rows, key=lambda r: (r["N"], r["container"])):
        w.writerow(row)

print(f"Wrote {out_csv}")
