"""Uni-Mail und Uni-Kalender (SOGo der LUH, docs/UNI-MAIL-2026-11-05.md): gemeinsame Faelle fuer Python und den Swift-Kern.

Liest die nachgebauten Antworten in packages/shared-contracts/fixtures/sogo/raw (erfunden, keine persoenlichen Daten;
Aufbau wie am 05.11.2026 gelesen bzw. aus dem Quelltext von SOGo abgeleitet) und schreibt
packages/shared-contracts/fixtures/sogo/cases.json mit den Ergebnissen von app/sogo.py: Ordnerpfade, Konto aus der
Adresse, Ablauf der Sitzung, Empfaengerfelder, HTML bereinigen, Klartext, Ordner, Kopfzeilen, Nachrichten, Entwuerfe,
Koerper fuer Speichern/Senden, Antwort des Sendens, ungelesene, Termine und Vorkommen im Stundenplan. Der Swift-Kern
(SOGoTests) prueft dieselben Faelle. Laedt nie etwas aus dem Netz.

Aufruf im Projektordner: .venv/bin/python tools/gen-sogo-fixture.py [--check]
"""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from schema_source import ROOT, write_or_check  # noqa: E402

from app import sogo  # noqa: E402

FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "sogo"
RAW = FX / "raw"
CASES = FX / "cases.json"
USER = "erika.muster@stud.uni-hannover.de"


def raw(name: str):
    return json.loads((RAW / name).read_text(encoding="utf-8"))


CSS = ["INBOX", "INBOX/Archiv 2026", "Sent Items", "a.b_c#d@e*f:g,h'i&j+k", "2026", "Übungen", ""]

URLS = [
    f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Calendar/view",
    "https://kalender.uni-hannover.de/SOGo/so/erika.muster%40stud.uni-hannover.de/Mail/view",
    "https://kalender.uni-hannover.de/SOGo/so/",
    "https://kalender.uni-hannover.de/SOGo/",
    "http://kalender.uni-hannover.de/SOGo/so/x/Mail",
    "https://evil.example/SOGo/so/x/Mail",
    "https://kalender.uni-hannover.de:8443/SOGo/so/x/Mail",
    "https://kalender.uni-hannover.de/SOGo/so/../Mail",
    "https://kalender.uni-hannover.de/other/so/x/Mail",
    "https://Kalender.Uni-Hannover.DE:443/SOGo/so/x%2Fy/Mail",
    "https://kalender.uni-hannover.de/SOGo/so/x/Mail?a=1#f",
    "",
]

EXPIRED = [
    [200, f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/view", "{}"],
    [401, None, ""],
    [403, f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/view", ""],
    [200, "https://kalender.uni-hannover.de/SOGo/", "<html></html>"],
    [200, None, "LOGIN"],
    [200, None, "<p>ok</p>"],
    [404, f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/mailboxes", "not found"],
]

RECIPIENTS = [
    "a@b.de", "Max Beispiel <max@example.uni-hannover.de>, tutor@example.uni-hannover.de",
    "\"Beispiel, Max\" <max@example.uni-hannover.de>; kaputt; x@y", "  \n , ;", "a@b.de\nc@d.de",
    "Name <a@b.de> extra", "<a@b.de>", "a b@c.de",
]

HTML = [
    "<p>Hallo <b>Welt</b></p>",
    "<a href='javascript:alert(1)' onmouseover=\"x()\">Link</a><a href=\"https://www.uni-hannover.de\">LUH</a>",
    "<img src=\"cid:123\"><img src='//cdn.example/x.png'><img SRC = \"HTTPS://x.example/y.png\" srcset=\"https://a 1x\">",
    "<div style=\"background-image: URL( 'https://x' )\">x</div><table background=\"http://x/bg.gif\"><tr><td>1</td></tr></table>",
    "<SCRIPT type=\"text/javascript\">evil()</SCRIPT><Style>.a{}</Style><meta http-equiv=\"refresh\" content=\"0\"><base href=\"https://x\">ok",
    "<svg onload=alert(1)><circle/></svg><math>1</math>text<object data=\"x\"></object><embed src=\"x\">",
    "<a href=\"data:text/html;base64,PHNjcmlwdD4=\">d</a><img src=\"data:image/png;base64,AAAA\">",
    "",
]

TEXT = [
    "<p>Absatz 1</p><p>Absatz 2</p>",
    "Zeile<br>Zeile<br/>Zeile<BR />",
    "<ul><li>eins</li><li>zwei</li></ul>",
    "&lt;tag&gt; &amp;amp; &quot;x&quot; &#39;y&#39; &#x41;&#66; &#0; &#xD800; &nbsp;&euro;",
    "<p>Am Montag schrieb A:</p><blockquote type=\"cite\"><p>erste</p><p>zweite</p><blockquote>dritte<br>vierte</blockquote>wieder eins</blockquote><p>danach</p>",
    "\n\n\n<div>a</div>\n\n\n\n<div>b</div>   \n\t",
    "<style>x{}</style><!-- c -->sichtbar<script>y()</script>",
    "",
]

SEND = [
    {"from": "a@b.de", "to": ["x@y.de"], "cc": [], "bcc": []},
    {"from": "a@b.de", "to": [], "cc": [], "bcc": ["x@y.de"]},
    {"from": "a@b.de", "to": [], "cc": [], "bcc": []},
    {"from": "a@b.de", "to": ["kaputt", "Name <x@y.de>"], "cc": [], "bcc": []},
    {"from": "", "to": ["x@y.de"], "cc": [], "bcc": []},
]


def occurrences() -> dict:
    conn = sqlite3.connect(":memory:")
    events = sogo.parse_events(raw("events.json"))
    n = sogo.store_events(conn, events, date(2026, 11, 9), date(2026, 11, 20), "2026-11-09T08:00:00")
    # zweiter Abruf eines kleineren Zeitraums: frueher gelesene Termine ausserhalb bleiben
    m = sogo.store_events(conn, [e for e in events if e["start"] < "2026-11-12"], date(2026, 11, 9), date(2026, 11, 11), "2026-11-09T09:00:00")
    occ = sogo.calendar_occurrences(conn, date(2026, 11, 9), date(2026, 11, 15))
    base = [{"event_id": 1, "date": "2026-11-09", "start": "08:15", "end": "09:45", "title": "Analysis", "status": "teilnahme"},
            {"event_id": 2, "date": "2026-11-09", "start": "10:15", "end": "11:45", "title": "tutorium  analysis", "status": "teilnahme"},
            {"event_id": 3, "date": "2026-11-10", "start": "16:00", "end": "17:00", "title": "Seminar", "status": "teilnahme"}]
    merged = sogo.with_calendar(conn, base, date(2026, 11, 9), date(2026, 11, 15))
    stored = sogo.stored_events(conn, date(2026, 11, 9), date(2026, 11, 30))
    empty = sogo.with_calendar(sqlite3.connect(":memory:"), base, date(2026, 11, 9), date(2026, 11, 15))
    return {"stored_first": n, "stored_second": m, "occurrences": occ, "merged": merged, "stored": stored, "no_table": empty,
            "range": ["2026-11-09", "2026-11-15"]}


def cases() -> dict:
    created = sogo.parse_created(raw("created-reply.json"))
    reply = sogo.draft(created, raw("edit-reply-html.json"), "reply", {"folder": "INBOX", "uid": 128})
    compose = sogo.draft(sogo.parse_created(raw("created-compose.json")), raw("edit-compose.json"))
    forward = sogo.draft(created, raw("edit-forward.json"), "forward", {"folder": "INBOX", "uid": 125})
    try:
        sogo.parse_created(raw("created-bad.json"))
        bad = None
    except sogo.SOGoError as e:
        bad = e.code
    boxes = sogo.parse_mailboxes(raw("mailboxes.json"))
    return {
        "user": USER,
        "css": [{"in": s, "css": sogo.css_identifier(s), "path": sogo.folder_path(s) if s else None,
                 "id": sogo.mailbox_id(s) if s else None, "move": sogo.move_target(s) if s else None} for s in CSS],
        "user_from_url": [{"url": u, "user": sogo.user_from_url(u)} for u in URLS],
        "login_page": sogo.looks_like_login((RAW / "login-page.html").read_text(encoding="utf-8")),
        "expired": [{"status": s, "final": f, "body": (RAW / "login-page.html").read_text(encoding="utf-8") if b == "LOGIN" else b,
                     "expired": sogo.expired(s, f, (RAW / "login-page.html").read_text(encoding="utf-8") if b == "LOGIN" else b)}
                    for s, f, b in EXPIRED],
        "truthy": [{"in": v, "out": sogo.truthy(v)} for v in [True, False, None, 0, 1, 2.0, "1", "true", "YES", "0", "", [], {}]],
        "recipients": [{"in": r, "out": sogo.split_recipients(r), "email": [sogo.email_of(x) for x in r.split(",")]} for r in RECIPIENTS],
        "sanitize": [{"in": h, "out": sogo.sanitize_html(h)} for h in HTML],
        "text": [{"in": h, "out": sogo.html_to_text(h)} for h in TEXT],
        "mailboxes": {"raw": "mailboxes.json", "out": boxes, "trash": sogo.folder_of_type(boxes, "trash", "Trash"),
                      "missing": sogo.folder_of_type([], "trash", "Trash")},
        "folder_request": [{"q": q, "body": sogo.folder_request(q)} for q in ["", "  Klausur   Analysis ", "x" * 300]],
        "folder": {"raw": "folder-inbox.json", "out": sogo.parse_folder(raw("folder-inbox.json"), "INBOX"),
                   "page1": sogo.page_uids(sogo.parse_folder(raw("folder-inbox.json"), "INBOX")["uids"], 1),
                   "page9": sogo.page_uids(sogo.parse_folder(raw("folder-inbox.json"), "INBOX")["uids"], 9),
                   "empty": sogo.parse_folder({}, "Sent")},
        "headers": {"raw": "headers-page2.json", "out": sogo.ordered(sogo.parse_headers(raw("headers-page2.json")), [79, 78, 77])},
        "flatten": [{"in": v, "out": sogo.flatten_uids(v)} for v in [[1, [2, 3], [[4]]], [5, 5, "6", "x", 0, -1, True, 7.0], "8", None]],
        "message_html": {"raw": "message-html.json", "out": sogo.parse_message(raw("message-html.json"), "INBOX", 128)},
        "message_text": {"raw": "message-text.json", "out": sogo.parse_message(raw("message-text.json"), "INBOX/Übungen", 3)},
        "attachment_path": [{"in": u, "out": sogo.attachment_path(u)} for u in [
            f"/SOGo/so/{USER}/Mail/0/folderINBOX/1/2/asAttachment/a.pdf",
            f"https://kalender.uni-hannover.de/SOGo/so/{USER}/Mail/0/folderINBOX/1/2/asAttachment/a.pdf?x=1",
            f"/SOGo/so/{USER}/Mail/0/folderINBOX/1/3/asAttachment/Blatt 3 (neu).pdf",
            "https://kalender.uni-hannover.de:abc/SOGo/so/x/a", "https://evil.example/SOGo/so/x/a", "/SOGo/x", "", None]],
        "quote_path": [{"in": p, "out": sogo.quote_path(p)} for p in [
            f"/SOGo/so/{USER}/Mail/0/folderINBOX/1/3/asAttachment/Blatt 3 (neu).pdf", "/SOGo/so/x/a%20b?x=1&y=ä", ""]],
        "created_bad": bad,
        "draft_reply": {"created": "created-reply.json", "edit": "edit-reply-html.json", "out": reply},
        "draft_compose": {"created": "created-compose.json", "edit": "edit-compose.json", "out": compose},
        "draft_forward": {"created": "created-reply.json", "edit": "edit-forward.json", "out": forward},
        "payload": [
            {"draft": "reply", "to": "Prof. Dr. Max Beispiel <max.beispiel@example.uni-hannover.de>", "cc": "tutor@example.uni-hannover.de; ",
             "bcc": "", "subject": reply["subject"], "text": "Danke!\r\n\r\n" + reply["text"],
             "out": sogo.payload(reply, "Prof. Dr. Max Beispiel <max.beispiel@example.uni-hannover.de>", "tutor@example.uni-hannover.de; ", "",
                                 reply["subject"], "Danke!\r\n\r\n" + reply["text"])},
            {"draft": "compose", "to": ["a@b.de", "  ", "Name  <c@d.de>"], "cc": [], "bcc": ["x@y.de"], "subject": "Frage", "text": "Hallo",
             "out": sogo.payload({**compose, "reply_to": "antwort@example.uni-hannover.de"}, ["a@b.de", "  ", "Name  <c@d.de>"], [], ["x@y.de"],
                                 "Frage", "Hallo")},
        ],
        "check_send": [{"in": b, "out": sogo.check_send(b)} for b in SEND],
        "send_result": [
            {"status": 200, "raw": "send-ok.json", "out": sogo.send_result(200, raw("send-ok.json"))},
            {"status": 405, "raw": "send-fail.json", "out": sogo.send_result(405, raw("send-fail.json"))},
            {"status": 500, "raw": None, "out": sogo.send_result(500, None)},
        ],
        "unseen": {"raw": "unseen.json", "inbox": sogo.parse_unseen(raw("unseen.json")), "sent": sogo.parse_unseen(raw("unseen.json"), "Sent"),
                   "missing": sogo.parse_unseen(raw("unseen.json"), "Junk")},
        "new_since": [{"uids": [130, 129, 128, 120], "last": 128, "out": sogo.new_since([130, 129, 128, 120], 128)},
                      {"uids": [130, 129], "last": None, "out": sogo.new_since([130, 129], None)}],
        "events": {"raw": "events.json", "out": sogo.parse_events(raw("events.json"))},
        "events_query": [{"day": "2026-11-09", "days": d, "out": sogo.events_query(date(2026, 11, 9), d)} for d in (7, 14, 30)],
        "calendars": {"raw": "calendars.json", "out": sogo.parse_calendars(raw("calendars.json"))},
        "multipart": {"name": "Blatt 3/Lösung \"final\".pdf", "mime": "application/pdf", "data": "%PDF-1.4 x",
                      "out": sogo.multipart("Blatt 3/Lösung \"final\".pdf", b"%PDF-1.4 x", "application/pdf")[0].decode("utf-8"),
                      "type": sogo.multipart("x", b"", "")[1]},
        "calendar": occurrences(),
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    ok = write_or_check(CASES, json.dumps(cases(), ensure_ascii=False, indent=1) + "\n", check)
    return 1 if check and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
