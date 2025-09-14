#!/usr/bin/env python3
import sys, json, os, glob, datetime
root = sys.argv[1] if len(sys.argv)>1 else "."
print("stage,pod,role,bw_MBps,iops,lat_ms,json_path,timestamp")
for jf in glob.glob(os.path.join(root, "**/fio.json"), recursive=True):
    try:
        with open(jf,"r",encoding="utf-8",errors="ignore") as f:
            t = f.read()
        data = None
        try:
            data = json.loads(t)
        except:
            for i,ch in enumerate(t):
                if ch=='{':
                    for j in range(len(t)-1,i,-1):
                        if t[j]=='}':
                            try:
                                data = json.loads(t[i:j+1]); break
                            except: pass
                    if data: break
        if not data: 
            continue
        job = (data.get("jobs") or [{}])[0]
        rd  = job.get("read") or {}
        wr  = job.get("write") or {}
        def f(x):
            try: return float(x)
            except: return 0.0
        bw = (rd.get("bw_bytes") or 0) + (wr.get("bw_bytes") or 0)
        if not bw: bw = (f(rd.get("bw",0)) + f(wr.get("bw",0))) * 1024.0
        iops = f(rd.get("iops",0)) + f(wr.get("iops",0))
        src = wr.get("clat_ns") or wr.get("lat_ns") or job.get("clat_ns") or job.get("lat_ns") or {}
        lat = (float(src.get("mean",0))/1e6) if isinstance(src,dict) else 0.0
        pod = os.path.basename(os.path.dirname(jf))
        role = "victim2x" if "victim2x" in jf else ("victim" if "victim" in jf else "noisy")
        ts = datetime.datetime.now().isoformat(timespec="seconds")
        stage = os.path.basename(root)
        print(f"{stage},{pod},{role},{bw/1024/1024:.3f},{iops:.3f},{lat:.3f},{jf},{ts}")
    except Exception:
        continue
