"""TEST STAND for AER Remote 2 (M14): real RDP through the own Gateway.

Starts, all on this machine and on loopback only:
  * the isolated headless GNOME host of lab-host.sh (own D-Bus/XDG dirs),
  * an isolated aer-core (own data dir, 127.0.0.1:<core port>),
  * aer-remote-gateway on 127.0.0.1:<gateway port> (fresh certificate),
  * aer-remote-host inside the lab session with the REAL gnome-remote-desktop
    (grdctl --headless), relay legs to the Gateway,
and prints/writes DIR/lab.json (pairing code, fingerprint, ids).
Nothing is exposed beyond 127.0.0.1 except what lab-host.sh's
gnome-remote-desktop binds (its test port, only while a session is open).

  python3 -I tools/remote-lab/relay_lab.py up DIR [core_port] [gw_port] [rdp_port]
  python3 -I tools/remote-lab/relay_lab.py down DIR
All data is TEST DATA.
"""
import json, os, signal, socket, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(ROOT, "core", "bin")
PIDS = {}


def wait_port(port, what, tries=200):
    for _ in range(tries):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    raise SystemExit(f"{what} did not come up on {port}")


def wait_file(path, tries=200):
    for _ in range(tries):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return
        time.sleep(0.1)
    raise SystemExit(f"{path} missing")


def up(d, core_port=18787, gw_port=18443, rdp_port=33891):
    d = os.path.abspath(d)
    os.makedirs(d, exist_ok=True)
    for p in (core_port, gw_port, rdp_port):
        try:
            socket.create_connection(("127.0.0.1", p), 0.2).close()
            raise SystemExit(f"port {p} is busy — refusing to touch whatever runs there")
        except OSError:
            pass
    pids = PIDS
    lab = os.path.join(d, "host")
    henv = dict(os.environ, AER_LAB_VMON=os.environ.get("AER_LAB_VMON", "none"))
    out = subprocess.check_output(["bash", os.path.join(ROOT, "tools/remote-lab/lab-host.sh"), lab, str(rdp_port)], env=henv).decode()
    pids["host"] = int(out.split()[-1])
    wait_file(os.path.join(lab, "bus"))

    env = dict(os.environ, AER_DATA_DIR=os.path.join(d, "core"), AER_LISTEN=f"127.0.0.1:{core_port}")
    core = subprocess.Popen([os.path.join(BIN, "aer-core")], env=env, stdout=open(os.path.join(d, "core.log"), "w"),
                            stderr=subprocess.STDOUT, start_new_session=True)
    pids["core"] = core.pid
    wait_port(core_port, "aer-core")
    owner = open(os.path.join(d, "core", "core.token")).read().strip()

    def api(method, path, body=None):
        req = urllib.request.Request(f"http://127.0.0.1:{core_port}/api/v1{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer " + owner, "Content-Type": "application/json"})
        with urllib.request.urlopen(req) as r:
            return json.load(r)["data"]

    srv = api("POST", "/registry/entities", {"name": "Сервер (стенд)", "type": "server"})
    pc = api("POST", "/registry/entities", {"name": "Тестовый хост Wayland (стенд)", "type": "computer"})
    gw = api("POST", "/monitoring/agents", {"entityId": srv["id"], "name": "gateway", "kind": "gateway"})
    host = api("POST", "/monitoring/agents", {"entityId": pc["id"], "name": "remote", "kind": "remote"})
    api("PUT", f"/remote/hosts/{pc['id']}/policy", {"enabled": True, "desktop": True, "clipboard": True, "files": True, "maxMinutes": 30})

    def secret(name, value):
        p = os.path.join(d, name)
        with open(p, "w") as f:
            f.write(value)
        os.chmod(p, 0o600)
        return p

    gwdir = os.path.join(d, "gw")
    os.makedirs(gwdir, exist_ok=True)
    gcfg = {"listenAddr": f"127.0.0.1:{gw_port}", "coreUrl": f"http://127.0.0.1:{core_port}",
            "tokenFile": secret("gateway.token", gw["token"]), "stateDir": gwdir, "aliveCheckSec": 2, "pairLimit": 100}  # lab: many test pairings
    json.dump(gcfg, open(os.path.join(gwdir, "gw.json"), "w"))
    fp = subprocess.check_output([os.path.join(BIN, "aer-remote-gateway"), "-config", os.path.join(gwdir, "gw.json"), "-fingerprint"]).decode().strip()
    g = subprocess.Popen([os.path.join(BIN, "aer-remote-gateway"), "-config", os.path.join(gwdir, "gw.json")],
                         stdout=open(os.path.join(d, "gateway.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
    pids["gateway"] = g.pid
    wait_port(gw_port, "aer-remote-gateway")

    acfg = {"coreUrl": f"http://127.0.0.1:{core_port}", "tokenFile": secret("remote-host.token", host["token"]),
            "stateDir": os.path.join(d, "agent"), "backend": "gnome-rdp", "grdctl": ["grdctl", "--headless"],
            "daemon": ["/usr/libexec/gnome-remote-desktop-daemon", "--headless"], "address": "127.0.0.1", "port": rdp_port,
            "rdpUser": "aer", "tlsCert": os.path.join(lab, "tls.crt"), "tlsKey": os.path.join(lab, "tls.key"), "approval": "auto",
            "clipboard": True, "files": {"enabled": True, "dir": os.path.join(d, "exchange"), "port": rdp_port + 1, "maxBytes": 10485760},
            "gatewayUrl": f"https://127.0.0.1:{gw_port}", "gatewayCertSha256": fp}
    json.dump(acfg, open(os.path.join(d, "remote-host.json"), "w"))
    # The agent runs inside the lab session: its D-Bus and XDG dirs only.
    aenv = dict(os.environ)
    for line in open(os.path.join(lab, "env.sh")):
        line = line.strip()
        if line.startswith("export "):
            for kv in line[len("export "):].split():
                k, v = kv.split("=", 1)
                aenv[k] = v
    aenv.pop("DISPLAY", None)
    aenv.pop("WAYLAND_DISPLAY", None)
    aenv["DBUS_SESSION_BUS_ADDRESS"] = open(os.path.join(lab, "bus")).read().strip()
    a = subprocess.Popen([os.path.join(BIN, "aer-remote-host"), "-config", os.path.join(d, "remote-host.json")], env=aenv,
                         stdout=open(os.path.join(d, "agent.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
    pids["agent"] = a.pid
    for _ in range(200):
        if api("GET", f"/remote/hosts/{pc['id']}")["canConnect"]:
            break
        time.sleep(0.1)
    else:
        raise SystemExit("host agent not ready, see agent.log")
    client = api("POST", "/remote/clients", {"name": "AER Connect (стенд)", "hosts": [pc["id"]], "clipboard": True, "files": True})
    info = {"gateway": f"https://127.0.0.1:{gw_port}", "fingerprint": fp, "pairingCode": client["code"],
            "clientId": client["client"]["id"], "hostId": pc["id"], "coreUrl": f"http://127.0.0.1:{core_port}",
            "ownerTokenFile": os.path.join(d, "core", "core.token"), "exchangeDir": acfg["files"]["dir"],
            "labDir": lab, "rdpPort": rdp_port, "pids": pids}
    json.dump(info, open(os.path.join(d, "lab.json"), "w"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in info.items() if k != "pairingCode"}, ensure_ascii=False))


def repair(d):
    """End leftover sessions and issue a fresh pairing code (between runs)."""
    p = os.path.join(os.path.abspath(d), "lab.json")
    info = json.load(open(p))
    tok = open(info["ownerTokenFile"]).read().strip()

    def call(method, path):
        req = urllib.request.Request(info["coreUrl"] + "/api/v1" + path, method=method, headers={"Authorization": "Bearer " + tok})
        with urllib.request.urlopen(req) as r:
            return json.load(r)["data"]

    for s in call("GET", "/remote/sessions?limit=20"):
        if s["state"] not in ("disconnected", "failed", "expired", "revoked"):
            call("POST", f"/remote/sessions/{s['id']}/end")
    clients = [c for c in call("GET", "/remote/clients") if not c["revokedAt"]]
    if clients:
        info["clientId"] = clients[0]["id"]
        info["pairingCode"] = call("POST", f"/remote/clients/{clients[0]['id']}/pairing")["code"]
    else:
        c = json.dumps({"name": "AER Connect (стенд)", "hosts": [info["hostId"]], "clipboard": True, "files": True}).encode()
        req = urllib.request.Request(info["coreUrl"] + "/api/v1/remote/clients", data=c, method="POST",
                                     headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
        r = json.load(urllib.request.urlopen(req))["data"]
        info["clientId"], info["pairingCode"] = r["client"]["id"], r["code"]
    json.dump(info, open(p, "w"), ensure_ascii=False, indent=1)
    print("repaired")


def down(d):
    info = json.load(open(os.path.join(os.path.abspath(d), "lab.json")))
    # agent first: it disables RDP and clears credentials on SIGTERM
    for name in ("agent", "gateway", "core", "host"):
        pid = info["pids"].get(name)
        if not pid:
            continue
        try:
            os.killpg(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            continue
        for _ in range(50):
            try:
                os.kill(pid, 0)
                time.sleep(0.1)
            except ProcessLookupError:
                break
    print("stopped")


if __name__ == "__main__":
    if sys.argv[1] == "up":
        try:
            up(sys.argv[2], *[int(x) for x in sys.argv[3:6]])
        except BaseException:
            # leave a lab.json with whatever started, so "down" can stop it
            p = os.path.join(os.path.abspath(sys.argv[2]), "lab.json")
            if not os.path.exists(p):
                json.dump({"pids": PIDS}, open(p, "w"))
            raise
    elif sys.argv[1] == "repair":
        repair(sys.argv[2])
    elif sys.argv[1] == "down":
        down(sys.argv[2])
