#!/usr/bin/env python3
"""AER Power test lab (M08). Everything here is TEST DATA and SIMULATED.

  python3 -I tools/power-lab/lab.py up DIR [PORT]     # Core + agent (check mode) + WoL receiver; runs until Ctrl+C
  python3 -I tools/power-lab/lab.py fake-boot DIR     # the WoL test PC "appears": a fake power agent says hello
  python3 -I tools/power-lab/lab.py bench DIR         # API latency, parallel jobs, CPU/RSS

Safety: the real aer-power-host runs with "execute": false (the lab refuses
anything else), so it only reads facts and answers "simulated". Wake-on-LAN
goes to a UDP receiver on 127.0.0.1 — no packet reaches the LAN.
"""
import json, os, random, socket, subprocess, sys, threading, time, urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(ROOT, "core", "bin")
DOC_MAC = "00:00:5e:00:53:aa"  # RFC 7042 documentation range
CAPS = ["power.wake", "power.shutdown", "power.reboot", "power.suspend", "power.switch_os", "network.ping"]


def api(state, method, path, body=None, token=None, headers=None):
    req = urllib.request.Request(state["url"] + "/api/v1" + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", "Bearer " + (token or state["owner"]))
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}").get("data")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}").get("error")


def load(d):
    return json.load(open(os.path.join(d, "lab.json")))


def receiver(sock, log):
    while True:
        data, src = sock.recvfrom(2048)
        ok = len(data) == 102 and data[:6] == b"\xff" * 6 and data[6:12] * 16 == data[6:]
        mac = ":".join(f"{b:02x}" for b in data[6:12]) if len(data) >= 12 else "?"
        with open(log, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {len(data)} bytes from {src[0]} magic={ok} mac={mac}\n")


def up(d, port):
    os.makedirs(d, exist_ok=True)
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    rx_port = rx.getsockname()[1]
    threading.Thread(target=receiver, args=(rx, os.path.join(d, "wol-received.log")), daemon=True).start()
    cfg = {"mode": "development", "listenAddr": f"127.0.0.1:{port}", "dataDir": os.path.join(d, "data"),
           "monitoring": {"docker": {"enabled": False}}, "power": {"wol": {"enabled": True}}}
    json.dump(cfg, open(os.path.join(d, "core.json"), "w"))
    core = subprocess.Popen([os.path.join(BIN, "aer-core"), "-config", os.path.join(d, "core.json")],
                            stdout=open(os.path.join(d, "core.log"), "w"), stderr=subprocess.STDOUT)
    state = {"url": f"http://127.0.0.1:{port}", "dir": d, "rxPort": rx_port, "corePid": core.pid}
    for _ in range(100):
        try:
            urllib.request.urlopen(state["url"] + "/api/v1/health", timeout=1)
            break
        except Exception:
            time.sleep(0.1)
    state["owner"] = open(os.path.join(d, "data", "core.token")).read().strip()
    _, me = api(state, "POST", "/registry/entities", {"name": "Этот ПК (стенд, режим проверки)", "type": "computer", "capabilities": CAPS})
    _, wol = api(state, "POST", "/registry/entities", {"name": "Тестовый ПК для WoL (стенд)", "type": "computer", "capabilities": CAPS})
    state["me"], state["wolPc"] = me["id"], wol["id"]
    _, cred = api(state, "POST", "/monitoring/agents", {"entityId": me["id"], "name": "power (стенд)", "kind": "power"})
    tok = os.path.join(d, "power.token")
    open(tok, "w").write(cred["token"])
    os.chmod(tok, 0o600)
    agent_cfg = {"coreUrl": state["url"], "tokenFile": tok, "execute": False}
    if agent_cfg["execute"] is not False:
        sys.exit("refusing: the lab runs the agent in check mode only")
    json.dump(agent_cfg, open(os.path.join(d, "agent.json"), "w"))
    api(state, "PUT", f"/power/devices/{me['id']}/policy",
        {"enabled": True, "wake": True, "shutdown": True, "reboot": True, "suspend": True, "switchOs": True})
    api(state, "PUT", f"/power/devices/{wol['id']}/wol", {"mac": DOC_MAC, "broadcast": "127.0.0.1", "port": rx_port})
    agent = subprocess.Popen([os.path.join(BIN, "aer-power-host"), "-config", os.path.join(d, "agent.json")],
                             stdout=open(os.path.join(d, "agent.log"), "w"), stderr=subprocess.STDOUT)
    state["agentPid"] = agent.pid
    json.dump(state, open(os.path.join(d, "lab.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in state.items() if k != "owner"}, ensure_ascii=False), flush=True)
    try:
        while core.poll() is None and agent.poll() is None:
            time.sleep(0.5)
    finally:
        for p in (agent, core):
            if p.poll() is None:
                p.terminate()
                p.wait(5)


def fake_boot(d):
    s = load(d)
    _, cred = api(s, "POST", "/monitoring/agents", {"entityId": s["wolPc"], "name": "power (имитация загрузки)", "kind": "power"})
    hello = {"os": "linux", "hostname": "wol-test-pc", "bootId": "sim-%06d" % random.randrange(10**6), "dryRun": True,
             "firmware": "uefi", "secureBoot": "unknown", "bitlocker": "n/a", "bootManager": "unknown", "bootEntries": [],
             "macs": [DOC_MAC], "actions": {}}
    print(api(s, "POST", "/power/agent/hello", hello, token=cred["token"]))


def proc(pid):
    f = open(f"/proc/{pid}/stat").read().split(")")[-1].split()
    rss = int(open(f"/proc/{pid}/statm").read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK"), rss


def bench(d):
    s = load(d)
    def t(fn, n=50):
        xs = []
        for _ in range(n):
            a = time.perf_counter(); fn(); xs.append((time.perf_counter() - a) * 1000)
        xs.sort()
        return round(xs[len(xs) // 2], 2), round(xs[int(len(xs) * 0.95) - 1], 2)
    out = {}
    out["GET /power/devices (2 устр.) p50/p95 мс"] = t(lambda: api(s, "GET", "/power/devices"))
    out["GET /power/devices/{id} p50/p95 мс"] = t(lambda: api(s, "GET", f"/power/devices/{s['me']}"))
    out["POST confirm p50/p95 мс"] = t(lambda: api(s, "POST", f"/power/devices/{s['me']}/actions/reboot/confirm", {}))
    out["POST check (задание) p50/p95 мс"] = t(lambda: api(s, "POST", f"/power/devices/{s['me']}/actions/check", {},
                                                          headers={"Idempotency-Key": "bench-%012d" % random.randrange(10**12)}), 30)
    # 40 more devices with fake agents in check mode; parallel reboots → simulated.
    ids, toks = [], []
    for i in range(40):
        _, e = api(s, "POST", "/registry/entities", {"name": f"Нагрузочный ПК {i:02d} (тест)", "type": "computer", "capabilities": CAPS})
        _, c = api(s, "POST", "/monitoring/agents", {"entityId": e["id"], "name": "power bench", "kind": "power"})
        api(s, "POST", "/power/agent/hello", {"os": "linux", "bootId": "b", "dryRun": True, "firmware": "uefi", "secureBoot": "unknown",
            "bitlocker": "n/a", "macs": [], "bootEntries": [], "actions": {"reboot": {"supported": True, "reason": ""}}}, token=c["token"])
        ids.append(e["id"]); toks.append(c["token"])
    out["GET /power/devices (42 устр.) p50/p95 мс"] = t(lambda: api(s, "GET", "/power/devices"), 20)
    c0 = proc(s["corePid"])
    res = [None] * len(ids)
    def one(i):
        _, c = api(s, "POST", f"/power/devices/{ids[i]}/actions/reboot/confirm", {})
        a = time.perf_counter()
        code, j = api(s, "POST", f"/power/devices/{ids[i]}/actions/reboot", {"confirmationToken": c["token"]},
                      headers={"Idempotency-Key": f"bench-par-{i:04d}-{random.randrange(10**9)}"})
        res[i] = (code, (time.perf_counter() - a) * 1000, j)
    th = [threading.Thread(target=one, args=(i,)) for i in range(len(ids))]
    [x.start() for x in th]; [x.join() for x in th]
    codes = {}
    for code, _, j in res:
        key = f"{code} {j.get('state') if code < 300 else j.get('code')}"
        codes[key] = codes.get(key, 0) + 1
    out["40 параллельных reboot (лимит maxActiveJobs=8): ответы"] = codes
    lat = sorted(r[1] for r in res)
    out["  время ответа execute p50/max мс"] = (round(lat[len(lat) // 2], 1), round(lat[-1], 1))
    # Agents take and answer their jobs (simulated).
    done = 0
    for i, tok in enumerate(toks):
        if res[i][0] != 202:
            continue
        code, data = api(s, "GET", "/power/agent/commands?wait=1", token=tok)
        for cmd in data["commands"]:
            api(s, "POST", f"/power/agent/jobs/{cmd['jobId']}/events", {"kind": "simulated", "message": "bench"}, token=tok)
            done += 1
    out["  выполнено агентами (SIMULATED)"] = done
    c1 = proc(s["corePid"])
    out["aer-core CPU за серию, с / RSS МБ"] = (round(c1[0] - c0[0], 3), round(c1[1] / 2**20, 1))
    a0 = proc(s["agentPid"]); time.sleep(30); a1 = proc(s["agentPid"]); c2 = proc(s["corePid"])
    out["aer-power-host простой 30 с: CPU % / RSS МБ"] = (round((a1[0] - a0[0]) / 30 * 100, 3), round(a1[1] / 2**20, 1))
    out["aer-core простой 30 с: CPU % / RSS МБ"] = (round((c2[0] - c1[0]) / 30 * 100, 3), round(c2[1] / 2**20, 1))
    _, jobs = api(s, "GET", "/power/jobs?limit=200")
    out["заданий в истории"] = len(jobs)
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    cmd, d = sys.argv[1], os.path.abspath(sys.argv[2])
    if cmd == "up":
        up(d, int(sys.argv[3]) if len(sys.argv) > 3 else 18797)
    elif cmd == "fake-boot":
        fake_boot(d)
    elif cmd == "bench":
        bench(d)
