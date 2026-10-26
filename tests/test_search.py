"""Suche und Skriptsuche (S7): globale Suche ueber Dateien, Module, Aufgaben und Seitentexte, Reihenfolge der Begriffe
der Skriptsuche. Nur erfundene Daten; die Seitentexte stehen fest in page_texts (wie nach dem Lesen der PDF)."""
import json

from conftest import asgi_call

FILLER = ["Wellen Schwingung Frequenz Amplitude Resonanz", "Strom Spannung Widerstand Kondensator Spule",
          "Graphen Knoten Kanten Pfade Zyklen", "Integral Stammfunktion Substitution Flaechen Grenzen",
          "Mengen Relationen Abbildungen Injektiv Surjektiv", "Wahrscheinlichkeit Zufall Erwartung Varianz Streuung"]


def _seed(tmp_path, file_id="s-skript", chdate=1760000000, texts=None, module=True):
    from app import db, scriptsearch
    pdf = tmp_path / f"{file_id}.pdf"
    pdf.write_bytes(b"%PDF-1.4 erfunden")
    with db.cursor() as conn:
        scriptsearch.ensure_table(conn)
        if module:
            conn.execute("INSERT OR IGNORE INTO modules(id, name, color, created_at) VALUES (91, 'Suchmodul Test', '#123456', '2026-10-26')")
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, module_id, created_at) VALUES ('c-such', 'Suchkurs Test', 'Suchmodul Test', 'vorlesung', ?, '2026-10-26')",
                     (91 if module else None,))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, chdate, local_path, studip_folder) VALUES (?, 'c-such', ?, 'pdf', 'neu', ?, ?, 'Skript')",
                     (file_id, f"{file_id}.pdf", chdate, str(pdf)))
        conn.execute("DELETE FROM page_texts WHERE file_id=?", (file_id,))
        for i, t in enumerate(texts or []):
            conn.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", (file_id, i + 1, t, chdate))


def test_search_finds_tasks_and_page_texts(app, tmp_path):
    from app import db
    _seed(tmp_path, texts=["Kapitel 1 Einleitung", "Der Satz von Rolle-Theorem\nund   Mittelwerte", "Anhang"])
    # veraltete Seitentexte (andere Aenderungszeit als die Datei) zaehlen nicht
    with db.cursor() as conn:
        conn.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('s-skript', 9, 'Rolle-Theorem alt', 1)")
        conn.execute("INSERT INTO study_packages(id, date, module_id, subject, title, planned_minutes, status, created_at) VALUES (901, '2026-10-27', 91, 'Suchmodul Test', 'Woche 2', 60, 'geplant', '2026-10-26')")
        conn.execute("INSERT INTO study_tasks(id, package_id, type, file_id, title, sort, est_minutes, status, created_at) VALUES (9001, 901, 'uebung', 's-skript', 'Rolle-Theorem ueben', 0, 30, 'geplant', '2026-10-26')")
    st, _, b = asgi_call(app, "GET", "/api/search?q=%20Rolle-THEOREM%20")
    assert st == 200
    r = json.loads(b)
    assert set(r) == {"files", "modules", "tasks", "pages"}
    assert [t["id"] for t in r["tasks"]] == [9001]
    assert r["tasks"][0]["date"] == "2026-10-27" and r["tasks"][0]["module_id"] == 91 and r["tasks"][0]["file_id"] == "s-skript"
    assert [(p["file_id"], p["page"]) for p in r["pages"]] == [("s-skript", 2)]
    assert r["pages"][0]["snippet"] == "Der Satz von Rolle-Theorem und Mittelwerte"
    assert r["pages"][0]["module_id"] == 91
    st, _, b = asgi_call(app, "GET", "/api/search?q=suchmodul")
    r = json.loads(b)
    assert [m["id"] for m in r["modules"]] == [91] and "s-skript" in [f["id"] for f in r["files"]]
    st, _, b = asgi_call(app, "GET", "/api/search?q=x")
    assert json.loads(b) == {"files": [], "modules": [], "tasks": [], "pages": []}


def test_related_terms_keep_query_order_for_equal_frequency(app, tmp_path):
    """Begriffe eines Treffers: nach Haeufigkeit, bei Gleichstand in der Reihenfolge der Anfrage (vorher die
    Reihenfolge einer Python-Menge, also je Lauf verschieden). Spur und Matrizen stehen auf drei Seiten,
    Determinante und Eigenwerte auf zwei; die erste Seite hat alle vier."""
    from app.scriptsearch import tokens
    texts = ["Spur Determinante Eigenwerte Matrizen Basiswechsel Diagonalisierung",
             "Spur Determinante Rechenregeln Beispiele Uebersicht Tabellen Sonstiges",
             "Matrizen Eigenwerte Rechenregeln Beispiele Uebersicht Tabellen Sonstiges",
             "Spur Matrizen Rechenregeln Beispiele Uebersicht Tabellen Sonstiges"]
    texts += [FILLER[i % len(FILLER)] + f" Abschnitt{chr(97 + i)}" for i in range(16)]
    _seed(tmp_path, file_id="s-lina", chdate=1760000500, texts=texts)
    _seed(tmp_path, file_id="s-blatt", chdate=1760000600, texts=["Aufgabe zur Spur"])
    df = lambda t: sum(1 for x in texts if t in tokens(x))  # noqa: E731
    orders = []
    for q in ("Spur Determinante Eigenwerte Matrizen", "Matrizen Eigenwerte Determinante Spur"):
        st, _, b = asgi_call(app, "POST", "/api/related", body=json.dumps({"file_id": "s-blatt", "text": q}))
        assert st == 200
        r = json.loads(b)
        hit = next(x for x in r["results"] if x["file_id"] == "s-lina")
        assert hit["page"] == 1
        assert hit["terms"] == sorted(dict.fromkeys(tokens(q)), key=lambda t: -df(t))
        orders.append(hit["terms"])
    assert orders == [["spur", "matriz", "determinant", "eigenwert"], ["matriz", "spur", "eigenwert", "determinant"]]
