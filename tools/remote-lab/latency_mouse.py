import os, sys, time, subprocess, statistics
os.environ["GDK_BACKEND"]="x11"
import gi; gi.require_version("Gdk","3.0"); from gi.repository import Gdk
root = Gdk.get_default_root_window()
X, Y, W, H = [int(v) for v in os.environ.get("AER_LAT_REGION", "830,592,130,30").split(",")]
def grab(): return Gdk.pixbuf_get_from_window(root, X, Y, W, H).get_pixels()
res=[]
for i in range(int(sys.argv[1])):
    subprocess.run(["xdotool","mousemove","747","607"]); time.sleep(0.6)
    base=grab(); t0=time.perf_counter()
    subprocess.run(["xdotool","mousemove","897","607"])
    while time.perf_counter()-t0<2:
        if grab()!=base: res.append((time.perf_counter()-t0)*1000); break
print(" ".join(f"{v:.0f}" for v in res)); res.sort()
print(f"n={len(res)} p50={statistics.median(res):.0f} ms p95={res[int(len(res)*0.95)-1]:.0f} ms min={res[0]:.0f} max={res[-1]:.0f}")
