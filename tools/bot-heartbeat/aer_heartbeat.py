"""AER HOME heartbeat for bots (agent protocol v1, stdlib only).

Usage inside a bot (token from a 0600 file, never from code or logs):

    from aer_heartbeat import Heartbeat
    hb = Heartbeat("http://127.0.0.1:8787", token_file="/etc/aer/pico-bot.token")
    hb.start()                       # background thread, every 15 s
    ...
    hb.success()                     # after a real successful action
    hb.error("timeout to Telegram")  # after a real failure (text is redacted by Core)
    hb.api_ok(False)                 # result of the bot's own dependency check

    job = hb.job_started("Ежедневная рассылка")   # jobs (M06 Bots), optional
    ...
    hb.job_finished(job, ok=True, result="отправлено 12")

Pass version="1.4.2" to show the bot's own version in AER HOME. CPU and RAM
of the bot process are sent on Linux (from /proc/self), nothing else.

The bot is reported "online" only while heartbeats arrive; a failing
dependency or a last error newer than the last success shows "degraded".
Network errors never raise into the bot; reports are best effort.
"""
import itertools
import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

VERSION = "0.2.0"


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class Heartbeat:
    def __init__(self, core_url, token_file, interval=15.0, name="bot", version=""):
        self.url = core_url.rstrip("/") + "/api/v1/monitoring/agent/report"
        self.jobs_url = core_url.rstrip("/") + "/api/v1/bots/agent/jobs"
        self.token_file = token_file
        self.interval = interval
        self.name = name
        self.started_at = _now()
        self._lock = threading.Lock()
        self._bot = {"startedAt": self.started_at}
        if version:
            self._bot["version"] = str(version)[:60]
        self._logs = []
        self._jobs = {}  # id -> job dict, sent until accepted
        self._job_seq = itertools.count(1)
        self._cpu_prev = None
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

    def job_started(self, name):
        """Report a job as running; returns its id for job_finished."""
        job_id = "%s-%d" % (self.started_at, next(self._job_seq))
        with self._lock:
            self._jobs[job_id] = {"id": job_id, "name": str(name)[:120], "status": "running", "startedAt": _now()}
        return job_id

    def job_finished(self, job_id, ok=True, result="", error="", cancelled=False):
        with self._lock:
            job = self._jobs.get(job_id) or {"id": job_id, "name": "job", "startedAt": _now()}
            job.update({"status": "cancelled" if cancelled else ("success" if ok else "failed"),
                        "finishedAt": _now(), "result": str(result)[:2000], "error": str(error)[:2000]})
            self._jobs[job_id] = job
            if ok and not cancelled:
                self._bot["lastSuccessAt"] = job["finishedAt"]
        if not ok and not cancelled:
            self.error(error or "job failed")

    def _process_samples(self):
        """CPU % and RSS of this process (Linux /proc); silently absent elsewhere."""
        out = []
        try:
            t = os.times()
            cpu, wall = t.user + t.system, time.monotonic()
            if self._cpu_prev and wall > self._cpu_prev[1]:
                pct = (cpu - self._cpu_prev[0]) / (wall - self._cpu_prev[1]) * 100.0
                out.append({"metric": "process.cpu_percent", "value": round(pct, 2), "at": _now(), "quality": "ok"})
            self._cpu_prev = (cpu, wall)
            with open("/proc/self/statm", encoding="ascii") as f:
                rss = int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
            out.append({"metric": "process.rss_bytes", "value": float(rss), "at": _now(), "quality": "ok"})
        except (OSError, ValueError, IndexError, AttributeError):
            pass
        return out

    def _post(self, url, token, body):
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()

    def send_once(self):
        with open(self.token_file, encoding="utf-8") as f:
            token = f.read().strip()
        samples = self._process_samples()
        with self._lock:
            body = {"agent": {"version": VERSION, "os": "bot"}, "bot": dict(self._bot), "logs": list(self._logs)}
            if "apiOk" in self._bot:
                samples.append({"metric": "bot.api_ok", "value": 1.0 if self._bot["apiOk"] else 0.0, "at": _now(), "quality": "ok"})
            jobs = [dict(j) for j in list(self._jobs.values())[:200]]
        if samples:
            body["samples"] = samples
        self._post(self.url, token, body)
        with self._lock:
            self._logs = self._logs[len(body["logs"]):]
        if jobs:
            self._post(self.jobs_url, token, {"jobs": jobs})
            with self._lock:
                for j in jobs:  # a delivered finished job is forgotten; running ones stay until they finish
                    cur = self._jobs.get(j["id"])
                    if cur is not None and cur["status"] == j["status"] and j["status"] not in ("running", "pending"):
                        del self._jobs[j["id"]]

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
