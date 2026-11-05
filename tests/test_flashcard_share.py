"""Geteilte Wochenstapel und "Stapel teilen" (Entscheidung des Inhabers vom 04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md):
Schluessel und Namen wie im Kern (Fixture cardshare/cases.json), Wochenstapel holen oder erzeugen (Einzelplatz und
Dienst mit Varianten: uebernehmen statt erzeugen, Platz frei nach Fehler), eigene Stapel in der Modul-Community teilen,
uebernehmen, zurueckziehen, liken, melden, nie ueber Module hinweg. Keine echte KI, kein Netz."""
import hashlib
import json
import time
from pathlib import Path

import pytest
from conftest import asgi_call
from test_subscriptions import _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

FIX = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "cardshare" / "cases.json"
H = {k: hashlib.sha256(k.encode()).hexdigest() for k in ("vl5", "skript5", "blatt5", "blatt5-b")}


class FakeCardsAI:
    """Attrappe der StudiNow-KI: liefert Karten und zaehlt die Aufrufe; `fail` laesst den Aufruf scheitern."""

    def __init__(self):
        self.calls, self.fail, self.prompts = 0, False, []

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import AIUnavailable, Completion
        self.calls += 1
        self.prompts.append(prompt)
        if self.fail:
            raise AIUnavailable("ai_provider_error", "Der KI-Anbieter antwortete mit Fehler 500.", 502)
        cards = [{"question": f"Frage {i} (Lauf {self.calls})", "answer": f"Antwort {i}"} for i in range(1, 4)]
        return Completion(json.dumps({"cards": cards}), 120, 40, "fake")


def _call(app, method, path, body=None, status=200, headers=None):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    assert st == status, f"{method} {path}: {st} {raw[:400]}"
    return json.loads(raw) if raw else None


def _seed(conn, module="Analysis I", files=(("f-vl5", "VL05.pdf", "vorlesung", "vl5"), ("f-sk5", "Skript_Kap05.pdf", "skript", "skript5"),
                                               ("f-bl5", "Blatt05.pdf", "uebung", "blatt5"))):
    """Modul mit einem Kurs und Dateien der Lehrwoche 5 (Woche aus dem Namen), Analyse-Art und Inhalts-Hash"""
    mid = conn.execute("INSERT INTO modules(name, semester, color, created_at) VALUES (?, 'WiSe 2026/27', '#123456', '2026-10-01')", (module,)).lastrowid
    cid = f"k-{mid}"
    conn.execute("INSERT INTO courses(id, title, subject, kind, active, created_at, module_id) VALUES (?,?,?,?,1,'2026-10-01',?)",
                 (cid, module + " (WS 2026/27)", module, "vorlesung", mid))
    for fid, name, doc_type, h in files:
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, chdate, text_excerpt, content_sha256) VALUES (?,?,?,?,?,?,?,?)",
                     (fid, cid, name, "pdf", "neu", int(time.time()), f"Text von {name}", H[h]))
        conn.execute("INSERT OR REPLACE INTO analysis(file_id, doc_type, title) VALUES (?,?,?)", (fid, doc_type, name))
    return mid


# eigene Kennungen dieser Datei (nur sie werden aufgeraeumt; andere Tests teilen sich die Datenbank am Einzelplatz und
# haben Zeilen, die auf ihre Dateien, Kurse und Module zeigen)
OWN_FILES = ("f-vl5", "f-sk5", "f-bl5")
OWN_MODULE = "semester='WiSe 2026/27' AND color='#123456'"


def _clean(conn):
    for t in ("flashcards", "flashcard_stacks"):
        conn.execute(f"DELETE FROM {t}")
    marks = ",".join("?" * len(OWN_FILES))
    conn.execute(f"DELETE FROM analysis WHERE file_id IN ({marks})", OWN_FILES)
    conn.execute(f"DELETE FROM files WHERE id IN ({marks})", OWN_FILES)
    own = [r[0] for r in conn.execute(f"SELECT id FROM modules WHERE {OWN_MODULE}").fetchall()]
    for mid in own:
        conn.execute("DELETE FROM courses WHERE id=? AND NOT EXISTS (SELECT 1 FROM files WHERE course_id=?)", (f"k-{mid}", f"k-{mid}"))
        conn.execute("DELETE FROM modules WHERE id=? AND NOT EXISTS (SELECT 1 FROM courses WHERE module_id=?)", (mid, mid))


# ---------------------------------------------------------------- reine Funktionen (gleich im Kern)

def test_keys_names_prompt_and_plaintext_match_shared_fixture():
    from app import ai, cardshare, testshare
    doc = json.loads(FIX.read_text(encoding="utf-8"))
    assert doc["version"] == cardshare.VERSION and doc["kinds"] == list(cardshare.KINDS) and doc["max_variants"] == testshare.MAX_VARIANTS
    assert doc["week_cards"] == cardshare.WEEK_CARDS <= ai.FLASHCARDS_MAX == doc["max_cards"]
    for cs in doc["cases"]:
        assert cardshare.week_key(cs["university"], cs["kind"], [{"content_sha256": h} for h in cs["materials"]]) == cs["expected_key"], cs["name"]
    for u in doc["unsafe"]:
        assert cardshare.week_key(u["university"], u["kind"], [{"content_sha256": h} for h in u["materials"]]) is None, u["name"]
    for n in doc["stack_names"]:
        assert cardshare.stack_name(n["kind"], n["week"]) == n["name"]
    p = doc["prompt"]
    assert cardshare.week_text(p["files"]) == p["week_text"]
    assert cardshare.prompt(p["module"], p["kind"], p["week"], p["files"]) == p["expected"]
    assert p["expected"].startswith(f"Kurs: Analysis I\nDatei: Vorlesung Woche 5\n\nAUFGABE: Erstelle genau {cardshare.WEEK_CARDS} Karteikarten")
    assert cardshare.canonical_cards(doc["plaintext"]["cards"]) == doc["plaintext"]["expected"]
    for r in doc["record_names"]:
        assert r["name"] == f"{r['key']}#{r['variant']}"
    # Schluesselregeln: Art und Hochschule trennen, Reihenfolge und Doppelte nicht
    a, b = ({"content_sha256": H["vl5"]}, {"content_sha256": H["skript5"]})
    k = cardshare.week_key("luh", "vorlesung", [a, b])
    assert k == cardshare.week_key("luh", "vorlesung", [b, a, a]) and k.startswith("cs1:")
    assert k != cardshare.week_key("luh", "uebung", [a, b]) != cardshare.week_key("hildesheim", "uebung", [a, b])
    assert cardshare.week_key("luh", "vorlesung", [a, {"content_sha256": None}]) is None
    assert cardshare.stack_name("uebung", 3) == "Übung Woche 3"


# ---------------------------------------------------------------- Einzelplatz: holen oder erzeugen

def test_week_stack_get_or_generate_single_user(app, monkeypatch):
    from app import ai, db
    db.init_db()
    with db.cursor() as conn:
        _clean(conn)
        mid = _seed(conn)
    calls = []

    def fake_ask(prompt, system, schema=None):
        calls.append(prompt)
        return json.dumps({"cards": [{"question": "Was ist eine Reihe?", "answer": "Summe einer Folge."}, {"question": " leer ", "answer": ""},
                                     {"question": "Majorante?", "answer": "Vergleichsreihe."}]})
    monkeypatch.setattr(ai, "ask", fake_ask)
    try:
        st = _call(app, "GET", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")
        assert st == {"stack": None, "files": 2, "name": "Vorlesung Woche 5", "shareable": True}
        r = _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")
        s = r["stack"]
        assert r["status"] == "unshared" and r["variant"] in (1, 2, 3) and r["of"] == 3 and r["credits"] is None, "eigene Variante gemerkt, nichts geteilt"
        assert (s["name"], s["subject"], s["kind"], s["week"], s["source"], s["cards"], s["due"]) == ("Vorlesung Woche 5", "Analysis I", "vorlesung", 5, "week", 2, 2)
        assert s["source_ref"].startswith("cs1:") and s["file_id"] is None and s["shared_id"] is None
        assert len(calls) == 1 and "Kurs: Analysis I\nDatei: Vorlesung Woche 5\n" in calls[0]
        assert "### Datei: VL05.pdf\nText von VL05.pdf" in calls[0] and "### Datei: Skript_Kap05.pdf" in calls[0] and "Blatt05" not in calls[0]
        cards = _call(app, "GET", f"/api/flashcards?stack_id={s['id']}&due=1")
        assert {c["question"] for c in cards} == {"Was ist eine Reihe?", "Majorante?"} and all(c["box"] == 1 and c["subject"] == "Analysis I" for c in cards)
        # ein zweites Mal: der vorhandene Stapel, keine KI
        again = _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")
        assert again["status"] == "exists" and again["stack"]["id"] == s["id"] and len(calls) == 1
        assert _call(app, "GET", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")["stack"]["id"] == s["id"]
        # Uebung derselben Woche: eigener Stapel aus dem Blatt
        u = _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/5/uebung")["stack"]
        assert (u["name"], u["kind"], u["cards"]) == ("Übung Woche 5", "uebung", 2) and u["source_ref"] != s["source_ref"] and len(calls) == 2
        assert "### Datei: Blatt05.pdf" in calls[1] and "VL05" not in calls[1]
        # ohne Unterlagen 404, falsche Art 422, unbekanntes Modul 404, Woche 0 422
        assert _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/6/uebung", status=404)["code"] == "no_materials"
        assert _call(app, "GET", f"/api/flashcard-stacks/week/{mid}/6/vorlesung") == {"stack": None, "files": 0, "name": "Vorlesung Woche 6", "shareable": False}
        _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/5/eigene", status=422)
        _call(app, "POST", f"/api/flashcard-stacks/week/{mid + 99}/5/vorlesung", status=404)
        _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/0/vorlesung", status=422)
        assert len(calls) == 2
        # die Stapel stehen in der Liste mit ihrer Herkunft; der Lernstand bleibt eigener (Wiederholung wie sonst)
        stacks = {x["id"]: x for x in _call(app, "GET", "/api/flashcard-stacks")}
        assert stacks[s["id"]]["source"] == "week" and stacks[u["id"]]["source"] == "week"
        c0 = cards[0]["id"]
        assert _call(app, "POST", f"/api/flashcards/{c0}/review", {"correct": True})["box"] == 2
    finally:
        with db.cursor() as conn:
            _clean(conn)


def test_week_stack_without_content_hash_is_private(app, monkeypatch):
    from app import ai, db
    db.init_db()
    with db.cursor() as conn:
        _clean(conn)
        mid = _seed(conn, files=(("f-vl5", "VL05.pdf", "vorlesung", "vl5"),))
        conn.execute("UPDATE files SET content_sha256=NULL WHERE id='f-vl5'")
    monkeypatch.setattr(ai, "ask", lambda prompt, system, schema=None: json.dumps({"cards": [{"question": "q", "answer": "a"}]}))
    try:
        assert _call(app, "GET", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")["shareable"] is False
        r = _call(app, "POST", f"/api/flashcard-stacks/week/{mid}/5/vorlesung")
        assert r["status"] == "unshared" and r["stack"]["source_ref"] == "" and r["stack"]["cards"] == 1
    finally:
        with db.cursor() as conn:
            _clean(conn)


# ---------------------------------------------------------------- Dienst: Varianten, uebernehmen statt erzeugen

def _seed_user(app, headers, **kw):
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            _clean(conn)
            return _seed(conn, **kw)
    finally:
        config.reset_user_context(t)


def _in_user(app, headers, fn):
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


def test_week_stack_is_generated_once_and_adopted_by_others_in_the_service(hosted, monkeypatch):
    from app import ai_backend, cardshare
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    monkeypatch.setattr(cardshare, "variant", lambda uid, key: 0)        # alle dieselbe Variante: uebernehmen statt erzeugen
    ada, ha = user(hosted, "ada@beispiel.de", plan="pro_ai")
    ben, hb = user(hosted, "ben@beispiel.de", plan="pro_ai")
    cid, hc = user(hosted, "cid@beispiel.de", plan="pro_ai")
    ma = _seed_user(hosted, ha)
    mb = _seed_user(hosted, hb, module="Analysis für alle")                 # anderer Modulname, dieselben Dateien
    mc = _seed_user(hosted, hc, files=(("f-vl5", "VL05.pdf", "vorlesung", "vl5"), ("f-sk5", "Skript_Kap05.pdf", "skript", "skript5"),
                                       ("f-bl5", "Blatt05-B.pdf", "uebung", "blatt5-b")))
    # Ada erzeugt (1 KI-Anfrage, Credits) und teilt
    a = _call(hosted, "POST", f"/api/flashcard-stacks/week/{ma}/5/vorlesung", headers=ha)
    assert (a["status"], a["variant"], a["of"], fake.calls) == ("generated", 1, 3, 1)
    assert a["credits"] is not None and a["credits"]["plan"] == "pro_ai"
    assert a["stack"]["cards"] == 3 and a["stack"]["source"] == "week"
    key = a["stack"]["source_ref"]
    assert key.startswith("cs1:") and cardshare.slots(key)[0]["status"] == "ready"
    # Ben hat dieselben Dateien: uebernimmt ohne KI, 0 Credits, eigener Stapel unter seinem Modulnamen
    b = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mb}/5/vorlesung", headers=hb)
    assert (b["status"], b["variant"], fake.calls, b["credits"]) == ("adopted", 1, 1, None)
    assert b["stack"]["subject"] == "Analysis für alle" and b["stack"]["name"] == "Vorlesung Woche 5" and b["stack"]["source_ref"] == key
    bens = _in_user(hosted, hb, lambda conn: conn.execute("SELECT question, box FROM flashcards ORDER BY id").fetchall())
    assert [q for q, _ in bens] == ["Frage 1 (Lauf 1)", "Frage 2 (Lauf 1)", "Frage 3 (Lauf 1)"] and all(box == 1 for _, box in bens)
    # Lernstand bleibt je Person: Bens Wiederholung aendert Adas Karten nicht
    bid = _in_user(hosted, hb, lambda conn: conn.execute("SELECT id FROM flashcards ORDER BY id LIMIT 1").fetchone()[0])
    _call(hosted, "POST", f"/api/flashcards/{bid}/review", {"correct": True}, headers=hb)
    assert _in_user(hosted, ha, lambda conn: conn.execute("SELECT MAX(box) FROM flashcards").fetchone()[0]) == 1
    # Cid: dieselbe Vorlesung -> uebernommen; anderes Blatt -> eigener Schluessel, erzeugt
    c = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mc}/5/vorlesung", headers=hc)
    assert c["status"] == "adopted" and fake.calls == 1
    c2 = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mc}/5/uebung", headers=hc)
    assert c2["status"] == "generated" and fake.calls == 2 and c2["stack"]["source_ref"] != key
    # Scheitert die KI, wird der belegte Platz wieder frei
    fake.fail = True
    _call(hosted, "POST", f"/api/flashcard-stacks/week/{ma}/5/uebung", headers=ha, status=502)
    assert cardshare.slots(c2["stack"]["source_ref"]) and not any(s["status"] == "pending" for s in cardshare.slots(cardshare.week_key("luh", "uebung", [{"content_sha256": H["blatt5"]}])).values())
    fake.fail = False
    # Plus (04.11.2026): uebernimmt einen fertigen Wochenstapel ohne KI, ohne Credits und ohne bestaetigte E-Mail; einen
    # NEUEN Satz erzeugen ist StudiNow-KI (Pro AI)
    _, hp = user(hosted, "plus@beispiel.de", plan="plus", verified=False)
    mp = _seed_user(hosted, hp)
    calls = fake.calls
    p = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mp}/5/vorlesung", headers=hp)
    assert (p["status"], p["credits"], fake.calls) == ("adopted", None, calls) and p["stack"]["source_ref"] == key
    d = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mp}/5/uebung", headers=hp, status=403)
    assert (d["code"], d["entitlement"]) == ("plan_required", "can_use_ai_generated_questions") and fake.calls == calls
    assert not any(s["status"] == "pending" for s in cardshare.slots(cardshare.week_key("luh", "uebung", [{"content_sha256": H["blatt5"]}])).values()), "kein belegter Platz"
    # Free: Wochenstapel (auch uebernehmen) gibt es ab Plus
    _, hf = user(hosted, "free@beispiel.de")
    mf = _seed_user(hosted, hf)
    d = _call(hosted, "POST", f"/api/flashcard-stacks/week/{mf}/5/vorlesung", headers=hf, status=403)
    assert (d["code"], d["entitlement"], d["detail"]) == ("plan_required", "can_use_flashcards", "Karteikarten gibt es ab StudiNow Plus.")
    assert _call(hosted, "GET", f"/api/flashcard-stacks/week/{mf}/5/vorlesung", headers=hf)["stack"] is None, "Stand lesen bleibt frei"
    ai_backend.set_provider(None)


def test_pool_obtain_rules(hosted, monkeypatch):
    """Platz belegen, veroeffentlichen, freigeben, warten (wie shared_tests): drei Plaetze, nie ein vierter."""
    from app import cardshare, test_library
    key = "cs1:" + "a" * 64
    assert cardshare.slots(key) == {}
    assert cardshare.claim(key, 0, "u1") and not cardshare.claim(key, 0, "u2"), "atomar"
    assert cardshare.slots(key)[0]["status"] == "pending"
    with pytest.raises(KeyError):
        cardshare.publish(key, 0, "u2", [{"question": "q", "answer": "a"}])
    cardshare.publish(key, 0, "u1", [{"question": "q", "answer": "a"}])
    assert cardshare.get(key, 0)["cards"] == [{"question": "q", "answer": "a"}]
    cardshare.release(key, 0, "u1")
    assert cardshare.slots(key)[0]["status"] == "ready", "fertige Plaetze bleiben"
    # obtain: eigene Variante fertig -> uebernehmen ohne KI; sonst erzeugen und veroeffentlichen; vierter nie
    monkeypatch.setattr(cardshare, "variant", lambda uid, k: {"u1": 0, "u2": 1, "u3": 2, "u4": 1}[uid])
    calls = []
    gen = lambda: calls.append(1) or [{"question": "neu", "answer": str(len(calls))}]
    assert cardshare.obtain(key, "u1", gen) == {"cards": [{"question": "q", "answer": "a"}], "variant": 0, "adopted_from": "service"}
    assert cardshare.obtain(key, "u2", gen)["variant"] == 1 and len(calls) == 1
    assert cardshare.obtain(key, "u3", gen)["variant"] == 2 and len(calls) == 2
    got = cardshare.obtain(key, "u4", gen)
    assert got["adopted_from"] == "service" and got["variant"] == 1 and len(calls) == 2, "drei da: uebernommen"
    # in Arbeit: kurz warten, dann uebernehmen
    key2 = "cs1:" + "b" * 64
    assert cardshare.claim(key2, 1, "u2")
    assert cardshare.wait(key2, 1, timeout_s=0.05) is None
    cardshare.publish(key2, 1, "u2", [{"question": "w", "answer": "x"}])
    assert cardshare.obtain(key2, "u4", gen, wait_s=0.1)["cards"] == [{"question": "w", "answer": "x"}] and len(calls) == 2
    # Konto loeschen vergisst den Besitzer nicht ueber diese Tabelle (owner_hash bleibt Kurzwert)
    assert test_library.owner_hash("u1") != "u1"


# ---------------------------------------------------------------- Dienst: eigene Stapel teilen

def _member(app, headers, key):
    _call(app, "POST", "/api/community/claims", {"fingerprints": [], "course_keys": [key]}, headers=headers)
    _call(app, "POST", f"/api/community/communities/{key}/join", {"kind": "course"}, headers=headers)


def _stack_with_cards(app, headers, subject, name="Klausur", week=None, kind="eigene", cards=(("Q1", "A1"), ("Q2", "A2"))):
    s = _call(app, "POST", "/api/flashcard-stacks", {"name": name, "subject": subject, "week": week, "kind": kind}, headers=headers)
    if cards:
        _call(app, "POST", "/api/flashcards", {"cards": [{"question": q, "answer": a} for q, a in cards], "stack_id": s["id"]}, headers=headers)
    return s


def test_share_adopt_withdraw_like_report_and_no_cross_module(hosted):
    from app.solution_format import community_module_key
    ada, ha = user(hosted, "ada@beispiel.de", plan="plus")
    ben, hb = user(hosted, "ben@beispiel.de", plan="plus")
    cid, hc = user(hosted, "cid@beispiel.de", plan="plus")
    dan, hd = user(hosted, "dan@beispiel.de", plan="plus")
    _seed_user(hosted, ha)
    _seed_user(hosted, hb)
    _seed_user(hosted, hc, module="Physik I")                                  # anderes Modul
    key = community_module_key("luh", "Analysis I")
    other = community_module_key("luh", "Physik I")
    for h in (ha, hb, hd):
        _member(hosted, h, key)
    _member(hosted, hc, other)
    own = _stack_with_cards(hosted, ha, "Analysis I", week=5, kind="vorlesung")
    empty = _stack_with_cards(hosted, ha, "Analysis I", name="Leer", cards=())
    loose = _call(hosted, "POST", "/api/flashcard-stacks", {"name": "Ohne Modul", "subject": None}, headers=ha)
    # teilen: nur mit Karten, nur mit Modul, nur einmal
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{empty['id']}/share", headers=ha, status=422)["code"] == "stack_empty"
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{loose['id']}/share", headers=ha, status=422)["code"] == "no_module"
    sh = _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    assert (sh["name"], sh["kind"], sh["week"], sh["cards"], sh["mine"], sh["community_key"], sh["likes"]) == ("Klausur", "vorlesung", 5, 2, True, key, 0)
    assert sh["pseudonym"].startswith("Studi-") and sh["stack"]["shared_id"] == sh["id"]
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha, status=409)["code"] == "already_shared"
    assert _call(hosted, "POST", "/api/flashcard-stacks/9999/share", headers=ha, status=404)
    # Ben (Mitglied) sieht ihn, mit Wochenfilter; Cid (anderes Modul) nicht; Nichtmitglied 403
    lst = _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)
    assert lst["community_key"] == key and [x["id"] for x in lst["stacks"]] == [sh["id"]] and lst["stacks"][0]["mine"] is False and lst["stacks"][0]["adopted"] is False
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}&week=5", headers=hb)["stacks"]
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}&week=0", headers=hb)["stacks"] == []
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}&week=6", headers=hb)["stacks"] == []
    mb = _in_user(hosted, hb, lambda conn: conn.execute("SELECT id FROM modules").fetchone()[0])
    assert [x["id"] for x in _call(hosted, "GET", f"/api/community/card-stacks?module_id={mb}", headers=hb)["stacks"]] == [sh["id"]]
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={other}", headers=hc)["stacks"] == []
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hc, status=403)["code"] == "not_a_member"
    assert _call(hosted, "GET", f"/api/community/card-stacks/{sh['id']}", headers=hc, status=403)["code"] == "not_a_member"
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/adopt", headers=hc, status=403)["code"] == "not_a_member"
    # Ben uebernimmt: eigener Stapel mit Art und Woche, Karten Fach 1, Lernstand getrennt; zweimal = derselbe Stapel
    ad = _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/adopt", headers=hb)
    st = ad["stack"]
    assert (ad["already"], ad["count"], st["name"], st["subject"], st["kind"], st["week"], st["source"], st["source_ref"], st["cards"]) == (False, 2, "Klausur", "Analysis I", "vorlesung", 5, "community", sh["id"], 2)
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/adopt", headers=hb)["already"] is True
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"][0]["adopted"] is True
    cards_b = _call(hosted, "GET", f"/api/flashcards?stack_id={st['id']}", headers=hb)
    assert {c["question"] for c in cards_b} == {"Q1", "Q2"} and all(c["box"] == 1 for c in cards_b)
    _call(hosted, "POST", f"/api/flashcards/{cards_b[0]['id']}/review", {"correct": True}, headers=hb)
    assert all(c["box"] == 1 for c in _call(hosted, "GET", f"/api/flashcards?stack_id={own['id']}", headers=ha)), "Adas Karten unberuehrt"
    # Dan hat das Modul nicht auf dem Geraet: 404 module_not_here
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/adopt", headers=hd, status=404)["code"] == "module_not_here"
    # Like (nicht der eigene), Melden (ab 3 verborgen, einmal je Konto)
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/like", headers=hb)["likes"] == 1
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/like", headers=ha, status=400)["code"] == "own_stack"
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"][0]["liked_by_me"] is True
    assert _call(hosted, "DELETE", f"/api/community/card-stacks/{sh['id']}/like", headers=hb)["likes"] == 0
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": "spam"}, headers=hb) == {"reported": True, "hidden": False, "reports": 1}
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": "spam"}, headers=hb, status=409)["code"] == "already_reported"
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": "kaputt"}, headers=hd, status=400)
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"][0]["reported_by_me"] is True
    _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": "offensive", "note": "x"}, headers=hd)
    eve, he = user(hosted, "eve@beispiel.de", plan="plus")
    _member(hosted, he, key)
    assert _call(hosted, "POST", f"/api/community/card-stacks/{sh['id']}/report", {"reason": "other"}, headers=he)["hidden"] is True
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"] == [], "ab 3 Meldungen verborgen"
    assert _call(hosted, "GET", "/api/community/card-stacks/mine", headers=ha)["stacks"][0]["status"] == "hidden"
    # zurueckziehen: nur der Autor; danach weg, erneut teilbar; Bens Kopie bleibt
    assert _call(hosted, "DELETE", f"/api/flashcard-stacks/{own['id']}/share", headers=hb, status=404)
    w = _call(hosted, "DELETE", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    assert w["withdrawn"] is True and w["stack"]["shared_id"] is None
    assert _call(hosted, "DELETE", f"/api/flashcard-stacks/{own['id']}/share", headers=ha, status=404)["code"] == "not_shared"
    assert _call(hosted, "GET", "/api/community/card-stacks/mine", headers=ha)["stacks"] == []
    assert _call(hosted, "GET", f"/api/flashcards?stack_id={st['id']}", headers=hb)
    sh2 = _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    assert sh2["id"] != sh["id"] and _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hd)["stacks"][0]["id"] == sh2["id"]
    # Stapel "Allgemein" (ohne Woche) landet unter Allgemein
    gen = _stack_with_cards(hosted, ha, "Analysis I", name="Formeln")
    g = _call(hosted, "POST", f"/api/flashcard-stacks/{gen['id']}/share", headers=ha)
    assert g["week"] is None and [x["id"] for x in _call(hosted, "GET", f"/api/community/card-stacks?module={key}&week=0", headers=hb)["stacks"]] == [g["id"]]
    # Free-Konto (z. B. nach der Probe, Stapel aus der Probe) darf nicht teilen, nicht uebernehmen und seit 05.11.2026
    # auch nicht lesen (Community ab Plus)
    from app import accounts
    accounts.set_plan(eve["id"], "free")
    _seed_user(hosted, he)
    fs = _in_user(hosted, he, lambda conn: conn.execute(
        "INSERT INTO flashcard_stacks(name, subject, created_at, kind) VALUES ('Klausur', 'Analysis I', '2026-11-01', 'eigene')").lastrowid)
    _in_user(hosted, he, lambda conn: conn.execute("INSERT INTO flashcards(subject, question, answer, created_at, box, due, stack_id) "
                                                   "VALUES ('Analysis I', 'Q', 'A', '2026-11-01', 1, '2026-11-01', ?)", (fs,)))
    d = _call(hosted, "POST", f"/api/flashcard-stacks/{fs}/share", headers=he, status=403)
    assert (d["code"], d["entitlement"], d["detail"]) == ("plan_required", "can_use_flashcards", "Karteikarten gibt es ab StudiNow Plus.")
    assert _call(hosted, "POST", f"/api/community/card-stacks/{g['id']}/adopt", headers=he, status=403)["entitlement"] == "can_use_flashcards"
    d = _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=he, status=403)
    assert (d["entitlement"], d["detail"]) == ("can_read_community", "Die Community gibt es ab StudiNow Plus.")
    # Konto loeschen zieht die eigenen Stapel zurueck
    from app import community_cards
    assert community_cards.forget_author(ada["id"]) == 2
    assert _call(hosted, "GET", f"/api/community/card-stacks?module={key}", headers=hb)["stacks"] == []


def test_sharing_needs_the_hosted_service(app):
    assert _call(app, "POST", "/api/flashcard-stacks/1/share", status=501)["code"] == "not_hosted"
    assert _call(app, "DELETE", "/api/flashcard-stacks/1/share", status=501)["code"] == "not_hosted"
    # /api/community/... leitet der Einzelplatz an den Dienst weiter (409 not_linked ohne Konto), wie bei Loesungen


def test_free_account_can_still_withdraw_its_shared_stack(hosted):
    """Zurueckziehen geht in jedem Tarif (wie bei Loesungen): nach dem Herabstufen auf Free bleibt nur das Teilen gesperrt,
    das eigene Geteilte laesst sich weiter aus der Community nehmen (04.11.2026)."""
    from app import accounts
    from app.solution_format import community_module_key
    ada, ha = user(hosted, "ada-frei@beispiel.de", plan="plus")
    _seed_user(hosted, ha)
    key = community_module_key("luh", "Analysis I")
    _member(hosted, ha, key)
    own = _stack_with_cards(hosted, ha, "Analysis I", week=3)
    sh = _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    accounts.set_plan(ada["id"], "free")
    w = _call(hosted, "DELETE", f"/api/flashcard-stacks/{own['id']}/share", headers=ha)
    assert w["withdrawn"] is True and w["stack"]["shared_id"] is None and sh["id"]
    # erneut teilen ist fuer Free gesperrt
    assert _call(hosted, "POST", f"/api/flashcard-stacks/{own['id']}/share", headers=ha, status=403)


def test_adopting_stacks_counts_plus_four_per_month_pro_ai_fair_use(hosted, monkeypatch):
    """Kontingent `card_stacks_adopted` (Entscheidung 05.11.2026): Plus uebernimmt 4 Stapel von StudiNow je Monat, der
    fuenfte antwortet 429 quota_exhausted; derselbe Stapel zaehlt einmal (vorhandene Kopie, Loeschen und erneut
    uebernehmen); Pro AI unbegrenzt (Fair Use 300)."""
    from app.solution_format import community_module_key
    monkeypatch.setenv("LERNAPP_LIMIT_DECK_USER", "100/1440")
    ada, ha = user(hosted, "ada-kontingent@beispiel.de", plan="plus")
    ben, hb = user(hosted, "ben-kontingent@beispiel.de", plan="plus")
    cleo, hc = user(hosted, "cleo-kontingent@beispiel.de", plan="pro_ai")
    key = community_module_key("luh", "Analysis I")
    for h in (ha, hb, hc):
        _seed_user(hosted, h)
        _member(hosted, h, key)
    shared = [_call(hosted, "POST", f"/api/flashcard-stacks/{_stack_with_cards(hosted, ha, 'Analysis I', name=f'S{i}', week=i + 1)['id']}/share",
                    headers=ha)["id"] for i in range(5)]
    first = _call(hosted, "POST", f"/api/community/card-stacks/{shared[0]}/adopt", headers=hb)
    for sid in shared[1:4]:
        assert _call(hosted, "POST", f"/api/community/card-stacks/{sid}/adopt", headers=hb)["already"] is False
    q = _call(hosted, "GET", "/api/entitlements", headers=hb)["quotas"]["card_stacks_adopted"]
    assert (q["used"], q["limit"]) == (4, 4)
    d = _call(hosted, "POST", f"/api/community/card-stacks/{shared[4]}/adopt", headers=hb, status=429)
    assert (d["code"], d["feature"], d["detail"]) == (
        "quota_exhausted", "card_stacks_adopted",
        "Karteikarten-Stapel von StudiNow (Wochenstapel und geteilte Stapel): Kontingent für diesen Monat aufgebraucht (4 von 4).")
    assert _call(hosted, "POST", f"/api/community/card-stacks/{shared[0]}/adopt", headers=hb)["already"] is True, "vorhandene Kopie"
    _call(hosted, "DELETE", f"/api/flashcard-stacks/{first['stack']['id']}", headers=hb)
    assert _call(hosted, "POST", f"/api/community/card-stacks/{shared[0]}/adopt", headers=hb)["already"] is False, "derselbe Stapel zaehlt einmal"
    for sid in shared:
        _call(hosted, "POST", f"/api/community/card-stacks/{sid}/adopt", headers=hc)
    q = _call(hosted, "GET", "/api/entitlements", headers=hc)["quotas"]["card_stacks_adopted"]
    assert (q["used"], q["limit"], q["unlimited"]) == (5, 300, True)
