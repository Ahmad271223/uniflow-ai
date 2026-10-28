"""Wochentest auf dem Geraet (app/server.py, 28.10.2026): Kursgruppe und Kalenderwoche eines Moduls, Material der Woche
(nur Texte, Altklausur nur mit passenden Seiten), Anfordern ohne Studora-Konto."""
import json
import time
from datetime import date

from conftest import asgi_call


def _seed():
    from app import db, scriptsearch
    db.init_db()
    now = int(time.time())
    with db.cursor() as conn:
        scriptsearch.ensure_table(conn)
        mid = conn.execute("INSERT INTO modules(name) VALUES ('Wochentest-Modul')").lastrowid
        # Uebung mit kleinerer ID: die Kursgruppe richtet sich trotzdem nach der Vorlesung
        conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id, kind, semester) VALUES ('wk-a-ue', 'Analysis Übung', ?, 'uebung', 'WiSe 2026/27')", (mid,))
        conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id, kind, semester) VALUES ('wk-b-vl', 'Analysis', ?, 'vorlesung', 'WiSe 2026/27')", (mid,))
        files = [("wk-vl", "wk-b-vl", "VL_Folgen.pdf", "vorlesung", "Folgen, Grenzwert, Konvergenz, Sandwich-Lemma, Cauchy-Folge, monotone beschraenkte Folge", now),
                 ("wk-ue", "wk-a-ue", "Blatt_Folgen.pdf", "uebung", "Aufgabe 1: Zeigen Sie die Konvergenz der Folge mit dem Sandwich-Lemma.", now),
                 ("wk-kl", "wk-b-vl", "Klausur_WS24.pdf", "klausur", "Aufgabe 4: Folgen Grenzwert Konvergenz Sandwich-Lemma Cauchy-Folge beschraenkte", now - 400 * 86400),
                 ("wk-kl2", "wk-b-vl", "Klausur_SS24.pdf", "klausur", "Aufgabe 2: Integral Stammfunktion partielle Integration", now - 300 * 86400)]
        for fid, cid, name, typ, text, ch in files:
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, chdate, content_sha256) VALUES (?,?,?, 'neu', ?, ?)",
                         (fid, cid, name, ch, (fid.encode().hex() * 32)[:64]))
            conn.execute("INSERT OR REPLACE INTO analysis(file_id, doc_type, title) VALUES (?,?,?)", (fid, typ, name[:-4]))
            conn.execute("INSERT OR REPLACE INTO page_texts(file_id, page, text, chdate) VALUES (?, 1, ?, ?)", (fid, text, ch))
    return mid, [f[0] for f in files]


def _cleanup(mid, fids):
    from app import db
    with db.cursor() as conn:
        for fid in fids:
            conn.execute("DELETE FROM page_texts WHERE file_id=?", (fid,))
            conn.execute("DELETE FROM analysis WHERE file_id=?", (fid,))
            conn.execute("DELETE FROM files WHERE id=?", (fid,))
        conn.execute("DELETE FROM courses WHERE id IN ('wk-a-ue', 'wk-b-vl')")
        conn.execute("DELETE FROM modules WHERE id=?", (mid,))


def _get(app, path):
    st, _, b = asgi_call(app, "GET", path)
    return st, json.loads(b)


def test_group_week_and_materials_of_a_module(app):
    from app.server import community_course_key
    from app import config
    mid, fids = _seed()
    try:
        today = date.today().isoformat()
        st, g = _get(app, f"/api/weekly/group?module_id={mid}&date={today}")
        assert st == 200, g
        y, w, _ = date.today().isocalendar()
        assert g["week"] == f"{y}-W{w:02d}" and g["course_title"] == "Analysis"
        assert g["course_key"] == community_course_key(config.university(), "wk-b-vl"), "Vorlesung bestimmt die Kursgruppe"
        assert g["term"] and g["term"] != "ohne-semester"
        st, m = _get(app, f"/api/weekly/materials?module_id={mid}&date={today}")
        assert st == 200, m
        kinds = {x["kind"]: x for x in m["materials"]}
        assert {"vorlesung", "uebung"} <= set(kinds), m["counts"]
        assert kinds["vorlesung"]["sha256"] and kinds["vorlesung"]["pages"][0]["text"].startswith("Folgen")
        alt = [x for x in m["materials"] if x["kind"] == "altklausur"]
        assert [x["title"] for x in alt] == ["Klausur_WS24"], "nur die Altklausur mit passendem Stoff"
        assert all(set(p) == {"page", "text"} for x in m["materials"] for p in x["pages"]), "nur Seitentexte, keine Dateien"
    finally:
        _cleanup(mid, fids)


def test_module_without_course_and_request_without_account(app):
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name) VALUES ('Leeres Modul')").lastrowid
    try:
        st, d = _get(app, f"/api/weekly/group?module_id={mid}")
        assert st == 404 and d["code"] == "no_course"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
    mid, fids = _seed()
    try:
        st, _, b = asgi_call(app, "POST", "/api/weekly/request", body=json.dumps({"module_id": mid}))
        assert st == 409 and json.loads(b)["code"] == "not_linked", "ohne Studora-Konto kein Test, klare Meldung"
    finally:
        _cleanup(mid, fids)
