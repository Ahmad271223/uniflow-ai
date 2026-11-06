"""Erzeugt packages/shared-contracts/fixtures/studip-lecturers/lecturers.json: Lehrende und Kontakte aus Stud.IP (LUH,
06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md) mit der Python-Referenz (app/studip_lecturers.py) auf ERFUNDENEN
JSON:API-Antworten (Namen und Adressen ausgedacht, nur example.org) und eingefrorenem Tag (Freitag, 06.11.2026). Der
Swift-Kern (StudIPLecturersTests) liest dieselben Antworten und vergleicht exakt.

Die Form der Antworten folgt der oeffentlichen Stud.IP-JSON:API-Doku (course-memberships, users, institute-memberships);
Aufbau live bestaetigt am 06.11.2026 (Anmeldung des Inhabers, nur GET, anonymisiert): include=user mit `email`, beide
Filter, institute-memberships mit office-hours, location, phone (StudiNow liest phone nicht).

Inhalt:
- display_name, clean_email, message_url: Einzelfaelle
- members: Antwort von courses/{id}/memberships -> gelesen (Studierende fallen weg)
- merge_user: Mitglied ohne include + users/{id}
- profiles: Antwort von users/{id}/institute-memberships -> Sprechzeiten, Raum, Einrichtung
- sync: Abruf mit festen Antworten (Reihenfolge der Anfragen, Ergebnis, Tabelle danach)
- due: welche Kurse dran sind (7 Tage)
- overview: GET /api/lecturers fuer Kurs, Modul, alle aktiven Kurse, Suche, HsH, Hildesheim, Dienst

Aufruf im Projektordner: python tools/gen-studip-lecturers-fixture.py [--check]
"""
from __future__ import annotations

import copy
import json
import sqlite3
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-lecturers" / "lecturers.json"
TODAY = date(2026, 11, 6)
NOW = "2026-11-06T10:00:00+01:00"
BASE = "https://studip.test"


def user(uid, **a):
    return {"type": "users", "id": uid, "attributes": a}


def member(cid, uid, perm, pos=None, label=None, typ="course-memberships"):
    a = {"permission": perm}
    if pos is not None:
        a["position"] = pos
    if label is not None:
        a["label"] = label
    return {"type": typ, "id": f"{cid}_{uid}", "attributes": a, "relationships": {"user": {"data": {"type": "users", "id": uid}}}}


U_PROF = user("u-prof", **{"formatted-name": "Prof. Dr. Erika Beispiel", "username": "beispiel", "email": "erika.beispiel@example.org",
                          "permission": "dozent"})
U_DOZ2 = user("u-doz2", **{"formatted-name": "Dr. Jonas Muster", "username": "j.muster", "email": "", "permission": "dozent"})
U_DOZ3 = user("u-doz3", **{"given-name": "Lena", "family-name": "Probe", "name-prefix": "Dr.", "username": "lprobe",
                          "email": "keine Angabe", "permission": "dozent"})
U_TUT1 = user("u-tut1", **{"formatted-name": "Mia Übungsleiterin", "username": "mia.ue", "email": "mia.uebung@example.org",
                          "permission": "autor"})
U_TUT2 = user("u-tut2", **{"formatted-name": "  Tom   Tutor  ", "username": "ttutor", "email": "tom.tutor@stud.example.org",
                          "permission": "autor"})
U_STUD = user("u-stud", **{"formatted-name": "Erfundene Kommilitonin", "username": "kommi", "email": "kommi@example.org"})

# courses/{id}/memberships?filter[permission]=<rolle>&include=user (bzw. ohne include)
ROUTES = {
    "courses/k-ana/memberships?filter[permission]=dozent&page[limit]=100&include=user": (200, {
        "data": [member("k-ana", "u-prof", "dozent", 0, "Modulverantwortliche"), member("k-ana", "u-doz2", "dozent", 1),
                 member("k-ana", "u-stud", "autor", 2), member("k-ana", "u-prof", "dozent", 3),
                 member("k-ana", "u-x", "dozent", 4, typ="users")],
        "included": [U_PROF, U_DOZ2, U_STUD]}),
    # Tutor-Liste ohne include (400): Namen kommen aus users/{id}
    "courses/k-ana/memberships?filter[permission]=tutor&page[limit]=100&include=user": (400, None),
    "courses/k-ana/memberships?filter[permission]=tutor&page[limit]=100": (200, {
        "data": [member("k-ana", "u-tut1", "tutor", "0")]}),
    "users/u-tut1": (200, {"data": U_TUT1}),
    "courses/k-ue/memberships?filter[permission]=dozent&page[limit]=100&include=user": (200, {
        "data": [member("k-ue", "u-prof", "dozent")], "included": [U_PROF]}),
    "courses/k-ue/memberships?filter[permission]=tutor&page[limit]=100&include=user": (200, {
        "data": [member("k-ue", "u-tut2", "tutor", 0), member("k-ue", "u-tut1", "tutor", 1)], "included": [U_TUT2, U_TUT1]}),
    "courses/k-prog/memberships?filter[permission]=dozent&page[limit]=100&include=user": (200, {
        "data": [member("k-prog", "u-doz3", "dozent", 0)], "included": [U_DOZ3]}),
    "courses/k-prog/memberships?filter[permission]=tutor&page[limit]=100&include=user": (200, {"data": []}),
    # Kurs, den Stud.IP nicht zeigt: Bestand bleibt, kein Eintrag als gelesen
    "courses/k-zu/memberships?filter[permission]=dozent&page[limit]=100&include=user": (403, None),
    # Sprechzeiten
    "users/u-prof/institute-memberships?include=institute": (200, {
        "data": [{"type": "institute-memberships", "id": "im1", "attributes": {"permission": "dozent", "office-hours": "nach Vereinbarung",
                                                                                 "location": "", "is-default": False, "priority": 1},
                  "relationships": {"institute": {"data": {"type": "institutes", "id": "i-alt"}}}},
                 {"type": "institute-memberships", "id": "im2", "attributes": {"permission": "dozent",
                                                                                 "office-hours": "<p>Di 10&ndash;11 Uhr<br>und nach Vereinbarung</p>",
                                                                                 "location": "Raum F 303 (1101)", "is-default": True, "priority": 0,
                                                                                 "phone": "+49 511 000000", "fax": None, "visible": True},
                  "relationships": {"institute": {"data": {"type": "institutes", "id": "i-mat"}}}}],
        "included": [{"type": "institutes", "id": "i-mat", "attributes": {"name": "Institut für Testmathematik", "city": "Hannover",
                                                                                   "url": "https://example.org/testmathematik"}},
                     {"type": "institutes", "id": "i-alt", "attributes": {"name": "Altes Institut"}}]}),
    "users/u-doz2/institute-memberships?include=institute": (400, None),
    "users/u-doz2/institute-memberships": (200, {"data": []}),
    "users/u-tut1/institute-memberships?include=institute": (403, None),
    "users/u-tut2/institute-memberships?include=institute": (400, None),
    "users/u-tut2/institute-memberships": (200, {
        "data": [{"type": "institute-memberships", "id": "im3", "attributes": {"location": "Gebäude 3403, Raum A003", "office-hours": ""}}]}),
    # Tutor/innen: nie gefragt (Sprechzeiten nur fuer Dozent/innen)
    "users/u-doz3/institute-memberships?include=institute": (200, {
        "data": [{"type": "institute-memberships", "id": "im4", "attributes": {"office-hours": "", "location": ""},
                  "relationships": {"institute": {"data": {"type": "institutes", "id": "i-inf"}}}}],
        "included": [{"type": "institutes", "id": "i-inf", "attributes": {"name": "Institut für Testinformatik"}}]}),
}

# Datenbank: Module und Kurse (k-alt aus einem frueheren Semester, inaktiv), k-alt schon vor 3 Tagen gelesen
MODULES = [(1, "Analysis I"), (2, "Programmieren")]
COURSES = [("k-ana", "Analysis I – Vorlesung", 1, 1), ("k-ue", "Analysis I – Übung", 1, 1), ("k-prog", "Programmieren", 2, 1),
           ("k-zu", "Geschlossener Kurs", None, 1), ("k-alt", "Altes Seminar", None, 0), ("k-neu", "Frisch gelesen", None, 1)]
SYNC_COURSES = ["k-ana", "k-ue", "k-prog", "k-zu", "k-neu", "k-ana"]
PRESET = [("k-alt", "u-alt", "dozent", 0, "", "Prof. Alt Beispiel", "alt", "alt@example.org", "", "", "", "2026-11-03T09:00:00+01:00"),
          ("k-neu", "u-doz2", "dozent", 0, "", "Dr. Jonas Muster", "j.muster", "", "", "", "", "2026-11-04T09:00:00+01:00")]
PRESET_COURSES = [("k-alt", "2026-11-03T09:00:00+01:00"), ("k-neu", "2026-11-04T09:00:00+01:00")]

DUE_CASES = [
    {"known": {}, "courses": ["a", "b", "a"]},
    {"known": {"a": "2026-10-30T09:00:00+01:00", "b": "2026-10-31T00:00:00+01:00", "c": "kaputt"}, "courses": ["a", "b", "c", "d"]},
]
OVERVIEW_QUERIES = [
    {"university": "luh"},
    {"university": "luh", "course_id": "k-ana"},
    {"university": "luh", "module_id": 1},
    {"university": "luh", "module_id": 2},
    {"university": "luh", "q": "übung"},
    {"university": "luh", "q": "ANALYSIS"},
    {"university": "luh", "q": "zzz"},
    {"university": "luh", "course_id": "k-zu"},
    {"university": "luh", "course_id": "k-unbekannt"},
    {"university": "hsh"},
    {"university": "hildesheim", "course_id": "k-ana"},
    {"university": "luh", "allowed": False},
]
NAME_CASES = [{"formatted-name": " Prof.  Dr. A  B "}, {"given-name": "Ä", "family-name": "Ö", "name-suffix": "M.Sc."}, {}, None,
              {"formatted-name": 5, "family-name": "Nur"}]
EMAIL_CASES = ["a.b@example.org", " a@example.org ", "keine Angabe", "a@b", "x@example.org, y@example.org", 7, None,
               "Erika <erika@example.org>", "ü@example.org"]
URL_CASES = ["beispiel", "j.muster", "", "a b/ä"]


def db_with(seed: bool):
    c = sqlite3.connect(":memory:")
    c.executescript("""CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE modules (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE courses (id TEXT PRIMARY KEY, title TEXT NOT NULL, module_id INTEGER, active INTEGER DEFAULT 1);""")
    c.executemany("INSERT INTO modules(id, name) VALUES (?,?)", MODULES)
    c.executemany("INSERT INTO courses(id, title, module_id, active) VALUES (?,?,?,?)", COURSES)
    if seed:
        from app import studip_lecturers as L
        L.ensure(c)
        c.executemany("INSERT INTO studip_lecturers VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", PRESET)
        c.executemany("INSERT INTO studip_lecturer_courses VALUES (?,?)", PRESET_COURSES)
    return c


def rows(c, table: str) -> list:
    return [list(r) for r in c.execute(f"SELECT * FROM {table} ORDER BY 1, 2")]


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import studip_lecturers as L

        members = []
        for key in [k for k in ROUTES if "/memberships" in k and ROUTES[k][1] is not None]:
            members.append({"path": key, "response": ROUTES[key][1], "items": L.parse_members(ROUTES[key][1])})
        no_name = L.parse_members(ROUTES["courses/k-ana/memberships?filter[permission]=tutor&page[limit]=100"][1])[0]
        merge = {"member": no_name, "response": ROUTES["users/u-tut1"][1], "merged": L.merge_user(no_name, ROUTES["users/u-tut1"][1])}
        profiles = [{"path": k, "response": v[1], "parsed": L.parse_profile(v[1])} for k, v in ROUTES.items()
                    if "institute-memberships" in k and v[1] is not None]

        # Abruf mit festen Antworten
        conn = db_with(seed=True)
        requests: list[str] = []

        def get(path):
            requests.append(path)
            status, body = ROUTES.get(path, (404, None))
            return status, copy.deepcopy(body)

        result = L.sync(get, conn, SYNC_COURSES, TODAY, NOW)
        after = {"studip_lecturers": rows(conn, "studip_lecturers"), "studip_lecturer_courses": rows(conn, "studip_lecturer_courses"),
                 "settings": rows(conn, "settings")}
        # zweiter Lauf am selben Tag: nichts dran, keine Anfrage
        before = len(requests)
        again = L.sync(get, conn, SYNC_COURSES, TODAY, NOW)
        second = {"result": again, "requests": requests[before:]}

        overview = []
        for qy in OVERVIEW_QUERIES:
            overview.append({"query": qy, "result": L.overview(conn, qy["university"], BASE, course_id=qy.get("course_id"),
                                                               module_id=qy.get("module_id"), q=qy.get("q"), allowed=qy.get("allowed", True))})
        empty = db_with(seed=False)
        overview_empty = L.overview(empty, "luh", BASE)

        # Route fehlt (404 bei allen Kursen): 30 Tage Ruhe
        miss = db_with(seed=False)
        miss_requests: list[str] = []

        def get404(path):
            miss_requests.append(path)
            return 404, None

        miss_result = L.sync(get404, miss, ["k-ana", "k-ue"], TODAY, NOW)
        miss_again = L.sync(get404, miss, ["k-ana", "k-ue"], TODAY, NOW)

        dues = []
        for case in DUE_CASES:
            c = db_with(seed=False)
            L.ensure(c)
            c.executemany("INSERT INTO studip_lecturer_courses VALUES (?,?)", list(case["known"].items()))
            dues.append(dict(case, due=L.due(c, case["courses"], TODAY)))

        out = {"generator": "tools/gen-studip-lecturers-fixture.py", "today": TODAY.isoformat(), "now": NOW, "base": BASE,
               "constants": {"refresh_days": L.REFRESH_DAYS, "max_courses": L.MAX_COURSES, "max_user_lookups": L.MAX_USER_LOOKUPS,
                             "max_profiles": L.MAX_PROFILES, "no_email": L.NO_EMAIL},
               "display_name": [{"attrs": a, "name": L.display_name(a)} for a in NAME_CASES],
               "clean_email": [{"value": v, "email": L.clean_email(v)} for v in EMAIL_CASES],
               "message_url": [{"username": u, "url": L.message_url(BASE, u)} for u in URL_CASES],
               "members": members, "merge_user": merge, "profiles": profiles,
               "db": {"modules": [list(m) for m in MODULES], "courses": [list(c) for c in COURSES], "preset": [list(p) for p in PRESET],
                      "preset_courses": [list(p) for p in PRESET_COURSES]},
               "sync": {"routes": {k: {"status": v[0], "body": v[1]} for k, v in ROUTES.items()}, "course_ids": SYNC_COURSES,
                        "requests": requests[:before], "result": result, "after": after, "second": second},
               "sync_missing": {"requests": miss_requests, "result": miss_result, "again": miss_again,
                                "settings": rows(miss, "settings")},
               "due": dues, "overview": overview, "overview_empty": overview_empty}
        text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        return 0 if write_or_check(OUT, text, check) or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
