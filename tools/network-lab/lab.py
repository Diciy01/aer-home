#!/usr/bin/env python3
"""AER Network + TV test lab (M09). Everything here is TEST DATA on 127.0.0.1.

  python3 -I tools/network-lab/lab.py up DIR [PORT]          # stubs + isolated Core; runs until killed
  python3 -I tools/network-lab/lab.py set DIR sunshine=busy  # free|busy|down|401  /  wan=up|down
  python3 -I tools/network-lab/lab.py bench DIR              # API latency, CPU/RSS

Stubs: a Sunshine GameStream serverinfo server (same reply shape as the real
one, fixture values), a UPnP IGD router (description + Get* SOAP actions),
TCP listeners standing for the router, a switch and internet targets. No
real device is contacted; the TV entity has no address (not configured).
"""
import http.server, json, os, socket, subprocess, sys, threading, time, urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(ROOT, "core", "bin", "aer-core")


def state(d):
    try:
        return json.load(open(os.path.join(d, "state.json")))
    except Exception:
        return {"sunshine": "free", "wan": "up"}


def handler(d):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, ctype="text/xml"):
            b = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            st = state(d)
            if self.path == "/serverinfo":
                s = st.get("sunshine", "free")
                if s == "down":
                    self.close_connection = True
                    self.connection.close()
                    return
                if s == "401":
                    return self.send(401, "")
                busy = s == "busy"
                return self.send(200, '<?xml version="1.0" encoding="utf-8"?><root status_code="200"><hostname>lab-host</hostname>'
                                 '<appversion>0.0.0-lab</appversion><uniqueid>0000000000000000</uniqueid><mac>00:00:5e:00:53:00</mac>'
                                 '<LocalIP>192.0.2.1</LocalIP><currentgame>%s</currentgame><state>SUNSHINE_SERVER_%s</state></root>'
                                 % ("1" if busy else "0", "BUSY" if busy else "FREE"))
            if self.path == "/rootDesc.xml":
                return self.send(200, '<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><serviceList>'
                                 '<service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/cmn</controlURL></service>'
                                 '</serviceList><deviceList><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>'
                                 '<controlURL>/ctl/ip</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>')
            self.send(404, "")

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            self.rfile.read(n)
            action = self.headers.get("SOAPAction", "")
            up = state(d).get("wan", "up") == "up"
            if "#GetStatusInfo" in action:
                inner = ('<u:GetStatusInfoResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewConnectionStatus>%s</NewConnectionStatus>'
                         '<NewUptime>86400</NewUptime></u:GetStatusInfoResponse>' % ("Connected" if up else "Disconnected"))
            elif "#GetCommonLinkProperties" in action:
                inner = ('<u:GetCommonLinkPropertiesResponse xmlns:u="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1">'
                         '<NewLayer1UpstreamMaxBitRate>100000000</NewLayer1UpstreamMaxBitRate><NewLayer1DownstreamMaxBitRate>500000000</NewLayer1DownstreamMaxBitRate>'
                         '<NewPhysicalLinkStatus>%s</NewPhysicalLinkStatus></u:GetCommonLinkPropertiesResponse>' % ("Up" if up else "Down"))
            else:
                return self.send(500, "")
            self.send(200, '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>%s</s:Body></s:Envelope>' % inner)
    return H


def tcp_listener():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(16)

    def loop():
        while True:
            c, _ = s.accept()
            c.close()
    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


def api(st, method, path, body=None):
    req = urllib.request.Request(st["url"] + "/api/v1" + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", "Bearer " + st["owner"])
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}").get("data")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}").get("error")


def up(d, port):
    os.makedirs(d, exist_ok=True)
    json.dump({"sunshine": "free", "wan": "up"}, open(os.path.join(d, "state.json"), "w"))
    stub = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler(d))
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    sp = stub.server_address[1]
    router, switch, inet1, inet2, web = (tcp_listener() for _ in range(5))
    st = {"url": f"http://127.0.0.1:{port}", "dir": d, "stub": sp}
    # Entities are created first with Core, then Core is restarted with the
    # network config that references their ids.
    def start_core(cfg):
        json.dump(cfg, open(os.path.join(d, "core.json"), "w"))
        p = subprocess.Popen([BIN, "-config", os.path.join(d, "core.json")], stdout=open(os.path.join(d, "core.log"), "a"), stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                urllib.request.urlopen(st["url"] + "/api/v1/health", timeout=1)
                return p
            except Exception:
                time.sleep(0.1)
        return p
    base = {"mode": "development", "listenAddr": f"127.0.0.1:{port}", "dataDir": os.path.join(d, "data"),
            "monitoring": {"docker": {"enabled": False}, "checkIntervalSec": 10}}
    core = start_core(base)
    st["owner"] = open(os.path.join(d, "data", "core.token")).read().strip()
    _, r = api(st, "POST", "/registry/entities", {"name": "Роутер (стенд)", "type": "router", "address": f"127.0.0.1:{router}"})
    _, sw = api(st, "POST", "/registry/entities", {"name": "Коммутатор (стенд)", "type": "network_device", "address": f"127.0.0.1:{switch}"})
    _, tv = api(st, "POST", "/registry/entities", {"name": "ТВ-приставка (стенд)", "type": "television"})
    _, pc = api(st, "POST", "/registry/entities", {"name": "ПК со Sunshine (стенд)", "type": "computer", "address": f"127.0.0.1:{web}"})
    core.terminate(); core.wait(10)
    cfg = dict(base)
    cfg["network"] = {"intervalSec": 10, "timeoutSec": 3, "failuresBeforeDown": 2,
                      "internet": {"targets": [f"127.0.0.1:{inet1}", f"127.0.0.1:{inet2}"]},
                      "routers": [{"entityId": r["id"], "upnpUrl": f"http://127.0.0.1:{sp}/rootDesc.xml"}],
                      "sunshine": [{"id": "lab", "name": "Sunshine (стенд)", "entityId": pc["id"], "tvEntityId": tv["id"],
                                    "serverInfoUrl": f"http://127.0.0.1:{sp}", "webUrl": f"https://127.0.0.1:{web}"}]}
    core = start_core(cfg)
    st.update(corePid=core.pid, router=r["id"], switch=sw["id"], tv=tv["id"], pc=pc["id"])
    json.dump(st, open(os.path.join(d, "lab.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in st.items() if k != "owner"}, ensure_ascii=False), flush=True)
    try:
        core.wait()
    finally:
        if core.poll() is None:
            core.terminate()


def set_state(d, kv):
    s = state(d)
    k, v = kv.split("=", 1)
    s[k] = v
    json.dump(s, open(os.path.join(d, "state.json"), "w"))
    print(s)


def proc(pid):
    f = open(f"/proc/{pid}/stat").read().split(")")[-1].split()
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK"), int(open(f"/proc/{pid}/statm").read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 2**20


def bench(d):
    st = json.load(open(os.path.join(d, "lab.json")))
    xs = []
    for _ in range(50):
        a = time.perf_counter(); api(st, "GET", "/network/overview"); xs.append((time.perf_counter() - a) * 1000)
    xs.sort()
    c0 = proc(st["corePid"]); time.sleep(60); c1 = proc(st["corePid"])
    print(json.dumps({"GET /network/overview p50/p95 мс": [round(xs[25], 2), round(xs[47], 2)],
                      "aer-core простой 60 с (проверки сети каждые 10 с): CPU %, RSS МБ": [round((c1[0] - c0[0]) / 60 * 100, 3), round(c1[1], 1)]},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    cmd, d = sys.argv[1], os.path.abspath(sys.argv[2])
    if cmd == "up":
        up(d, int(sys.argv[3]) if len(sys.argv) > 3 else 18798)
    elif cmd == "set":
        set_state(d, sys.argv[3])
    elif cmd == "bench":
        bench(d)
