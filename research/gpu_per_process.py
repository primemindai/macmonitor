# gpu_per_process.py : per-process GPU time from AGXDeviceUserClient "AppUsage" (ioreg). READ-ONLY. run: python3 -I gpu_per_process.py
import plistlib, subprocess, time, re, collections
def snap():
    out = subprocess.run(["ioreg","-a","-r","-c","AGXDeviceUserClient","-l"],capture_output=True).stdout
    tot = collections.Counter(); names = {}
    def walk(n):
        if isinstance(n,dict):
            c = n.get("IOUserClientCreator","")
            m = re.match(r"pid (\d+), (.*)", c)
            if m:
                pid = int(m.group(1)); names[pid] = m.group(2)
                for u in n.get("AppUsage",[]): tot[pid] += u.get("accumulatedGPUTime",0)
            for v in n.values(): walk(v)
        elif isinstance(n,list):
            for v in n: walk(v)
    walk(plistlib.loads(out)); return tot, names
t0=time.time(); a,_=snap(); cost=(time.time()-t0)*1000
time.sleep(1); b,names=snap()
print(f"# snapshot cost {cost:.0f} ms (ioreg subprocess); clients {len(names)}")
for pid,v in sorted(b.items(), key=lambda kv: -(kv[1]-a.get(kv[0],0)))[:8]:
    d=v-a.get(pid,0); print(f"pid {pid:6d} {names[pid][:28]:28s} GPU busy {d/1e7:6.1f}%  lifetime {v/1e9:10.1f} s")
