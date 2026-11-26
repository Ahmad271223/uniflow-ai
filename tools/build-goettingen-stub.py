"""Nachbildung des Stud.IP der Uni Goettingen fuer Simulator und Tests (docs/GOETTINGEN-2026-11-26.md).

Schreibt apps/apple/DebugStub/goettingen/: Anmeldeseite mit den echten Feldnamen des Formulars, `routes.json` und die
Antworten der JSON:API im Aufbau, wie er am 26.11.2026 am echten Stud.IP Goettingen gesehen wurde (Feldnamen, Status,
Arten) - mit erfundenen Kursen, Personen und Texten. Auch die Antworten, die dort NICHT gehen, sind nachgebildet:
`studip/news` 500, Sprechstunden 404, Wiki 404, `courseware-tasks` 400, `courseware-task-groups` 404, die Erweiterung
der LUH fuer Aufzeichnungen 403. Laedt nie etwas aus dem Netz.

Aufruf im Projektordner: .venv/bin/python tools/build-goettingen-stub.py [--check]
"""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps" / "apple" / "DebugStub" / "goettingen"
PDFS = ROOT / "apps" / "apple" / "DebugStub" / "erststart"
BASE = "https://studip.uni-goettingen.de"
API = "jsonapi.php/v1/"


def hid(name: str) -> str:
    """Kennung wie in Stud.IP (32 Hex-Zeichen), fest aus dem Namen"""
    return hashlib.md5(("goettingen-stub:" + name).encode()).hexdigest()


ME = hid("user-me")
DOZ, TUT = hid("user-dozentin"), hid("user-tutor")
SEM_W26, SEM_S26 = hid("sem-w26"), hid("sem-s26")
COURSES = [
    # (Schluessel, Titel, Nummer, Art laut sem-types Goettingen, Semester, Endsemester-Beziehung?)
    ("mathe", "Mathematik für Wirtschaftswissenschaftler", "700011", 111, SEM_W26, True),      # Vorlesung mit Übung
    ("mathe-ue", "Übung zu Mathematik für Wirtschaftswissenschaftler", "700012", 21, SEM_W26, True),
    ("recht", "Einführung in das Bürgerliche Recht", "200305", 1, SEM_W26, True),
    ("sem", "Seminar Unternehmensführung", "800120", 4, SEM_W26, True),
    ("forum", "Erstsemester-Forum der Fakultät", None, 15, SEM_W26, False),                    # ohne end-semester
    ("alt", "Statistik (Sommersemester)", "700020", 1, SEM_S26, True),
]
CID = {k: hid("course-" + k) for k, *_ in COURSES}
SEMESTERS = {
    SEM_W26: {"title": "WiSe 2026/27", "token": "", "start": "2026-10-01T00:00:00+02:00", "end": "2027-03-31T23:59:59+02:00",
              "start-of-lectures": "2026-10-26T00:00:00+01:00", "end-of-lectures": "2027-02-12T23:59:59+01:00",
              "visible": True, "is-current": True},
    SEM_S26: {"title": "SoSe 2026", "token": "", "start": "2026-04-01T00:00:00+02:00", "end": "2026-09-30T23:59:59+02:00",
              "start-of-lectures": "2026-04-13T00:00:00+02:00", "end-of-lectures": "2026-07-17T23:59:59+02:00",
              "visible": True, "is-current": False},
}
# (Kurs, Ordner, Datei-Schluessel, Name, PDF aus dem Erststart-Stub, geaendert)
FILES = [
    ("mathe", None, "m1", "01_Vorlesung_Mengen_und_Abbildungen.pdf", "ma-vl1.pdf", "2026-10-27T10:00:00+01:00"),
    ("mathe", None, "m2", "02_Vorlesung_Folgen.pdf", "ma-vl2.pdf", "2026-11-03T10:00:00+01:00"),
    ("mathe-ue", "Übungsblätter", "u1", "Uebungsblatt_01.pdf", "ma-ue1.pdf", "2026-10-28T09:00:00+01:00"),
    ("recht", None, "r1", "Skript_BGB_AT.pdf", "prog-vl1.pdf", "2026-10-27T12:00:00+01:00"),
    ("recht", "Fälle", "r2", "Fall_01_Kaufvertrag.pdf", "prog-ue1.pdf", "2026-11-04T12:00:00+01:00"),
]
BOARD = [("biete", "Biete", 2), ("suche", "Suche", 1), ("wohnen", "Wohnen & Zimmer", 1)]


def user(uid: str, name: str, username: str, permission: str, email: str | None) -> dict:
    given, family = name.split(" ", 1) if " " in name else (name, "")
    return {"type": "users", "id": uid,
            "attributes": {"username": username, "formatted-name": name, "family-name": family, "given-name": given,
                           "name-prefix": "", "name-suffix": "", "permission": permission, "email": email},
            "links": {"self": f"/jsonapi.php/v1/users/{uid}"}}


def page(data: list, included: list | None = None, total: int | None = None) -> dict:
    out: dict = {"meta": {"page": {"offset": 0, "limit": 100, "total": len(data) if total is None else total}},
                 "links": {"first": "/jsonapi.php/v1/x?page[offset]=0", "last": "/jsonapi.php/v1/x?page[offset]=0"}, "data": data}
    if included is not None:
        out["included"] = included
    return out


def course(key: str, title: str, number: str | None, ctype: int, sem: str, has_end: bool) -> dict:
    rel = {"start-semester": {"data": {"type": "semesters", "id": sem}}}
    if has_end:
        rel["end-semester"] = {"data": {"type": "semesters", "id": sem}}
    return {"type": "courses", "id": CID[key],
            "attributes": {"course-number": number, "title": title, "subtitle": None, "course-type": ctype,
                           "description": None, "location": None, "miscellaneous": None},
            "relationships": rel, "links": {"self": f"/jsonapi.php/v1/courses/{CID[key]}"}}


def cycle(key: str, name: str, weekday: int, start: str, end: str, room: str) -> dict:
    return {"type": "seminar-cycle-dates", "id": hid("cycle-" + name),
            "attributes": {"title": "Kurszeit", "description": "", "start": start, "end": end, "weekday": weekday,
                           "recurrence": {"FREQ": "WEEKLY", "INTERVAL": 1, "DTSTART": f"2026-10-{25 + weekday}T{start}:00+01:00",
                                          "UNTIL": "2027-02-12T23:59:59+01:00", "EXDATES": []},
                           "locations": [room]},
            "relationships": {"owner": {"data": {"type": "courses", "id": CID[key]}}}}


def event(key: str, n: int, day: str, start: str, end: str, room: str, cancelled: bool = False) -> dict:
    return {"type": "course-events", "id": hid(f"event-{key}-{n}"),
            "attributes": {"title": "", "description": "", "start": f"{day}T{start}:00+01:00", "end": f"{day}T{end}:00+01:00",
                           "type": 1, "categories": "Sitzung", "location": room, "is-cancelled": cancelled,
                           "mkdate": "2026-09-20T10:00:00+02:00", "chdate": "2026-09-20T10:00:00+02:00", "recurrence": ""},
            "relationships": {"owner": {"data": {"type": "courses", "id": CID[key]}}}}


def folder(fid: str, ftype: str, name: str) -> dict:
    return {"type": "folders", "id": fid,
            "attributes": {"folder-type": ftype, "name": name, "description": "", "mkdate": "2026-09-20T10:00:00+02:00",
                           "chdate": "2026-09-20T10:00:00+02:00", "is-visible": True, "is-readable": True, "is-writable": False,
                           "is-editable": False, "is-empty": False, "is-subfolder-allowed": False, "data-content": []},
            "relationships": {"file-refs": {"links": {"related": f"/jsonapi.php/v1/folders/{fid}/file-refs"}},
                              "folders": {"links": {"related": f"/jsonapi.php/v1/folders/{fid}/folders"}}}}


def file_ref(key: str, name: str, pdf: str, changed: str) -> dict:
    fid = hid("file-" + key)
    size = (PDFS / pdf).stat().st_size
    return {"type": "file-refs", "id": fid,
            "attributes": {"name": name, "description": "", "mkdate": changed, "chdate": changed, "downloads": 12, "filesize": size,
                           "mime-type": "application/pdf", "is-readable": True, "is-downloadable": True, "is-editable": False,
                           "is-writable": False},
            "relationships": {"terms-of-use": {"data": {"type": "terms-of-use", "id": "SELFMADE_NONPUB"}}},
            "meta": {"download-url": f"{BASE}/sendfile.php?type=0&file_id={fid}&file_name={name}"}}


def ics() -> str:
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Stud.IP//NONSGML Stud.IP//DE", "METHOD:PUBLISH", "CALSCALE:GREGORIAN"]
    for key, n, day, start, end, room in [("mathe", 1, "20261130", "1015", "1145", "ZHG010 (ZHG)"),
                                          ("mathe-ue", 1, "20261202", "1415", "1545", "ZHG006 (ZHG)"),
                                          ("recht", 1, "20261201", "0815", "0945", "ZHG011 (ZHG)")]:
        title = next(t for k, t, *_ in COURSES if k == key)
        lines += ["BEGIN:VEVENT", f"DTSTART;TZID=Europe/Berlin:{day}T{start}00", f"DTEND;TZID=Europe/Berlin:{day}T{end}00",
                  f"SUMMARY:{title}", f"LOCATION:{room}", "CATEGORIES:Sitzung", "LAST-MODIFIED:20260920T080000Z",
                  "CREATED:20260920T080000Z", "DTSTAMP:20261126T120000Z", f"UID:Stud.IP-SEM-{hid(f'event-{key}-{n}')}@studip.uni-goettingen.de",
                  "DESCRIPTION:", "END:VEVENT"]
    return "\r\n".join(lines + ["END:VCALENDAR", ""])


def html_page(title: str, body: str) -> str:
    return ('<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f"<title>{title}</title><style>body{{font-family:-apple-system,Helvetica,sans-serif;background:#f3f4f6;margin:0;padding:40px}}"
            ".box{max-width:460px;margin:0 auto;background:#fff;border:1px solid #d6d9de;border-radius:10px;padding:28px}h1{font-size:22px;margin:0 0 6px}"
            "p{color:#555;font-size:14px}input{width:100%;box-sizing:border-box;padding:10px;border:1px solid #c9ccd1;border-radius:6px;font-size:15px;margin:8px 0}"
            ".button{display:block;width:100%;margin-top:14px;background:#13294b;color:#fff;text-align:center;padding:11px;border:0;border-radius:6px;font-size:15px}"
            ".note{font-size:12px;color:#888;margin-top:16px}</style></head>" + f'<body id="login"><div class="box">{body}</div></body></html>\n')


def overview(key: str, media: bool) -> str:
    cid = CID[key]
    tabs = [("Übersicht", f"{BASE}/dispatch.php/course/overview?cid={cid}"), ("Forum", f"{BASE}/dispatch.php/course/forum/topics?cid={cid}"),
            ("Teilnehmende", f"{BASE}/dispatch.php/course/members?cid={cid}"), ("Dateien", f"{BASE}/dispatch.php/course/files?cid={cid}"),
            ("Ablaufplan", f"{BASE}/dispatch.php/course/dates?cid={cid}"), ("Wiki", f"{BASE}/dispatch.php/course/wiki/page?cid={cid}")]
    if media:
        tabs.append(("Medien", f"{BASE}/plugins.php/mediacastplugin/media/wall?cid={cid}"))
    nav = "".join(f'<li><a href="{u}">{t}</a></li>' for t, u in tabs)
    return f'<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Übersicht</title></head><body><ul id="navigation-level-2">{nav}</ul><main><h1>Kurzinfo</h1></main></body></html>\n'


def board_list() -> str:
    items = "".join(f'<li><a href="{BASE}/plugins.php/schwarzesbrettplugin/category/view/{hid("board-" + k)}" class="category unseen">'
                    f'{t} ({n})<small>Anzeigen der Rubrik {t}</small></a>'
                    f'<a href="{BASE}/plugins.php/schwarzesbrettplugin/rss/{hid("board-" + k)}" class="rss">RSS</a></li>' for k, t, n in BOARD)
    return ('<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Schwarzes Brett</title></head><body>'
            f'<ul class="sb-categories">{items}</ul><ul class="sb-articles"></ul></body></html>\n')


def board_feed(key: str, title: str, n: int) -> str:
    texts = {"biete": [("Lehrbuch Mathematik für Wirtschaftswissenschaftler", "Gut erhalten, 12 Euro. Abholung am Zentralcampus."),
                       ("Fahrrad, 28 Zoll", "Mit Licht und Schloss. 60 Euro.")],
             "suche": [("Lerngruppe BGB AT", "Wir treffen uns mittwochs im LSG. Zwei Plätze sind frei.")],
             "wohnen": [("WG-Zimmer Nähe Nordcampus", "16 qm, ab Januar, 340 Euro warm.")]}[key]
    items = ""
    for i, (t, body) in enumerate(texts[:n]):
        aid = hid(f"article-{key}-{i}")
        items += (f"<item><title>{t}</title><link>{BASE}/plugins.php/schwarzesbrettplugin/article/view/{aid}</link>"
                  f"<description><![CDATA[<div><p>{body}</p></div>]]></description>"
                  f"<pubDate>Tue, 2{4 - i} Nov 2026 10:1{i}:00 +0100</pubDate><guid>{aid}</guid></item>")
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>{title}</title>{items}</channel></rss>\n'


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    routes: list[dict] = []

    def put(name: str, content) -> str:
        files[name] = content if isinstance(content, bytes) else (
            content if isinstance(content, str) else json.dumps(content, ensure_ascii=False, indent=1) + "\n").encode("utf-8")
        return name

    def route(match: str, file: str | None = None, **more) -> None:
        r = {"match": match}
        if file:
            r["file"] = file
        r.update(more)
        routes.append(r)

    err404 = json.dumps({"errors": [{"status": "404", "title": "Not found."}]})
    # Anmeldung: Formular wie auf der echten Seite (form#login-form, loginname, password, button#submit_login "Login")
    put("studip.html", html_page("Stud.IP – Anmeldung (Nachbildung Göttingen)",
        "<h1>Stud.IP – Anmeldung</h1><p>Nachbildung für den Simulator – keine echte Seite der Universität Göttingen.</p>"
        '<form class="default login-top" name="login_form" id="login-form" method="post" onsubmit="location.href=\'studip-angemeldet.html\'; return false;">'
        '<label><span class="sr-only">Benutzername</span><input type="text" id="loginname" name="loginname" autocomplete="username" placeholder="Benutzername"></label>'
        '<label><span class="sr-only">Passwort</span><input type="password" id="password" name="password" autocomplete="current-password" placeholder="Passwort"></label>'
        '<input type="hidden" name="security_token" value="stub"><input type="hidden" name="login_ticket" value="stub"><input type="hidden" name="resolution" value="">'
        '<button type="submit" class="button" id="submit_login" name="Login">Anmelden</button></form>'
        '<p class="note">Im echten Stud.IP stehen daneben „CAS Login“ und „Other Institutes Login“; StudiNow nutzt nur diese Felder.</p>'))
    put("studip-angemeldet.html", html_page("Startseite - Georg-August-Universität Göttingen (Nachbildung)",
        "<h1>Startseite</h1><p>Angemeldet (Nachbildung). StudiNow übernimmt jetzt die Sitzung.</p>"))

    # Nutzer
    put("me.json", {"data": user(ME, "Erika Muster", "erika.muster", "autor", "erika.muster@stud.uni-goettingen.de")})
    route(API + "users/me", "me.json")
    # Lehrende je Kurs (nur lesend), Einrichtungen leer wie am echten Konto
    for key in ("mathe", "mathe-ue", "recht", "sem"):
        cid = CID[key]
        doz = {"type": "course-memberships", "id": f"{cid}_{DOZ}",
               "attributes": {"permission": "dozent", "position": 0, "group": 0, "mkdate": "2026-09-20T10:00:00+02:00", "label": ""},
               "relationships": {"course": {"data": {"type": "courses", "id": cid}}, "user": {"data": {"type": "users", "id": DOZ}}}}
        put(f"members-{key}-dozent.json", page([doz], [user(DOZ, "Prof. Dr. Beispiel Dozentin", "b.dozentin", "dozent", "beispiel.dozentin@example.org")]))
        route(f"{API}courses/{cid}/memberships?filter[permission]=dozent", f"members-{key}-dozent.json")
    put("empty.json", page([]))
    route("/memberships?filter[permission]=", "empty.json")
    route("/institute-memberships", "empty.json")
    put("user-dozentin.json", {"data": user(DOZ, "Prof. Dr. Beispiel Dozentin", "b.dozentin", "dozent", "beispiel.dozentin@example.org")})
    route(f"{API}users/{DOZ}", "user-dozentin.json")

    # Kurse mit Start- und Endsemester (ein Kurs ohne end-semester, wie gesehen)
    put("courses.json", page([course(*c) for c in COURSES],
                             [{"type": "semesters", "id": sid, "attributes": a} for sid, a in SEMESTERS.items()]))
    route(f"{API}users/{ME}/courses", "courses.json")
    # Stundenplan: seminar-cycle-dates mit Raeumen in der Schreibweise des echten Stud.IP ("ZHG010 (ZHG)")
    put("schedule.json", {"meta": {"semester": f"/jsonapi.php/v1/semesters/{SEM_W26}"}, "links": {"self": f"/jsonapi.php/v1/users/{ME}/schedule"},
                          # weekday wie Stud.IP: 1 = Montag
                          "data": [cycle("mathe", "mathe", 1, "10:15", "11:45", "ZHG010 (ZHG)"),
                                   cycle("mathe-ue", "mathe-ue", 3, "14:15", "15:45", "ZHG006 (ZHG)"),
                                   cycle("recht", "recht", 2, "08:15", "09:45", "ZHG011 (ZHG)"),
                                   cycle("sem", "sem", 4, "16:15", "17:45", "E-Prüfungsraum MZG 1.116 (MZG/Blauer Turm)")]})
    route(f"{API}users/{ME}/schedule", "schedule.json")
    put("events.ics", ics())
    route(f"{API}users/{ME}/events.ics", "events.ics", contentType="text/calendar;charset=UTF-8")

    # Nachrichten (Posteingang), Aenderungen, Semester, Ferien
    msg = [{"type": "messages", "id": hid("msg-1"),
            "attributes": {"subject": "Raumänderung Übung", "message": "<p>Die Übung am 02.12. findet im ZHG006 statt.</p>",
                           "mkdate": "2026-11-24T08:15:00+01:00", "is-read": False, "priority": "normal", "tags": []},
            "relationships": {"sender": {"data": {"type": "users", "id": DOZ}},
                              "recipients": {"data": [{"type": "users", "id": ME}]}}},
           {"type": "messages", "id": hid("msg-2"),
            "attributes": {"subject": "Willkommen im Wintersemester", "message": "Viel Erfolg im neuen Semester!",
                           "mkdate": "2026-10-26T09:00:00+01:00", "is-read": True, "priority": "normal", "tags": []},
            "relationships": {"sender": {"data": {"type": "users", "id": "____%system%____"}},
                              "recipients": {"data": [{"type": "users", "id": ME}]}}}]
    put("inbox.json", page(msg, [user(DOZ, "Prof. Dr. Beispiel Dozentin", "b.dozentin", "dozent", None)]))
    route(f"{API}users/{ME}/inbox", "inbox.json")
    put("activity.json", {"meta": {"filter": {}, "page": {"offset": 0, "limit": 30}}, "links": {"first": "x", "last": "x"},
                          "data": [{"type": "activities", "id": hid("act-1"),
                                    "attributes": {"title": "Datei hochgeladen", "mkdate": "2026-11-25T10:00:00+01:00", "content": "",
                                                   "verb": "created", "activity-type": "documents"},
                                    "relationships": {"actor": {"data": {"type": "users", "id": DOZ}},
                                                      "object": {"data": {"type": "file-refs", "id": hid("file-m2")}},
                                                      "context": {"data": {"type": "courses", "id": CID["mathe"]}}}}]})
    route(f"{API}users/{ME}/activitystream", "activity.json")
    put("semesters.json", page([{"type": "semesters", "id": sid, "attributes": a} for sid, a in SEMESTERS.items()]))
    route(API + "semesters", "semesters.json")
    route(API + "holidays", "empty.json")
    # was am echten Stud.IP Goettingen NICHT geht (26.11.2026)
    route(API + "studip/news", status=500, body=json.dumps({"errors": [{"status": "500", "title": "Internal Server Error"}]}),
          contentType="application/vnd.api+json")
    route("/consultation-bookings", status=404, body=err404, contentType="application/vnd.api+json")
    route("/wiki-pages", status=404, body=err404, contentType="application/vnd.api+json")
    route(API + "courseware-tasks", status=400, body=json.dumps({"errors": [{"status": "400", "title": "Bad Request"}]}),
          contentType="application/vnd.api+json")
    route("/courseware-task-groups", status=404, body=err404, contentType="application/vnd.api+json")
    route("/courseware-units", "empty.json")
    route("/forum-categories", "empty.json")
    put("denied.html", '<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Zugriff verweigert</title></head><body><h1>Zugriff verweigert</h1>'
                       "<p>Sie besitzen keine Rechte zum Aufruf dieses Plugins.</p></body></html>\n")
    route("plugins.php/opencastpluginluh/", "denied.html", status=403)
    route("plugins.php/opencast/", "denied.html", status=403)
    route("plugins.php/opencastv3/api/courses/", body=json.dumps({"videos": [], "count": "0"}), contentType="application/json")
    route("plugins.php/opencastv3/course/index", status=500, body="<html><body>Fehler</body></html>")

    # je Kurs: Ordner, Dateien, Termine, Ankuendigungen, Ueberblick
    for key, *_ in COURSES:
        cid = CID[key]
        root = hid("root-" + key)
        mine = [f for f in FILES if f[0] == key]
        subs = sorted({f[1] for f in mine if f[1]})
        put(f"folders-{key}.json", page([folder(root, "RootFolder", "")] + [folder(hid(f"sub-{key}-{s}"), "StandardFolder", s) for s in subs]))
        route(f"{API}courses/{cid}/folders", f"folders-{key}.json")
        put(f"files-{key}-root.json", page([file_ref(f[2], f[3], f[4], f[5]) for f in mine if not f[1]]))
        route(f"{API}folders/{root}/file-refs", f"files-{key}-root.json")
        put(f"subfolders-{key}.json", page([folder(hid(f"sub-{key}-{s}"), "StandardFolder", s) for s in subs]))
        route(f"{API}folders/{root}/folders", f"subfolders-{key}.json")
        for s in subs:
            sid = hid(f"sub-{key}-{s}")
            put(f"files-{key}-{hid(s)[:6]}.json", page([file_ref(f[2], f[3], f[4], f[5]) for f in mine if f[1] == s]))
            route(f"{API}folders/{sid}/file-refs", f"files-{key}-{hid(s)[:6]}.json")
            route(f"{API}folders/{sid}/folders", "empty.json")
        ev = {"mathe": [event("mathe", 1, "2026-11-30", "10:15", "11:45", "ZHG010 (ZHG)"),
                        event("mathe", 2, "2026-12-07", "10:15", "11:45", "ZHG010 (ZHG)", cancelled=True)],
              "mathe-ue": [event("mathe-ue", 1, "2026-12-02", "14:15", "15:45", "ZHG006 (ZHG)")],
              "recht": [event("recht", 1, "2026-12-01", "08:15", "09:45", "ZHG011 (ZHG)")]}.get(key, [])
        put(f"events-{key}.json", page(ev))
        route(f"{API}courses/{cid}/events", f"events-{key}.json")
        news = [{"type": "news", "id": hid("news-" + key),
                 "attributes": {"title": "Klausurtermin steht fest", "content": "<p>Die Klausur findet am 15.02.2027 im ZHG statt.</p>",
                                "mkdate": "2026-11-20T10:00:00+01:00", "chdate": "2026-11-20T10:00:00+01:00",
                                "publication-start": "2026-11-20T10:00:00+01:00", "publication-end": "2027-02-20T10:00:00+01:00",
                                "comments-allowed": False},
                 "relationships": {"author": {"data": {"type": "users", "id": DOZ}}}}] if key == "mathe" else []
        put(f"news-{key}.json", page(news))
        route(f"{API}courses/{cid}/news", f"news-{key}.json")
        put(f"overview-{key}.html", overview(key, media=key == "recht"))
        route(f"dispatch.php/course/overview?cid={cid}", f"overview-{key}.html")
    for _, _, fkey, _, pdf, _ in FILES:
        files[pdf] = (PDFS / pdf).read_bytes()
        route(f"{API}file-refs/{hid('file-' + fkey)}/content", pdf)
    route(API + "terms-of-use", "empty.json")

    # Schwarzes Brett: Themenliste (sb-categories) und RSS je Thema wie am echten Stud.IP
    put("brett-list.html", board_list())
    route("plugins.php/schwarzesbrettplugin/category/list", "brett-list.html")
    for k, t, n in BOARD:
        put(f"brett-{k}.xml", board_feed(k, t, n))
        route(f"plugins.php/schwarzesbrettplugin/rss/{hid('board-' + k)}", f"brett-{k}.xml", contentType="application/rss+xml;charset=utf-8")

    put("routes.json", routes)
    put("README.md", "# Debug-Stub Uni Göttingen (nur Debug-Builds und Tests)\n\n"
        "Erzeugt von `tools/build-goettingen-stub.py` – nicht von Hand ändern. Erfundene Kurse, Personen und Texte im Aufbau,\n"
        "wie das Stud.IP der Universität Göttingen am 26.11.2026 geantwortet hat (docs/GOETTINGEN-2026-11-26.md), samt der\n"
        "Antworten, die dort nicht gehen (`studip/news` 500, Sprechstunden und Wiki 404, Aufzeichnungs-Erweiterung der LUH 403).\n\n"
        "Simulator: `-UFUniversity goettingen -UFOnboarding login -UFLoginStub <dieser Ordner>`.\n")
    return files


def main() -> int:
    check = "--check" in sys.argv[1:]
    files = build()
    stale = []
    for name, content in files.items():
        p = OUT / name
        if not p.exists() or p.read_bytes() != content:
            stale.append(name)
            if not check:
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(content)
    extra = sorted(p.name for p in OUT.glob("*") if p.is_file() and p.name not in files) if OUT.exists() else []
    if not check:
        for name in extra:
            (OUT / name).unlink()
    if check and (stale or extra):
        print("VERALTET: " + ", ".join(stale + extra), file=sys.stderr)
        return 1
    print(("aktuell" if not stale and not extra else "geschrieben") + f": {OUT.relative_to(ROOT)} ({len(files)} Dateien)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
