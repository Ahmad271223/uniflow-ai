"""Erzeugt packages/shared-contracts/fixtures/studip-texts/texte.json: Lernstoff aus Stud.IP (app/studip_texts.py,
2.11.2026) mit erfundenen JSON:API-Antworten und eingefrorener Uhr. Der Swift-Kern (StudIPTexts) geht dieselben
Schritte und vergleicht exakt: Reihenfolge der Anfragen, gespeicherte Texte, Fristen, Merker, Modulansicht, Suche,
Tutor-Quellen und Wochentest-Zeilen.

Laeufe:
- erst: zwei Kurse. Analysis mit Aufgaben (abgegeben, Verlaengerung), Courseware (Bloecke mitgeliefert und je
  Container), Wiki ueber zwei Seiten (eine ohne Inhalt in der Liste), Forum mit Zitat, Erwaehnung und Autor (der nie
  gespeichert wird). Programmierung: Aufgaben 404 (nur der bekannte Pfad), Courseware 404, Wiki 403, Forum 500.
- zweit (am Folgetag): unveraendert -> keine Inhalte neu; nicht vorhandene Funktionen werden nicht gefragt.
- spaeter (+20 Tage): Inhalte werden wieder geprueft, die zweite Wiki-Seite ist weg (Liste ohne Folgeseite).
- knapp: Anfragegrenze 5 -> Teilstand, nichts geloescht.
- fehlt: zwei Kurse ohne jede Funktion -> an der Hochschule nicht vorhanden; der naechste Lauf fragt nichts.

Aufruf im Projektordner: python tools/gen-studip-texts-fixture.py [--check]
"""
from __future__ import annotations

import copy
import json
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-texts" / "texte.json"
BASE = "https://studip.test"
P = "/jsonapi.php/v1/"


def ok(data, included=None, nxt=None):
    body = {"data": data, "links": {"next": nxt} if nxt else {}}
    if included is not None:
        body["included"] = included
    return {"status": 200, "body": body}


def err(status):
    return {"status": status, "body": {"errors": [{"status": str(status)}]}}


def block(bid, kind, payload, container=None):
    b = {"id": bid, "type": "courseware-blocks", "attributes": {"block-type": kind, "payload": payload}}
    if container:
        b["relationships"] = {"container": {"data": {"type": "courseware-containers", "id": container}}}
    return b


def element(eid, title, chdate):
    return {"id": eid, "type": "courseware-structural-elements", "attributes": {"title": title, "chdate": chdate}}


AUTHOR = {"author": {"data": {"type": "users", "id": "u-max"}}}

ROUTES = {
    # Aufgaben Analysis: offen, abgegeben, verlaengert; Gruppe als Titel
    P + "courseware-tasks?filter[cid]=c-ana&include=task-group,structural-element&page[limit]=100": ok([
        {"id": "t1", "type": "courseware-tasks", "attributes": {"submission-date": "2026-11-12T23:59:00+01:00", "submitted": False},
         "relationships": {"task-group": {"data": {"type": "courseware-task-groups", "id": "g1"}}}},
        {"id": "t2", "type": "courseware-tasks", "attributes": {"submission-date": "2026-11-05T12:00:00+01:00", "submitted": True},
         "relationships": {"task-group": {"data": {"type": "courseware-task-groups", "id": "g1"}}}},
        {"id": "t3", "type": "courseware-tasks", "attributes": {"submission-date": "2026-11-19T10:00:00+01:00", "renewal": "granted",
                                                                 "renewal-date": "2026-11-26T11:30:00Z"},
         "relationships": {"structural-element": {"data": {"type": "courseware-structural-elements", "id": "e-task"}}}},
        {"id": "t4", "type": "courseware-tasks", "attributes": {"submitted": False},
         "relationships": {"task-group": {"data": {"type": "courseware-task-groups", "id": "g4"}}}},
        {"id": "t5", "type": "courseware-tasks", "attributes": {"submission-date": "bald"}},
    ], [
        {"id": "g1", "type": "courseware-task-groups", "attributes": {"title": "Übungsblatt  3"}},
        {"id": "g4", "type": "courseware-task-groups", "attributes": {"title": "Projekt", "end-date": "2026-12-01"}},
        element("e-task", "Hausaufgabe Reihen", "2026-10-01T09:00:00+02:00"),
    ]),
    # Courseware Analysis
    P + "courses/c-ana/courseware-units?include=structural-element&page[limit]=50": ok(
        [{"id": "u1", "type": "courseware-units", "relationships": {"structural-element": {"data": {"type": "courseware-structural-elements", "id": "e-root"}}}},
         {"id": "u2", "type": "courseware-units", "relationships": {}}],
        [element("e-root", "Analysis I – Lernmodul", "2026-10-30T10:00:00+01:00")]),
    P + "courseware-structural-elements/e-root/containers?include=blocks&page[limit]=100": ok(
        [{"id": "k1", "type": "courseware-containers"}, {"id": "k2", "type": "courseware-containers"}],
        [block("b3", "code", {"content": "def lim(a):\n    return a[-1]\n", "lang": "python"}, "k2"),
         block("b1", "text", {"text": "<p>Der <b>Grenzwert</b> einer Folge&nbsp;ist eindeutig.</p><ul><li>Konvergenz</li></ul>"}, "k1"),
         block("b2", "headline", json.dumps({"title": "Folgen und Grenzwerte", "subtitle": "Woche 2"}), "k1"),
         block("b4", "download", {"title": "Skript Kapitel 2.pdf", "file_id": "f9"}, "k2"),
         block("b5", "video", {"title": "Video"}, "k2"),
         block("b6", "key-point", {"text": "Merke: jede konvergente Folge ist beschraenkt."})]),
    P + "courseware-structural-elements/e-root/children?page[limit]=100": ok(
        [element("e-ch1", "Kapitel 1: Folgen", "2026-10-31T08:00:00+01:00"), element("e-ch2", "Leere Seite", "2026-10-31T08:00:00+01:00")]),
    P + "courseware-structural-elements/e-ch1/containers?include=blocks&page[limit]=100": ok([{"id": "k3", "type": "courseware-containers"}]),
    P + "courseware-containers/k3/blocks?page[limit]=100": ok(
        [block("b7", "text", {"text": "<p>Eine Folge heisst Cauchy-Folge, wenn ... Konvergenz der Folge folgt im Vollstaendigen.</p>"}),
         block("b8", "katex", {"formula": "\\lim_{n\\to\\infty} a_n = a"})]),
    P + "courseware-structural-elements/e-ch1/children?page[limit]=100": ok([]),
    P + "courseware-structural-elements/e-ch2/containers?include=blocks&page[limit]=100": ok([]),
    P + "courseware-structural-elements/e-ch2/children?page[limit]=100": ok([]),
    # Wiki Analysis: zwei Seiten der Liste, w2 ohne Inhalt in der Liste
    P + "courses/c-ana/wiki-pages?page[limit]=100": ok(
        [{"id": "w1", "type": "wiki-pages", "attributes": {"keyword": "Klausurinfos", "chdate": "2026-10-20T12:00:00+02:00",
                                                           "content": "!!Klausur\n**Termin** am [[Termine|10.02.2027]], Hilfsmittel: ein Blatt.  \n\n%%Grenzwert%% und Folge"}}],
        nxt=P + "courses/c-ana/wiki-pages?page[offset]=1&page[limit]=100"),
    P + "courses/c-ana/wiki-pages?page[offset]=1&page[limit]=100": ok(
        [{"id": "w2", "type": "wiki-pages", "attributes": {"name": "Literatur", "chdate": 1761900000}},
         {"id": "w3", "type": "wiki-pages", "attributes": {"keyword": "Leer", "content": "   "}}]),
    P + "wiki-pages/w2": {"status": 200, "body": {"data": {"id": "w2", "type": "wiki-pages",
                                                         "attributes": {"content-html": "<h2>Literatur</h2><p>Forster: Analysis 1, Kapitel Folge und Grenzwert</p>"}}}},
    # Forum Analysis: Autor in den Beziehungen, Zitat und Erwaehnung im Text
    P + "courses/c-ana/forum-categories?page[limit]=50": ok([{"id": "cat1", "type": "forum-categories", "attributes": {"title": "Allgemein"}}]),
    P + "forum-categories/cat1/entries?page[limit]=50": ok(
        [{"id": "f1", "type": "forum-entries", "attributes": {"title": "Frage zu Blatt 3", "chdate": "2026-11-01T18:00:00+01:00",
                                                              "content": "[quote=Max Mustermann]alter Text[/quote] Wie zeige ich die Konvergenz der Folge? @lisa.m"},
          "relationships": AUTHOR}]),
    P + "forum-entries/f1/entries?page[limit]=100": ok(
        [{"id": "p1", "type": "forum-entries", "attributes": {"title": "Re: Frage zu Blatt 3", "content-html":
                                                              "<blockquote>Max Mustermann schrieb: alter Text</blockquote><p>Mit dem Cauchy-Kriterium f&uuml;r die Folge.</p>"},
          "relationships": AUTHOR}],
        [{"id": "u-max", "type": "users", "attributes": {"formatted-name": "Max Mustermann"}}]),
    # Programmierung: nichts davon vorhanden bzw. gestoert
    P + "courses/c-prog/courseware-units?include=structural-element&page[limit]=50": err(404),
    P + "courses/c-prog/wiki-pages?page[limit]=100": err(403),
    P + "courses/c-prog/forum-categories?page[limit]=50": err(500),
}

COURSES = [{"id": "c-ana", "title": "Testanalysis I"}, {"id": "c-prog", "title": "Testprogrammierung"}]

ABSENT_ROUTES: dict = {}
ABSENT_COURSES = [{"id": "x-1", "title": "Kurs eins"}, {"id": "x-2", "title": "Kurs zwei"}]


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import db, studip_texts as st

        def runner(routes):
            def get(path):
                r = routes.get(path) or err(404)
                return r["status"], copy.deepcopy(r["body"])
            return get

        def run(name, routes, courses, today, now, budget=st.MAX_REQUESTS, replace=None):
            routes = {**routes, **(replace or {})}
            with db.cursor() as conn:
                known, state = st.load(conn)
                d = st.fetch(runner(routes), courses, known, state, today, BASE, budget)
                res = st.store(conn, d, now)
                return {"name": name, "today": today.isoformat(), "now": now, "budget": budget, "replace": replace or {},
                        "log": d["log"], "requests": d["requests"], "stopped": d["stopped"], "result": res,
                        "texts": db.rows(conn, "SELECT id, course_id, kind, title, text, url, changed, fetched_at FROM studip_texts ORDER BY id"),
                        "deadlines": db.rows(conn, """SELECT id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at
                                                       FROM deadlines WHERE source='studip' ORDER BY id"""),
                        "state": db.rows(conn, "SELECT key, value FROM studip_text_state ORDER BY key")}

        out = {"base": BASE, "routes": ROUTES, "courses": COURSES, "max_requests": st.MAX_REQUESTS, "runs": []}
        src.fresh_db("texte")
        with db.cursor() as conn:
            mid = conn.execute("INSERT INTO modules(name) VALUES ('Testanalysis')").lastrowid
            conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-ana', 'Testanalysis I', ?, 1)", (mid,))
            conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-prog', 'Testprogrammierung', NULL, 1)")
        out["module_id"] = mid
        out["runs"].append(run("erst", ROUTES, COURSES, date(2026, 11, 2), "2026-11-02T09:00:00"))
        out["runs"].append(run("zweit", ROUTES, COURSES, date(2026, 11, 3), "2026-11-03T09:00:00"))
        with db.cursor() as conn:
            out["overview"] = st.overview(conn, mid)
            out["item"] = st.item(conn, "forum-f1")
            out["search"] = {q: st.search(conn, mid, q) for q in ("Konvergenz der Folge Grenzwert", "Klausur Termin Hilfsmittel", "Grenzwert", "xyz quark")}
            out["tutor_sources"] = st.tutor_sources(conn, mid, "Wie zeige ich die Konvergenz der Folge?", 3)
            out["weekly_lines"] = st.weekly_lines(conn, mid, "Folgen und Grenzwert Konvergenz")
        out["runs"].append(run("spaeter", ROUTES, COURSES, date(2026, 11, 22), "2026-11-22T09:00:00",
                               replace={P + "courses/c-ana/wiki-pages?page[limit]=100": ok(ROUTES[P + "courses/c-ana/wiki-pages?page[limit]=100"]["body"]["data"])}))
        src.fresh_db("knapp")
        out["runs"].append(run("knapp", ROUTES, COURSES, date(2026, 11, 2), "2026-11-02T09:00:00", budget=5))
        src.fresh_db("fehlt")
        out["runs"].append(run("fehlt", ABSENT_ROUTES, ABSENT_COURSES, date(2026, 11, 2), "2026-11-02T09:00:00"))
        out["runs"].append(run("fehlt-danach", ABSENT_ROUTES, ABSENT_COURSES, date(2026, 11, 3), "2026-11-03T09:00:00"))
        for r in out["runs"]:
            r["courses"] = "absent" if r["name"].startswith("fehlt") else "main"
        out["absent_courses"] = ABSENT_COURSES
        out["cases"] = {
            "berlin_local": {v: st.berlin_local(v) for v in ("2026-11-12T23:59:00+01:00", "2026-07-01T10:00:00Z", "2026-11-12T08:15",
                                                             "2026-11-12", "2026-13-01", "morgen", "2026-10-25T01:30:00Z")},
            "markup": {v: st.markup_to_text(v) for v in ("!!!Titel\n**fett** [[Seite|Text]] [[Ziel]]", "  a \t b \n\n c  ")},
            "anonymize": {v: st.anonymize(v) for v in ("[QUOTE=Anna]x[/quote]Danke @anna.b, gut", "Mail an a@b.de")},
            "cut": {v: st.cut(v, 12) for v in ("kurz", "ein ziemlich langer Satz hier")},
        }
        ok_ = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
        return 0 if ok_ or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv))
