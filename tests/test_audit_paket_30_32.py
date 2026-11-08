"""Audit-Pakete 30-32 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-30-32.md): KI-Tutor und Karteikarten
(`_tutor_*`, `_ai_flashcards_*`, `_flashcards_*`, `_page_list`, `_stack_name`), Stapel, Wochenplan und Tests (`get_test`,
`week_stack_get_or_generate`, `get_plan`, `add_item`/`patch_item`, `gen_test`) sowie Seitenmarker, Wochentests, Demo,
Einstellungen und StudiNow-Konto der Windows-App (`api_marker_*`, `api_weekly_*`, `demo_toggle`, `put_settings`,
`_public_settings`). Dienst zuerst, dann PC. Keine echten KI-Aufrufe: Attrappen wie in tests/test_ai_lastfest.py."""
import asyncio
import json
import sqlite3
import threading
import time

import pytest
from conftest import asgi_call
from test_ai_abuse import trial_account
from test_ai_lastfest import asgi_acall
from test_flashcards_hosted import FakeCardsAI
from test_subscriptions import FakeAI, _j, ent, hosted, user  # noqa: F401 - hosted ist eine Fixture


def call(app, method, path, body=None, headers=None):
    """Wie asgi_call, aber ein durchgereichter Fehler zaehlt als 500 (so antwortet uvicorn)."""
    raw = body if isinstance(body, (str, bytes)) or body is None else json.dumps(body)
    try:
        st, _, b = asgi_call(app, method, path, body=raw, headers=headers)
    except Exception as e:  # noqa: BLE001
        return 500, {"exception": repr(e)}
    try:
        return st, (json.loads(b) if b else None)
    except ValueError:
        return st, b


def in_user(app, headers, fn):
    """fn(conn) in der Datenbank des Kontos"""
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


def seed_doc(conn, file_id="f-audit", pages=None):
    """Kurs, Modul und Dokument; Seitentexte im Index (page_texts)"""
    mid = conn.execute("INSERT INTO modules(name) VALUES ('Audit Modul')").lastrowid
    conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id) VALUES ('c-audit', 'Audit Kurs', 'vorlesung', 1, ?)", (mid,))
    conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, kind) VALUES (?, 'c-audit', 'Audit.pdf', 'neu', 'pdf')", (file_id,))
    return mid


@pytest.fixture
def doc_pages(monkeypatch):
    from app import scriptsearch
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: ["Seite eins Matrizen", "Seite zwei Determinanten",
                                                                                      "Seite drei Eigenwerte"])


def used(app, h, feature="ai_assist"):
    return ent(app, h)["quotas"][feature]["used"]


def ledger(uid):
    from app import credits
    conn = credits.connect()
    try:
        return conn.execute("SELECT request_id, state, charged FROM credit_ledger WHERE user_id=? ORDER BY rowid", (uid,)).fetchall()
    finally:
        conn.close()


# ================================================================== PAKET 30

# ---------------------------------------------------------------- P30-01 / P30-05 / P30-06: Eingaben des Tutors

BAD_TUTOR = [
    ("page", "abc"), ("page", [1]), ("page", {"x": 1}), ("page", 0), ("page", 10 ** 12), ("page", True),
    ("page_text", 123), ("page_text", ["Text"]), ("selection", 123), ("question", []), ("own_solution", {"a": 1}),
    ("mode", ["explain"]), ("mode", 7),
]


@pytest.mark.parametrize("field,value", BAD_TUTOR)
def test_p30_01_05_06_tutor_rejects_wrong_types_with_422_in_the_service(hosted, field, value):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    u, h = trial_account(hosted, f"tutor-{field}@beispiel.de")
    body = {"mode": "explain", "page_text": "Was ist eine Matrix?", "request_id": "bad-1", "file_id": None, field: value}
    st, d = call(hosted, "POST", "/api/ai/tutor", body, headers=h)
    assert st == 422, (field, value, st, d)
    assert fake.calls == 0 and used(hosted, h) == 0, "vor der KI und vor dem Kontingent abgewiesen"


@pytest.mark.parametrize("field,value", [("page", "abc"), ("page_text", 123), ("selection", 5), ("question", [])])
def test_p30_01_05_06_tutor_rejects_wrong_types_with_422_on_the_pc(app, monkeypatch, field, value):
    from app import ai

    def no_ai(*a, **k):
        raise AssertionError("KI darf nicht gefragt werden")
    monkeypatch.setattr(ai, "tutor", no_ai)
    st, d = call(app, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": "Matrix", field: value})
    assert st == 422, (field, st, d)


def test_p30_01_tutor_still_takes_numeric_page_strings_and_null(hosted):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, h = trial_account(hosted, "tutor-ok@beispiel.de")
    for i, page in enumerate(("2", 3, None)):
        st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": f"Matrix {i}", "page": page, "request_id": f"ok-{i}",
                                                       "selection": None, "question": ""}, headers=h)
        assert st == 200, (page, d)


def test_p30_05_long_page_text_is_cut_in_the_prompt(hosted):
    """Laenge: der Prompt kuerzt den Seitentext (ai.tutor_prompt), die Anfrage selbst begrenzt die Middleware."""
    from app import ai_backend

    class Seen(FakeAI):
        def complete(self, system, prompt, schema=None):
            self.prompt = prompt
            return super().complete(system, prompt, schema)
    fake = Seen()
    ai_backend.set_provider(fake)
    _, h = trial_account(hosted, "tutor-lang@beispiel.de")
    st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": "x" * 400_000, "request_id": "lang"}, headers=h)
    assert st == 200, d
    assert len(fake.prompt) < 60_000, len(fake.prompt)


# ---------------------------------------------------------------- P30-02: Erklaerungsspeicher und zwei Konten

def test_p30_02_explanations_stay_in_the_account_database(hosted):
    """Der Erklaerungsspeicher (explain_local) liegt in der Datenbank des Kontos; ein zweites Konto findet dort nichts.
    Der gemeinsame Zwischenspeicher der StudiNow-KI trifft nur denselben Seitentext (P9-01: wer trifft, hat den Text schon)."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, ha = trial_account(hosted, "erkl-a@beispiel.de")
    _, hb = trial_account(hosted, "erkl-b@beispiel.de")
    secret = "Notiz von Erika Musterfrau, Matrikel 1234567: Eigenwerte"
    st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": secret, "request_id": "a-1"}, headers=ha)
    assert st == 200 and d["explain"] is not None
    count = lambda conn: conn.execute("SELECT COUNT(*) FROM page_explain_local").fetchone()[0]  # noqa: E731
    assert in_user(hosted, ha, count) == 1
    st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": "Etwas ganz anderes", "request_id": "b-1"}, headers=hb)
    assert st == 200 and "Musterfrau" not in json.dumps(d)
    assert in_user(hosted, hb, lambda conn: conn.execute("SELECT COUNT(*) FROM page_explain_local WHERE answer LIKE '%Musterfrau%'").fetchone()[0]) == 0
    # mit Frage, Markierung oder eigenen Notizen nie in einen Speicher
    st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": secret + " 2", "own_notes": "privat", "request_id": "a-2"},
                 headers=ha)
    assert st == 200 and d["explain"] is None and in_user(hosted, ha, count) == 1


# ---------------------------------------------------------------- P30-03: unbrauchbare Karten

def test_p30_03_unusable_cards_refund_the_quota_and_bill_the_credits(hosted, doc_pages):
    """Abrechnungsregel (festgenagelt, docs/KARTEIKARTEN-STAPEL-2026-11-04.md): keine brauchbaren Karten -> 502 ai_no_cards,
    `ai_assist` zurueck, die Credits der Anbieter-Antwort bleiben berechnet. Dieselbe request_id kostet nichts mehr."""
    from app import ai_backend
    ai_backend.set_provider(FakeCardsAI(empty=True))
    u, h = user(hosted, "leer@beispiel.de", plan="pro_ai")
    in_user(hosted, h, seed_doc)
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"file_id": "f-audit", "count": 5, "request_id": "leer-1"}, headers=h)
    assert (st, d["code"]) == (502, "ai_no_cards") and used(hosted, h) == 0
    assert [(r[0], r[1]) for r in ledger(u["id"])] == [("leer-1", "settled")]
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"file_id": "f-audit", "count": 5, "request_id": "leer-1"}, headers=h)
    assert (st, d["code"]) == (502, "ai_no_cards") and len(ledger(u["id"])) == 1 and used(hosted, h) == 0


def test_p30_03_unusable_answer_does_not_stay_in_the_shared_cache(hosted, doc_pages):
    """Eine unbrauchbare Antwort im gemeinsamen Zwischenspeicher blieb fuer alle mit demselben Dokument CACHE_DAYS lang
    die Antwort: jedes weitere Konto bekam 502 ai_no_cards, ohne dass die KI noch einmal gefragt wurde."""
    from app import ai_backend
    bad = FakeCardsAI(empty=True)
    ai_backend.set_provider(bad)
    _, ha = user(hosted, "gift-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "gift-b@beispiel.de", plan="pro_ai")
    in_user(hosted, ha, seed_doc)
    in_user(hosted, hb, seed_doc)
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"file_id": "f-audit", "count": 5, "request_id": "g-a"}, headers=ha)
    assert (st, d["code"]) == (502, "ai_no_cards")
    good = FakeCardsAI()
    ai_backend.set_provider(good)
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"file_id": "f-audit", "count": 5, "request_id": "g-b"}, headers=hb)
    assert st == 200 and len(d["cards"]) == 5 and good.calls == 1, (st, d, good.calls)


def test_p30_03_unusable_order_answer_does_not_stay_in_the_shared_cache(hosted, monkeypatch):
    from test_flashcards_hosted import seed
    from app import ai_backend, scriptsearch
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: ["Determinante Leibniz-Formel", "Laplace-Entwicklung"])
    ai_backend.set_provider(FakeCardsAI(empty=True))
    _, ha = user(hosted, "auftrag-a@beispiel.de", plan="pro_ai")
    mid = seed(hosted, ha)
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"module_id": mid, "week": 3, "count": 5, "request_id": "o-1"}, headers=ha)
    assert (st, d["code"]) == (502, "ai_no_cards")
    good = FakeCardsAI()
    ai_backend.set_provider(good)
    st, d = call(hosted, "POST", "/api/ai/flashcards", {"module_id": mid, "week": 3, "count": 5, "request_id": "o-2"}, headers=ha)
    assert st == 200 and good.calls == 1, (st, d)


# ---------------------------------------------------------------- P30-04 / P30-07: Umfang

def test_p30_07_client_material_is_bounded(hosted):
    from app import flashcard_order as fo
    big = [{"title": "T" * 5000, "text": "x" * 1_000_000}] * 100 + [None, 3, {"text": 5}, {"title": [], "text": "ok"}]
    m = fo.client_material(big)
    assert len(m["text"]) <= fo.STACK_TEXT_CHARS + 31 * 210 and len(m["sources"]) <= 30
    assert fo.client_material("kein Material")["text"] == "" and fo.client_material(None)["text"] == ""


# ---------------------------------------------------------------- P30-08: Speicher scheitert nach der KI-Antwort

def test_p30_08_answer_survives_a_failing_explanation_store(hosted, monkeypatch):
    from app import ai_backend, explain_local
    ai_backend.set_provider(FakeAI())
    _, h = trial_account(hosted, "speicher@beispiel.de")

    def locked(*a, **k):
        raise sqlite3.OperationalError("database is locked")
    monkeypatch.setattr(explain_local, "store", locked)
    st, d = call(hosted, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": "Gesperrt", "request_id": "s-1"}, headers=h)
    assert st == 200 and d["answer"].startswith("Erklärung") and d["credits"]["charged"] >= 0, d


def test_p30_08_answer_survives_a_failing_explanation_store_on_the_pc(app, monkeypatch):
    from app import ai, explain_local, explain_service
    monkeypatch.setattr(ai, "tutor", lambda *a, **k: "Erklärung vom PC")
    monkeypatch.setattr(explain_service, "lookup", lambda *a, **k: None)
    monkeypatch.setattr(explain_service, "publish_later", lambda *a, **k: None)
    monkeypatch.setattr(explain_local, "lookup", lambda *a, **k: None)

    def locked(*a, **k):
        raise sqlite3.OperationalError("database is locked")
    monkeypatch.setattr(explain_local, "store", locked)
    st, d = call(app, "POST", "/api/ai/tutor", {"mode": "explain", "page_text": "Gesperrt PC"})
    assert st == 200 and d["answer"] == "Erklärung vom PC", d


# ---------------------------------------------------------------- P30-09: Abbruch waehrend der Anbieter antwortet

class SlowAsync:
    def __init__(self, cards=False):
        self.calls, self.entered, self.cards = 0, None, cards

    async def acomplete(self, system, prompt, schema=None, **opts):
        from app.ai_backend import Completion
        self.calls += 1
        if self.entered is not None:
            self.entered.set()
            await asyncio.sleep(30)
        text = json.dumps({"cards": [{"question": "F?", "answer": "A"}]}) if self.cards else "Erklärung nach Abbruch."
        return Completion(text, 100, 30, "fake-async")


def _cancel_midway(app, h, path, body, fake):
    async def run():
        fake.entered = asyncio.Event()
        task = asyncio.create_task(asgi_acall(app, "POST", path, body=json.dumps(body), headers=h))
        await asyncio.wait_for(fake.entered.wait(), 10)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(run())
    from app import ai_async
    ai_async.wait_detached()      # Aufraeumen laeuft unabhaengig von der Schleife in eigenem Thread
    fake.entered = None


def test_p30_09_cancelled_tutor_request_gives_the_quota_back(hosted):
    from app import ai_backend
    fake = SlowAsync()
    ai_backend.set_provider(fake)
    u, h = trial_account(hosted, "abbruch-t@beispiel.de")
    body = {"mode": "explain", "page_text": "Abbruch", "request_id": "ab-1"}
    _cancel_midway(hosted, h, "/api/ai/tutor", body, fake)
    assert used(hosted, h) == 0, "Kontingent ai_assist bleibt bei Abbruch nicht belegt"
    assert [r[1] for r in ledger(u["id"])] == ["refunded"]
    st, d = call(hosted, "POST", "/api/ai/tutor", body, headers=h)
    assert st == 200 and d["answer"].startswith("Erklärung"), "dieselbe request_id geht nach dem Abbruch wieder (vorher 409)"
    assert used(hosted, h) == 1


def test_p30_09_cancelled_flashcards_request_gives_the_quota_back(hosted, doc_pages):
    from app import ai_backend
    fake = SlowAsync(cards=True)
    ai_backend.set_provider(fake)
    _, h = user(hosted, "abbruch-k@beispiel.de", plan="pro_ai")
    in_user(hosted, h, seed_doc)
    body = {"file_id": "f-audit", "count": 5, "request_id": "ab-k"}
    _cancel_midway(hosted, h, "/api/ai/flashcards", body, fake)
    assert used(hosted, h) == 0
    st, d = call(hosted, "POST", "/api/ai/flashcards", body, headers=h)
    assert st == 200 and d["cards"], d


# ---------------------------------------------------------------- P30-10: Seitenauswahl

def test_p30_10_explicit_page_choice_without_a_valid_page_is_422(app, monkeypatch, doc_pages):
    from app import ai, db
    db.init_db()
    with db.cursor() as conn:
        seed_doc(conn, "f-p30-10")
    calls = []
    monkeypatch.setattr(ai, "ask", lambda prompt, system, schema=None: calls.append(1) or '{"cards": [{"question": "F?", "answer": "A"}]}')
    try:
        for pages in ([9999], ["x"], [0, -1], "1-3", 5):
            st, d = call(app, "POST", "/api/ai/flashcards", {"file_id": "f-p30-10", "pages": pages})
            assert st == 422, (pages, st, d)
        assert calls == []
        for pages, want in ((None, [1, 2, 3]), ([], [1, 2, 3]), ([3, 9999, "2"], [2, 3])):
            st, d = call(app, "POST", "/api/ai/flashcards", {"file_id": "f-p30-10", "pages": pages})
            assert st == 200 and d["pages"] == want, (pages, d)
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM files WHERE id='f-p30-10'")


# ---------------------------------------------------------------- P30-11 / P30-12: Stapelname, Lehrwoche

def test_p30_11_stack_name_has_a_limit(hosted):
    _, h = user(hosted, "name@beispiel.de", plan="plus")
    st, d = call(hosted, "POST", "/api/flashcard-stacks", {"name": "N" * 5000}, headers=h)
    assert st == 422, (st, d)
    st, d = call(hosted, "POST", "/api/flashcard-stacks", {"name": "  " + "N" * 120 + "  "}, headers=h)
    assert st == 200 and d["name"] == "N" * 120
    st, d = call(hosted, "PATCH", f"/api/flashcard-stacks/{d['id']}", {"name": "M" * 121}, headers=h)
    assert st == 422


def test_p30_12_week_value_takes_any_positive_integer_documented(hosted):
    """Designfrage, unveraendert: die Lehrwoche eines Stapels ist jede ganze Zahl ab 1 (Kern: FlashcardEndpoints)."""
    _, h = user(hosted, "woche@beispiel.de", plan="plus")
    st, d = call(hosted, "POST", "/api/flashcard-stacks", {"name": "W", "week": 999999999}, headers=h)
    assert st == 200 and d["week"] == 999999999
    for bad in (0, -1, "3", 2.5, True):
        assert call(hosted, "POST", "/api/flashcard-stacks", {"name": "W", "week": bad}, headers=h)[0] == 422, bad


# ================================================================== PAKET 31

# ---------------------------------------------------------------- Zwei Konten: fremde IDs

def test_p31_foreign_ids_never_reach_another_account(hosted):
    """Jedes Konto hat seine eigene Datenbank: dieselbe Zahl als ID trifft im zweiten Konto nie die Zeile des ersten
    (Karte, Stapel, Planeintrag, Test) - weder lesen noch aendern noch loeschen."""
    _, ha = user(hosted, "konto-a@beispiel.de", plan="plus")
    _, hb = user(hosted, "konto-b@beispiel.de", plan="plus")
    st, stack = call(hosted, "POST", "/api/flashcard-stacks", {"name": "Geheim A"}, headers=ha)
    assert st == 200
    st, d = call(hosted, "POST", "/api/flashcards", {"stack_id": stack["id"], "cards": [{"question": "A-Frage", "answer": "A-Antwort"}]}, headers=ha)
    assert st == 200
    card = call(hosted, "GET", "/api/flashcards", headers=ha)[1][0]
    st, item = call(hosted, "POST", "/api/plan/items", {"day": 1, "title": "A lernt"}, headers=ha)
    assert st == 200
    tid = in_user(hosted, ha, lambda conn: conn.execute(
        "INSERT INTO tests(subject, title, questions, created_at) VALUES ('S', 'A-Test', '[]', '2026-11-08')").lastrowid)
    assert call(hosted, "GET", "/api/flashcards", headers=hb)[1] == []
    assert call(hosted, "PATCH", f"/api/flashcards/{card['id']}", {"question": "B war hier"}, headers=hb)[0] == 404
    assert call(hosted, "POST", f"/api/flashcards/{card['id']}/review", {"correct": True}, headers=hb)[0] == 404
    assert call(hosted, "DELETE", f"/api/flashcards/{card['id']}", headers=hb)[0] == 404
    assert call(hosted, "PATCH", f"/api/flashcard-stacks/{stack['id']}", {"name": "B"}, headers=hb)[0] == 404
    assert call(hosted, "DELETE", f"/api/flashcard-stacks/{stack['id']}", headers=hb)[0] == 404
    assert call(hosted, "POST", "/api/flashcards", {"stack_id": stack["id"], "cards": [{"question": "q", "answer": "a"}]}, headers=hb)[0] == 404
    assert call(hosted, "PATCH", f"/api/plan/items/{item['id']}", {"title": "B"}, headers=hb)[0] == 404
    assert call(hosted, "DELETE", f"/api/plan/items/{item['id']}", headers=hb)[0] == 404
    assert call(hosted, "GET", f"/api/tests/{tid}", headers=hb)[0] == 404
    assert call(hosted, "DELETE", f"/api/tests/{tid}", headers=hb)[0] == 404
    # A unveraendert
    assert call(hosted, "GET", "/api/flashcards", headers=ha)[1][0]["question"] == "A-Frage"
    assert call(hosted, "GET", "/api/plan", headers=ha)[1]["items"][0]["title"] == "A lernt"


# ---------------------------------------------------------------- P31-01: Loesungen vor der Abgabe

def test_p31_01_unsubmitted_test_shows_no_solutions_and_no_answers(hosted):
    _, h = user(hosted, "test-los@beispiel.de", plan="plus")
    q = [{"nr": 1, "type": "mc", "question": "Was?", "options": ["a", "b"], "answer": "b", "steps": "x", "rubric": "r", "refs": [1],
          "from_exam": "WS25", "exam_mode": "x", "explanation": "weil", "blank": "b", "points": 5}]
    tid = in_user(hosted, h, lambda conn: conn.execute("INSERT INTO tests(subject, title, questions, created_at) VALUES ('S', 'T', ?, '2026-11-08')",
                                                       (json.dumps(q),)).lastrowid)
    st, t = call(hosted, "GET", f"/api/tests/{tid}", headers=h)
    assert st == 200 and t["answers"] == {} and t["feedback"] is None
    assert set(t["questions"][0]) == {"nr", "type", "question", "options", "points"}, t["questions"][0]
    assert "weil" not in json.dumps(t)


# ---------------------------------------------------------------- P31-02 / P31-10: Wochenstapel doppelt erzeugt

def test_p31_02_parallel_week_stack_requests_generate_once(hosted, monkeypatch):
    from test_flashcard_share import _seed, _clean
    from app import ai_backend

    class Slow(FakeCardsAI):
        def complete(self, system, prompt, schema=None):
            from app.ai_backend import Completion
            with self.lock:
                self.calls += 1
            time.sleep(0.6)
            return Completion(json.dumps({"cards": [{"question": f"F{self.calls}", "answer": "A"}]}), 100, 30, "fake")
    fake = Slow()
    ai_backend.set_provider(fake)
    u, h = user(hosted, "doppel@beispiel.de", plan="pro_ai")

    def prep(conn):
        _clean(conn)
        mid = _seed(conn, files=(("f-vl5", "VL05.pdf", "vorlesung", "vl5"),))
        conn.execute("UPDATE files SET content_sha256=NULL WHERE id='f-vl5'")     # ohne Inhalts-Hash: eigener Stapel
        return mid
    mid = in_user(hosted, h, prep)
    out = []
    ts = [threading.Thread(target=lambda: out.append(call(hosted, "POST", f"/api/flashcard-stacks/week/{mid}/5/vorlesung", headers=h)))
          for _ in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(30)
    assert sorted(st for st, _ in out) == [200, 200], out
    assert sorted(d["status"] for _, d in out) == ["exists", "unshared"], out
    assert fake.calls == 1, f"{fake.calls} KI-Aufrufe fuer einen Stapel"
    assert [r[1] for r in ledger(u["id"])] == ["settled"], ledger(u["id"])
    assert in_user(hosted, h, lambda conn: conn.execute("SELECT COUNT(*) FROM flashcard_stacks").fetchone()[0]) == 1


# ---------------------------------------------------------------- P31-03 / P31-04 / P31-08: Kartenvertrag

def test_p31_03_04_08_card_inputs_are_pinned_by_the_core_contract():
    """Bestaetigt, aber Vertrag des Kerns (packages/shared-contracts/fixtures/local-backend/flashcards.json, gegen den
    UniFlowCore LocalBackend prueft): {"correct": "false"} zaehlt als richtig, `cards: "Frage"` gibt 500, `count` zaehlt
    auch uebersprungene Eintraege. Eine Aenderung gehoert in Python UND Swift zugleich (Designfrage im Bericht)."""
    from pathlib import Path
    fx = json.loads((Path(__file__).resolve().parents[1] / "packages/shared-contracts/fixtures/local-backend/flashcards.json").read_text())
    steps = [s for sc in fx["scenarios"] for s in sc.get("steps", [])]
    by = {(s["method"], s["path"], s["raw"]): s for s in steps}
    assert by[("POST", "/api/flashcards/3/review", '{"correct": "false"}')]["response"]["box"] == 2
    assert by[("POST", "/api/flashcards", '{"cards": "Frage"}')]["status"] == 500


# ---------------------------------------------------------------- P31-05 / P31-06 / P31-12: Wochenplan

@pytest.mark.parametrize("week", ["abc", "2026-13-01", "2026-11-08T10:00"])
def test_p31_05_plan_with_invalid_week_is_422(hosted, week):
    _, h = user(hosted, f"plan-{week[:4]}{len(week)}@beispiel.de")
    st, d = call(hosted, "GET", f"/api/plan?week={week}", headers=h)
    assert st == 422, (st, d)


@pytest.mark.parametrize("body", [{"day": "abc"}, {"day": 99}, {"day": -1}, {"duration_min": "x"}, {"duration_min": -5}, {"duration_min": 100000},
                                  {"start_time": "25:99"}, {"start_time": 900}, {"title": ["x"]}, {"week_start": "morgen"}, {"day": True}])
def test_p31_06_plan_item_inputs_are_checked(hosted, body):
    _, h = user(hosted, f"item-{abs(hash(json.dumps(body))) % 10 ** 8}@beispiel.de")
    st, d = call(hosted, "POST", "/api/plan/items", {"title": "Lernen", **body}, headers=h)
    assert st == 422, (body, st, d)
    st, item = call(hosted, "POST", "/api/plan/items", {"title": "Lernen", "day": 2, "start_time": "10:15", "duration_min": 45}, headers=h)
    assert st == 200 and (item["day"], item["start_time"], item["duration_min"]) == (2, "10:15", 45)
    st, d = call(hosted, "PATCH", f"/api/plan/items/{item['id']}", body, headers=h)
    if set(body) <= {"week_start"}:
        assert st == 200                       # week_start laesst sich nicht aendern (nicht in der Liste)
    else:
        assert st == 422, (body, st, d)


def test_p31_06_12_plan_item_patch_works_and_unknown_is_404(hosted):
    _, h = user(hosted, "patch-item@beispiel.de")
    st, item = call(hosted, "POST", "/api/plan/items", {"title": "Lernen"}, headers=h)
    assert st == 200 and item["day"] == 0 and item["duration_min"] == 60
    st, d = call(hosted, "PATCH", f"/api/plan/items/{item['id']}", {"day": 6, "done": True, "duration_min": 30, "sort_order": 2, "x": 1}, headers=h)
    assert st == 200 and (d["day"], d["done"], d["duration_min"], d["sort_order"]) == (6, 1, 30, 2), d
    st, d = call(hosted, "PATCH", "/api/plan/items/987654", {"title": "x"}, headers=h)
    assert st == 404, (st, d)


# ---------------------------------------------------------------- P31-07: Test erzeugen (nur PC)

def test_p31_07_generate_test_is_501_in_the_service(hosted):
    _, h = user(hosted, "gen@beispiel.de", plan="pro_ai")
    assert call(hosted, "POST", "/api/tests/generate", {"module_id": "xyz"}, headers=h)[0] == 501


@pytest.mark.parametrize("body", [{"module_id": "xyz"}, {"subject": "S", "duration_min": "xyz"}, {"subject": "S", "week_no": "xyz"},
                                  {"module_id": [1]}, {"subject": "S", "duration_min": -5}])
def test_p31_07_generate_test_rejects_wrong_numbers_on_the_pc(app, monkeypatch, body):
    from app import planner
    monkeypatch.setattr(planner, "create_test", lambda *a, **k: (_ for _ in ()).throw(AssertionError("nicht erzeugen")))
    st, d = call(app, "POST", "/api/tests/generate", body)
    assert st == 422, (body, st, d)


# ---------------------------------------------------------------- P31-09: Stapel loeschen

def test_p31_09_delete_stack_without_target_deletes_its_cards_documented(hosted):
    _, h = user(hosted, "loeschen@beispiel.de", plan="plus")
    _, s1 = call(hosted, "POST", "/api/flashcard-stacks", {"name": "Eins"}, headers=h)
    _, s2 = call(hosted, "POST", "/api/flashcard-stacks", {"name": "Zwei"}, headers=h)
    call(hosted, "POST", "/api/flashcards", {"stack_id": s1["id"], "cards": [{"question": "q", "answer": "a"}]}, headers=h)
    assert call(hosted, "DELETE", f"/api/flashcard-stacks/{s1['id']}?move_to={s1['id']}", headers=h)[0] == 422
    st, d = call(hosted, "DELETE", f"/api/flashcard-stacks/{s1['id']}?move_to={s2['id']}", headers=h)
    assert st == 200 and (d["moved"], d["deleted"]) == (1, 0)
    st, d = call(hosted, "DELETE", f"/api/flashcard-stacks/{s2['id']}", headers=h)
    assert st == 200 and (d["moved"], d["deleted"]) == (0, 1)


# ================================================================== PAKET 32

# ---------------------------------------------------------------- P32-01 / P32-05: Seitenmarker

def _marker_fixture(conn):
    from app import weekly
    weekly.ensure_schema(conn)
    mid = conn.execute("INSERT INTO modules(name) VALUES ('Marker Modul')").lastrowid
    conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id) VALUES ('c-mk', 'Marker Kurs', 'vorlesung', 1, ?)", (mid,))
    conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, kind) VALUES ('f-mk', 'c-mk', 'VL01.pdf', 'neu', 'pdf')")
    cols = {"user_id": "local", "module_id": mid, "file_id": "f-mk", "doc_version": "v1", "page": 3, "page_fingerprint": "fp", "page_count": 10,
            "lecture_date": "2026-10-20", "iso_week": "2026-W43", "week_no": 1, "topic": "T", "scope": "personal", "created_at": "2026-10-20T10:00:00"}
    return conn.execute(f"INSERT INTO lecture_markers({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", list(cols.values())).lastrowid


@pytest.mark.parametrize("confirm", ["false", "true", 1, "ja", [True]])
def test_p32_01_marker_release_needs_a_real_true(hosted, confirm):
    _, h = user(hosted, f"marker-{abs(hash(str(confirm))) % 10 ** 6}@beispiel.de")
    mk = in_user(hosted, h, _marker_fixture)
    st, d = call(hosted, "POST", f"/api/markers/{mk}/release", {"confirm": confirm}, headers=h)
    assert st == 400 and "bestätigt" in d["detail"], (confirm, st, d)
    assert in_user(hosted, h, lambda conn: conn.execute("SELECT COUNT(*) FROM lecture_markers WHERE scope='course'").fetchone()[0]) == 0


def test_p32_01_marker_release_with_true_still_works(hosted, monkeypatch):
    from app import weekly
    monkeypatch.setattr(weekly, "_check_order", lambda *a, **k: None)
    _, h = user(hosted, "marker-ok@beispiel.de")
    mk = in_user(hosted, h, _marker_fixture)
    st, d = call(hosted, "POST", f"/api/markers/{mk}/release", {"confirm": True}, headers=h)
    assert st == 200 and d["scope"] == "course", d


@pytest.mark.parametrize("method,path,body", [
    ("POST", "/api/markers", {"file_id": "f-mk", "page": "abc"}),
    ("POST", "/api/markers", {"file_id": "f-mk", "page": [1]}),
    ("POST", "/api/markers", {"file_id": "f-mk", "page": 3, "lecture_date": "gestern"}),
    ("POST", "/api/markers", {"file_id": "f-mk", "page": 3, "lecture_date": 20261020}),
    ("PATCH", "/api/markers/{mk}", {"page": "abc"}),
    ("PATCH", "/api/markers/{mk}", {"lecture_date": "kein Datum"}),
    ("PATCH", "/api/markers/{mk}", {"topic": 5}),
])
def test_p32_05_marker_input_errors_are_422_not_500(hosted, method, path, body):
    _, h = user(hosted, f"mk5-{abs(hash(path + json.dumps(body))) % 10 ** 8}@beispiel.de")
    mk = in_user(hosted, h, _marker_fixture)
    st, d = call(hosted, method, path.format(mk=mk), body, headers=h)
    assert st == 422, (body, st, d)


def test_p32_05_internal_marker_errors_do_not_leak_details(hosted, monkeypatch):
    from app import weekly

    def boom(*a, **k):
        raise sqlite3.OperationalError("no such column: geheim_intern")
    monkeypatch.setattr(weekly, "def_details", boom)
    _, h = user(hosted, "mk-intern@beispiel.de")
    st, d = call(hosted, "GET", "/api/weekly/defs/1", headers=h)
    assert st == 500 and "geheim_intern" not in json.dumps(d), d


# ---------------------------------------------------------------- P32-02 / P32-06: Wochentest-Takt

def test_p32_02_weekly_tick_in_the_service_resets_only_the_own_account(hosted, monkeypatch):
    from app import jobs
    seen = []
    monkeypatch.setattr(jobs, "enqueue", lambda uid, kind, trigger: seen.append((uid, kind)) or {"status": "queued", "id": 1, "already": False})
    ua, ha = user(hosted, "tick-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "tick-b@beispiel.de", plan="pro_ai")

    def failed_plan(conn):
        from app import weekly
        weekly.ensure_schema(conn)
        conn.execute("INSERT INTO wt_plans(module_id, week_no, scope, scope_key, user_id, coverage, lecture_end, publish_at, deadline_at, status, attempts) "
                     "VALUES (1, 1, 'personal', 'k', 'local', '{}', '2026-11-01', '2026-11-01', '2026-11-08', 'fehlgeschlagen', 3)")
    in_user(hosted, ha, failed_plan)
    in_user(hosted, hb, failed_plan)
    st, d = call(hosted, "POST", "/api/weekly/tick", headers=ha)
    assert st == 200 and d["job_id"] == 1 and seen == [(ua["id"], "weekly")]
    att = lambda conn: conn.execute("SELECT attempts FROM wt_plans").fetchone()[0]  # noqa: E731
    assert in_user(hosted, ha, att) == 0 and in_user(hosted, hb, att) == 3, "nur das eigene Konto"


def test_p32_06_weekly_loop_never_starts_in_the_service(hosted, monkeypatch):
    from app import server
    started = []
    monkeypatch.delenv("LERNAPP_NO_SCHEDULER", raising=False)
    monkeypatch.setattr(server.threading, "Thread", lambda *a, **k: started.append(k) or type("T", (), {"start": lambda self: None})())
    server._start_weekly_loop()
    assert started == []


# ---------------------------------------------------------------- P32-04: Probeklausur

def test_p32_04_mock_exam_is_not_run_in_a_thread_of_the_service(hosted, monkeypatch):
    """Im Dienst lief die Probeklausur in einem Thread des Prozesses (_run_bg): ohne Konto-Kontext (Datenbank des
    Einzelplatzes, keine StudiNow-KI) und mit EINER Sperre fuer alle Konten. Jetzt 501 wie /api/tests/generate."""
    from app import server, weekly
    monkeypatch.setattr(weekly, "coverage", lambda conn, mid, **k: {"segments": [{"file_id": "x"}]})
    ran = []
    monkeypatch.setattr(server, "_run_bg", lambda name, fn: ran.append(name) or {"started": name})
    _, h = user(hosted, "probe@beispiel.de", plan="pro_ai")
    st, d = call(hosted, "POST", "/api/weekly/mock-exam", {"module_id": 1}, headers=h)
    assert st == 501 and d["code"] == "not_available_hosted" and ran == [], (st, d)


@pytest.mark.parametrize("body", [{"module_id": "abc"}, {"module_id": [1]}, {"module_id": 1, "full": "false"}, {"module_id": 1, "full": 1}])
def test_p32_04_mock_exam_inputs_on_the_pc(app, monkeypatch, body):
    from app import server, weekly
    monkeypatch.setattr(weekly, "coverage", lambda conn, mid, **k: {"segments": [{"file_id": "x"}]})
    ran = []
    monkeypatch.setattr(server, "_run_bg", lambda name, fn: ran.append(name) or {"started": name})
    st, d = call(app, "POST", "/api/weekly/mock-exam", body)
    assert st == 422 and ran == [], (body, st, d)
    st, d = call(app, "POST", "/api/weekly/mock-exam", {"module_id": 1, "full": False})
    assert st == 200 and ran == ["Probeklausur"]


# ---------------------------------------------------------------- P32-03: Demo beenden

def test_p32_03_ending_the_demo_keeps_own_data(hosted):
    """Eigene Kurse, Karten und Notizen bleiben; eigene Karten in einem Stapel eines Demo-Dokuments landen wieder in
    einem eigenen Stapel (vorher verwaist: stack_id zeigte auf den geloeschten Stapel, in keiner Stapel-Liste mehr)."""
    _, h = user(hosted, "demo@beispiel.de", plan="plus")
    st, d = call(hosted, "POST", "/api/demo", {"enabled": True}, headers=h)
    assert st == 200 and d["enabled"] and d["files"] == 3

    def own(conn):
        conn.execute("INSERT INTO courses(id, title, kind, active, subject) VALUES ('c-echt', 'Echte Mathe', 'vorlesung', 1, 'Mathe')")
        conn.execute("INSERT INTO files(id, course_id, name, status) VALUES ('f-echt', 'c-echt', 'Echt.pdf', 'neu')")
        conn.execute("INSERT INTO annotations(file_id, data, updated_at) VALUES ('f-echt', '{}', '2026-11-08')")
    in_user(hosted, h, own)
    st, s = call(hosted, "POST", "/api/flashcard-stacks", {"name": "Mein Demo-Stapel", "file_id": "demo-skript", "subject": "Mathe"}, headers=h)
    assert st == 200
    call(hosted, "POST", "/api/flashcards", {"stack_id": s["id"], "cards": [{"question": "Meine Frage", "answer": "Meine Antwort"}]}, headers=h)
    call(hosted, "POST", "/api/flashcards", {"file_id": "f-echt", "cards": [{"question": "Echt", "answer": "ja"}]}, headers=h)
    st, d = call(hosted, "POST", "/api/demo", {"enabled": False, "thorough": True}, headers=h)
    assert st == 200 and not d["enabled"] and d["files"] == 0
    left = in_user(hosted, h, lambda conn: (conn.execute("SELECT COUNT(*) FROM files WHERE id='f-echt'").fetchone()[0],
                                            conn.execute("SELECT COUNT(*) FROM annotations WHERE file_id='f-echt'").fetchone()[0],
                                            conn.execute("SELECT COUNT(*) FROM courses WHERE id='c-echt'").fetchone()[0]))
    assert left == (1, 1, 1)
    stacks = call(hosted, "GET", "/api/flashcard-stacks", headers=h)[1]
    cards = call(hosted, "GET", "/api/flashcards", headers=h)[1]
    mine = [c for c in cards if c["question"] == "Meine Frage"]
    assert len(mine) == 1 and mine[0]["stack_id"] in {x["id"] for x in stacks}, (mine, stacks)
    assert sum(x["cards"] for x in stacks) == 2


# ---------------------------------------------------------------- P32-07 / P32-10: Einstellungen

def test_p32_07_settings_cannot_overwrite_the_lan_pin_or_the_share_id(app):
    from app import db, server
    pin = server._lan_pin()
    with db.cursor() as conn:
        before = conn.execute("SELECT value FROM settings WHERE key='share_user_id'").fetchone()
    st, d = call(app, "PUT", "/api/settings", {"lan_pin": "1", "share_user_id": "fremd", "theme": "dark"})
    assert st == 200 and d["theme"] == "dark" and "lan_pin" not in d
    with db.cursor() as conn:
        assert db.get_settings(conn)["lan_pin"] == pin
        assert conn.execute("SELECT value FROM settings WHERE key='share_user_id'").fetchone() == before
    call(app, "PUT", "/api/settings", {"theme": "auto"})


def test_p32_07_10_service_settings_stay_in_the_account(hosted):
    _, ha = user(hosted, "set-a@beispiel.de")
    _, hb = user(hosted, "set-b@beispiel.de")
    st, d = call(hosted, "PUT", "/api/settings", {"theme": "dark", "university": "hsh"}, headers=ha)
    assert (st, d["code"]) == (400, "use_account")
    st, d = call(hosted, "PUT", "/api/settings", {"theme": "dark", "ai_consent": '{"version": "x"}', "lan_pin": "1"}, headers=ha)
    assert st == 200 and d["theme"] == "dark" and "lan_pin" not in d
    assert call(hosted, "GET", "/api/settings", headers=hb)[1]["theme"] != "dark"
    assert in_user(hosted, ha, lambda conn: conn.execute("SELECT COUNT(*) FROM settings WHERE key='ai_consent'").fetchone()[0]) == 0


# ---------------------------------------------------------------- P32-08/09/12: StudiNow-Konto der Windows-App

@pytest.mark.parametrize("method,path", [("POST", "/api/studora/login"), ("POST", "/api/studora/sync"), ("GET", "/api/studora/devices"),
                                         ("POST", "/api/studora/claims")])
def test_p32_08_09_windows_account_paths_do_nothing_in_the_service(hosted, monkeypatch, method, path):
    from app import sync_client
    monkeypatch.setattr(sync_client, "start_background", lambda: (_ for _ in ()).throw(AssertionError("kein Abgleich im Dienst")))
    _, h = user(hosted, f"studora-{len(path)}{method}@beispiel.de")
    st, d = call(hosted, method, path, {"email": "x@y.de", "password": "p"} if method == "POST" else None, headers=h)
    assert st == 400 and d["code"] in ("already_hosted",), (st, d)
    assert call(hosted, "GET", "/api/studora/status", headers=h)[1] == {"linked": False, "hosted": True}
