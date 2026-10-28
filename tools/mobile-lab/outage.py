#!/usr/bin/env python3
"""Host half of LiveCoreTest.coreOutageAndRecovery (M12). Lab Core only.

  python3 -I tools/mobile-lab/outage.py LABDIR SERIAL ADB

Waits for the app to signal «online», freezes the lab Core (SIGSTOP: the
port stays open but nothing answers — the hardest case for a client), waits
until the app shows the outage, then resumes it (SIGCONT).
"""
import json, os, signal, subprocess, sys, time

d, serial, adb = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
st = json.load(open(os.path.join(d, "lab.json")))
pid = st["corePid"]
if open(f"/proc/{pid}/comm").read().strip() != "aer-core":
    sys.exit("refusing: pid is not the lab aer-core")


def marker(name):
    return subprocess.run([adb, "-s", serial, "shell", "ls", f"/data/local/tmp/{name}"], capture_output=True).returncode == 0


def wait(name, limit=240):
    end = time.time() + limit
    while time.time() < end:
        if marker(name):
            return True
        time.sleep(1)
    return False


if not wait("aer-outage-ready"):
    sys.exit("app never signalled online")
os.kill(pid, signal.SIGSTOP)
print("core stopped", flush=True)
try:
    ok = wait("aer-outage-seen", 120)
    print("app saw outage" if ok else "app did NOT report the outage", flush=True)
finally:
    os.kill(pid, signal.SIGCONT)
    print("core resumed", flush=True)
