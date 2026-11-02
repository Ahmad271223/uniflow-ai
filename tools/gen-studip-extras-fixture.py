"""Erzeugt packages/shared-contracts/fixtures/studip-extras/extras.json: Semester, vorlesungsfreie Zeiten, Stud.IP-weite
Ankuendigungen, Nachrichten (nur Liste), Activity-Stream, Sprechstunden und die Karte "Neuigkeiten" (02.11.2026) mit
der Python-Referenz (app/studip_terms.py, app/studip_extras.py) auf erfundenen JSON:API-Antworten und eingefrorenem Tag
(Montag, 02.11.2026). Der Swift-Kern (StudIPExtrasTests) liest dieselben Antworten und vergleicht exakt.

Inhalt:
- semesters / holidays: Antwort -> gelesen (parse_semesters, parse_holidays)
- day_marks: holidays.day_marks mit und ohne Stud.IP-Zeiten fuer 20.12.2026-15.01.2027 und 25.01.-20.04.2027
- lecture_week: Lehrwoche fuer den Lernplan an Tagen vor, in und nach der Weihnachtspause
- missing: should_ask / remember (fehlende Endpunkte merken)
- global_news, messages, activity, bookings: Antwort -> gelesen
- feed: Karte "Neuigkeiten" aus Kurs-Ankuendigung, Stud.IP-weiter Ankuendigung, Nachrichten und Aenderungen

Aufruf im Projektordner: python tools/gen-studip-extras-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, berlin_time, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-extras" / "extras.json"
TODAY = date(2026, 11, 2)
BASE = "https://studip.test"

SEMESTERS = {"data": [
    {"id": "s27", "type": "semesters", "attributes": {"title": "SoSe 2027", "start": "2027-04-01T00:00:00+02:00", "end": "2027-09-30T23:59:59+02:00",
                                                       "start-of-lectures": "2027-04-12T00:00:00+02:00", "end-of-lectures": "2027-07-24T23:59:59+02:00"}},
    {"id": "s26", "type": "semesters", "attributes": {"title": "WiSe 2026/27", "start": "2026-10-01T00:00:00+02:00", "end": "2027-03-31T23:59:59+02:00",
                                                       "start-of-lectures": "2026-10-12T00:00:00+02:00", "end-of-lectures": "2027-02-06T23:59:59+01:00"}},
    {"id": "s31", "type": "semesters", "attributes": {"title": "WiSe 2031/32", "start-of-lectures": "2031-10-13T00:00:00+02:00",
                                                       "end-of-lectures": "2032-01-31T23:59:59+01:00"}},
    {"id": "kaputt", "type": "semesters", "attributes": {"title": "Ohne Daten", "start": 1790000000}},
    {"type": "semesters", "attributes": {"title": "ohne Kennung"}},
]}
HOLIDAYS = {"data": [
    {"id": "h1", "type": "holidays", "attributes": {"title": "Hochschultag", "start": "2026-11-18T00:00:00+01:00", "end": "2026-11-18T23:59:59+01:00"}},
    {"id": "h2", "type": "holidays", "attributes": {"name": "Weihnachtspause", "begin": "2026-12-23", "end": "2027-01-05"}},
    {"id": "h3", "type": "holidays", "attributes": {"title": "Rueckwaerts", "start": "2027-01-10", "end": "2027-01-09"}},
]}
GLOBAL_NEWS = {"data": [
    {"id": "g1", "type": "news", "attributes": {"title": "Rückmeldung zum SoSe 2027", "content": "<p>Bitte bis zum 15.01.2027 zurückmelden (Frist).</p>",
                                                "publication-start": "2026-11-01T10:00:00+01:00"}},
    {"id": "k1", "type": "news", "attributes": {"title": "Steht auch im Kurs", "content": "x", "mkdate": "2026-10-30T08:00:00+01:00"}},
    {"type": "news", "attributes": {"title": "ohne Kennung"}},
]}
INBOX = {"data": [
    {"id": "m1", "type": "messages", "attributes": {"subject": "Tutorium entfällt", "message": "<p>Liebe Studierende,<br>das Tutorium am 12.11. fällt aus. "
                                                    "Die Abgabe von Blatt 4 ist bis 19.11. um 12 Uhr möglich.</p>", "mkdate": "2026-11-02T08:15:00+01:00", "is-read": False},
     "relationships": {"sender": {"data": {"type": "users", "id": "u-doz"}}}},
    {"id": "m2", "type": "messages", "attributes": {"subject": "Ihre Bescheinigung", "message": "Text", "mkdate": "2026-10-31T12:00:00+01:00"},
     "relationships": {"sender": {"data": {"type": "users", "id": "____%system%____"}}}},
    {"id": "m3", "type": "messages", "attributes": {"subject": "", "message": "Hallo   \n zusammen " + "x" * 300, "mkdate": "2026-10-20T12:00:00+02:00"},
     "relationships": {"sender": {"data": {"type": "users", "id": "u-anon"}}}},
    {"id": "m4", "type": "messages", "attributes": {"subject": "Ohne Absender", "message": "", "mkdate": "2026-10-19T12:00:00+02:00"},
     "relationships": {"sender": {"data": None}}},
], "included": [
    {"id": "u-doz", "type": "users", "attributes": {"formatted-name": "Prof. Erika Test", "permission": "dozent"}},
    {"id": "u-anon", "type": "users", "attributes": {"given-name": "Max", "family-name": "Probe"}},
]}
ACTIVITY = {"data": [
    {"id": "a1", "type": "activities", "attributes": {"activity-type": "documents", "mkdate": "2026-11-02T07:00:00+01:00", "title": "Erika Test hat eine Datei hochgeladen"},
     "relationships": {"context": {"data": {"type": "courses", "id": "k-vl"}}}},
    {"id": "a2", "type": "activities", "attributes": {"activity-type": "documents", "mkdate": "2026-11-02T07:30:00+01:00"},
     "relationships": {"context": {"data": {"type": "courses", "id": "k-vl"}}}},
    {"id": "a3", "type": "activities", "attributes": {"activity-type": "forum", "mkdate": "2026-11-01T18:00:00+01:00"},
     "relationships": {"context": {"data": {"type": "courses", "id": "k-vl"}}}},
    {"id": "a4", "type": "activities", "attributes": {"activity-type": "participants", "mkdate": "2026-11-02T09:00:00+01:00"},
     "relationships": {"context": {"data": {"type": "courses", "id": "k-vl"}}}},
    {"id": "a5", "type": "activities", "attributes": {"activity-type": "news", "mkdate": "2026-11-02T09:00:00+01:00"},
     "relationships": {"context": {"data": {"type": "courses", "id": "k-vl"}}}},
    {"id": "a6", "type": "activities", "attributes": {"activity-type": "wiki", "mkdate": "2026-11-02T09:00:00+01:00"},
     "relationships": {"context": {"data": {"type": "institutes", "id": "i1"}}}},
]}
BOOKINGS = {"data": [
    {"id": "b1", "type": "consultation-bookings", "attributes": {"reason": "Frage zur Hausarbeit"},
     "relationships": {"slot": {"data": {"type": "consultation-slots", "id": "sl1"}}}},
    {"id": "b2", "type": "consultation-bookings", "relationships": {"slot": {"data": {"type": "consultation-slots", "id": "sl2"}}}},
    {"id": "b3", "type": "consultation-bookings", "relationships": {"slot": {"data": {"type": "consultation-slots", "id": "fehlt"}}}},
], "included": [
    {"id": "sl1", "type": "consultation-slots", "attributes": {"start-time": "2026-11-05T14:00:00+01:00", "end-time": "2026-11-05T14:15:00+01:00"},
     "relationships": {"block": {"data": {"type": "consultation-blocks", "id": "bl1"}}}},
    {"id": "sl2", "type": "consultation-slots", "attributes": {"start": 1794063600, "end": 1794064500}},
    {"id": "bl1", "type": "consultation-blocks", "attributes": {"room": "Raum 101 (Testgebäude)"}},
]}

MARK_RANGES = [("2026-11-16", "2026-11-20"), ("2026-12-20", "2027-01-15"), ("2027-01-25", "2027-04-20")]
LECTURE_DAYS = ["2026-12-21", "2026-12-23", "2026-12-28", "2027-01-05", "2027-01-06", "2027-01-11", "2027-02-10"]
MISSING_CASES = [
    {"missing": {}, "name": "holidays", "today": "2026-11-02"},
    {"missing": {"holidays": "2026-10-20"}, "name": "holidays", "today": "2026-11-02"},
    {"missing": {"holidays": "2026-10-03"}, "name": "holidays", "today": "2026-11-02"},
    {"missing": {"holidays": 5}, "name": "holidays", "today": "2026-11-02"},
]
REMEMBER_CASES = [
    {"missing": {}, "name": "inbox", "status": 404},
    {"missing": {}, "name": "inbox", "status": 403},
    {"missing": {"inbox": "2026-09-01"}, "name": "inbox", "status": 200},
    {"missing": {"inbox": "2026-09-01"}, "name": "inbox", "status": 500},
]
COURSE_NEWS = {"id": "kn1", "type": "news", "attributes": {"title": "Vorlesung entfällt", "content": "<p>Die Vorlesung am 12.11. fällt aus.</p>",
                                                           "publication-start": "2026-11-02T09:00:00+01:00"}}


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import announcements, holidays, studip_extras, studip_terms, study

        study.today = lambda: TODAY
        sems = studip_terms.parse_semesters(SEMESTERS["data"])
        hols = studip_terms.parse_holidays(HOLIDAYS["data"])
        studip = {"semesters": sems, "holidays": hols}
        marks = []
        for a, b in MARK_RANGES:
            lo, hi = date.fromisoformat(a), date.fromisoformat(b)
            marks.append({"from": a, "to": b, "plain": holidays.day_marks(lo, hi, "luh"), "studip": holidays.day_marks(lo, hi, "luh", studip=studip)})
        sem_start = date(2026, 10, 12)
        free = studip_terms.free_days(date(2026, 12, 21), date(2027, 2, 10), "luh", studip)
        weeks = [{"day": d, "week": studip_terms.lecture_week(sem_start, date.fromisoformat(d), free),
                  "plain_week": study.day_week(sem_start, date.fromisoformat(d))} for d in LECTURE_DAYS]
        merged = [[n, s, e, [list(x) for x in br]] for n, s, e, br in studip_terms.merged_semesters("luh", studip)]
        missing = [dict(c, ask=studip_extras.should_ask(c["missing"], c["name"], c["today"])) for c in MISSING_CASES]
        remember = [dict(c, after=studip_extras.remember(c["missing"], c["name"], c["status"], "2026-11-02")) for c in REMEMBER_CASES]
        gnews = studip_extras.global_news(GLOBAL_NEWS["data"], BASE)
        msgs = studip_extras.parse_messages(INBOX["data"], INBOX["included"], BASE, TODAY)
        with berlin_time():
            bookings = studip_extras.parse_bookings(BOOKINGS["data"], BOOKINGS["included"])
        act = studip_extras.parse_activity(ACTIVITY["data"], BASE)
        course = announcements.from_studip_news(COURSE_NEWS, "k-vl", BASE)
        news = [dict(course, course_title="Testmathematik", color="#4f5bd5", upcoming=[])] + \
               [dict(g, course_title=None, color=None, upcoming=[]) for g in gnews]
        news.sort(key=lambda x: x["posted_at"], reverse=True)
        acts = [dict(x, course_title="Testmathematik", color="#4f5bd5") for x in act]
        card = studip_extras.feed(news, msgs, acts, TODAY.isoformat())
        out = {"generator": "tools/gen-studip-extras-fixture.py", "today": TODAY.isoformat(), "base": BASE,
               "semesters": {"response": SEMESTERS, "parsed": sems}, "holidays": {"response": HOLIDAYS, "parsed": hols},
               "merged_semesters": merged, "day_marks": marks, "lecture_week": {"semester_start": sem_start.isoformat(), "days": weeks},
               "should_ask": missing, "remember": remember,
               "global_news": {"response": GLOBAL_NEWS, "items": gnews},
               "messages": {"response": INBOX, "items": msgs},
               "activity": {"response": ACTIVITY, "items": act},
               "bookings": {"response": BOOKINGS, "items": bookings},
               "feed": {"course_news": COURSE_NEWS, "news": news, "activity": acts, "items": card}}
        text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        return 0 if write_or_check(OUT, text, check) or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
