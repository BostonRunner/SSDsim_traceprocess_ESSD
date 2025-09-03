#!/usr/bin/env python3
# Robust fio JSON summarizer
# - Works with fio JSON where iops/bw may be numbers, strings, or dicts (with mean/avg/value)
# - Write latency prefers write.clat_ns.mean, then write.lat_ns.mean, then job-level clat/lat
# - Aggregates per-container across multiple json files if present
import json, sys, csv, re
from pathlib import Path

def to_float(v):
    # Convert fio JSON field (num/str/dict) to float safely.
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except Exception:
            return 0.0
    if isinstance(v, dict):
        for k in ("mean", "value", "avg"):
            if k in v:
                return to_float(v[k])
        return 0.0
    return 0.0

def section_bw_bytes(sec: dict) -> float:
    # Return bandwidth in bytes/s from a fio section (read/write).
    if not isinstance(sec, dict):
        return 0.0
    bwb = sec.get("bw_bytes", None)
    if bwb is not None:
        return to_float(bwb)
    # fallback: 'bw' is usually KiB/s
    bw_kib = sec.get("bw", None)
    return to_float(bw_kib) * 1024.0

def section_iops(sec: dict) -> float:
    # Return IOPS from a fio section (read/write).
    if not isinstance(sec, dict):
        return 0.0
    return to_float(sec.get("iops", 0.0))

def pick_write_latency_ms(job: dict) -> float:
    # Pick write latency in milliseconds; prefer completion latency (clat_ns.mean).
    if not isinstance(job, dict):
        return 0.0
    wr = job.get("write") or {}
    for key in ("clat_ns", "lat_ns"):
        val = wr.get(key)
        if isinstance(val, dict) and "mean" in val:
            return to_float(val["mean"]) / 1e6
        if isinstance(val, (int, float, str)):
            return to_float(val) / 1e6
    # fallbacks: job-level latency (rare)
    for key in ("clat_ns", "lat_ns"):
        val = job.get(key)
        if isinstance(val, dict) and "mean" in val:
            return to_float(val["mean"]) / 1e6
        if isinstance(val, (int, float, str)):
            return to_float(val) / 1e6
    return 0.0

def parse_one_json(jf: Path):
    try:
        with open(jf, "r") as f:
            data = json.load(f)
        jobs = data.get("jobs") or []
        if not jobs:
            print(f"[WARN] {jf} has no jobs[]")
            return 0.0, 0.0, 0.0
        job = jobs[0]
        rd = job.get("read", {}) or {}
        wr = job.get("write", {}) or {}
        bw = section_bw_bytes(rd) + section_bw_bytes(wr)   # bytes/s
        iops = section_iops(rd) + section_iops(wr)
        wlat_ms = pick_write_latency_ms(job)
        return bw, iops, wlat_ms
    except Exception as e:
        print(f"[WARN] failed to parse {jf}: {e}")
        return 0.0, 0.0, 0.0

def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "./results_all")
    rows = []
    # result* folders under root
    result_dirs = sorted([p for p in root.glob("result*") if p.is_dir()],
                         key=lambda p: int(''.join(filter(str.isdigit, p.name)) or 0))
    wl_regex = re.compile(r'fio_c(\d+)_(\w+)\.json$')
    for rdir in result_dirs:
        # infer N from folder name (e.g., result6 -> 6); if not present, 0
        N = int(''.join(filter(str.isdigit, rdir.name)) or 0)

        # Optional workload mapping
        wl_map = {}
        wlf = rdir / "workloads.json"
        if wlf.exists():
            try:
                wl_map = json.load(open(wlf, "r"))
            except Exception:
                wl_map = {}

        # Each container folder c1..c6..
        cdirs = sorted([p for p in rdir.glob("c*") if p.is_dir()], key=lambda p: int(p.name[1:] or 0))
        for cdir in cdirs:
            try:
                cid = int(cdir.name[1:])
            except Exception:
                continue
            # collect jsons
            jsons = sorted(cdir.glob("fio_*.json"))
            if not jsons:
                jsons = sorted(cdir.glob("fio_c*.json"))
            if not jsons:
                print(f"[INFO] No fio JSON in {cdir}, skip")
                continue

            total_bw = total_iops = total_lat = 0.0
            n = 0
            workload = wl_map.get(f"c{cid}", "")
            for jf in jsons:
                bw, iops, lat = parse_one_json(jf)
                total_bw += bw
                total_iops += iops
                total_lat += lat
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
                # Convert bytes/s to MiB/s
                "bw_MBps": total_bw / n / (1024.0 * 1024.0),
                "iops": total_iops / n,
                "write_latency_ms": total_lat / n,
                "jobs_count": n
            })

    out_csv = root / "summary.csv"
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "result_dir","N","container","workload","bw_MBps","iops","write_latency_ms","jobs_count"
        ])
        w.writeheader()
        for row in sorted(rows, key=lambda r: (r["N"], r["container"])):
            w.writerow(row)
    print(f"Wrote {out_csv}")

if __name__ == "__main__":
    main()
