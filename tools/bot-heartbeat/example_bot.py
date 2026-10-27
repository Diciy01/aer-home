"""TEST / EXAMPLE bot for AER HOME (M06). Not a real bot: it talks to nothing
but AER Core, sends heartbeats, prints log lines and runs fake jobs.

Use it to try the Bots section or as a template for wiring aer_heartbeat
into a real bot:

    python3 -u example_bot.py --core http://127.0.0.1:8787 --token-file ~/.config/aer/example-bot.token

Every third job fails on purpose ("simulated failure") so errors, incidents
and job history have something to show. Stops cleanly on SIGTERM.
"""
import argparse
import os
import signal
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aer_heartbeat import Heartbeat  # noqa: E402

VERSION = "0.6.0-example"


def main():
    p = argparse.ArgumentParser(description="AER HOME example (test) bot")
    p.add_argument("--core", required=True)
    p.add_argument("--token-file", required=True)
    p.add_argument("--job-every", type=float, default=20.0)
    p.add_argument("--interval", type=float, default=10.0)
    a = p.parse_args()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    hb = Heartbeat(a.core, token_file=a.token_file, interval=a.interval, name="example-bot", version=VERSION)
    hb.start()
    print("INFO example bot %s started (test bot, no Telegram)" % VERSION, flush=True)

    n = 0
    while not stop.wait(a.job_every):
        n += 1
        job = hb.job_started("Тестовое задание №%d" % n)
        time.sleep(0.5)
        if n % 3 == 0:
            print("ERROR simulated failure in job %d" % n, file=sys.stderr, flush=True)
            hb.job_finished(job, ok=False, error="simulated failure (тест)")
        else:
            print("INFO job %d done" % n, flush=True)
            hb.job_finished(job, ok=True, result="обработано %d записей (тест)" % (n * 3))
            hb.success()

    print("INFO example bot stopping (SIGTERM)", flush=True)
    try:
        hb.send_once()  # deliver the last jobs before exit
    except OSError:
        pass
    hb.stop()


if __name__ == "__main__":
    main()
