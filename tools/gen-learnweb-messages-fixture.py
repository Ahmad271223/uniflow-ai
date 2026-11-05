"""Erzeugt packages/shared-contracts/fixtures/learnweb/messages-cases.json: Learnweb-Nachrichten (Moodle-Unterhaltungen)
der Uni Hildesheim aus der Python-Referenz (app/learnweb_messages.py).
Die Eingaben sind ERFUNDEN (konstruierte Beispiele nach der Moodle-4.4-Schnittstelle, keine echten Personen); der
Swift-Kern prueft dieselben Erwartungen (LearnwebMessagesTests).
Aufruf im Projektordner: python tools/gen-learnweb-messages-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "learnweb" / "messages-cases.json"
BASE = "https://www.uni-hildesheim.de/learnweb2026"
ME = 4711

CONVERSATIONS = {"conversations": [
    {"id": 12, "name": "", "type": 1, "membercount": 2, "unreadcount": 1,
     "members": [{"id": 815, "fullname": "Erika Beispiel (erfunden)"}],
     "messages": [{"id": 345, "useridfrom": 815, "text": "<p>Hallo, die Sprechstunde am 12.11. um 14 Uhr f&auml;llt aus.</p>",
                   "timecreated": 1793869200}]},
    {"id": 13, "name": "Lerngruppe <b>Statistik</b> A", "type": 2, "membercount": 5, "unreadcount": 0,
     "messages": [{"id": 400, "useridfrom": ME, "text": "eigene", "timecreated": 1793876000},
                  {"id": 399, "useridfrom": 900, "text": "Treffen Donnerstag?\nRaum C 012", "timecreated": 1793872800}]},
    {"id": 14, "name": "", "type": 3, "membercount": 1,
     "messages": [{"id": 500, "useridfrom": ME, "text": "Notiz an mich", "timecreated": 1793868400}]},
    {"id": 15, "name": "", "type": 1, "membercount": 2,
     "messages": [{"id": 501, "useridfrom": ME, "text": "nur eigene", "timecreated": 1793868400}]},
    {"id": 16, "type": 1, "messages": []},
]}

CONTEXTS = [
    {"name": "einzeln", "input": {"id": 12, "type": 1, "membercount": 2, "name": "",
                                  "members": [{"id": ME, "fullname": "Ich"}, {"id": 815, "fullname": "Erika Beispiel (erfunden)"}]}},
    {"name": "gruppe", "input": {"id": 13, "type": 2, "membercount": 3, "name": "Lerngruppe Statistik A",
                                 "members": [{"id": 900, "fullname": "Max Muster (erfunden)"}, {"id": 901, "fullname": "Lea Probe (erfunden)"}]}},
    {"name": "gesperrt", "input": {"id": 20, "type": 1, "members": [{"id": 815, "fullname": "Erika Beispiel (erfunden)", "canmessage": False}]}},
    {"name": "selbst", "input": {"id": 14, "type": 3, "members": [{"id": ME, "fullname": "Ich"}]}},
]

PAGES = [
    {"name": "mcfg", "html": '<script>M.cfg = {"wwwroot":"' + BASE + '","sesskey":"AbC123xyz","userId":4711,"theme":"classic"};</script>', "user": 4711, "sesskey": "AbC123xyz"},
    {"name": "popover", "html": '<div id="nav-message-popover-container" data-userid="4711"></div>"sesskey":"k1"', "user": 4711, "sesskey": "k1"},
    {"name": "gast", "html": '<div data-userid="1"></div>', "user": None, "sesskey": None},
]


def build() -> dict:
    sys.path.insert(0, str(ROOT))
    from app import learnweb_messages as lm
    convs = lm.parse_conversations(CONVERSATIONS, ME, BASE, date(2026, 11, 5))
    contexts = [{"name": c["name"], "input": c["input"], "expected": _ctx(lm, c["input"])} for c in CONTEXTS]
    pages = [{**p, "user": lm.user_id_from_page(p["html"]), "sesskey": lm.sesskey_from_page(p["html"])} for p in PAGES]
    assert all(p["user"] == q["user"] and p["sesskey"] == q["sesskey"] for p, q in zip(pages, PAGES))
    return {"_hinweis": "Erzeugt mit tools/gen-learnweb-messages-fixture.py aus app/learnweb_messages.py; "
                        "Eingaben erfunden (Moodle 4.4), nicht von Hand aendern.",
            "base": BASE, "me": ME, "today": "2026-11-05",
            "conversations": {"input": CONVERSATIONS, "expected": convs},
            "contexts": contexts,
            "pages": pages,
            "local_ids": [{"id": "lw-msg-12-345", "conversation": 12}, {"id": "sp-msg-abc", "conversation": None},
                          {"id": "lw-msg-x-1", "conversation": None}],
            "send_args": {"conversation": 12, "text": "Danke!\nBis dann", "expected": lm.send_args(12, "Danke!\nBis dann"),
                          "flat": lm.flatten(lm.send_args(12, "Danke!\nBis dann"))},
            "errors": [{"code": c, "expected": lm.error_for(c).code} for c in
                       ["invalidsesskey", "usercantbemessaged", "invalidrecord", "irgendwas", ""]]}


def _ctx(lm, inp):
    try:
        return lm.reply_context(inp, ME)
    except lm.MessageError as e:
        return {"error": e.code}


def main(check: bool) -> bool:
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
