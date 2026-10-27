"""AER HOME heartbeat for bots (agent protocol v1, stdlib only).

Usage inside a bot (token from a 0600 file, never from code or logs):

    from aer_heartbeat import Heartbeat
    hb = Heartbeat("http://127.0.0.1:8787", token_file="/etc/aer/pico-bot.token")
    hb.start()                       # background thread, every 15 s
    ...
    hb.success()                     # after a real successful action
    hb.error("timeout to Telegram")  # after a real failure (text is redacted by Core)
    hb.api_ok(False)                 # result of the bot's own dependency check

The bot is reported "online" only while heartbeats arrive; a failing
dependency or a last error newer than the last success shows "degraded".
Network errors never raise into the bot; reports are best effort.
"""
import json
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

VERSION = "0.1.0"


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class Heartbeat:
    def __init__(self, core_url, token_file, interval=15.0, name="bot"):
        self.url = core_url.rstrip("/") + "/api/v1/monitoring/agent/report"
        self.token_file = token_file
        self.interval = interval
        self.name = name
        self.started_at = _now()
        self._lock = threading.Lock()
        self._bot = {"startedAt": self.started_at}
        self._logs = []
        self._stop = threading.Event()
        self.last_error = None

    def success(self):
        with self._lock:
            self._bot["lastSuccessAt"] = _now()

    def error(self, message):
        with self._lock:
            self._bot["lastError"] = str(message)[:300]
            self._bot["lastErrorAt"] = _now()
            self._logs.append({"at": _now(), "level": "error", "source": self.name, "message": str(message)[:2000]})
            del self._logs[:-200]

    def api_ok(self, ok):
        with self._lock:
            self._bot["apiOk"] = bool(ok)

    def send_once(self):
        with open(self.token_file, encoding="utf-8") as f:
            token = f.read().strip()
        with self._lock:
            body = {"agent": {"version": VERSION, "os": "bot"}, "bot": dict(self._bot), "logs": list(self._logs)}
            if "apiOk" in self._bot:
                body["samples"] = [{"metric": "bot.api_ok", "value": 1.0 if self._bot["apiOk"] else 0.0, "at": _now(), "quality": "ok"}]
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        with self._lock:
            self._logs = self._logs[len(body["logs"]):]

    def _loop(self):
        while not self._stop.is_set():
            try:
                self.send_once()
                self.last_error = None
            except (OSError, urllib.error.URLError) as e:  # Core away: retry next tick
                self.last_error = type(e).__name__
            self._stop.wait(self.interval)

    def start(self):
        threading.Thread(target=self._loop, name="aer-heartbeat", daemon=True).start()
        return self

    def stop(self):
        self._stop.set()
