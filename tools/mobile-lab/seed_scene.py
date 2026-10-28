#!/usr/bin/env python3
"""AER mobile client lab (M12). TEST DATA only, isolated Core from tools/network-lab.

  python3 -I tools/network-lab/lab.py up DIR 18798      # stubs + isolated Core
  python3 -I tools/mobile-lab/seed_scene.py DIR          # store a scene bound to the lab entities

Takes the canonical demo layout (examples/home.scene.json), binds the router,
switch, PC and TV objects to the lab's Registry entities, drops the demo test
states (allowed only in demo scenes) and stores it in the lab Core, so the
Android «Дом» shows real Monitoring states. Never run it against a real Core.
"""
import json, os, sys, urllib.request, uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main(d):
    st = json.load(open(os.path.join(d, "lab.json")))
    if not st["url"].startswith("http://127.0.0.1:"):
        sys.exit("refusing: not a loopback lab Core")
    token = open(os.path.join(d, "data", "core.token")).read().strip()
    doc = json.load(open(os.path.join(ROOT, "examples", "home.scene.json")))
    doc["sceneId"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "aer-mobile-lab-scene"))
    doc["name"] = "Дом (стенд мобильного клиента)"
    doc["demo"] = False
    doc["metadata"] = {"source": "tools/mobile-lab", "note": "Тестовая сцена стенда"}
    binds = {"cozy/router": st["router"], "cozy/network_switch": st["switch"], "cozy/pc_tower": st["pc"], "cozy/tv": st["tv"]}
    used = set()
    for o in doc["objects"]:
        o["visualState"] = None
        a = o["assetId"]
        if a in binds and a not in used:
            o["entityBinding"] = {"entityId": binds[a], "role": "primary"}
            used.add(a)
    req = urllib.request.Request(st["url"] + "/api/v1/scenes", method="POST", data=json.dumps(doc).encode())
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print("stored", r.status, doc["sceneId"], "bound:", sorted(used))
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 409:
            print("already stored", doc["sceneId"])
        else:
            sys.exit(f"{e.code} {body}")


if __name__ == "__main__":
    main(os.path.abspath(sys.argv[1]))
