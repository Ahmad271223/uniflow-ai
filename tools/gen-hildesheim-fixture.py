"""Erzeugt packages/shared-contracts/fixtures/hildesheim/expected.json mit der Python-Referenz.

Der Swift-Kern (HildesheimFixtureTests) rechnet dieselben Eingaben und vergleicht: Kurstitel, Learnweb-Dateilisten
(REST und Sitzung), Pluginfile-Links, Semester und Learnweb-Instanz, CAS-Adressen, LSF-iCal (BYDAY, EXDATE),
LSF-Veranstaltungstitel und den Notenspiegel im Hildesheimer Tabellenaufbau. Alle Eingaben sind erfunden.
Aufruf im Projektordner: python tools/gen-hildesheim-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import date
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="uniflow-hi-fixture-")
os.environ["LERNAPP_DATA_DIR"] = str(Path(_TMP) / "data")      # die App-Module legen sonst Ordner unter data/ an
os.environ["LERNAPP_LOG_DIR"] = str(Path(_TMP) / "logs")
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from schema_source import write_or_check  # noqa: E402

import base64  # noqa: E402
import hashlib  # noqa: E402

from app import cas, learnweb, lsf, qis, studip_sync, timetable  # noqa: E402

D = ROOT / "packages" / "shared-contracts" / "fixtures" / "hildesheim"
BASE = "https://www.uni-hildesheim.de/learnweb2026"


def main(check: bool) -> bool:
    ics_course = (D / "lsf-course.ics").read_text(encoding="utf-8")
    ics_plan = (D / "lsf-plan.ics").read_text(encoding="utf-8")
    contents = json.loads((D / "learnweb-course-contents.json").read_text(encoding="utf-8"))

    titles = ["SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "WiSe 2026/27:  1532   Klein(st)kinder", "Mathe-Vorkurs",
              "SS 26: 3200 Grundlagen der BWL", "WS 2026/27: Ringvorlesung"]
    plugin_links = [f"{BASE}/pluginfile.php/4711/mod_resource/content/3/01%20Folien.pdf?forcedownload=1",
                    f"{BASE}/pluginfile.php/9/mod_folder/content/12/Kapitel%201/Text.pdf",
                    f"{BASE}/pluginfile.php/1/mod_resource/content/2/Einfu%CC%88hrung.pdf",
                    f"{BASE}/mod/resource/view.php?id=1"]
    state = {"section": [{"id": "10", "number": 0, "title": "Informationen"}, {"id": "11", "number": 1, "title": "1"},
                         {"id": "12", "number": 2, "title": ""}],
             "cm": [{"id": "1", "module": "resource", "name": "Folien 1", "sectionid": "11"},
                    {"id": "2", "module": "folder", "name": "Texte", "sectionid": "10"},
                    {"id": "3", "module": "forum", "name": "Forum", "sectionid": "10"},
                    {"id": "4", "module": "resource", "name": "versteckt", "sectionid": "10", "uservisible": False},
                    {"id": "5", "module": "resource", "name": "Blatt", "sectionid": "12"}]}
    links = {"1": [f"{BASE}/pluginfile.php/5/mod_resource/content/4/Folien%201.pdf"],
             "2": [f"{BASE}/pluginfile.php/6/mod_folder/content/2/x.pdf?forcedownload=1", f"{BASE}/pluginfile.php/6/mod_folder/content/2/Sub/y.pdf"],
             "5": [f"{BASE}/pluginfile.php/7/mod_resource/content/1/blatt.pdf"]}
    folder_html = (f'<a href="{BASE}/pluginfile.php/6/mod_folder/content/2/x.pdf?forcedownload=1">x</a>'
                   f'<a href="{BASE}/pluginfile.php/6/mod_folder/content/2/x.pdf">x</a><a href="/other">o</a>')
    discover_names = {2025: "Learnweb SoSe 2025 - WiSe 2025/26", 2026: "Learnweb SoSe 2026 - WiSe 2026/27",
                      2027: "Learnweb SoSe 2027 - WiSe 2027/28"}
    discover_cases = [("2026-10-25", [2025, 2026]), ("2027-01-20", [2025, 2026, 2027]), ("2027-04-10", [2026, 2027]),
                      ("2027-04-10", [2026])]
    grade_rows = [
        ["Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022 Prüfungsordnung Studienordnung"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["5010", "Modul 1: Einführung", "", "", "12"],
        ["5011", "TM 1: Grundlagen /\n0424 Einführung", "1,7", "bestanden", "6"],
        ["5013", "TM 3: Prozesse / 0503 Methodik", "", "bestanden", "3"],
        ["5032", "TM 2: Kindheit / 0410 Kindheit", "", "angemeldet (SoSe 26)", "0"],
        ["8000", "Gesamtkonto studienbegleitender Prüfungen", "", "", "44,5"],
        ["Abschluss: [82] Bachelor Studiengang: [021] Begleitfach PO-Version: 2022"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["10010", "Pflichtmodule (mindestens 12 LP)", "", "Prüfung vorhanden", "6"],
        ["4220", "Grundlagen I / 3200 Grundlagen 1", "2,3", "bestanden", "6"],
    ]
    keep = ("number", "title", "lecturer", "weekday", "start_time", "end_time", "rrule", "date_from", "date_to", "exdates")
    probe = lambda years: (lambda base: discover_names.get(int(base[-4:])) if int(base[-4:]) in years else None)

    out = {
        "_hinweis": "Erzeugt mit tools/gen-hildesheim-fixture.py aus der Python-Referenz; nicht von Hand aendern.",
        "course-titles": {t: learnweb.parse_course_title(t) for t in titles},
        "section-labels": [{"title": t, "number": n, "label": learnweb.section_label(t, n)}
                           for t, n in (("3", 3), ("Informationen", 0), ("", 4), ("  Woche  2 ", 2), ("12", 12))],
        "file-ids": [{"cmid": 77, "filepath": "/", "filename": "plan.pdf", "id": learnweb.file_id(77, "/", "plan.pdf")},
                     {"cmid": 80, "filepath": "/Teil 1/", "filename": "Einführung.pdf", "id": learnweb.file_id(80, "/Teil 1/", "Einführung.pdf")}],
        "learnweb-course-contents.json": [{k: f[k] for k in ("id", "name", "size", "mime", "chdate", "download_url", "folder")}
                                          for f in learnweb.files_from_contents(contents)],
        "pluginfile": [{"url": u, "parsed": learnweb.parse_pluginfile(u)} for u in plugin_links],
        "with-token": [{"url": u, "token": "ABC123", "result": learnweb.with_token(u, "ABC123")}
                       for u in (f"{BASE}/webservice/pluginfile.php/5/a.pdf", f"{BASE}/x.php?a=1")],
        "session-state": {"state": state, "links": links,
                          "files": [{k: f[k] for k in ("id", "name", "chdate", "download_url", "folder")}
                                    for f in learnweb.files_from_state(state, lambda c: links.get(str(c), []), lambda c: links.get(str(c), []))]},
        "folder-html": {"html": folder_html, "links": learnweb.folder_links(folder_html)},
        "semester-labels": {d: learnweb.semester_label(date.fromisoformat(d)) for d in
                            ("2026-03-15", "2026-04-01", "2026-09-30", "2026-10-01", "2026-12-24", "2027-01-20")},
        "learnweb-discover": {"names": {str(k): v for k, v in discover_names.items()},
                              "cases": [{"today": t, "alive": a, "base": learnweb.discover_base(date.fromisoformat(t), probe(set(a)))}
                                        for t, a in discover_cases]},
        "cas": {"login_url": cas.login_url("https://www.uni-hildesheim.de/sso", "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1"),
                "is_cas_page": [{"url": u, "result": cas.is_cas_page(u, "https://www.uni-hildesheim.de/sso")} for u in
                                ("https://www.uni-hildesheim.de/sso/login?service=x", "https://uni-hildesheim.de/sso/login",
                                 "https://www.uni-hildesheim.de/learnweb2026/my/", "https://lsf.uni-hildesheim.de/sso/login")]},
        "lsf-course.ics": [{k: e[k] for k in ("weekday", "start_time", "end_time", "rrule", "date_from", "date_to", "exdates")}
                           for e in timetable.parse_ics(ics_course)],
        "lsf-plan.ics": [{k: e[k] for k in keep} for e in lsf.plan_entries(ics_plan)],
        "lsf-summary": [{"summary": s, **lsf.split_summary(s)} for s in
                        ("0449 - Erinnerungen\\, Erzählungen (Zimmermann)", "1532 - Klein(st)kinder in den stationären Hilfen",
                         "Ohne Nummer (Meier, Schulz)", "2072 - Das perfekte Zimmer. Wohnraum als Konsumkultur")],
        "lsf-plan-link": [{"html": h, "link": lsf.plan_ics_link(h)} for h in (
            '<a href="https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&amp;status=transform&amp;termine=1,2&amp;moduleCall=iCalendarPlan">',
            '<a href="rds?state=wplan&amp;moduleCall=iCalendarPlan">', "<html>kein Plan</html>")],
        "grade-rows": {"abschluss": "Fallback", "rows": grade_rows,
                       "grades": [{k: g.get(k) for k in ("pruefungsnr", "text", "note", "status", "credits", "abschluss")}
                                  for g in qis.parse_grade_rows(grade_rows, "Fallback")]},
    }
    sig = hashlib.md5((BASE + "pass123").encode()).hexdigest()
    good = base64.b64encode(f"{sig}:::abcdef0123456789:::priv99".encode()).decode()
    only = base64.b64encode(f"{sig}:::tok42".encode()).decode()
    out["moodle-launch"] = {
        "base": BASE, "passport": "pass123", "launch_url": learnweb.launch_url(BASE, "pass123"),
        "cases": [{"url": u, "passport": pp, "result": learnweb.parse_launch_token(u, BASE, pp)} for u, pp in (
            (f"moodlemobile://token={good}", "pass123"), (f"moodlemobile://token={only}", "pass123"),
            (f"moodlemobile://token={good}", "falsch"), ("moodlemobile://token=%%%", "pass123"), ("moodlemobile://nix", "pass123"))]}
    titles_kind = ["Übung zu Mathematik I", "Gruppenübung Programmieren", "Hörsaalübung Mathe", "Tutorium Physik",
                   "Seminar: Kindheit", "Labor Elektrotechnik", "0406 Theorien der Erziehungswissenschaft",
                   "Begrüßung Erstsemester", "Mathematik I (Tranche A)", "Fragestunde Numerik"]
    out["classify"] = [{"title": t, "subject": studip_sync.classify(t)[0], "kind": studip_sync.classify(t)[1],
                        "event_kind": timetable.guess_kind(t)} for t in titles_kind]
    out["file-kind"] = [{"name": n, "mime": m, "kind": studip_sync.file_kind(n, m)} for n, m in (
        ("Folie.PDF", None), ("blatt.pdf", "application/pdf"), ("a.py", "text/x-python"), ("bild.JPG", None),
        ("x.bin", "image/png"), ("archiv.zip", None), ("ohne", "application/pdf"))]
    text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=False) + "\n"
    return write_or_check(D / "expected.json", text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
