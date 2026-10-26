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


def test_page_search_finds_capital_and_decomposed_umlauts(app, tmp_path):
    """Seitensuche mit Umlaut am Wortanfang und mit zerlegten Umlauten: SQLite lower() und LIKE kennen nur ASCII,
    darum fand "übersicht" die Seite "Übersicht ..." nicht, und "unabhängigkeit" nur die Schreibweise in NFC.
    Verglichen wird jetzt die Suchform (normalize, klein, NFC), auch fuer Zeilen von vor der Suchform."""
    from app import db, scriptsearch
    _seed(tmp_path, file_id="s-umlaut", chdate=1760000700,
          texts=["Übersicht der Äquivalenzrelationen und Übungsaufgaben", "Lineare Unabhängigkeit",
                 "Lineare Unabh¨ angigkeit", "Lineare Unabhängigkeit", "Ökonomie"])
    with db.cursor() as conn:
        assert db.rows(conn, "SELECT search FROM page_texts WHERE file_id='s-umlaut' AND search IS NOT NULL") == []

    def pages(q):
        st, _, b = asgi_call(app, "GET", "/api/search?q=" + q)
        assert st == 200
        return [p["page"] for p in json.loads(b)["pages"] if p["file_id"] == "s-umlaut"]

    assert pages("%C3%BCbersicht") == [1]
    assert pages("%C3%9Cbersicht") == [1]
    assert pages("%C3%A4quivalenz") == [1]
    assert pages("bersicht") == [1]
    assert pages("unabh%C3%A4ngigkeit") == [2, 3, 4]
    assert pages("unabha%CC%88ngigkeit") == [2, 3, 4]
    assert pages("%C3%B6konomie") == [5]
    with db.cursor() as conn:
        forms = [r["search"] for r in db.rows(conn, "SELECT search FROM page_texts WHERE file_id='s-umlaut' ORDER BY page")]
    assert forms[0] == "übersicht der äquivalenzrelationen und übungsaufgaben"
    assert forms[1:4] == ["lineare unabhängigkeit"] * 3
    assert scriptsearch.search_form("ÄRGER") == "ärger"


def test_page_search_skips_files_that_are_not_on_the_device(app, tmp_path):
    """Nach "Dateien löschen" (local_path leer) keine Seitentreffer mehr, die sich nicht oeffnen lassen; die
    Seitentexte selbst bleiben (eine neue Fassung braucht sie noch)."""
    from app import db
    _seed(tmp_path, file_id="s-weg", chdate=1760000800, texts=["Seite mit Spektralzerlegung"])
    st, _, b = asgi_call(app, "GET", "/api/search?q=spektralzerlegung")
    assert [p["file_id"] for p in json.loads(b)["pages"]] == ["s-weg"]
    with db.cursor() as conn:
        conn.execute("UPDATE files SET local_path=NULL, downloaded_at=NULL WHERE id='s-weg'")
    st, _, b = asgi_call(app, "GET", "/api/search?q=spektralzerlegung")
    assert json.loads(b)["pages"] == []
    with db.cursor() as conn:
        assert len(db.rows(conn, "SELECT 1 FROM page_texts WHERE file_id='s-weg'")) == 1


def test_page_texts_table_gets_search_column(app):
    """Aeltere page_texts ohne Suchform bekommen die Spalte (ensure_table), mehrfach aufgerufen ohne Fehler."""
    from app import db, scriptsearch
    with db.cursor() as conn:
        conn.execute("DROP TABLE IF EXISTS page_texts")
        conn.execute("CREATE TABLE page_texts (file_id TEXT NOT NULL, page INTEGER NOT NULL, text TEXT, chdate INTEGER, "
                     "PRIMARY KEY (file_id, page))")
        conn.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('alt', 1, 'Übung', 0)")
        scriptsearch.ensure_table(conn)
        scriptsearch.ensure_table(conn)
        assert "search" in {r[1] for r in conn.execute("PRAGMA table_info(page_texts)")}
        assert db.rows(conn, "SELECT text, search FROM page_texts") == [{"text": "Übung", "search": None}]


def test_search_names_with_capital_umlauts_and_like_characters(app, tmp_path):
    """Namen von Dateien, Modulen und Aufgaben werden in der Suchform verglichen (klein, NFC): SQLite lower() und LIKE
    kennen nur ASCII, darum fanden "übung" und "Ökonomie" weder "Übung 1.pdf" noch das Modul "Ökonomie Übung".
    % und _ sind keine Platzhalter mehr ("%%" fand alle Dateien); Papierkorb und abgewaehlte Kurse fehlen."""
    from app import db
    _seed(tmp_path, file_id="s-name", chdate=1760000900, texts=["Seite 50% sicher"])
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(id, name, color, created_at) VALUES (92, 'Ökonomie Übung', '#336699', '2026-10-26')")
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('c-alt', 'Alt', 'Alt', 'vorlesung', 92, 0, '2026-10-26')")
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate) VALUES ('s-ue', 'c-such', 'Übung 1.pdf', 'pdf', 'neu', 1760000901)")
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate) VALUES ('s-pk', 'c-such', 'Übung 2.pdf', 'pdf', 'neu', 1760000902)")
        conn.execute("UPDATE files SET deleted_at='2026-10-26T10:00:00' WHERE id='s-pk'")
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate) VALUES ('s-inakt', 'c-alt', 'Übung 3.pdf', 'pdf', 'neu', 1760000903)")
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate) VALUES ('s-proz', 'c-such', 'Rabatt_50%.pdf', 'pdf', 'neu', 1760000904)")
        conn.execute("INSERT INTO study_packages(id, date, module_id, subject, title, planned_minutes, status, created_at) VALUES (902, '2026-10-28', 92, 'Ökonomie Übung', 'Woche 2', 60, 'geplant', '2026-10-26')")
        conn.execute("INSERT INTO study_tasks(id, package_id, type, title, sort, est_minutes, status, created_at) VALUES (9002, 902, 'uebung', 'Übungsblatt Ökonomie', 0, 30, 'geplant', '2026-10-26')")

    def search(q):
        st, _, b = asgi_call(app, "GET", "/api/search?q=" + q)
        assert st == 200
        return json.loads(b)

    for q in ("%C3%BCbung", "%C3%9Cbung"):
        r = search(q)
        assert [f["id"] for f in r["files"]] == ["s-ue"]
        assert [m["id"] for m in r["modules"]] == [92]
        assert [t["id"] for t in r["tasks"]] == [9002]
    assert [m["id"] for m in search("%C3%96konomie")["modules"]] == [92]
    assert [m["id"] for m in search("u%CC%88bung")["modules"]] == [92]      # zerlegter Umlaut (NFD)
    assert [f["id"] for f in search("%25%25")["files"]] == []
    assert [f["id"] for f in search("_5")["files"]] == ["s-proz"]
    assert [f["id"] for f in search("0%25")["files"]] == ["s-proz"]
    assert [(p["file_id"], p["page"]) for p in search("50%25")["pages"]] == [("s-name", 1)]
    assert search("0_")["files"] == [] and search("0_")["pages"] == []
