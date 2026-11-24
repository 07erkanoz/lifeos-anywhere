"""A LifeOS Yakındakiler peer for AnyWhere's interop tests (test/interop/lifeos_interop_test.dart).

Runs LifeOS's own code (lifeos_store/yakin.py from the lifeOSArch checkout named by LIFEOS_ARCH) in a throwaway
home: its own config, certificate and trust store. Pairing questions are answered "yes" and their codes written to
stdout; nothing reaches the desktop (no notification, no Ada).

    server ROOT              serves on a free port; prints {"port", "fingerprint", "id"}, then one {"code"} line per
                             pairing question
    client ROOT PORT ID      pairs with the AnyWhere server at 127.0.0.1:PORT (device ID) over TLS and sends it a
                             file; prints {"code", "paired", "sent", "pin"}
    trust ROOT               prints the trust store (yakin-guven.json)
    esitle ROOT PORT ID DIR  pairs with the AnyWhere server as `client` does, then syncs DIR with it through LifeOS's
                             own Syncthing (yakin_esitle.sync); prints {"paired", "id", "remotePath"}
    kapat ROOT               stops this home's Syncthing (the one yakin_esitle started)
    oku ROOT ID              prints LifeOS İleti's conversation with device ID (ileti.conversation)
    yaz ROOT PORT ID TEXT FILE   LifeOS İleti sends TEXT, then FILE, to the AnyWhere server at 127.0.0.1:PORT
    okundu ROOT PORT ID      LifeOS read the conversation (its read receipt goes to AnyWhere)
    posta-tanis ROOT PORT ID     (the real LifeOS server) LifeOS opens its box and exchanges boxes with AnyWhere on
                                 the network; prints {"adres", "theirs"}
    posta-al ROOT ID             LifeOS fetches its box once and takes what came; prints the conversation
    posta-yaz ROOT ID TEXT       LifeOS writes to AnyWhere, which is away: through the server
    posta-davet ROOT             LifeOS makes a remote pairing code; prints {"code"}
    posta-bekle ROOT CODE        LifeOS waits for the code's answer; prints what ileti_uzak.wait_invite returned
    posta-katil ROOT CODE        LifeOS joins with a code; prints what ileti_uzak.join returned and the trust store
    posta-calis ROOT SECONDS ID [PATH]  LifeOS online for SECONDS as lifeos-yakin.service is (its box loop and its
                                 queue); with PATH it first sends that file to ID, which is away; prints the conversation

Eşitleme: LIFEOS_ESITLE_GUI and LIFEOS_ESITLE_PORT must be set (a Syncthing of its own, never the computer's
lifeos-esitleme.service); its state, like everything else, is under ROOT.
"""

import json
import os
import sys
import threading
import time
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.environ["LIFEOS_ARCH"])
mode, root = sys.argv[1], Path(sys.argv[2])
for name, sub in (("XDG_CONFIG_HOME", "c"), ("XDG_CACHE_HOME", "k"), ("XDG_DATA_HOME", "d"),
                  ("XDG_STATE_HOME", "s"), ("HOME", "ev")):
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
mock.patch.object(yakin_paylas, "allowed", lambda device, kind, ask=True: True).start()  # "eşitleme": yes
from lifeos_store import ileti, ileti_posta  # noqa: E402
# İleti: no desktop (notifications, its window) and never the internet (the support server's mailbox)
for name in ("in_front", "notice", "announce", "open_app"):
    mock.patch.object(ileti, name, lambda *a, **k: None).start()
if not mode.startswith("posta"):   # the posta-* modes use the real LifeOS server (ILETI_SUNUCU=1 tests only)
    mock.patch.object(ileti_posta, "ready", lambda *a, **k: False).start()


def phone_at(port, device_id):
    """AnyWhere's server at 127.0.0.1:PORT, as Yakındakiler would have heard it."""
    peer = {"id": device_id, "name": "AnyWhere", "ip": "127.0.0.1", "port": port, "platform": "android",
            "seen": 9e12, "here": True, "tls": True}
    mock.patch.object(yakin_paylas, "_peer_of", lambda device: dict(peer)).start()
    yakin._State.peers[device_id] = {**peer, "seen": time.time()}

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
elif mode == "esitle":
    from lifeos_store import yakin_esitle
    port, device_id, folder = int(sys.argv[3]), sys.argv[4], sys.argv[5]
    peer = {"id": device_id, "name": "AnyWhere", "ip": "127.0.0.1", "port": port, "platform": "android",
            "seen": 9e12, "here": True, "tls": True}
    mock.patch.object(yakin, "_peer", lambda device: dict(peer)).start()
    result = yakin.pair("AnyWhere", shown=lambda code: None)
    mock.patch.object(yakin_paylas, "_peer_of", lambda device: dict(peer)).start()
    done = yakin_esitle.sync(device_id, folder)
    say(paired=bool(result.get("paired")), id=done["id"], remotePath=done["remotePath"])
elif mode == "kapat":
    from lifeos_store import yakin_esitle
    if yakin_esitle.running():
        yakin_esitle._api("POST", "/rest/system/shutdown")
    say(ok=True)
elif mode == "oku":
    say(conversation=ileti.conversation(sys.argv[3]))
elif mode == "yaz":
    port, device_id, text, path = int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
    phone_at(port, device_id)
    a = ileti.send_text(device_id, text)
    b = ileti.send_files(device_id, [path])
    say(text=a, file=b, conversation=ileti.conversation(device_id))
elif mode == "okundu":
    port, device_id = int(sys.argv[3]), sys.argv[4]
    phone_at(port, device_id)
    ileti.mark_read(device_id, wait=True)
    say(conversation=ileti.conversation(device_id))
elif mode == "posta-tanis":
    port, device_id = int(sys.argv[3]), sys.argv[4]
    phone_at(port, device_id)
    ok = ileti.exchange(device_id)
    ileti_posta.sync_allowed(force=True)
    say(ok=ok, adres=ileti_posta.address(), theirs=ileti_posta.peer_address(device_id))
elif mode == "posta-al":
    device_id = sys.argv[3]
    got = ileti_posta.fetch((), wait=8)
    for envelope in got:
        ileti.from_server(envelope)
    ileti_posta.fetch([str(e.get("id", "")) for e in got], wait=0)
    say(count=len(got), conversation=ileti.conversation(device_id))
elif mode == "posta-yaz":
    device_id, text = sys.argv[3], sys.argv[4]
    yakin._State.peers.pop(device_id, None)   # away: not heard on the network
    mock.patch.object(yakin_paylas, "_peer_of", lambda device: {"id": device, "name": "AnyWhere", "ip": "",
                                                                "port": 0, "platform": "android", "tls": True}).start()
    ileti.send_text(device_id, text)
    say(conversation=ileti.conversation(device_id))
elif mode == "posta-davet":
    from lifeos_store import ileti_uzak
    say(code=ileti_uzak.invite()["code"])
elif mode == "posta-bekle":
    from lifeos_store import ileti_uzak
    for _ in range(10):
        done = ileti_uzak.wait_invite(sys.argv[3], seconds=15)
        if not done.get("waiting"):
            break
    say(done=done, trust=yakin.trusted())
elif mode == "posta-katil":
    from lifeos_store import ileti_uzak
    say(done=ileti_uzak.join(sys.argv[3]), trust=yakin.trusted())
elif mode == "posta-calis":
    seconds, device_id = int(sys.argv[3]), sys.argv[4]
    yakin._State.peers.pop(device_id, None)   # away: never on this network
    mock.patch.object(yakin_paylas, "_peer_of", lambda device: {"id": device, "name": "AnyWhere", "ip": "",
                                                                "port": 0, "platform": "android", "tls": True}).start()
    stop = threading.Event()
    threading.Thread(target=ileti_posta.run, args=(stop,), daemon=True).start()
    threading.Thread(target=ileti.pump, args=(stop,), daemon=True).start()
    if len(sys.argv) > 5:
        time.sleep(3)
        ileti.send_files(device_id, [sys.argv[5]], text="internetten dosya")
    say(online=True)
    time.sleep(seconds)
    stop.set()
    say(conversation=ileti.conversation(device_id))
elif mode == "trust":
    say(trust=yakin.trusted())
