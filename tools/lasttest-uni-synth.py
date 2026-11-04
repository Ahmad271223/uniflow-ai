#!/usr/bin/env python3
"""Synthetische Hochschulen fuer den Riesentest (03.11.2026): N erfundene Studierende mit Stud.IP + QIS (LUH) oder
Learnweb + LSF (Hildesheim), als feste Antworten je Adresse. Nichts hiervon ruft je eine echte Hochschule auf; die
Adressen tragen Hosts, die kein Netz kennt (studip.synth.invalid) bzw. werden von den Pruefwerkzeugen abgefangen.

Je Konto entsteht eine Datei acc-NNNNN.json:
  account    Kennung, Hochschule, Studiengang, Semester, Adversarial-Schalter
  routes     {"<Pfad?Abfrage>": {"status", "type", "body" | "b64", "flaky": [429, ...]}} fuer Stud.IP (ohne Host),
             dazu volle Adressen fuer QIS, LSF, Learnweb; Learnweb-REST als "REST|<wsfunction>|<Schluessel>"
  files      {"<id>": {"serve": Bytes, "kind": "pdf"|..., "html": bool}} - Inhalt rechnen beide Seiten gleich (content())
  expected   Zahlen und Listen, gegen die die Pipelines (Python und Swift) geprueft werden

Aufruf im Projektordner: python tools/lasttest-uni-synth.py --accounts 50 --out /pfad/ordner [--seed 2026]
Nur Standardbibliothek. Dieselben Daten lesen tools/riesentest-python.py (Python-Referenz) und
RiesentestSynthTests (Swift-Kern, apps/apple/Packages/UniFlowCore) bzw. RiesentestSynthAppTests (iPad-App).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import random
import re
import sys
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import quote

TODAY = date(2026, 11, 3)
STUDIP_HOST = "studip.synth.invalid"
LEARNWEB_BASE = "https://www.uni-hildesheim.de/learnweb2026"      # abgefangen, nie aufgerufen (Host-Pruefung der App)
LSF_BASE = "https://lsf.uni-hildesheim.de"
QIS_BASE = "https://qis.verwaltung.uni-hannover.de"
CAS_BASE = "https://www.uni-hildesheim.de/sso"
API = "/jsonapi.php/v1/"
TOKEN = "synthtoken0001"

# Semester neueste zuerst: (Titel, Semesterbeginn, Semesterende, Vorlesungsbeginn, Vorlesungsende)
SEMESTERS = [
    ("WiSe 2026/27", "2026-10-01", "2027-03-31", "2026-10-12", "2027-01-30"),
    ("SoSe 2026", "2026-04-01", "2026-09-30", "2026-04-07", "2026-07-18"),
    ("WiSe 2025/26", "2025-10-01", "2026-03-31", "2025-10-13", "2026-01-31"),
    ("SoSe 2025", "2025-04-01", "2025-09-30", "2025-04-07", "2025-07-19"),
    ("WiSe 2024/25", "2024-10-01", "2025-03-31", "2024-10-14", "2025-02-01"),
    ("SoSe 2024", "2024-04-01", "2024-09-30", "2024-04-08", "2024-07-20"),
    ("WiSe 2023/24", "2023-10-01", "2024-03-31", "2023-10-16", "2024-02-03"),
    ("SoSe 2023", "2023-04-01", "2023-09-30", "2023-04-11", "2023-07-22"),
]
XMAS = ("2026-12-21", "2027-01-03")

PROGRAMS = {
    "luh": {
        "Informatik": ["Programmieren I", "Programmieren II", "Datenstrukturen und Algorithmen", "Theoretische Informatik",
                       "Grundlagen digitaler Systeme", "Rechnerarchitektur", "Betriebssysteme", "Datenbanksysteme",
                       "Softwaretechnik", "Mathematik für Informatiker I", "Mathematik für Informatiker II", "Lineare Algebra A",
                       "Logik und formale Systeme", "Rechnernetze", "IT-Sicherheit", "Künstliche Intelligenz", "Verteilte Systeme",
                       "Compilerbau", "Mensch-Computer-Interaktion"],
        "Elektrotechnik und Informationstechnik": ["Grundlagen der Elektrotechnik I", "Grundlagen der Elektrotechnik II",
                       "Mathematik für Ingenieure I", "Mathematik für Ingenieure II", "Signale und Systeme", "Elektromagnetische Felder",
                       "Grundlagen digitaler Systeme", "Messtechnik I", "Halbleiterelektronik", "Regelungstechnik I",
                       "Nachrichtentechnik", "Energieversorgung", "Hochfrequenztechnik", "Werkstoffe der Elektrotechnik",
                       "Elektrische Maschinen", "Leistungselektronik", "Physik für Elektrotechniker"],
        "Maschinenbau": ["Technische Mechanik I", "Technische Mechanik II", "Technische Mechanik III", "Werkstoffkunde A",
                       "Konstruktionslehre I", "Thermodynamik I", "Strömungsmechanik I", "Maschinenelemente", "Fertigungstechnik",
                       "Mathematik für Ingenieure I", "Mathematik für Ingenieure II", "Regelungstechnik I", "Produktionstechnik",
                       "Werkzeugmaschinen", "Fahrzeugtechnik", "Technische Dynamik"],
        "Mechatronik": ["Grundlagen der Elektrotechnik I", "Technische Mechanik I", "Mechatronische Systeme", "Regelungstechnik I",
                       "Programmieren I", "Mathematik für Ingenieure I", "Mathematik für Ingenieure II", "Sensorik und Aktorik",
                       "Robotik I", "Elektrische Antriebe", "Signale und Systeme", "Mikrocontroller und eingebettete Systeme",
                       "Konstruktionslehre I", "Technische Dynamik", "Messtechnik I"],
        "Wirtschaftswissenschaften": ["Mathematik für Wirtschaftswissenschaftler", "Statistik I", "Statistik II", "Mikroökonomik",
                       "Makroökonomik", "Rechnungswesen", "Marketing", "Finanzierung und Investition", "Unternehmensführung",
                       "Wirtschaftsinformatik", "Operations Research", "Wirtschaftsprivatrecht", "Controlling", "Steuerlehre",
                       "Personal und Organisation", "Ökonometrie"],
        "Lehramt Mathematik/Physik": ["Analysis A", "Analysis B", "Lineare Algebra A", "Lineare Algebra B", "Experimentalphysik I",
                       "Experimentalphysik II", "Didaktik der Mathematik", "Didaktik der Physik", "Elementare Zahlentheorie",
                       "Geometrie", "Stochastik für Lehramt", "Theoretische Physik I", "Bildungswissenschaften", "Schulpraktische Studien"],
        "Biomedizintechnik": ["Anatomie und Physiologie für Ingenieure", "Grundlagen der Elektrotechnik I", "Medizinische Messtechnik",
                       "Biosignalverarbeitung", "Mathematik für Ingenieure I", "Biomaterialien", "Medizinische Bildgebung",
                       "Zellbiologie", "Regelungstechnik I", "Medizintechnische Geräte", "Statistik für Biomedizin", "Programmieren I"],
        "Informatik mit Nebenfach BWL": ["Programmieren I", "Datenstrukturen und Algorithmen", "Rechnungswesen", "Marketing",
                       "Theoretische Informatik", "Mathematik für Informatiker I", "Datenbanksysteme", "Mikroökonomik", "Softwaretechnik",
                       "Statistik I", "Betriebssysteme", "Unternehmensführung"],
    },
    "hildesheim": {
        "Erziehungswissenschaft": ["Einführung in die Erziehungswissenschaft", "Bildungssoziologie", "Theorien der Bildung",
                       "Pädagogische Psychologie", "Methoden der empirischen Bildungsforschung", "Statistik I", "Statistik II",
                       "Kindheit und Jugend", "Erwachsenenbildung", "Sozialpädagogik", "Inklusion und Heterogenität", "Medienpädagogik",
                       "Schulentwicklung", "Diagnostik und Beratung"],
        "Psychologie": ["Einführung in die Psychologie", "Statistik I", "Statistik II", "Allgemeine Psychologie I", "Entwicklungspsychologie",
                       "Sozialpsychologie", "Biologische Psychologie", "Diagnostik", "Klinische Psychologie", "Arbeits- und Organisationspsychologie",
                       "Methodenlehre", "Pädagogische Psychologie", "Persönlichkeitspsychologie", "Empirisch-experimentelles Praktikum"],
        "Lehramt Grundschule": ["Einführung in die Grundschulpädagogik", "Mathematik in der Grundschule", "Deutsch als Zweitsprache",
                       "Sachunterricht", "Schriftspracherwerb", "Bildungssoziologie", "Diagnostik und Förderung", "Inklusion und Heterogenität",
                       "Kinderliteratur", "Elementare Geometrie", "Musik in der Grundschule", "Schulpraktische Studien"],
        "Wirtschaftsinformatik": ["Einführung in die Wirtschaftsinformatik", "Programmierung I", "Datenbanken", "Betriebswirtschaftslehre I",
                       "Mathematik für Wirtschaftsinformatiker", "Statistik I", "Softwareentwicklung", "IT-Management", "Geschäftsprozesse",
                       "Rechnernetze und Sicherheit", "Projektmanagement", "Data Science"],
        "Informationsmanagement und Informationstechnologie": ["Einführung in das Informationsmanagement", "Programmierung I",
                       "Datenbanken", "Mathematik I", "Statistik I", "Informationsrecht", "Wissensmanagement", "Softwareentwicklung",
                       "Human-Computer-Interaction", "Webtechnologien", "Betriebswirtschaftslehre I", "Data Science"],
    },
}

# Kurs-Familien: (Titelmuster, erwartete Art). {S} = Fachname. Alle Varianten einer Familie sollen auf dasselbe Fach
# fuehren (ein Modul). Die mit "miss:" markierten Muster traf classify vor dem 03.11.2026 nicht (Befund dieses Tests).
VARIANTS = [
    ("{S}", "vorlesung"), ("Vorlesung {S}", "vorlesung"), ("Vorlesung: {S}", "vorlesung"), ("{S} (Vorlesung)", "vorlesung"),
    ("{N} {S}", "vorlesung"), ("{S} (für {P})", "vorlesung"), ("Vorlesung und Übung {S}", "vorlesung"),
    ("Übung zu {S}", "uebung"), ("Übung: {S}", "uebung"), ("Übungen zur {S}", "uebung"), ("Übung zur Vorlesung {S}", "uebung"),
    ("{S} - Übung", "uebung"), ("{S} – Übung", "uebung"), ("{S} (Übung)", "uebung"), ("{S} (Übung, Tranche A)", "uebung"),
    ("Übung {S} - Gruppe {G}", "uebung"), ("Fragestunde {S}", "uebung"), ("Fragestunde zur Vorlesung {S}", "uebung"),
    ("{S} - Fragestunden", "uebung"),
    ("Hörsaalübung {S}", "hoersaaluebung"), ("Hörsaalübung zur {S}", "hoersaaluebung"), ("Zentralübung {S}", "hoersaaluebung"),
    ("Gruppenübung zu {S} (Tranche B)", "gruppenuebung"), ("Gruppenübungen zu {S}, Tranche 2", "gruppenuebung"),
    ("{S} – Gruppenübung Tranche 3", "gruppenuebung"),
    ("Tutorium {S}", "tutorium"), ("Tutorien {S}", "tutorium"), ("{S} (Tutorium Gruppe {G})", "tutorium"),
]
LECTURE_VARIANTS = [v for v in VARIANTS if v[1] == "vorlesung"]
EXERCISE_VARIANTS = [v for v in VARIANTS if v[1] != "vorlesung"]
STANDALONE = ["Praktikum {S}", "Seminar {S}", "Projektseminar {S}", "Labor {S}", "Proseminar: {S}", "Blockseminar {S}"]
OTHER = ["Einführungsveranstaltung Erstsemester {P}", "Begrüßung der Erstsemester {P}", "Studiengänge der Fakultät: {P}"]
ROOMS = ["Hörsaal F 102", "Raum B 305", "Hörsaal V 111", "Seminarraum A 210, Gebäude 3403", "Audimax", "Raum 1101-F107", "Hörsaal 1 / Testgebäude"]
FILE_EXT = [("pdf", 60), ("pptx", 10), ("docx", 8), ("mp4", 5), ("zip", 5), ("png", 4), ("jpg", 3), ("xlsx", 2), ("txt", 1), ("py", 1), ("ipynb", 1)]
MIME = {"pdf": "application/pdf", "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "mp4": "video/mp4",
        "zip": "application/zip", "png": "image/png", "jpg": "image/jpeg", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "txt": "text/plain", "py": "text/x-python", "ipynb": "application/x-ipynb+json"}
FOLDERS = ["Vorlesung", "Übung", "Übungsblätter", "Lösungen", "Skript", "Altklausuren", "Zusatzmaterial", "Folien (Handout)",
           "Videos", "Praktikum", "Organisatorisches", "Woche 1", "Woche 2", "Woche 3", "Woche 4", "Woche 5", "Woche 6"]
ODD_NAMES = ["Übung 3 – Lösung (final) [v2].pdf", "Vorlesung 02: Mengen & Relationen.pdf", "Blatt  mit  doppelten  Leerzeichen.pdf",
             "Einführung.pdf", "name/mit/schraegstrich.pdf", "trailing dot..pdf", ".versteckt.pdf", "CON.pdf", "ohne-endung",
             "Ä Ö Ü ß €.pptx", "日本語の資料.pdf", "a" * 190 + ".pdf", "  leer am rand .pdf", "emoji 📚.pdf", "x.PDF", "null\x00byte.pdf"]
NEWS_PHRASES = [
    ("frist", "Abgabe des {n}. Übungsblatts bis zum {d}, 23:59 Uhr über Stud.IP."),
    ("frist", "Bitte reicht die Lösungen spätestens am {d} ein (Frist!)."),
    ("ausfall", "Die Vorlesung am {d} fällt aus."),
    ("ausfall", "Am {d} findet die Übung nicht statt."),
    ("ausfall", "Keine Vorlesung am {d} (Dienstreise)."),
    ("pruefung", "Die Klausur findet am {d} um 9 Uhr im Hörsaal F 303 statt."),
    ("pruefung", "Prüfung: {d}, Beginn 14:00 Uhr, bitte 15 Minuten vorher da sein."),
    ("verlegt", "Die Sitzung vom {d} wird auf einen Ersatztermin verlegt (Termin folgt)."),
    ("raum", "Raumwechsel: ab dem {d} treffen wir uns in Raum B 305."),
]


# ---------------------------------------------------------------- Hilfen

def h32(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()  # noqa: S324 - nur Kennungen


def berlin_offset(d: date) -> str:
    """+02:00 in der Sommerzeit (letzter Sonntag Maerz bis letzter Sonntag Oktober), sonst +01:00"""
    def last_sunday(y, m):
        last = (date(y + 1, 1, 1) if m == 12 else date(y, m + 1, 1)) - timedelta(days=1)
        return last - timedelta(days=(last.weekday() - 6) % 7)
    return "+02:00" if last_sunday(d.year, 3) <= d < last_sunday(d.year, 10) else "+01:00"


def iso(d: date, hm: str) -> str:
    return f"{d.isoformat()}T{hm}:00{berlin_offset(d)}"


def unix(d: date, hm: str) -> int:
    from datetime import timezone
    h, m = map(int, hm.split(":"))
    off = 2 if berlin_offset(d) == "+02:00" else 1
    return int(datetime(d.year, d.month, d.day, h, m, tzinfo=timezone.utc).timestamp()) - off * 3600


def pick(rng: random.Random, weighted):
    total = sum(w for _, w in weighted)
    x = rng.uniform(0, total)
    for v, w in weighted:
        x -= w
        if x <= 0:
            return v
    return weighted[-1][0]


def jsonapi(data, included=None, links=None) -> dict:
    out = {"data": data}
    if included is not None:
        out["included"] = included
    out["links"] = links or {}
    return out


def body(obj, status: int = 200, ctype: str = "application/vnd.api+json") -> dict:
    return {"status": status, "type": ctype, "body": json.dumps(obj, ensure_ascii=False)}


def text_body(s: str, status: int = 200, ctype: str = "text/html; charset=utf-8") -> dict:
    return {"status": status, "type": ctype, "body": s}


def content(fid: str, n: int, kind: str = "pdf") -> bytes:
    """Dateiinhalt, in Python und Swift gleich gerechnet: Kopf mit Kennung, dann Wiederholung bis n Bytes."""
    head = (f"%PDF-1.4\n% synth {fid}\n" if kind == "pdf" else f"SYNTH {kind} {fid}\n").encode("utf-8")
    if n <= 0:
        return b""
    reps = n // len(head) + 1
    return (head * reps)[:n]


def paged(items: list, path: str, limit: int, extra_query: str = "") -> dict[str, dict]:
    """JSON:API-Seiten mit links.next (relativer Pfad) fuer `path` (ohne Abfrage)."""
    out = {}
    pages = max(1, (len(items) + limit - 1) // limit)
    for i in range(pages):
        key = f"{path}?page[limit]={limit}" + (f"&page[offset]={i * limit}" if i else "") + extra_query
        nxt = f"{path}?page[limit]={limit}&page[offset]={(i + 1) * limit}" + extra_query if i + 1 < pages else None
        out[key] = jsonapi(items[i * limit:(i + 1) * limit], links={"next": nxt} if nxt else {})
    return out


def sem_key(title: str) -> tuple[int, int]:
    m = re.search(r"(WiSe|SoSe)\s*(\d{4})", title)
    return (int(m.group(2)), 2 if m.group(1) == "WiSe" else 1)


CURRENT = sem_key(SEMESTERS[0][0])


# ---------------------------------------------------------------- Konto

class Account:
    def __init__(self, index: int, seed: int):
        self.index = index
        self.rng = random.Random(f"{seed}:{index}")
        rng = self.rng
        self.university = "hildesheim" if index % 4 == 3 else "luh"
        self.program = rng.choice(list(PROGRAMS[self.university]))
        self.uid = ("u" + h32(f"user-{seed}-{index}"))[:32]
        self.username = f"synth{index:05d}"
        self.heavy = index % 37 == 5                               # wie das echte LUH-Konto: 8 Semester, bis 200 Kurse
        self.n_semesters = 8 if self.heavy else pick(rng, [(1, 25), (2, 25), (3, 15), (4, 12), (5, 8), (6, 6), (7, 5), (8, 4)])
        self.flags = self._flags()
        self.routes: dict[str, dict] = {}
        self.files: dict[str, dict] = {}
        self.courses: list[dict] = []
        self.expected: dict = {}

    def _flags(self) -> dict:
        i, rng = self.index, self.rng
        f = {"rate_limit": i % 11 == 4, "server_error": i % 13 == 6, "session_expiry": i % 17 == 9,
             "no_semester_rel": i % 10 == 7, "dup_course": i % 9 == 8, "empty_title": i % 12 == 3, "long_text": i % 8 == 1,
             "html_in_text": i % 6 == 2, "non_utf8": i % 14 == 10, "huge_tree": self.heavy or i % 19 == 12,
             "extras_missing": i % 15 == 11, "calendar_missing": i % 16 == 13, "deep_tree": i % 21 == 14,
             "course_not_in_calendar": i % 7 == 5, "hidden_course": i % 5 == 1, "empty_download": i % 10 == 2,
             "webpage_instead_of_file": i % 23 == 16, "many_groups": i % 6 == 4}
        return f

    # ---------------------------------------------------------------- Kurse

    def build_courses(self) -> None:
        rng = self.rng
        subjects = list(PROGRAMS[self.university][self.program])
        rng.shuffle(subjects)
        total = rng.randint(60, 200) if self.heavy else rng.randint(8, 25)
        sems = SEMESTERS[:self.n_semesters]
        # je Semester ein Anteil, das aktuelle bekommt mindestens 3
        per_sem = [0] * len(sems)
        per_sem[0] = min(total, max(3, total // len(sems)))
        rest = total - per_sem[0]
        for k in range(rest):
            per_sem[1 + k % (len(sems) - 1) if len(sems) > 1 else 0] += 1
        used_subjects = 0
        ci = 0
        for si, sem in enumerate(sems):
            n = per_sem[si]
            while n > 0:
                subject = subjects[used_subjects % len(subjects)]
                used_subjects += 1
                family = self._family(subject, n)
                for title, kind, family_subject in family:
                    self._add_course(ci, title, kind, family_subject, sem)
                    ci += 1
                    n -= 1
        # Sonstiges (kein Modul) im aktuellen Semester
        if rng.random() < 0.6:
            self._add_course(ci, rng.choice(OTHER).format(P=self.program), "sonstiges", None, sems[0]); ci += 1
        if self.flags["empty_title"] and self.university == "luh":            # Moodle kennt keinen leeren Kursnamen
            self._add_course(ci, "", "vorlesung", None, sems[0]); ci += 1
        if self.flags["no_semester_rel"]:
            c = self._add_course(ci, f"Mathe-Vorkurs {self.program}", "vorlesung", f"Mathe-Vorkurs {self.program}", None); ci += 1
            c["no_semester"] = True
        # "unbegrenzt": ein Kurs aus einem alten Semester, der laut Endsemester (data: null) weiterlaeuft (nur Stud.IP;
        # das Learnweb kennt kein Endsemester, dort zaehlt der Semestername im Titel)
        old = [c for c in self.courses if c["semester"] and c["semester"] != sems[0][0]] if self.university == "luh" else []
        if old:
            c = rng.choice(old)
            c["semester_end"] = "unbegrenzt"
            c["active"] = True

    def _family(self, subject: str, budget: int) -> list[tuple[str, str, str]]:
        rng = self.rng
        if self.university == "hildesheim":
            # Learnweb-Titel: "WiSe 2026/27: 9072 Einführung in ..." - Fach und Art wie classify; Seminare eigene Fächer
            if rng.random() < 0.35:
                t = rng.choice(["Seminar: {S}", "Seminar {S}", "Blockseminar {S}", "Praktikum {S}"]).format(S=subject)
                return [(t, "vorlesung", t)]
            out = [("{S}", "vorlesung", subject)]
            if budget > 1 and rng.random() < 0.5:
                out.append((rng.choice(["Übung {S}", "Übung zu {S}", "Tutorium {S}", "Tutorien {S}"]), "uebung", subject))
            return [(t.format(S=subject), ("tutorium" if "Tutori" in t else k), s) for t, k, s in out]
        r = rng.random()
        if r < 0.12:
            t = rng.choice(STANDALONE).format(S=subject)
            return [(t, "vorlesung", t)]
        lecture = rng.choice(LECTURE_VARIANTS)
        n_ex = 0 if budget <= 1 else pick(rng, [(0, 20), (1, 45), (2, 25), (3, 10)])
        if self.flags["many_groups"] and budget > 4 and rng.random() < 0.3:
            n_ex = 4
        exercises = rng.sample(EXERCISE_VARIANTS, min(n_ex, len(EXERCISE_VARIANTS)))
        out = []
        for tpl, kind in [lecture] + exercises:
            t = tpl.format(S=subject, N=rng.randint(10000, 99999), P=self.program.split()[0], G=rng.randint(1, 12))
            out.append((t, kind, subject))
        return out

    def _add_course(self, ci: int, title: str, kind: str, subject: str | None, sem) -> dict:
        rng = self.rng
        cid = h32(f"course-{self.uid}-{ci}")
        sem_title = sem[0] if sem else ""
        c = {"id": cid, "n": ci, "title": title, "kind": kind, "subject": subject, "semester": sem_title, "sem": sem,
             "semester_end": sem_title if sem else None, "number": f"{rng.randint(1000, 9999)}" if rng.random() < 0.7 else None,
             "course_type": {"vorlesung": 1, "uebung": 3, "hoersaaluebung": 3, "gruppenuebung": 3, "tutorium": 3, "sonstiges": 99}.get(kind, 1),
             "active": (sem is None) or (sem_key(sem_title) >= CURRENT), "moodle_id": 1000 + ci, "slots": [], "files": [], "events": [],
             "news": [], "description": f"<p>Beschreibung von {html.escape(title)}.</p>" if rng.random() < 0.7 else None}
        # Kurszeiten: Vorlesung 1-2, Uebung 1 (Gruppen sind eigene Kurse), bei many_groups eine Uebung mit 3 Gruppen
        n_slots = 1 if kind != "vorlesung" else pick(rng, [(1, 70), (2, 30)])
        if kind in ("uebung", "gruppenuebung") and self.flags["many_groups"] and rng.random() < 0.4:
            n_slots = 3
        if kind == "sonstiges":
            n_slots = 0
        used = set()
        for k in range(n_slots):
            while True:
                wd, hour = rng.randint(0, 4), rng.choice([8, 10, 12, 14, 16])
                if (wd, hour) not in used:
                    used.add((wd, hour)); break
            start = f"{hour:02d}:{'15' if hour == 8 else '00'}"
            end = f"{hour + 1:02d}:{'45' if hour == 8 else '30'}"
            c["slots"].append({"id": h32(f"cycle-{cid}-{k}"), "weekday": wd, "start": start, "end": end, "room": rng.choice(ROOMS),
                               "in_calendar": True})
        self.courses.append(c)
        return c

    # ---------------------------------------------------------------- Dateien

    def build_files(self) -> None:
        rng = self.rng
        total = rng.randint(900, 1500) if self.heavy else pick(rng, [(rng.randint(50, 120), 40), (rng.randint(120, 300), 35), (rng.randint(300, 700), 20), (rng.randint(700, 1500), 5)])
        n_courses = max(1, len(self.courses))
        weights = [3 if c["active"] else 1 for c in self.courses]
        for i, c in enumerate(self.courses):
            share = max(1, int(total * weights[i] / sum(weights)))
            self._course_tree(c, share)
        if self.flags["huge_tree"]:
            c = next((c for c in self.courses if c["active"] and c["kind"] == "vorlesung"), self.courses[0])
            self._big_folder(c, 620)
        if self.flags["deep_tree"]:
            c = next((c for c in self.courses if c["active"]), self.courses[0])
            self._deep_chain(c, 8)

    def _file(self, c: dict, folder: dict, name: str | None = None, ext: str | None = None, depth: int = 0) -> dict:
        rng = self.rng
        ext = ext or pick(rng, FILE_EXT)
        if name is None:
            base = rng.choice(["Vorlesung", "Übung", "Blatt", "Lösung", "Folien", "Skript", "Handout", "Aufgaben", "Klausur", "Video"])
            name = f"{base} {rng.randint(1, 14):02d}_{rng.choice(['Mengen', 'Induktion', 'Matrizen', 'Signale', 'Kräfte', 'Wärme', 'Felder', 'Graphen'])}.{ext}"
        n = len(self.files) + 1
        fid = h32(f"file-{self.uid}-{n}")
        size = {"pdf": rng.randint(50_000, 20_000_000), "pptx": rng.randint(1_000_000, 40_000_000), "mp4": rng.randint(50_000_000, 800_000_000),
                "zip": rng.randint(1_000_000, 200_000_000)}.get(ext, rng.randint(2_000, 5_000_000))
        serve = min(size, 1024)
        if rng.random() < 0.004:
            serve = min(size, 2_000_000)                      # ein paar grosse Dateien (Streaming)
        day = date.fromisoformat((c["sem"] or SEMESTERS[0])[3]) + timedelta(days=rng.randint(0, 100))
        f = {"id": fid, "course": c["id"], "folder": folder["id"], "path": folder["path"], "depth": depth, "name": name, "ext": ext, "size": size,
             "serve": serve, "mime": MIME.get(ext), "chdate": iso(day, f"{rng.randint(7, 20):02d}:{rng.choice(['00', '15', '30', '45'])}"),
             "chdate_unix": unix(day, "10:00"), "downloadable": True, "link": None, "forbidden": folder.get("forbidden", False),
             "html": False}
        if rng.random() < 0.03:
            f["downloadable"] = False
            if rng.random() < 0.6:
                f["link"] = f"https://example.invalid/material/{n}"
        if rng.random() < 0.02:
            f["chdate"] = str(f["chdate_unix"])               # Aenderungszeit als Zahl (aeltere Fassung)
        self.files[fid] = f
        folder["files"].append(fid)
        c["files"].append(fid)
        return f

    def _folder(self, c: dict, parent: dict | None, name: str, depth: int, forbidden: bool = False, status: int = 403) -> dict:
        fo = {"id": h32(f"folder-{c['id']}-{name}-{depth}-{len(c.setdefault('folders', []))}"), "name": name,
              "path": (f"{parent['path']}/{name}" if parent and parent["path"] else name) if parent else "", "files": [], "subs": [],
              "depth": depth, "forbidden": forbidden or (parent or {}).get("forbidden", False), "status": status, "root": parent is None}
        c.setdefault("folders", []).append(fo)
        if parent:
            parent["subs"].append(fo)
        return fo

    def _course_tree(self, c: dict, n_files: int) -> None:
        rng = self.rng
        root = self._folder(c, None, "", 0)
        n_sub = pick(rng, [(0, 15), (1, 25), (2, 25), (3, 20), (5, 15)])
        subs = [self._folder(c, root, nm, 1) for nm in rng.sample(FOLDERS, min(n_sub, len(FOLDERS)))]
        if subs and rng.random() < 0.3:
            subs.append(self._folder(c, subs[0], "Lösungen", 2))
        if subs and rng.random() < 0.2:
            self._folder(c, root, "Nur für Lehrende", 1, forbidden=True)
        if subs and rng.random() < 0.1:
            self._folder(c, root, "Gelöschter Ordner", 1, forbidden=True, status=404)
        if rng.random() < 0.05:
            self._folder(c, root, "", 1)                      # Ordner ohne Namen
        targets = [root] + [s for s in subs]
        for k in range(n_files):
            fo = rng.choice(targets) if rng.random() < 0.85 else rng.choice([x for x in c["folders"]])
            self._file(c, fo, depth=fo["depth"])
        forb = [fo for fo in c["folders"] if fo["forbidden"]]
        for fo in forb:
            for _ in range(rng.randint(1, 4)):
                self._file(c, fo, depth=fo["depth"])
        # Sonderfaelle: seltsame Namen, Doppelte, leerer Name
        if c["active"]:
            for nm in rng.sample(ODD_NAMES, min(len(ODD_NAMES), rng.randint(1, 4))):
                self._file(c, root, name=nm, ext=nm.rsplit(".", 1)[-1].lower() if "." in nm else "bin")
            if rng.random() < 0.5 and c["files"]:
                dup = self.files[rng.choice(c["files"])]
                self._file(c, self._find_folder(c, dup["folder"]), name=dup["name"], ext=dup["ext"], depth=dup["depth"])   # gleicher Name, gleicher Ordner
                other = rng.choice(targets)
                self._file(c, other, name=dup["name"], ext=dup["ext"], depth=other["depth"])                              # gleicher Name, anderer Ordner
            if rng.random() < 0.3:
                self._file(c, root, name="", ext="pdf")

    def _find_folder(self, c: dict, fid: str) -> dict:
        return next(fo for fo in c["folders"] if fo["id"] == fid)

    def _big_folder(self, c: dict, n: int) -> None:
        fo = self._folder(c, self._find_folder(c, c["folders"][0]["id"]), "Alle Folien", 1)
        for k in range(n):
            self._file(c, fo, name=f"Folie {k + 1:03d}.pdf", ext="pdf", depth=1)

    def _deep_chain(self, c: dict, depth: int) -> None:
        parent = c["folders"][0]
        for d in range(1, depth + 1):
            parent = self._folder(c, parent, f"Ebene {d}", d)
            self._file(c, parent, name=f"tief-{d}.pdf", ext="pdf", depth=d)

    # ---------------------------------------------------------------- Termine, Ankuendigungen

    def build_events(self) -> None:
        rng = self.rng
        for c in self.courses:
            if not c["slots"]:
                continue
            sem = c["sem"] or SEMESTERS[0]                       # ohne Semester: Termine im laufenden Semester
            ls, le = date.fromisoformat(sem[3]), date.fromisoformat(sem[4])
            xs, xe = date.fromisoformat(XMAS[0]), date.fromisoformat(XMAS[1])
            for slot in c["slots"]:
                first = ls + timedelta(days=(slot["weekday"] - ls.weekday()) % 7)
                d = first
                k = 0
                while d <= le:
                    if not (xs <= d <= xe):
                        c["events"].append({"id": h32(f"event-{c['id']}-{slot['id']}-{k}"), "slot": slot["id"], "date": d.isoformat(),
                                            "start": slot["start"], "end": slot["end"], "room": slot["room"], "cancelled": False,
                                            "title": f"{k + 1}. Sitzung", "description": ""})
                    d += timedelta(days=7)
                    k += 1
            if c["active"] and c["events"]:
                # ein Ausfall, eine Verlegung (Ersatztermin als Einzeltermin)
                ev = rng.choice([e for e in c["events"] if e["date"] >= TODAY.isoformat()] or c["events"])
                ev["cancelled"] = True
                ev["description"] = "Fällt aus (Dienstreise)"
                mv = rng.choice(c["events"])
                moved_day = date.fromisoformat(mv["date"]) + timedelta(days=1)
                # 17:45: nie im Zeitfenster einer Kurszeit (ein Ersatztermin im Fenster einer fremden Gruppe liesse diese am PC als
                # eigene gelten; Befund Riesentest, dokumentiert)
                c["events"].append({"id": h32(f"event-{c['id']}-ersatz"), "slot": None, "date": moved_day.isoformat(), "start": "17:45", "end": "19:15",
                                    "room": rng.choice(ROOMS), "cancelled": False, "title": "Ersatztermin", "description": "Nachholtermin"})
            # Ankuendigungen mit Fristen (nur aktive Kurse)
            if c["active"] and rng.random() < 0.8:
                for k in range(rng.randint(1, 4)):
                    kind, phrase = rng.choice(NEWS_PHRASES)
                    day = TODAY + timedelta(days=rng.randint(3, 60))
                    dtext = rng.choice([day.strftime("%d.%m.%Y"), day.strftime("%d.%m."), f"{day.day}.{day.month}.{day.year}"])
                    text = phrase.format(n=rng.randint(1, 9), d=dtext)
                    posted = TODAY - timedelta(days=rng.randint(0, 20))
                    c["news"].append({"id": h32(f"news-{c['id']}-{k}"), "title": f"Hinweis {k + 1}", "content": f"<p>{html.escape(text)}</p>",
                                      "posted": iso(posted, "09:00"), "deadline": {"date": day.isoformat(), "kind": kind}})
        if self.flags["long_text"]:
            c = next((c for c in self.courses if c["active"]), None)
            if c:
                c["news"].append({"id": h32(f"news-{c['id']}-long"), "title": "Sehr lange Mitteilung", "content": "<p>" + ("Lorem ipsum dolor sit amet. " * 400) + "</p>",
                                  "posted": iso(TODAY, "08:00"), "deadline": None})
                c["description"] = "<p>" + ("Sehr lange Beschreibung. " * 500) + "</p>"
        if self.flags["html_in_text"]:
            c = next((c for c in self.courses if c["active"]), None)
            if c:
                c["news"].append({"id": h32(f"news-{c['id']}-html"), "title": "<b>Fett</b> &amp; <script>alert(1)</script>",
                                  "content": "<table><tr><td>Zelle</td></tr></table><script>alert('x')</script><p>Abgabe bis zum 20.11.2026 &nbsp;&lt;spätestens&gt;</p>",
                                  "posted": iso(TODAY, "08:30"), "deadline": {"date": "2026-11-20", "kind": "frist"}})
                c["news"].append({"id": h32(f"news-{c['id']}-leer"), "title": "", "content": "", "posted": iso(TODAY, "08:40"), "deadline": None})
        # Kalender: eigene Gruppen; ein Kurs ganz ohne Kalenderbindung
        for c in self.courses:
            ue = [s for s in c["slots"]]
            if c["kind"] in ("uebung", "gruppenuebung", "tutorium") and len(ue) > 1:
                own = rng.choice(ue)
                for s in ue:
                    s["in_calendar"] = s is own
        if self.flags["course_not_in_calendar"]:
            c = next((c for c in self.courses if c["active"] and c["slots"] and c["kind"] == "vorlesung"), None)
            if c:
                for s in c["slots"]:
                    s["in_calendar"] = False
                c["not_in_calendar"] = True

    # ---------------------------------------------------------------- Stud.IP-Routen (LUH)

    def build_studip(self) -> None:
        rng = self.rng
        R = self.routes
        R[API + "users/me"] = body({"data": {"id": self.uid, "type": "users", "attributes": {"username": self.username, "formatted-name": "Synth Student"}}})
        sem_ids = {s[0]: "s-" + h32(s[0])[:8] for s in SEMESTERS}
        included = [{"id": sem_ids[s[0]], "type": "semesters", "attributes": {"title": s[0], "start": iso(date.fromisoformat(s[1]), "00:00"),
                     "end": iso(date.fromisoformat(s[2]), "23:59"), "start-of-lectures": iso(date.fromisoformat(s[3]), "00:00"),
                     "end-of-lectures": iso(date.fromisoformat(s[4]), "23:59")}} for s in SEMESTERS]
        data = []
        for c in self.courses:
            attrs = {"title": c["title"], "course-number": c["number"], "course-type": c["course_type"]}
            if c["description"] is not None:
                attrs["description"] = c["description"]
            item = {"id": c["id"], "type": "courses", "attributes": attrs}
            if not c.get("no_semester"):
                rel = {"start-semester": {"data": {"type": "semesters", "id": sem_ids[c["semester"]]}}}
                if c["semester_end"] == "unbegrenzt":
                    rel["end-semester"] = {"data": None}
                elif c["semester_end"]:
                    rel["end-semester"] = {"data": {"type": "semesters", "id": sem_ids[c["semester_end"]]}}
                item["relationships"] = rel
            data.append(item)
        if self.flags["dup_course"] and data:
            data.append(dict(data[0]))                        # derselbe Kurs noch einmal (Seitenueberlappung)
        path = f"{API}users/{self.uid}/courses"
        pages = paged(data, path, 100, "&include=start-semester,end-semester")
        for k, v in pages.items():
            inc = [i for i in included if any((it.get("relationships") or {}).get("start-semester", {}).get("data", {}) and
                                              it["relationships"]["start-semester"]["data"]["id"] == i["id"] or
                                              ((it.get("relationships") or {}).get("end-semester") or {}).get("data") and
                                              it["relationships"]["end-semester"]["data"]["id"] == i["id"] for it in v["data"])]
            R[k] = body({**v, "included": inc})
        # Stundenplan: Kurszeiten + eigene Eintraege
        sched = []
        for c in self.courses:
            sem = c["sem"] or SEMESTERS[0]
            for s in c["slots"]:
                first = date.fromisoformat(sem[3]) + timedelta(days=(s["weekday"] - date.fromisoformat(sem[3]).weekday()) % 7)
                sched.append({"id": s["id"], "type": "seminar-cycle-dates", "attributes": {
                    "title": "Kurszeit", "description": "", "start": s["start"], "end": s["end"], "weekday": s["weekday"] + 1, "color": None,
                    "recurrence": {"FREQ": "WEEKLY", "INTERVAL": 1, "DTSTART": iso(first, s["start"]), "UNTIL": iso(date.fromisoformat(sem[4]), s["end"])},
                    "locations": [s["room"]]}, "relationships": {"owner": {"data": {"type": "courses", "id": c["id"]}}}})
        self.personal = []
        for k in range(rng.randint(0, 2)):
            e = {"id": h32(f"personal-{self.uid}-{k}"), "type": "schedule-entries", "attributes": {
                "title": ["Hochschulsport", "Nebenjob", "Lerngruppe (alle 2 Wochen)"][k], "weekday": 1 + (rng.randint(0, 4) + k) % 5,
                "start": "18:00", "end": "19:30", "description": ""}}
            sched.append(e)
            self.personal.append(e)
        R[f"{API}users/{self.uid}/schedule"] = body(jsonapi(sched))
        # Kalender (ICS)
        lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Stud.IP//synth//DE"]
        for c in self.courses:
            if not c["active"]:
                continue
            for e in c["events"]:
                slot = next((s for s in c["slots"] if s["id"] == e["slot"]), None)
                if (slot and slot["in_calendar"]) or (slot is None and not c.get("not_in_calendar")):
                    d = date.fromisoformat(e["date"])
                    lines += ["BEGIN:VEVENT", f"UID:Stud.IP-SEM-{e['id']}@{STUDIP_HOST}", f"DTSTART;TZID=Europe/Berlin:{d.strftime('%Y%m%d')}T{e['start'].replace(':', '')}00",
                              f"DTEND;TZID=Europe/Berlin:{d.strftime('%Y%m%d')}T{e['end'].replace(':', '')}00", f"SUMMARY:{c['title']}", "END:VEVENT"]
        lines.append("END:VCALENDAR")
        if self.flags["calendar_missing"]:
            R[f"{API}users/{self.uid}/events.ics"] = text_body("<html>not found</html>", 404)
        else:
            R[f"{API}users/{self.uid}/events.ics"] = text_body("\r\n".join(lines), 200, "text/calendar; charset=utf-8")
        # je Kurs: Ordner, Dateien, Termine, Ankuendigungen, Flat-Ansicht (Python), Courseware/Wiki/Forum
        for c in self.courses:
            self._studip_course(c)
        self._studip_extras()
        self._bulletin()
        self._qis_luh()
        # Sitzung laeuft mitten im Abgleich ab: nach so vielen Stud.IP-Anfragen nur noch 401
        self.expire_after = (40 + rng.randint(0, 40)) if self.flags["session_expiry"] else None

    def _studip_course(self, c: dict) -> None:
        rng = self.rng
        R = self.routes
        cid = c["id"]
        folders = c.get("folders") or []
        tops = [{"id": fo["id"], "type": "folders", "attributes": {"folder-type": "RootFolder" if fo["root"] else "StandardFolder", "name": fo["name"]}}
                for fo in folders if fo["depth"] == 0]
        key = f"{API}courses/{cid}/folders?page[limit]=200"
        R[key] = body(jsonapi(tops))
        if self.flags["rate_limit"] and c["active"] and c is next((x for x in self.courses if x["active"]), None):
            R[key]["flaky"] = [429]
            c["transient"] = "429 folders"
        for fo in folders:
            refs = []
            for fid in fo["files"]:
                f = self.files[fid]
                a = {"name": f["name"], "filesize": f["size"], "mime-type": f["mime"], "chdate": f["chdate"], "is-downloadable": f["downloadable"]}
                if f["mime"] is None:
                    a.pop("mime-type")
                if f["link"]:
                    a["url"] = f["link"]
                refs.append({"id": fid, "type": "file-refs", "attributes": a})
            if fo["forbidden"]:
                R[f"{API}folders/{fo['id']}/file-refs?page[limit]=500"] = body({"errors": [{"status": str(fo["status"])}]}, fo["status"])
                R[f"{API}folders/{fo['id']}/folders?page[limit]=200"] = body({"errors": [{"status": str(fo["status"])}]}, fo["status"])
                continue
            for k, v in paged(refs, f"{API}folders/{fo['id']}/file-refs", 500).items():
                R[k] = body(v)
            subs = [{"id": s["id"], "type": "folders", "attributes": {"folder-type": "StandardFolder", "name": s["name"]}} for s in fo["subs"]]
            R[f"{API}folders/{fo['id']}/folders?page[limit]=200"] = body(jsonapi(subs))
            if self.flags["server_error"] and c["active"] and fo["depth"] == 1 and not c.get("transient") and not c.get("srv"):
                R[f"{API}folders/{fo['id']}/file-refs?page[limit]=500"]["flaky"] = [503]
                c["srv"] = fo["id"]
                c["transient"] = "503 file-refs"
            if self.flags["non_utf8"] and c["active"] and fo["depth"] == 1 and not c.get("bad_folder") and not c.get("transient"):
                raw = json.dumps(jsonapi(refs), ensure_ascii=False).encode("utf-8").replace("Ü".encode("utf-8"), b"\xdc")
                R[f"{API}folders/{fo['id']}/file-refs?page[limit]=500"] = {"status": 200, "type": "application/vnd.api+json", "b64": base64.b64encode(raw).decode()}
                c["bad_folder"] = fo["id"]
        # Flat-Ansicht (nur Python): alle lesbaren Dateien
        flat = []
        for fid in c["files"]:
            f = self.files[fid]
            if f["forbidden"]:
                continue
            flat.append({"id": fid, "name": f["name"], "size": f["size"], "mime_type": f["mime"], "author_name": "Synth Dozent", "chdate": f["chdate_unix"],
                         "download_url": f"/jsonapi.php/v1/file-refs/{fid}/content" if f["downloadable"] else ""})
        R[f"/dispatch.php/course/files/flat?cid={cid}"] = text_body(f'<html><body><div id="files" data-files="{html.escape(json.dumps(flat, ensure_ascii=False), quote=True)}"></div></body></html>')
        # Dateiinhalte
        for fid in c["files"]:
            f = self.files[fid]
            entry = {"serve": f["serve"], "kind": f["ext"], "html": False}
            if self.flags["empty_download"] and c["active"] and f["downloadable"] and not f["forbidden"] and not any(x.get("empty") for x in self.files.values()):
                entry["serve"] = 0; f["empty"] = True
            if self.flags["webpage_instead_of_file"] and c["active"] and f["downloadable"] and not f["forbidden"] and f["ext"] == "pdf" and not any(x.get("webpage") for x in self.files.values()):
                entry["html"] = True; f["webpage"] = True
            entry.update({"serve": entry["serve"], "status": 200})
            f["entry"] = entry
        # Termine
        evs = []
        for e in c["events"]:
            d = date.fromisoformat(e["date"])
            evs.append({"id": e["id"], "type": "course-dates", "attributes": {"title": e["title"], "start": iso(d, e["start"]), "end": iso(d, e["end"]),
                        "location": e["room"], "description": e["description"], "is-cancelled": e["cancelled"]}})
        for k, v in paged(evs, f"{API}courses/{cid}/events", 200).items():
            R[k] = body(v)
        news = [{"id": n["id"], "type": "news", "attributes": {"title": n["title"], "content": n["content"], "publication-start": n["posted"], "mkdate": n["posted"]}} for n in c["news"]]
        for k, v in paged(news, f"{API}courses/{cid}/news", 100).items():
            R[k] = body(v)
        self._studip_texts(c)

    def _studip_texts(self, c: dict) -> None:
        rng = self.rng
        R = self.routes
        cid = c["id"]
        c["cw_deadlines"] = []
        tasks, inc = [], []
        for k in range(rng.randint(0, 2) if c["active"] else 0):
            due = TODAY + timedelta(days=rng.randint(2, 40))
            tid, gid, eid = h32(f"task-{cid}-{k}"), h32(f"group-{cid}-{k}"), h32(f"elem-{cid}-{k}")
            tasks.append({"id": tid, "type": "courseware-tasks", "attributes": {"submitted": False, "submission-date": iso(due, "23:59"), "renewal": "none"},
                          "relationships": {"task-group": {"data": {"type": "courseware-task-groups", "id": gid}},
                                            "structural-element": {"data": {"type": "courseware-structural-elements", "id": eid}}}})
            inc.append({"id": gid, "type": "courseware-task-groups", "attributes": {"title": f"Aufgabe {k + 1}: Rekursion", "end-date": iso(due, "23:59")}})
            c["cw_deadlines"].append({"id": f"sp-cw-{tid}", "due": f"{due.isoformat()}T23:59"})
        R[f"{API}courseware-tasks?filter[cid]={cid}&include=task-group,structural-element&page[limit]=100"] = body(jsonapi(tasks, inc))
        units, elements = [], []
        for k in range(rng.randint(0, 2) if c["active"] else 0):
            eid = h32(f"unit-elem-{cid}-{k}")
            units.append({"id": h32(f"unit-{cid}-{k}"), "type": "courseware-units", "relationships": {"structural-element": {"data": {"type": "courseware-structural-elements", "id": eid}}}})
            elements.append({"id": eid, "type": "courseware-structural-elements", "attributes": {"title": f"Kapitel {k + 1}", "chdate": iso(TODAY - timedelta(days=5), "10:00")}})
            ct = h32(f"container-{eid}")
            blocks = [{"id": h32(f"block-{eid}-1"), "type": "courseware-blocks", "attributes": {"block-type": "headline", "payload": {"title": f"Kapitel {k + 1}", "subtitle": "Grundlagen"}},
                       "relationships": {"container": {"data": {"type": "courseware-containers", "id": ct}}}},
                      {"id": h32(f"block-{eid}-2"), "type": "courseware-blocks", "attributes": {"block-type": "text", "payload": {"text": "<p>" + ("Lerntext. " * rng.randint(5, 60)) + "</p>"}},
                       "relationships": {"container": {"data": {"type": "courseware-containers", "id": ct}}}}]
            R[f"{API}courseware-structural-elements/{eid}/containers?include=blocks&page[limit]=100"] = body(jsonapi([{"id": ct, "type": "courseware-containers"}], blocks))
            R[f"{API}courseware-structural-elements/{eid}/children?page[limit]=100"] = body(jsonapi([]))
        R[f"{API}courses/{cid}/courseware-units?include=structural-element&page[limit]=50"] = body(jsonapi(units, elements))
        wiki = [{"id": h32(f"wiki-{cid}-{k}"), "type": "wiki-pages", "attributes": {"keyword": rng.choice(["Glossar", "FAQ", "Formelsammlung"]),
                 "content-html": "<p>" + ("Wikitext. " * rng.randint(3, 40)) + "</p>", "chdate": iso(TODAY - timedelta(days=9), "11:00")}}
                for k in range(rng.randint(0, 3) if c["active"] else 0)]
        R[f"{API}courses/{cid}/wiki-pages?page[limit]=100"] = body(jsonapi(wiki))
        c["no_forum"] = rng.random() < 0.3
        if c["no_forum"]:
            R[f"{API}courses/{cid}/forum-categories?page[limit]=50"] = body({"errors": [{"status": "404"}]}, 404)
        else:
            cats = [{"id": h32(f"fcat-{cid}-{k}"), "type": "forum-categories", "attributes": {"title": "Allgemein"}} for k in range(rng.randint(1, 2))]
            R[f"{API}courses/{cid}/forum-categories?page[limit]=50"] = body(jsonapi(cats))
            for cat in cats:
                entries = [{"id": h32(f"fe-{cat['id']}-{k}"), "type": "forum-entries", "attributes": {"title": f"Frage zu Blatt {k + 1}", "content": "Wie löst man Aufgabe 2? @Dozent", "chdate": iso(TODAY - timedelta(days=2), "12:00")}}
                           for k in range(rng.randint(0, 3))]
                R[f"{API}forum-categories/{cat['id']}/entries?page[limit]=50"] = body(jsonapi(entries))
                for e in entries:
                    posts = [{"id": h32(f"fp-{e['id']}-{k}"), "type": "forum-entries", "attributes": {"title": "Re: Frage", "content": "[quote=Tutor]Hallo[/quote] Siehe Skript Seite 12."}} for k in range(rng.randint(0, 2))]
                    R[f"{API}forum-entries/{e['id']}/entries?page[limit]=100"] = body(jsonapi(posts))

    def _studip_extras(self) -> None:
        rng = self.rng
        R = self.routes
        if self.flags["extras_missing"]:
            for p in ("semesters?page[limit]=100", "holidays?page[limit]=100", "studip/news?page[limit]=50", f"users/{self.uid}/inbox?page[limit]=30&include=sender",
                      f"users/{self.uid}/inbox?page[limit]=30", f"users/{self.uid}/activitystream", f"users/{self.uid}/consultation-bookings?include=slot,slot.block",
                      f"users/{self.uid}/consultation-bookings"):
                R[API + p] = body({"errors": [{"status": "404"}]}, 404)
            self.expected_extras = {"semesters": 0, "messages": 0}
            return
        sems = [{"id": "s-" + h32(s[0])[:8], "type": "semesters", "attributes": {"title": s[0], "start": iso(date.fromisoformat(s[1]), "00:00"), "end": iso(date.fromisoformat(s[2]), "23:59"),
                 "start-of-lectures": iso(date.fromisoformat(s[3]), "00:00"), "end-of-lectures": iso(date.fromisoformat(s[4]), "23:59")}} for s in SEMESTERS]
        R[API + "semesters?page[limit]=100"] = body(jsonapi(sems))
        R[API + "holidays?page[limit]=100"] = body(jsonapi([{"id": "h1", "type": "holidays", "attributes": {"title": "Weihnachtspause", "start": "2026-12-21T00:00:00+01:00", "end": "2027-01-03T23:59:00+01:00"}}]))
        R[API + "studip/news?page[limit]=50"] = body(jsonapi([{"id": "gn1", "type": "news", "attributes": {"title": "Wartung am 15.11.2026", "content": "<p>Stud.IP ist am 15.11.2026 von 6 bis 8 Uhr nicht erreichbar.</p>",
                                                                "publication-start": iso(TODAY, "07:00")}}]))
        msgs = [{"id": h32(f"msg-{self.uid}-{k}"), "type": "messages", "attributes": {"subject": f"Nachricht {k + 1}", "message": "<p>Bitte Abgabe bis zum 30.11.2026 beachten.</p>", "mkdate": iso(TODAY - timedelta(days=k), "10:00")},
                 "relationships": {"sender": {"data": {"type": "users", "id": "lehr1"}}}} for k in range(3)]
        R[API + f"users/{self.uid}/inbox?page[limit]=30&include=sender"] = body(jsonapi(msgs, [{"id": "lehr1", "type": "users", "attributes": {"permission": "dozent"}}]))
        act = [{"id": f"act{k}", "type": "activities", "attributes": {"activity-type": "documents", "mkdate": iso(TODAY - timedelta(days=1), "09:00")},
                "relationships": {"context": {"data": {"type": "courses", "id": c["id"]}}}} for k, c in enumerate(self.courses[:3])]
        R[API + f"users/{self.uid}/activitystream"] = body(jsonapi(act))
        R[API + f"users/{self.uid}/consultation-bookings?include=slot,slot.block"] = body(jsonapi(
            [{"id": "bk1", "type": "consultation-bookings", "relationships": {"slot": {"data": {"type": "consultation-slots", "id": "sl1"}}}}],
            [{"id": "sl1", "type": "consultation-slots", "attributes": {"start-time": iso(TODAY + timedelta(days=4), "14:00"), "end-time": iso(TODAY + timedelta(days=4), "14:30")},
              "relationships": {"block": {"data": {"type": "consultation-blocks", "id": "bl1"}}}},
             {"id": "bl1", "type": "consultation-blocks", "attributes": {"room": "Büro 1234"}}]))
        self.expected_extras = {"semesters": len(sems), "messages": 3}

    def _bulletin(self) -> None:
        R = self.routes
        topics = [(h32("topic-wohnen"), "Wohnungen", 12), (h32("topic-markt"), "Marktplatz", 5)]
        items = "".join(f'<li><a href="/plugins.php/schwarzesbrettplugin/category/view/{tid}" class="category">{t} ({n})</a></li>' for tid, t, n in topics)
        R["/plugins.php/schwarzesbrettplugin/category/list"] = text_body(f'<html><body><ul class="sb-categories">{items}</ul></body></html>')
        for tid, t, n in topics:
            its = "".join(f"<item><title>{t} Anzeige {k + 1}</title><link>https://{STUDIP_HOST}/plugins.php/schwarzesbrettplugin/show/{h32(f'{tid}-{k}')}</link>"
                          f"<description><![CDATA[<p>Text der Anzeige {k + 1} &amp; mehr.</p>]]></description><pubDate>Mon, 02 Nov 2026 10:15:00 +0100</pubDate>"
                          f"<guid>{h32(f'{tid}-{k}')}</guid></item>" for k in range(min(n, 20)))
            R[f"/plugins.php/schwarzesbrettplugin/rss/{tid}/20"] = text_body(f'<?xml version="1.0"?><rss version="2.0"><channel><title>{t}</title>{its}</channel></rss>', 200, "application/rss+xml")
        self.expected_bulletin = sum(min(n, 20) for _, _, n in topics)

    def _qis_luh(self) -> None:
        rng = self.rng
        R = self.routes
        asi = "SynthSitzung01"
        q = QIS_BASE + "/qisserver/rds?"
        logout = f'<a href="{q}state=user&amp;type=4&amp;category=auth.logout&amp;asi={asi}">Abmelden</a>'
        start = QIS_BASE + "/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf"
        R[start] = text_body(f'<html><body><h1>Meine Funktionen</h1>{logout}<ul><li><a href="{q}state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;nextdir=change&amp;next=menu.vm&amp;asi={asi}">Mein Studium</a></li></ul></body></html>')
        R[f"{q}state=change&type=1&moduleParameter=studyPOSMenu&nextdir=change&next=menu.vm&asi={asi}"] = text_body(
            f'<html><body><h1>Mein Studium</h1>{logout}<a href="{q}state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;menuid=notenspiegelStudent&amp;asi={asi}">Notenspiegel / Studienverlauf</a></body></html>')
        R[f"{q}state=notenspiegelStudent&next=tree.vm&nextdir=qispos/notenspiegel/student&menuid=notenspiegelStudent&asi={asi}"] = text_body(
            f'<html><body><h1>Notenspiegel</h1>{logout}<table summary="Stammdaten"><tr><th>Name</th><td>Synth Student</td></tr><tr><th>Matrikelnummer</th><td>{1000000 + self.index}</td></tr></table>'
            f'<ul><li><a href="{q}state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;nodeID=auswahlBaum|abschluss:abschl=82&amp;expand=0&amp;asi={asi}">Abschluss 82 Bachelor of Science</a></li></ul></body></html>')
        R[f"{q}state=notenspiegelStudent&next=tree.vm&nextdir=qispos/notenspiegel/student&nodeID=auswahlBaum|abschluss:abschl=82&expand=0&asi={asi}"] = text_body(
            f'<html><body><h1>Notenspiegel</h1>{logout}<ul><li>{html.escape(self.program)} (PO-Version 2017) <a href="{q}state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=079&amp;asi={asi}" title="Leistungen für {html.escape(self.program)} anzeigen">Leistungen für {html.escape(self.program)} anzeigen</a></li></ul></body></html>')
        rows, self.expected_grades = [], []
        old = [c for c in self.courses if c["subject"] and c["kind"] == "vorlesung" and not c["active"]]
        for k, c in enumerate(old[:12]):
            note = rng.choice(["1,0", "1,3", "1,7", "2,0", "2,3", "2,7", "3,0", "3,3", "3,7", "4,0", "5,0"])
            status = "bestanden" if note != "5,0" else "nicht bestanden"
            nr = str(1001 + k)
            rows.append(f"<tr><td>{nr}</td><td>{html.escape(c['subject'])}</td><td>{c['semester'].replace('20', '', 1) if c['semester'] else ''}</td><td>{note}</td><td>{status}</td><td>{rng.choice([5, 6, 8])}</td><td>1</td><td>12.02.2026</td></tr>")
            self.expected_grades.append({"pruefungsnr": nr, "text": c["subject"], "note": note})
        if rng.random() < 0.3:
            rows.append("<tr><td>9000</td><td>Modul Grundlagen</td><td></td><td></td><td>Prüfung vorhanden</td><td></td><td></td><td></td></tr>")   # Modulzeile, keine Leistung
        R[f"{q}state=notenspiegelStudent&next=list.vm&nextdir=qispos/notenspiegel/student&nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=079&asi={asi}"] = text_body(
            f'<html><body><h1>Notenspiegel</h1>{logout}<table summary="Stammdaten"><tr><th>Name</th><td>Synth Student</td></tr></table>'
            f'<table><tr><th>Prüfungsnr</th><th>Prüfungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th><th>Versuch</th><th>Datum</th></tr>{"".join(rows)}</table></body></html>')
        self.qis_start = start

    # ---------------------------------------------------------------- Learnweb + LSF (Hildesheim)

    def build_hildesheim(self) -> None:
        rng = self.rng
        R = self.routes
        R["REST|core_webservice_get_site_info|"] = body({"userid": 42, "sitename": "Learnweb (synthetisch)"}, 200, "application/json")
        courses = []
        self.lw_files: dict[str, list[dict]] = {}
        for c in self.courses:
            if c["kind"] == "sonstiges":
                continue
            sem = c["semester"] or "WiSe 2026/27"
            full = f"{sem}: {c['number'] + ' ' if c['number'] else ''}{c['title']}".strip()
            if self.flags["hidden_course"] and c is self.courses[0]:
                c["hidden"] = True
            courses.append({"id": c["moodle_id"], "fullname": full, "displayname": full, "hidden": 1 if c.get("hidden") else 0})
            # Inhalte: Abschnitte mit resource/folder
            sections, files = [], []
            n_sec = rng.randint(2, 8)
            for s in range(n_sec):
                name = "Allgemeines" if s == 0 else str(s)
                mods = []
                n_mod = rng.randint(1, 4)
                for m in range(n_mod):
                    cmid = c["moodle_id"] * 100 + s * 10 + m
                    kind = "folder" if rng.random() < 0.3 else "resource"
                    contents = []
                    n_f = rng.randint(1, 5) if kind == "folder" else 1
                    for k in range(n_f):
                        ext = pick(rng, FILE_EXT)
                        fname = rng.choice(["Folien", "Text", "Sitzung", "Reader", "Aufgabe"]) + f"_{s}_{m}_{k}.{ext}"
                        if k == 0 and rng.random() < 0.05:
                            fname = "Einführung.pdf"            # zerlegter Umlaut (NFD); je Modul hoechstens einmal (Moodle kennt keine Doppelnamen)
                        fp = "/" if kind == "resource" or rng.random() < 0.5 else f"/Kapitel {k}/"
                        rev = rng.randint(1, 4)
                        url = f"{LEARNWEB_BASE}/webservice/pluginfile.php/{cmid}/mod_{kind}/content/{rev}{quote(fp)}{quote(fname)}?forcedownload=1"
                        size = rng.randint(2000, 5_000_000)
                        contents.append({"type": "file", "filename": fname, "filepath": fp, "filesize": size, "timemodified": unix(TODAY - timedelta(days=rng.randint(1, 60)), "10:00"),
                                         "fileurl": url, "mimetype": MIME.get(ext)})
                        fid = "lw-%d-%s" % (cmid, hashlib.sha256(f"{unicodedata.normalize('NFC', fp) or '/'}{unicodedata.normalize('NFC', fname)}".encode()).hexdigest()[:8])
                        files.append({"id": fid, "name": unicodedata.normalize("NFC", fname), "url": url.split("?")[0], "size": size, "serve": min(size, 1024), "ext": ext})
                        self.files[fid] = {"id": fid, "course": c["id"], "name": fname, "ext": ext, "size": size, "serve": min(size, 1024), "downloadable": True,
                                           "forbidden": False, "depth": 0, "entry": {"serve": min(size, 1024), "kind": ext, "html": False, "status": 200}, "url": url.split("?")[0]}
                    if rng.random() < 0.1:
                        contents.append({"type": "url", "filename": "Link", "fileurl": "https://example.invalid/"})
                    mods.append({"id": cmid, "name": f"Material {s}.{m}", "modname": kind, "contents": contents})
                if rng.random() < 0.2:
                    mods.append({"id": c["moodle_id"] * 100 + s * 10 + 9, "name": "Forum", "modname": "forum"})
                sections.append({"id": c["moodle_id"] * 10 + s, "section": s, "name": name, "modules": mods})
            if rng.random() < 0.08:
                R[f"REST|core_course_get_contents|courseid={c['moodle_id']}"] = body({"exception": "moodle_exception", "errorcode": "nopermissions", "message": "Kein Zugriff"}, 200, "application/json")
                c["lw_error"] = True
                files = []
            else:
                R[f"REST|core_course_get_contents|courseid={c['moodle_id']}"] = body(sections, 200, "application/json")
            self.lw_files[c["id"]] = files
        R["REST|core_enrol_get_users_courses|"] = body(courses, 200, "application/json")
        # Fristen
        self.lw_deadlines = []
        events = []
        for k, c in enumerate([c for c in self.courses if c["active"] and c["kind"] != "sonstiges"][:6]):
            due = TODAY + timedelta(days=rng.randint(1, 30))
            eid = 5000 + k
            events.append({"id": eid, "name": f"Abgabe Essay {k + 1} (schließt am {due.strftime('%d.%m.')} um 23:59 Uhr)", "activityname": f"Abgabe Essay {k + 1}",
                           "timestart": unix(due, "23:59"), "modulename": "assign", "eventtype": "due", "course": {"id": c["moodle_id"]},
                           "url": f"{LEARNWEB_BASE}/mod/assign/view.php?id={k}", "overdue": False})
            self.lw_deadlines.append({"id": f"lw-ev-{eid}", "course_id": c["id"], "kind": "abgabe"})
        R["REST|core_calendar_get_action_events_by_timesort|"] = body({"events": events}, 200, "application/json")
        R["REST|core_calendar_get_calendar_upcoming_view|"] = body({"events": []}, 200, "application/json")
        # Ankuendigungen (Foren vom Typ news)
        forums, self.lw_announcements = [], []
        for k, c in enumerate([c for c in self.courses if c["active"] and c["kind"] != "sonstiges" and not c.get("hidden")][:5]):
            fid = 700 + k
            forums.append({"id": fid, "course": c["moodle_id"], "type": "news"})
            discs = []
            for j in range(rng.randint(0, 3)):
                did = fid * 10 + j
                day = TODAY + timedelta(days=rng.randint(3, 40))
                discs.append({"id": did, "discussion": did, "subject": f"Ankündigung {j + 1}", "message": f"<p>Die Sitzung am {day.strftime('%d.%m.%Y')} fällt aus.</p>",
                              "userfullname": "Dozent", "created": unix(TODAY - timedelta(days=j), "09:00")})
                self.lw_announcements.append({"id": f"lw-post-{did}", "course_id": c["id"], "date": day.isoformat(), "kind": "ausfall"})
            R[f"REST|mod_forum_get_forum_discussions|forumid={fid}"] = body({"discussions": discs}, 200, "application/json")
        R["REST|mod_forum_get_forums_by_courses|"] = body(forums, 200, "application/json")
        # LSF: Startseite, Stundenplan, iCal, Notenspiegel
        logout = '<a href="rds?state=user&amp;type=4">Abmelden</a>'
        R[f"{LSF_BASE}/qisserver/rds?state=user&type=0"] = text_body(f'<html><body><h1>Meine Funktionen</h1>{logout}<a href="rds?state=notenspiegelStudent&amp;nodeID=a">Studien-/Prüfungsleistungen (Notenspiegel)</a></body></html>')
        R[f"{LSF_BASE}/qisserver/rds?state=user&type=1"] = R[f"{LSF_BASE}/qisserver/rds?state=user&type=0"]
        ics_url = f"{LSF_BASE}/qisserver/rds?state=verpublish&status=transform&moduleCall=iCalendarPlan&termine=1,2"
        R[f"{LSF_BASE}/qisserver/rds?state=wplan&act=show&show=plan&P.subc=plan&week=-2"] = text_body(f'<html><body>{logout}<a href="{html.escape(ics_url)}">iCal</a></body></html>')
        lines = ["BEGIN:VCALENDAR", "PRODID:QIS-LSF HIS eG", "VERSION:2.0", "METHOD:PUBLISH"]
        self.lsf_series = 0
        self.lsf_cancelled = 0
        byday = ["MO", "TU", "WE", "TH", "FR"]
        for k, c in enumerate([c for c in self.courses if c["active"] and c["slots"]]):
            for s in c["slots"]:
                st = date(2026, 10, 26)
                lines += ["BEGIN:VEVENT", f"DTSTART;TZID=Europe/Berlin:{st.strftime('%Y%m%d')}T{s['start'].replace(':', '')}00", f"DTEND;TZID=Europe/Berlin:{st.strftime('%Y%m%d')}T{s['end'].replace(':', '')}00",
                          f"RRULE:FREQ=WEEKLY;UNTIL=20270205T235900Z;INTERVAL=1;BYDAY={byday[s['weekday']]}", "EXDATE;TZID=Europe/Berlin:20261222T100000,20261229T100000,",
                          f"LOCATION:{s['room']}", f"UID:{k + 1}:{s['id'][:4]}", f"SUMMARY:{c['number'] + ' - ' if c['number'] else ''}{c['title']} (Muster)", "CATEGORIES:Seminar"]
                if k == 0:
                    lines.append("DESCRIPTION:Diese Veranstaltung wird nur aus technischen Gründen angezeigt.")
                lines.append("END:VEVENT")
                self.lsf_series += 1
                if s["weekday"] == 1:
                    self.lsf_cancelled += 2                   # die beiden EXDATE-Dienstage im Dezember
        lines.append("END:VCALENDAR")
        R[ics_url] = text_body("\r\n".join(lines), 200, "text/calendar")
        rows, self.expected_grades = [], []
        for k, c in enumerate([c for c in self.courses if c["subject"] and not c["active"]][:10]):
            note = rng.choice(["1,0", "1,7", "2,3", "3,0", "4,0", "5,0"])
            nr = str(5011 + k)
            rows.append(f"<tr><td>{nr}</td><td>{html.escape(c['subject'])}</td><td>{note}</td><td>{'bestanden' if note != '5,0' else 'nicht bestanden'}</td><td>6</td></tr>")
            self.expected_grades.append({"pruefungsnr": nr, "text": c["subject"], "note": note})
        R[f"{LSF_BASE}/qisserver/rds?state=notenspiegelStudent&nodeID=a"] = text_body(
            f'<html><body>{logout}<table summary="Angaben zur Person"><tr><td>Name</td><td>Synth Student</td></tr></table>'
            f'<table><tr><td colspan="5">Abschluss: [82] Bachelor Studiengang: [052] B.A. {html.escape(self.program)} PO-Version: 2022</td></tr>'
            f'<tr><th>Prüfungsnr.</th><th>Bezeichnung der Leistung / der Lehrveranstaltung</th><th>Note</th><th>Status</th><th>Bonus</th></tr>'
            f'<tr><td>5010</td><td>Modul 1: Grundlagen</td><td></td><td></td><td>12</td></tr>{"".join(rows)}</table></body></html>')

    # ---------------------------------------------------------------- Erwartung

    def build_expected(self) -> None:
        active_ids = {c["id"] for c in self.courses if c["active"]}
        files_rows, deep, forbidden, transient, inactive = [], [], [], [], []
        by_id = {c["id"]: c for c in self.courses}
        # Kennung in der Datenbank: Stud.IP-Kurs-ID (LUH) bzw. "lw-<Moodle-ID>" (Learnweb, app/learnweb.py `_course`)
        db_id = {c["id"]: (c["id"] if self.university == "luh" else f"lw-{c['moodle_id']}") for c in self.courses}
        for f in self.files.values():
            c = by_id[f["course"]]
            if f["forbidden"]:
                forbidden.append(f["id"]); continue
            if not c["active"] or c.get("hidden") or c.get("lw_error"):
                inactive.append(f["id"]); continue
            if c.get("transient"):
                transient.append(f["id"])
            if f["depth"] > 12:                                       # StudIPClient.maxFolderDepth / MAX_FOLDER_DEPTH
                deep.append(f["id"])
            files_rows.append(f["id"])
        subjects = {}
        for c in self.courses:
            if c["active"] and c["kind"] != "sonstiges" and c["subject"] and c["title"] and not c.get("hidden"):
                subjects.setdefault(c["subject"], []).append(c["id"])
        planted = [{"course_id": c["id"], "date": n["deadline"]["date"], "kind": n["deadline"]["kind"], "news": f"sp-news-{n['id']}"}
                   for c in self.courses if c["active"] for n in c["news"] if n.get("deadline")]
        # Serien, die der Stundenplan uebernimmt: nur Kurse mit kuenftigen Terminen (aktuelles Semester; ein "unbegrenzt"
        # laufender Kurs aus einem alten Semester hat nur vergangene Termine und bleibt unentschieden). Mit Kalender die
        # eigenen Kurszeiten, ohne Kalender (Flag calendar_missing) die Gruppenregel: hoechstens zwei Serien je Kurs
        # own_series: Regel des PC (hoechstens zwei unentschiedene Serien je Kurs); own_series_device: das iPad zaehlt bei
        # Uebung, Gruppenuebung, Tutorium und Labor schon zwei Kurszeiten als Gruppen (StudIPSchedule.timetable)
        own_series, own_series_device = 0, 0
        for c in self.courses:
            if not (c["active"] and c["kind"] != "sonstiges" and c["title"]):
                continue
            past_only = bool(c["sem"]) and c["sem"][0] != SEMESTERS[0][0]      # "unbegrenzt" aus altem Semester: Kalender entscheidet nichts
            # Art auf dem iPad (StudIPSchedule.titleArt): classify-Art, bei "vorlesung" dazu UniRules.eventKind ueber den
            # ganzen Titel ("Vorlesung und Übung X" zaehlt dort als Uebung, "Labor X" als Labor)
            group_art = c["kind"] in ("uebung", "gruppenuebung", "tutorium") or \
                re.search(r"übung|uebung|ü:|exercise|tutorium|labor|praktikum|lab", c["title"], re.I) is not None
            if self.flags["calendar_missing"] or past_only:
                n = len(c["slots"])
                own_series += n if n <= 2 else 0
                own_series_device += n if (n <= 2 and not (n >= 2 and group_art)) else 0
            elif not c.get("not_in_calendar"):
                own = sum(1 for s in c["slots"] if s["in_calendar"])
                own_series += own
                own_series_device += own
        cancelled = sum(1 for c in self.courses if c["active"] for e in c["events"] if e["cancelled"])
        events_active = sum(len(c["events"]) for c in self.courses if c["active"])
        self.expected = {
            "courses": len(self.courses), "courses_active": len(active_ids), "course_ids_active": sorted(active_ids),
            "courses_expected": [{"id": c["id"], "db_id": db_id[c["id"]], "title": c["title"], "subject": c["subject"], "kind": c["kind"], "active": c["active"],
                                  "no_semester": bool(c.get("no_semester")), "transient": c.get("transient"), "moodle_id": c["moodle_id"],
                                  "hidden": bool(c.get("hidden")), "lw_error": bool(c.get("lw_error")), "bad_folder": c.get("bad_folder"),
                                  "not_in_calendar": bool(c.get("not_in_calendar")), "slots": len(c["slots"])} for c in self.courses],
            "modules": sorted(subjects), "module_count": len(subjects),
            "files_total": len(self.files), "files_expected": sorted(files_rows), "files_forbidden": sorted(forbidden), "files_inactive": sorted(inactive),
            "files_deep": sorted(deep), "files_transient": sorted(transient),
            "files_downloadable": sorted(f["id"] for f in self.files.values() if f["id"] in set(files_rows) and f["downloadable"] and f["entry"]["serve"] > 0 and not f["entry"]["html"]),
            "files_meta": {f["id"]: {"course": db_id[f["course"]], "depth": f["depth"], "downloadable": f["downloadable"], "serve": f["entry"]["serve"], "html": f["entry"]["html"],
                                     "forbidden": f["forbidden"], "name": f["name"]} for f in self.files.values()},
            "deadlines_news": planted, "cw_deadlines": [d for c in self.courses if c["active"] for d in c.get("cw_deadlines", [])],
            "series_own": own_series, "series_own_device": own_series_device, "personal": len(getattr(self, "personal", [])), "cancelled_events": cancelled, "events_active": events_active,
            "extras": getattr(self, "expected_extras", {}), "bulletin": getattr(self, "expected_bulletin", 0),
            "grades": getattr(self, "expected_grades", []),
            "learnweb_files": {k: sorted({f["id"] for f in v}) for k, v in getattr(self, "lw_files", {}).items()},
            "learnweb_deadlines": getattr(self, "lw_deadlines", []), "learnweb_announcements": getattr(self, "lw_announcements", []),
            "lsf_series": getattr(self, "lsf_series", 0), "lsf_cancelled": getattr(self, "lsf_cancelled", 0),
            "strict": not self.flags["session_expiry"],
        }

    # ---------------------------------------------------------------- Ausgabe

    def build(self) -> dict:
        self.build_courses()
        if self.university == "luh":
            self.build_files()
        self.build_events()
        if self.university == "luh":
            self.build_studip()
        else:
            self.build_hildesheim()
        self.build_expected()
        return {"account": {"index": self.index, "uid": self.uid, "username": self.username, "university": self.university, "program": self.program,
                            "semesters": self.n_semesters, "heavy": self.heavy, "flags": {k: v for k, v in self.flags.items() if v},
                            "expire_after": getattr(self, "expire_after", None), "studip_host": STUDIP_HOST, "learnweb_base": LEARNWEB_BASE,
                            "lsf_base": LSF_BASE, "qis_start": getattr(self, "qis_start", None), "token": TOKEN, "today": TODAY.isoformat()},
                "routes": self.routes,
                "files": {fid: f["entry"] for fid, f in self.files.items() if "entry" in f} | {f["url"]: f["entry"] for f in self.files.values() if f.get("url")},
                "expected": self.expected}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--accounts", type=int, default=50)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--start", type=int, default=1)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = []
    for i in range(a.start, a.start + a.accounts):
        acc = Account(i, a.seed).build()
        p = out / f"acc-{i:05d}.json"
        p.write_text(json.dumps(acc, ensure_ascii=False), encoding="utf-8")
        e = acc["expected"]
        manifest.append({"index": i, "file": p.name, "university": acc["account"]["university"], "program": acc["account"]["program"], "courses": e["courses"],
                         "files": e["files_total"], "routes": len(acc["routes"]), "flags": sorted(acc["account"]["flags"])})
    (out / "manifest.json").write_text(json.dumps({"seed": a.seed, "today": TODAY.isoformat(), "accounts": manifest}, ensure_ascii=False, indent=1), encoding="utf-8")
    tot_files = sum(m["files"] for m in manifest)
    print(f"{len(manifest)} Konten, {sum(m['courses'] for m in manifest)} Kurse, {tot_files} Dateien, {sum(m['routes'] for m in manifest)} Routen -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
