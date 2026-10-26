"""Erzeugt packages/shared-contracts/fixtures/local-backend/search.json (S7): Suche und Skriptsuche aus app/server.py
und app/scriptsearch.py (`GET /api/search`, `POST /api/related`, `GET /api/files/{id}/pagetext`) auf erfundenen
Daten. Der Swift-Kern (LocalSearchTests) legt dieselben Daten und Dateien an, schickt dieselben Anfragen an das
lokale Backend und vergleicht jede Antwort exakt.

Seitentexte: Am PC liest pypdf die PDF, auf dem iPad PDFKit; beide liefern nicht immer denselben Text. Darum sind die
PDFs hier aus festen Zeilen gebaut (Helvetica, WinAnsi), und `page_texts` enthaelt genau das, was pypdf aus ihnen
liest (mit der Aenderungszeit der Datei, also gueltig). Skriptsuche und Suche lesen dann auf beiden Seiten denselben
Text; `/pagetext` liest am PC die PDF selbst (pypdf), lokal den gespeicherten Text, und beide stimmen ueberein.

Inhalt:
- seed: SQL-Anweisungen nach init_db (Module, Kurse, Dateien mit Analysen, Lernpakete mit Aufgaben, page_texts)
- files: Dateien auf der Platte (Pfad relativ zum Datenordner wie local_path, Inhalt Base64)
- steps: Anfragen mit Status und Antwort
- tokens, normalize, snippets: scriptsearch.tokens, scriptsearch.normalize und scriptsearch._snippet fuer
  erfundene Texte (zerlegte Umlaute, Stoppwoerter, Wortstaemme, Zeilenumbrueche, Kleinschreibung, die die Laenge
  aendert)
- tables_after: page_texts nach allen Anfragen (nichts wird neu gelesen)

Keine KI-Aufrufe. Der Server laeuft nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Aufruf im Projektordner: python tools/gen-search-fixture.py [--check]
"""
from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import sys
from pathlib import Path

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "search.json"


def text_pdf(pages: list[list[str]]) -> bytes:
    """PDF mit festen Zeilen je Seite (Helvetica, WinAnsiEncoding), die pypdf zeilenweise liest."""
    def esc(s: str) -> bytes:
        return s.encode("cp1252").replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")

    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            f"<< /Type /Pages /Kids [{' '.join(f'{4 + 2 * i} 0 R' for i in range(len(pages)))}] /Count {len(pages)} >>".encode(),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
    for i, lines in enumerate(pages):
        content = b"".join(b"BT /F1 12 Tf 72 %d Td (" % (760 - 16 * j) + esc(line) + b") Tj ET\n" for j, line in enumerate(lines))
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> "
                    f"/Contents {5 + 2 * i} 0 R >>".encode())
        objs.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"endstream")
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for n, o in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % n + o + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
    out.write(b"".join(b"%010d 00000 n \n" % off for off in offsets))
    out.write(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref))
    return out.getvalue()


# 1x1 Pixel, PNG (kein PDF: keine Seitentexte)
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360f8cfc0f01f0005fe02fea72c5c"
                    "6d0000000049454e44ae426082")

MODULES = [(1, "Lineare Algebra Test", "#4f6df5"), (2, "Analysis Beispiel", "#0ea5a0"), (3, "Ökonomie Übung", "#e0803a")]
COURSES = [  # id, Titel, Fach, Art, Modul, aktiv
    ("k-la-vl", "Lineare Algebra Test", "Lineare Algebra Test", "vorlesung", 1, 1),
    ("k-la-ue", "Übung zu Lineare Algebra Test", "Lineare Algebra Test", "uebung", 1, 1),
    ("k-la-alt", "Lineare Algebra Test (altes Semester)", "Lineare Algebra Test", "vorlesung", 1, 0),
    ("k-an-vl", "Analysis Beispiel", "Analysis Beispiel", "vorlesung", 2, 1),
    ("k-an-ue", "Übung Analysis Beispiel", "Analysis Beispiel", "uebung", 2, 1),
    ("k-frei", "Freies Seminar Beispiel", None, "sonstiges", None, 1),
]
DET = [["Determinanten", "Laplace-Entwicklung nach Zeilen und Spalten", "Rechenregeln für Determinanten: Multiplikativität"],
       ["Determinante und Invertierbarkeit", "Eine Matrix ist invertierbar genau dann wenn die Determinante nicht null ist",
        "Cramersche Regel und Determinante der Inversen"]]
SKRIPT = [
    ["Vektorräume über Körpern", "Unterräume, Erzeugnis und Linearkombination von Vektoren"],
    ["Basis und Dimension", "Austauschsatz von Steinitz und Basisergänzung im Vektorraum"],
    ["Lineare Unabh¨ angigkeit", "Vektoren heißen linear unabh¨ angig wenn nur die triviale Kombination null ergibt"],
    ["Skalarprodukt und Norm", "Orthogonalität, Projektion und Gram-Schmidt-Verfahren für Orthonormalbasen"],
    ["Spektralsatz für symmetrische Matrizen", "Reelle Eigenwerte und orthogonale Diagonalisierung"],
    ["Jordan-Normalform", "Hauptvektoren, Jordanblöcke und Minimalpolynom einer Matrix"],
    ["Quadriken und Hauptachsentransformation", "Kegelschnitte, Ellipsen, Hyperbeln und Parabeln"],
    ["Dualraum und Bilinearformen", "Duale Basis, Annulator und Sylvesterscher Trägheitssatz"],
    ["Lineare Gleichungssysteme", "Gaußsches Eliminationsverfahren, Rang und Lösungsmenge"],
    ["Eigenwerte numerisch", "Potenzmethode und QR-Verfahren zur Berechnung von Eigenwerten"],
    ["Tensorprodukt", "Multilineare Abbildungen, universelle Eigenschaft und Basen"],
    ["Zusammenfassung", "Wichtige Sätze, Definitionen und typische Klausuraufgaben im Überblick"],
]
# lange Seiten mit je zwei Begriffen der Anfragen: viele schwache Treffer, gegen die sich die passende Stelle abheben
# muss (Mindestguete: deutlich ueber dem Durchschnitt)
FILLER = "Geschichte Anwendungen Ingenieurwesen Physik Informatik Statistik Grafik Optimierung Netzwerke Codierung Robotik"
ERGAENZUNG = [[f"Ergänzung {i + 1}: {a} und {b}", FILLER, "Literatur Hinweise Beispiele Bilder Tabellen Lernziele"]
              for i, (a, b) in enumerate([("Matrix", "Regel"), ("Determinante", "Beispiel"), ("Entwicklung", "Matrix"),
                                          ("Eigenwerte", "Vektoren"), ("Polynom", "Matrix"), ("Linear", "Vektoren"),
                                          ("Determinante", "Matrix"), ("Regel", "Polynom"), ("Vektoren", "Matrix"),
                                          ("Linear", "Polynom"), ("Vektoren", "Regel"), ("Linear", "Determinante"),
                                          ("Eigenwerte", "Matrix"), ("Polynom", "Vektoren")])]
# id, Kurs, Name, Ordner, Aenderungszeit, Seiten (None = nicht geladen), Datei statt PDF
FILES = [
    ("f-la-v1", "k-la-vl", "VL01 Eigenwerte.pdf", "Vorlesung", 1760256000, [
        ["Lineare Algebra Test", "Vorlesung 1: Eigenwerte und Eigenvektoren", "Einführung in Matrizen und lineare Abbildungen"],
        ["Eigenwerte einer Matrix", "Das charakteristische Polynom liefert die Eigenwerte.",
         "Eigenvektoren lösen das homogene System.", "Diagonalmatrix mit Eigenwerten auf der Diagonale"],
        ["Fragen?"]], None),
    ("f-la-v2", "k-la-vl", "VL02 Determinanten.pdf", "Vorlesung", 1760860800, DET, None),
    ("f-la-v2d", "k-la-vl", "VL02 Determinanten Druckfassung.pdf", "Vorlesung", 1760861100, DET, None),
    ("f-la-s", "k-la-vl", "Skript Lineare Algebra.pdf", "Skript", 1760947200, SKRIPT, None),
    ("f-la-e", "k-la-vl", "Ergänzungen zur Vorlesung.pdf", "Vorlesung", 1760950000, ERGAENZUNG, None),
    ("f-la-u1", "k-la-ue", "Blatt 1.pdf", "Übungsblätter", 1761033600, [
        ["Übungsblatt 1", "Aufgabe 1: Berechnen Sie die Eigenwerte und Eigenvektoren der Matrix A.",
         "Bestimmen Sie das charakteristische Polynom und diagonalisieren Sie die Matrix."],
        ["Aufgabe 2: Berechnen Sie die Determinante mit der Laplace-Entwicklung.", "Ist die Matrix invertierbar? Cramersche Regel"],
        ["Aufgabe 3: Zeigen Sie die lineare Unabhängigkeit der Vektoren.", "Vektoren linear unabhängig triviale Kombination"]], None),
    ("f-la-png", "k-la-vl", "Tafelbild.png", "Vorlesung", 1761120000, None, PNG),
    ("f-la-v4", "k-la-vl", "VL04 Ausblick.pdf", "Vorlesung", 1761206400, None, None),
    ("f-la-alt", "k-la-alt", "VL01 Eigenwerte alt.pdf", "Vorlesung", 1729000000, [
        ["Eigenwerte einer Matrix", "Das charakteristische Polynom liefert die Eigenwerte und Eigenvektoren der Matrix."]], None),
    ("f-an-v1", "k-an-vl", "VL01 Folgen.pdf", "Vorlesung", 1760266000, [["Folgen"], ["Grenzwerte"]], None),
    ("f-an-u1", "k-an-ue", "Übung 1.pdf", "Übungen", 1760366000, [["Folgen und Grenzwerte", "Konvergenz nach Cauchy"]], None),
    ("f-frei1", "k-frei", "Seminar.pdf", None, 1760466000, [["Seminar Organisation", "Termine und Vorträge"]], None),
]
ANALYSIS = [("f-la-v1", "vorlesung", "Eigenwerte und Eigenvektoren", json.dumps(["Spektralsatz", "Diagonalisierung"])),
            ("f-la-u1", "uebung", None, None)]
PACKAGES = [  # id, Datum, Modul, Fach, Titel
    (1, "2026-10-20", 1, "Lineare Algebra Test", "Woche 1"),
    (2, "2026-10-26", 1, "Lineare Algebra Test", "Woche 2"),
    (3, "2026-10-28", 2, "Analysis Beispiel", "Woche 2"),
    (4, "2026-10-27", None, "Allgemein", "Lesen"),
]
TASKS = [  # id, Paket, Art, Datei, Titel, Status
    (1, 1, "vorlesung", "f-la-v1", "Eigenwerte wiederholen", "erledigt"),
    (2, 2, "uebung", "f-la-u1", "Blatt 1 rechnen", "geplant"),
    (3, 2, "vorlesung", "f-la-v2", "VL02 Determinanten nacharbeiten", "geplant"),
    (4, 3, "uebung", "f-an-u1", "Übung 1 Folgen", "nachholen"),
    (5, 4, "frei", None, "Lesen: Determinanten im Alltag", "geplant"),
]

LONG = "Abc " * 1500 + "Determinante Laplace Entwicklung Invertierbarkeit"
STEPS: list[dict] = [
    {"method": "GET", "path": "/api/search?q=eigenwert"},
    {"method": "GET", "path": "/api/search?q=%20EIGENWERTE%20"},
    {"method": "GET", "path": "/api/search?q=Determinante"},
    {"method": "GET", "path": "/api/search?q=spektralsatz"},
    {"method": "GET", "path": "/api/search?q=lineare"},
    {"method": "GET", "path": "/api/search?q=unabh"},
    {"method": "GET", "path": "/api/search?q=blatt"},
    {"method": "GET", "path": "/api/search?q=%25%25"},
    {"method": "GET", "path": "/api/search?q=konomie"},
    {"method": "GET", "path": "/api/search?q=%C3%96konomie"},
    {"method": "GET", "path": "/api/search?q=%C3%BCbung"},
    {"method": "GET", "path": "/api/search?q=%20a%20"},
    {"method": "GET", "path": "/api/search?q=zzzz"},
    {"method": "GET", "path": "/api/search"},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "page": 1}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "page": 2}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "page": "3"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "page": 9}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "  ", "page": 2}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "Berechnen Sie die Eigenwerte"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "Berechnen Sie die Aufgabe"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "Spektralsatz symmetrische Matrizen reelle Eigenwerte orthogonale Diagonalisierung"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "Laplace Entwicklung Determinante Determinante Invertierbarkeit"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-v1", "text": "Eigenwerte Eigenvektoren charakteristische Polynom Matrix"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": "Eigenwerte Eigenvektoren charakteristisches Polynom Matrix Diagonalisierung Spektralsatz symmetrisch numerisch"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-la-u1", "text": LONG}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-an-u1", "text": "Folgen Grenzwerte Konvergenz Cauchy"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "f-frei1", "text": "Seminar Organisation Termine"}},
    {"method": "POST", "path": "/api/related", "body": {"file_id": "nope", "text": "Eigenwerte"}},
    {"method": "POST", "path": "/api/related", "body": {}},
    {"method": "POST", "path": "/api/related", "body": ["kein", "Objekt"]},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=2"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=3"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=0"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=4"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=-1"},
    {"method": "GET", "path": "/api/files/f-la-s/pagetext?page=3"},
    {"method": "GET", "path": "/api/files/f-la-u1/pagetext?page=1"},
    {"method": "GET", "path": "/api/files/f-la-v4/pagetext"},
    {"method": "GET", "path": "/api/files/nope/pagetext"},
    {"method": "GET", "path": "/api/files/f-la-v1/pagetext?page=abc"},
]

TOKEN_CASES = [
    "Berechnen Sie die Eigenwerte und Eigenvektoren der Matrix A.",
    "Lineare Unabh¨ angigkeit und Unabh¨\nangigkeit, Übung, Müller, ökonomisch",
    "Übung Uebung Übungsblatt Aufgabe Teilaufgabe Lösung Hinweis Punkte",
    "Abbildungen Abbildung Zuordnungen Zuordnung Rechnungen Spannungen Vektoren Matrizen Normen Ergebnisses Systemen Kreise",
    "ab abc ABCD Straße STRASSE groß Größe Maß ÄÖÜ äöü",
    "x1 x2 3D-Grafik C++ e-Funktion π-Formel naïve café",
    "",
]
SNIPPET_CASES = [
    ("Der  Satz\nvon   Rolle   besagt", ["rolle"]),
    ("Kein Treffer in diesem Text", ["zzz"]),
    (("Einleitung " * 30) + "Hier steht der Spektralsatz mit Beweis " + ("und weiter " * 30), ["spektralsatz", "beweis"]),
    (("İİİ " * 20) + "Eigenwert", ["eigenwert"]),
    ("   ", ["x"]),
    ("Kurz Eigenwert", ["eigenwert", "kurz"]),
]


def seed_sql(src: SchemaSource, pdf_text) -> tuple[list[tuple[str, list]], list[dict]]:
    """Seed und Dateien; Seitentexte so, wie pypdf sie aus den gebauten PDFs liest"""
    seed: list[tuple[str, list]] = []
    for mid, name, color in MODULES:
        seed.append(("INSERT INTO modules(id, name, semester, color, sort, created_at) VALUES (?,?,?,?,?,?)",
                     [mid, name, "WiSe 2026/27", color, mid - 1, "2026-10-01T09:00:00"]))
    for cid, title, subject, kind, module, active in COURSES:
        seed.append(("INSERT INTO courses(id, title, semester, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,?,?,?,?)",
                     [cid, title, "WiSe 2026/27", subject, kind, active, module, "2026-10-01T09:00:00"]))
    files: list[dict] = []
    texts: list[tuple[str, list]] = []
    for i, (fid, course, name, folder, chdate, pages, raw) in enumerate(FILES):
        data = text_pdf(pages) if pages is not None else raw
        local = f"files/{course}/{name}" if data is not None else None
        kind = "image" if name.endswith(".png") else "pdf"
        seed.append(("INSERT INTO files(id, course_id, name, size, mime, chdate, studip_folder, local_path, downloaded_at, status, kind, first_seen) "
                     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                     [fid, course, name, len(data) if data else 0, "image/png" if kind == "image" else "application/pdf", chdate, folder,
                      local, "2026-10-22T08:00:00" if local else None, "neu", kind, "2026-10-22T08:00:00"]))
        if data is not None:
            files.append({"path": local, "base64": base64.b64encode(data).decode()})
        if pages is not None:
            for p, t in enumerate(pdf_text(data)):
                texts.append(("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", [fid, p + 1, t, chdate]))
    for fid, doc_type, title, topics in ANALYSIS:
        seed.append(("INSERT INTO analysis(file_id, doc_type, title, topics, created_at) VALUES (?,?,?,?,?)",
                     [fid, doc_type, title, topics, "2026-10-22T08:00:00"]))
    for pid, day, module, subject, title in PACKAGES:
        seed.append(("INSERT INTO study_packages(id, date, module_id, subject, title, planned_minutes, status, created_at) VALUES (?,?,?,?,?,?,?,?)",
                     [pid, day, module, subject, title, 60, "geplant", "2026-10-19T08:00:00"]))
    for tid, pid, typ, fid, title, status in TASKS:
        seed.append(("INSERT INTO study_tasks(id, package_id, type, file_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                     [tid, pid, typ, fid, title, tid, 30, status, "2026-10-19T08:00:00"]))
    return seed + texts, files


def main() -> int:
    check = "--check" in sys.argv[1:]
    cwd = os.getcwd()
    src = SchemaSource()
    try:
        from pypdf import PdfReader

        from app import scriptsearch, server
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)

        def pdf_text(data: bytes) -> list[str]:
            return [p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages]

        seed, files = seed_sql(src, pdf_text)
        # local_path relativ wie auf dem iPad (zum App-Container): der Server liest relativ zum Arbeitsordner
        data_dir = src.tmp / "container"
        data_dir.mkdir()
        for f in files:
            target = data_dir / f["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(base64.b64decode(f["base64"]))
        os.chdir(data_dir)
        src.use_db(src.tmp / "suche.db")
        src.db.init_db()
        with src.db.cursor() as conn:
            scriptsearch.ensure_table(conn)
            for sql, params in seed:
                conn.execute(sql, params)
        steps = []
        for s in STEPS:
            status, value = gen.asgi(server.app, s["method"], s["path"], s.get("body"))
            assert status != 500, (s, value)
            step = {"method": s["method"], "path": s["path"], "status": status, "response": value}
            if "body" in s:
                step["body"] = s["body"]
            steps.append(step)
        with src.db.cursor() as conn:
            after = src.db.rows(conn, "SELECT file_id, page, text, chdate FROM page_texts ORDER BY file_id, page")
        tokens = [{"text": t, "tokens": scriptsearch.tokens(t)} for t in TOKEN_CASES]
        normalize = [{"text": t, "normalized": scriptsearch.normalize(t)} for t in TOKEN_CASES]
        snippets = [{"text": t, "terms": terms, "snippet": scriptsearch._snippet(t, terms)} for t, terms in SNIPPET_CASES]
    finally:
        os.chdir(cwd)
        src.cleanup()
    out = {"generator": "tools/gen-search-fixture.py", "seed": [{"sql": q, "params": p} for q, p in seed], "files": files,
           "steps": steps, "tokens": tokens, "normalize": normalize, "snippets": snippets, "tables_after": {"page_texts": after}}
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
