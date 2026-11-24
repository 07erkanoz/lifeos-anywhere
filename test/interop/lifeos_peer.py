"""A LifeOS Yakındakiler peer for AnyWhere's interop tests (test/interop/lifeos_interop_test.dart).

Runs LifeOS's own code (lifeos_store/yakin.py from the lifeOSArch checkout named by LIFEOS_ARCH) in a throwaway
home: its own config, certificate and trust store. Pairing questions are answered "yes" and their codes written to
stdout; nothing reaches the desktop (no notification, no Ada).

    server ROOT              serves on a free port; prints {"port", "fingerprint", "id"}, then one {"code"} line per
                             pairing question
    client ROOT PORT ID      pairs with the AnyWhere server at 127.0.0.1:PORT (device ID) over TLS and sends it a
                             file; prints {"code", "paired", "sent", "pin"}
    trust ROOT               prints the trust store (yakin-guven.json)
"""

import json
import os
import sys
import threading
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.environ["LIFEOS_ARCH"])
mode, root = sys.argv[1], Path(sys.argv[2])
for name, sub in (("XDG_CONFIG_HOME", "c"), ("XDG_CACHE_HOME", "k"), ("XDG_DATA_HOME", "d")):
    os.environ[name] = str(root / sub)
    (root / sub).mkdir(parents=True, exist_ok=True)

from lifeos_store import yakin  # noqa: E402

incoming = root / "gelen"


def say(**row):
    print(json.dumps(row), flush=True)


for name, value in (("_notify", lambda *a, **k: ""), ("_received", lambda *a: None), ("_incoming", lambda *a: incoming),
                    ("_write_menu", lambda *a: None)):
    mock.patch.object(yakin, name, value).start()
mock.patch.object(yakin, "_ask_pairing", lambda name, platform, device_id="", ip="", code="": say(code=code) or True).start()
from lifeos_store import yakin_paylas  # noqa: E402
mock.patch.object(yakin_paylas, "write_places", lambda *a: None).start()

if mode == "server":
    server = yakin._Server(("127.0.0.1", 0), yakin._Handler)
    say(port=server.server_port, fingerprint=yakin.fingerprint(), id=yakin.identity()["id"])
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sys.stdin.read()  # until the test closes it
elif mode == "client":
    port, device_id = int(sys.argv[3]), sys.argv[4]
    peer = {"id": device_id, "name": "AnyWhere", "ip": "127.0.0.1", "port": port, "platform": "android",
            "seen": 9e12, "here": True, "tls": True}
    mock.patch.object(yakin, "_peer", lambda device: dict(peer)).start()
    codes = []
    result = yakin.pair("AnyWhere", shown=codes.append)
    sample = root / "lifeos-den.txt"
    sample.write_text("LifeOS'tan merhaba", encoding="utf-8")
    sent = yakin.send_files("AnyWhere", [sample])
    say(code=codes[0] if codes else "", paired=bool(result.get("paired")), sent=sent,
        pin=yakin.trusted().get(device_id, {}).get("fingerprint", ""), fingerprint=yakin.fingerprint())
elif mode == "trust":
    say(trust=yakin.trusted())
