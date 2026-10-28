#!/usr/bin/env python3
"""Read-only check of REAL home devices through an isolated Core (M09).

  python3 -I tools/network-lab/real_check.py DIR --router IP --tv IP \
      [--sunshine http://127.0.0.1:47989] [--internet 1.1.1.1:443 --internet 9.9.9.9:443]

What it does: a separate Core (own data dir, port 18799) gets Registry
objects for the router and the TV; Monitoring makes TCP connects to their
default ports (80/443/22/53 — never ADB), the network module reads Sunshine
serverinfo and probes the internet targets (TLS handshake on :443). Nothing
is configured or changed on any device; no scanning. The printed result
masks IP addresses; nothing is written outside DIR.
"""
import argparse, json, re, subprocess, time, urllib.request, os

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--router", required=True)
ap.add_argument("--tv", required=True)
ap.add_argument("--sunshine", default="http://127.0.0.1:47989")
ap.add_argument("--web", default="https://127.0.0.1:47990")
ap.add_argument("--internet", action="append", default=[])
a = ap.parse_args()
d = os.path.abspath(a.dir)
os.makedirs(d, exist_ok=True)
BIN = os.path.join(os.path.dirname(__file__), "..", "..", "core", "bin", "aer-core")
URL = "http://127.0.0.1:18799"
tok = None


def start(cfg):
    json.dump(cfg, open(d + "/core.json", "w"))
    p = subprocess.Popen([BIN, "-config", d + "/core.json"], stdout=open(d + "/core.log", "a"), stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            urllib.request.urlopen(URL + "/api/v1/health", timeout=1)
            return p
        except Exception:
            time.sleep(0.1)
    return p


def api(m, p, b=None):
    r = urllib.request.Request(URL + "/api/v1" + p, method=m, data=None if b is None else json.dumps(b).encode())
    r.add_header("Authorization", "Bearer " + tok)
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=30) as x:
        return json.loads(x.read())["data"]


mask = lambda s: re.sub(r"\b\d+\.\d+\.\d+\.\d+\b", "<ip>", s)
base = {"mode": "development", "listenAddr": "127.0.0.1:18799", "dataDir": d + "/data",
        "monitoring": {"docker": {"enabled": False}, "checkIntervalSec": 10}}
p = start(base)
tok = open(d + "/data/core.token").read().strip()
r = api("POST", "/registry/entities", {"name": "Роутер (реальный)", "type": "router", "address": a.router})
t = api("POST", "/registry/entities", {"name": "ТВ-приставка (реальная)", "type": "television", "address": a.tv})
pc = api("POST", "/registry/entities", {"name": "ПК со Sunshine (реальный)", "type": "computer"})
p.terminate(); p.wait(10)
cfg = dict(base)
cfg["network"] = {"intervalSec": 10, "timeoutSec": 3, "internet": {"targets": a.internet},
                  "sunshine": [{"id": "main", "name": "Sunshine (реальный)", "entityId": pc["id"], "tvEntityId": t["id"],
                                "serverInfoUrl": a.sunshine, "webUrl": a.web}]}
p = start(cfg)
try:
    time.sleep(25)
    o = api("GET", "/network/overview")
    dv = lambda x: {"status": x["status"], "monitoring": x["monitoringStatus"], "latencyMs": x["latencyMs"], "reason": mask(x["reason"])}
    sh = o["sunshine"][0]
    out = {"summary": o["summary"]["title"],
           "internet": {"status": o["internet"]["status"], "reason": mask(o["internet"]["reason"]),
                        "targets": [{"ok": x["ok"], "latencyMs": x["latencyMs"], "error": x["error"]} for x in o["internet"]["details"]["targets"]]
                        if o["internet"].get("details") else []},
           "router": dict(dv(o["routers"][0]["device"]), adapter=o["routers"][0]["adapter"]),
           "tv": dv(o["tvs"][0]),
           "sunshine": {"status": sh["check"]["status"], "reason": sh["check"]["reason"], "details": sh["check"]["details"], "latencyMs": sh["check"]["latencyMs"]},
           "sunshine_tv_status": sh["tv"]["status"],
           "net_log_lines": len(api("GET", "/monitoring/logs?source=net.&limit=50")["items"]),
           "private_fields_in_api": [k for k in ("hostname", "uniqueid", "LocalIP", '"mac"') if k in json.dumps(o)]}
finally:
    p.terminate(); p.wait(10)
json.dump(out, open(d + "/result.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False, indent=1))
