"""Geraete-Abgleich im Dienst (LERNAPP_FILES=stream): das Geraet laedt die Hochschuldatei selbst (eigene Hochschul-
Anmeldung in der App) und meldet dem Dienst nur Fingerabdruck (PUT .../fingerprint) und Seitentext (PUT .../pagetext);
dazu das Anmeldeprofil der Hochschule (GET /api/university/profile, Werte wie fixtures/learnweb/launch.json) und die
Herkunftsfelder in den Dateilisten. Gleiche Muster wie tests/test_filestream.py; nichts geht ins Netz."""
import hashlib
import json
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
LAUNCH_FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "learnweb" / "launch.json"
SHA_A = hashlib.sha256(b"Fassung A").hexdigest()
SHA_B = hashlib.sha256(b"Fassung B").hexdigest()
STUDIP_URL = "https://studip.uni-hannover.de/sendfile.php?type=0&file_id=f1&file_name=Blatt.pdf"
LEARNWEB_URL = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/7/mod_resource/content/1/Blatt.pdf"


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config, filestream, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setattr(config, "FILES_MODE", "")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    vault.reset_master()
    filestream.forget()
    yield app
    filestream.forget()
    accounts.db_path().unlink(missing_ok=True)


def _user(app, email="s@beispiel.de", uni="luh"):
    st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    assert st == 201, b
    d = json.loads(b)
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _with_user(user, uni, fn):
    from app import config, db
    t = config.set_user_context(user["id"], uni)
    try:
        db.init_db()
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


def _seed(user, uni="luh", file_id="f1", url=STUDIP_URL, name="Blatt 3.pdf", course="c1", sha=None):
    def go(conn):
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES (?, 'Mathe I', 'vorlesung', 1, '2026-10-27')", (course,))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url, chdate, size, content_sha256) VALUES (?,?,?,?,?,?,?,?,?)",
                     (file_id, course, name, "pdf", "neu", url, 1761500000, 0, sha))
    _with_user(user, uni, go)


def _seed_own(user, uni="luh", file_id="own", local_path=None):
    def go(conn):
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene', 'sonstiges', 1, '2026-10-27')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, chdate, local_path, download_url) VALUES (?, '__user__', 'Notizbuch.pdf', 'pdf', 'neu', 1761500000, ?, '')",
                     (file_id, local_path))
    _with_user(user, uni, go)


def _file(user, uni, file_id, cols="content_sha256"):
    from app import db
    return _with_user(user, uni, lambda conn: db.row(conn, f"SELECT {cols} FROM files WHERE id=?", (file_id,)))


def _pages(user, uni, file_id):
    from app import db, scriptsearch

    def go(conn):
        scriptsearch.ensure_table(conn)                     # frisches Konto: Tabelle gibt es erst nach dem ersten Ablegen
        return db.rows(conn, "SELECT page, text, chdate, search FROM page_texts WHERE file_id=? ORDER BY page", (file_id,))
    return _with_user(user, uni, go)


def _j(result):
    st, _, body = result
    return st, (json.loads(body) if body else None)


# ---------------------------------------------------------------- Fingerabdruck vom Geraet

def test_put_fingerprint_sets_once_and_reports_mismatch(hosted):
    user, h = _user(hosted)
    _seed(user)
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=h, body=json.dumps({"sha256": SHA_A})))
    assert (st, d) == (200, {"sha256": SHA_A, "source": "geraet"})
    assert _file(user, "luh", "f1")["content_sha256"] == SHA_A
    # gleicher Wert erneut (zweites Geraet): ok, Grossschreibung wird angeglichen
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=h, body=json.dumps({"sha256": SHA_A.upper()})))
    assert (st, d) == (200, {"sha256": SHA_A, "source": "geraet"})
    # anderer Wert: der Dienst kennt die Datei anders -> 409, nichts ueberschrieben
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=h, body=json.dumps({"sha256": SHA_B})))
    assert (st, d["code"]) == (409, "fingerprint_mismatch")
    assert _file(user, "luh", "f1")["content_sha256"] == SHA_A
    # danach kennt POST den Schluessel ohne Abruf bei der Hochschule
    st, d = _j(asgi_call(hosted, "POST", "/api/files/f1/fingerprint", headers=h))
    assert (st, d) == (200, {"sha256": SHA_A, "source": "bekannt"})
    # ungueltig: zu kurz, kein Hex, fehlt
    for body in ({"sha256": "abc"}, {"sha256": "g" * 64}, {}, {"sha256": None}):
        st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=h, body=json.dumps(body)))
        assert (st, d["code"]) == (400, "fingerprint_invalid"), body
    # unbekannte Datei -> 404 (Regel G6)
    assert asgi_call(hosted, "PUT", "/api/files/gibtsnicht/fingerprint", headers=h, body=json.dumps({"sha256": SHA_A}))[0] == 404


def test_put_fingerprint_accepts_a_known_equal_value_from_streaming(hosted):
    """Hat der Dienst den Hash schon beim Durchreichen gelernt, bestaetigt das Geraet ihn nur."""
    user, h = _user(hosted, "k@beispiel.de", "hildesheim")
    _seed(user, "hildesheim", "lw-7", LEARNWEB_URL, sha=SHA_B)
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/lw-7/fingerprint", headers=h, body=json.dumps({"sha256": SHA_B})))
    assert (st, d) == (200, {"sha256": SHA_B, "source": "geraet"})
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/lw-7/fingerprint", headers=h, body=json.dumps({"sha256": SHA_A})))
    assert (st, d["code"]) == (409, "fingerprint_mismatch")


# ---------------------------------------------------------------- Seitentext vom Geraet

def test_put_pagetext_is_stored_readable_and_searchable(hosted):
    user, h = _user(hosted)
    _seed(user)
    pages = ["Kapitel 1 Einleitung", "Der Satz von Rolle und der Mittelwertsatz", ""]
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=h, body=json.dumps({"pages": pages})))
    assert (st, d) == (200, {"pages": 3})
    rows = _pages(user, "luh", "f1")
    assert [r["page"] for r in rows] == [1, 2, 3] and all(r["chdate"] == 1761500000 for r in rows), "chdate der Datei wie bei index_bytes"
    assert rows[1]["search"] == "der satz von rolle und der mittelwertsatz", "Suchform wie index_bytes"
    # lesbar ueber den Index, ohne Datei und ohne Abruf bei der Hochschule
    st, d = _j(asgi_call(hosted, "GET", "/api/files/f1/pagetext?page=2", headers=h))
    assert (st, d) == (200, {"text": pages[1], "pages": 3})
    st, d = _j(asgi_call(hosted, "GET", "/api/files/f1/pagetext?page=3", headers=h))
    assert (st, d) == (200, {"text": "", "pages": 3})
    # globale Suche findet die Seite (Datei ohne local_path, aber mit Quelle: das Geraet hat sie)
    st, d = _j(asgi_call(hosted, "GET", "/api/search?q=MITTELWERTSATZ", headers=h))
    assert st == 200 and [(p["file_id"], p["page"]) for p in d["pages"]] == [("f1", 2)]
    assert d["pages"][0]["snippet"] == "Der Satz von Rolle und der Mittelwertsatz"
    # neue Meldung ersetzt die alte Fassung
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=h, body=json.dumps({"pages": ["Nur eine Seite"]})))
    assert (st, d) == (200, {"pages": 1})
    st, d = _j(asgi_call(hosted, "GET", "/api/files/f1/pagetext?page=1", headers=h))
    assert (st, d) == (200, {"text": "Nur eine Seite", "pages": 1})
    assert _j(asgi_call(hosted, "GET", "/api/search?q=mittelwertsatz", headers=h))[1]["pages"] == []


def test_put_pagetext_rejects_bad_input(hosted):
    user, h = _user(hosted)
    _seed(user)
    bad = ({}, {"pages": "text"}, {"pages": []}, {"pages": ["a"] * 2001}, {"pages": ["x" * 20001]}, {"pages": [1]}, {"pages": [None]},
           {"pages": {"1": "a"}})
    for body in bad:
        st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=h, body=json.dumps(body)))
        assert (st, d["code"]) == (400, "pagetext_invalid"), str(body)[:60]
    assert _pages(user, "luh", "f1") == [], "nichts abgelegt"
    # Grenzen gelten einschliesslich
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=h, body=json.dumps({"pages": ["x" * 20000]})))
    assert (st, d) == (200, {"pages": 1})
    assert asgi_call(hosted, "PUT", "/api/files/gibtsnicht/pagetext", headers=h, body=json.dumps({"pages": ["a"]}))[0] == 404


def test_related_uses_device_page_texts(hosted):
    """Uebung <-> Skript (BM25 je Modul) arbeitet mit den gemeldeten Seiten, obwohl keine Datei beim Dienst liegt."""
    user, h = _user(hosted)

    def go(conn):
        conn.execute("INSERT OR IGNORE INTO modules(id, name, color, created_at) VALUES (7, 'Lineare Algebra', '#123456', '2026-10-27')")
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('c-la', 'LinA', 'Lineare Algebra', 'vorlesung', 7, 1, '2026-10-27')")
        for fid, name in (("skript", "Skript LinA.pdf"), ("blatt", "Blatt 2.pdf")):
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url, chdate, size) VALUES (?, 'c-la', ?, 'pdf', 'neu', ?, 1761500000, 0)",
                         (fid, name, STUDIP_URL.replace("f1", fid)))
    _with_user(user, "luh", go)
    filler = ["Wellen Schwingung Frequenz Amplitude Resonanz", "Strom Spannung Widerstand Kondensator Spule",
              "Graphen Knoten Kanten Pfade Zyklen", "Integral Stammfunktion Substitution Flaechen Grenzen"]
    texts = ["Spur Determinante Eigenwerte Matrizen Basiswechsel Diagonalisierung",
             "Spur Determinante Rechenregeln Beispiele Uebersicht Tabellen Sonstiges",
             "Matrizen Eigenwerte Rechenregeln Beispiele Uebersicht Tabellen Sonstiges",
             "Spur Matrizen Rechenregeln Beispiele Uebersicht Tabellen Sonstiges"]
    texts += [filler[i % len(filler)] + f" Abschnitt{chr(97 + i)}" for i in range(16)]
    # vor der Meldung: Modul ohne Seiten
    st, d = _j(asgi_call(hosted, "POST", "/api/related", headers=h, body=json.dumps({"file_id": "blatt", "text": "Spur Determinante Eigenwerte Matrizen"})))
    assert st == 200 and d["results"] == []
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/skript/pagetext", headers=h, body=json.dumps({"pages": texts})))
    assert (st, d) == (200, {"pages": 20})
    st, d = _j(asgi_call(hosted, "POST", "/api/related", headers=h, body=json.dumps({"file_id": "blatt", "text": "Spur Determinante Eigenwerte Matrizen"})))
    assert st == 200 and d["results"], d
    assert (d["results"][0]["file_id"], d["results"][0]["page"]) == ("skript", 1)


# ---------------------------------------------------------------- nur Hochschuldateien ohne Datei beim Dienst

def test_own_documents_and_stored_files_are_rejected(hosted, tmp_path):
    user, h = _user(hosted)
    _seed_own(user)
    for path, body in (("fingerprint", {"sha256": SHA_A}), ("pagetext", {"pages": ["a"]})):
        st, d = _j(asgi_call(hosted, "PUT", f"/api/files/own/{path}", headers=h, body=json.dumps(body)))
        assert (st, d["code"]) == (400, "not_university_file"), path
    # Hochschuldatei, die der Dienst auf der Platte hat (Betriebsart store oder Altbestand): dort kennt er sie selbst
    p = tmp_path / "Blatt 3.pdf"
    p.write_bytes(b"%PDF-1.4 erfunden")
    _seed(user, file_id="f-disk")
    _with_user(user, "luh", lambda conn: conn.execute("UPDATE files SET local_path=? WHERE id='f-disk'", (str(p),)))
    for path, body in (("fingerprint", {"sha256": SHA_A}), ("pagetext", {"pages": ["a"]})):
        st, d = _j(asgi_call(hosted, "PUT", f"/api/files/f-disk/{path}", headers=h, body=json.dumps(body)))
        assert (st, d["code"]) == (400, "file_stored"), path
    assert _file(user, "luh", "f-disk")["content_sha256"] is None and _pages(user, "luh", "f-disk") == []
    # local_path, dessen Datei fehlt (nach "Dateien löschen"): wieder eine Datei ohne Speicherung -> Meldung erlaubt
    _with_user(user, "luh", lambda conn: conn.execute("UPDATE files SET local_path=? WHERE id='f-disk'", (str(tmp_path / "weg.pdf"),)))
    st, d = _j(asgi_call(hosted, "PUT", "/api/files/f-disk/fingerprint", headers=h, body=json.dumps({"sha256": SHA_A})))
    assert (st, d) == (200, {"sha256": SHA_A, "source": "geraet"})


def test_accounts_only_report_their_own_files(hosted):
    """Zwei Konten, dieselbe Stud.IP-Datei-ID: jedes meldet nur in seiner eigenen Datenbank; fremde ID -> 404."""
    a, ha = _user(hosted, "a@beispiel.de")
    b, hb = _user(hosted, "b@beispiel.de")
    _seed(a)
    assert asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=hb, body=json.dumps({"sha256": SHA_B}))[0] == 404
    assert asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=hb, body=json.dumps({"pages": ["fremd"]}))[0] == 404
    assert _file(a, "luh", "f1")["content_sha256"] is None and _pages(a, "luh", "f1") == []
    _seed(b)
    assert _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=ha, body=json.dumps({"sha256": SHA_A})))[0] == 200
    assert _j(asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", headers=hb, body=json.dumps({"sha256": SHA_B})))[0] == 200
    assert _j(asgi_call(hosted, "PUT", "/api/files/f1/pagetext", headers=ha, body=json.dumps({"pages": ["Seite von A"]})))[0] == 200
    assert _file(a, "luh", "f1")["content_sha256"] == SHA_A and _file(b, "luh", "f1")["content_sha256"] == SHA_B
    assert [r["text"] for r in _pages(a, "luh", "f1")] == ["Seite von A"] and _pages(b, "luh", "f1") == []
    st, d = _j(asgi_call(hosted, "GET", "/api/search?q=seite%20von", headers=hb))
    assert st == 200 and d["pages"] == []
    # ohne Sitzung: 401 (hosted_guard)
    assert asgi_call(hosted, "PUT", "/api/files/f1/fingerprint", body=json.dumps({"sha256": SHA_A}))[0] == 401
    assert asgi_call(hosted, "PUT", "/api/files/f1/pagetext", body=json.dumps({"pages": ["x"]}))[0] == 401


# ---------------------------------------------------------------- Dateilisten: Quelle, Adresse, Fingerabdruck

def test_library_and_files_lists_carry_source_url_and_fingerprint(hosted):
    from app import vault
    user, h = _user(hosted, "l@beispiel.de", "hildesheim")
    vault.set_values(user["id"], {"LEARNWEB_TOKEN": "tokGEHEIM123456", "HILDESHEIM_PASSWORD": "pwGEHEIM"})
    _seed(user, "hildesheim", "f1", STUDIP_URL, sha=SHA_A)
    _seed(user, "hildesheim", "lw-7", LEARNWEB_URL, name="Folien 1.pdf")
    _seed(user, "hildesheim", "x9", LEARNWEB_URL.replace("/7/", "/9/"), name="Folien 2.pdf")   # ohne lw-, aber pluginfile.php
    _seed_own(user, "hildesheim")
    expect = {"f1": ("studip", STUDIP_URL, SHA_A), "lw-7": ("learnweb", LEARNWEB_URL, None),
              "x9": ("learnweb", LEARNWEB_URL.replace("/7/", "/9/"), None), "own": ("own", "", None)}
    for path, pick in (("/api/library", lambda d: d["files"]), ("/api/files", lambda d: d)):
        st, body, raw = (lambda r: (r[0], json.loads(r[2]), r[2].decode()))(asgi_call(hosted, "GET", path, headers=h))
        assert st == 200, path
        got = {f["id"]: (f["source"], f["download_url"], f["content_sha256"]) for f in pick(body) if f["id"] in expect}
        assert got == expect, path
        assert "GEHEIM" not in raw and "token" not in raw.lower() and "cookie" not in raw.lower(), path
    st, d = _j(asgi_call(hosted, "GET", "/api/files?course_id=c1", headers=h))
    assert st == 200 and {f["id"]: f["source"] for f in d} == {"f1": "studip", "lw-7": "learnweb", "x9": "learnweb"}


def test_file_source_rule():
    from app.study import file_source
    assert file_source({"id": "u1", "course_id": "__user__", "download_url": LEARNWEB_URL}) == "own"
    assert file_source({"id": "lw-1", "course_id": "c"}) == "learnweb"
    assert file_source({"id": "abc", "course_id": "c", "download_url": LEARNWEB_URL}) == "learnweb"
    assert file_source({"id": "abc", "course_id": "c", "download_url": STUDIP_URL}) == "studip"
    assert file_source({"id": "abc", "course_id": "c"}) == "studip"


# ---------------------------------------------------------------- Anmeldeprofil der Hochschule

def _fixture_profile(key):
    fx = json.loads(LAUNCH_FIXTURE.read_text(encoding="utf-8"))
    return dict(fx["profiles"][key], key=key, name=fx["profiles"][key]["name"], launch_scheme=fx["launch"]["scheme"])


def test_university_profile_matches_fixture_per_account(hosted):
    from app import vault
    luh, hl = _user(hosted, "luh@beispiel.de", "luh")
    hi, hh = _user(hosted, "hi@beispiel.de", "hildesheim")
    vault.set_values(hi["id"], {"HILDESHEIM_USER": "peev", "HILDESHEIM_PASSWORD": "pwGEHEIM", "LEARNWEB_TOKEN": "tokGEHEIM123456"})
    st, d = _j(asgi_call(hosted, "GET", "/api/university/profile", headers=hl))
    assert (st, d) == (200, _fixture_profile("luh"))
    st, _, raw = asgi_call(hosted, "GET", "/api/university/profile", headers=hh)
    assert st == 200 and json.loads(raw) == _fixture_profile("hildesheim")
    assert "GEHEIM" not in raw.decode() and "token" not in raw.decode().lower()
    assert d["launch_scheme"] == "uniflow" and d["learnweb_base"] is None and d["cas_base"] is None
    # Learnweb-Adresse des Kontos (HILDESHEIM_LEARNWEB_URL) ueberschreibt die Konstante, ohne Netz
    vault.set_values(hi["id"], {"HILDESHEIM_LEARNWEB_URL": "https://www.uni-hildesheim.de/learnweb2027/"})
    st, d = _j(asgi_call(hosted, "GET", "/api/university/profile", headers=hh))
    lw = "https://www.uni-hildesheim.de/learnweb2027"
    assert st == 200 and d["learnweb_base"] == lw and d["login_url"] == f"{lw}/login/index.php?authCAS=CAS" and d["logged_in_check_url"] == f"{lw}/my/"
    assert d["hosts"] == ["www.uni-hildesheim.de", "lsf.uni-hildesheim.de"] and d["file_host"] == "www.uni-hildesheim.de"
    assert _j(asgi_call(hosted, "GET", "/api/university/profile", headers=hl))[1] == _fixture_profile("luh"), "anderes Konto unveraendert"
    # ohne Sitzung: 401
    assert asgi_call(hosted, "GET", "/api/university/profile")[0] == 401


def test_university_profile_is_free_in_local_mode(app, monkeypatch):
    from app import config, universities
    monkeypatch.setattr(config, "MODE", "local")
    st, d = _j(asgi_call(app, "GET", "/api/university/profile"))
    assert st == 200 and d == _fixture_profile(universities.current_key())
