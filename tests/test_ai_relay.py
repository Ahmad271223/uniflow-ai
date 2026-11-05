"""StudiNow-KI am PC ueber das Konto (app/ai_relay.py, 05.11.2026): die Windows-App baut den Prompt, der Dienst rechnet
mit Credits, Tarif, Kontingent und harter Obergrenze. "Dienst" ist dieselbe App im gehosteten Modus, direkt per ASGI
aufgerufen (wie tests/test_service_link.py); die KI des Dienstes ist eine Attrappe, `claude -p` darf nie laufen."""
import json
import shutil
import subprocess
import uuid

import pytest
from conftest import asgi_call

SERVICE = "http://127.0.0.1:9"


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


class CardsAI:
    """Attrappe der StudiNow-KI: Karteikarten bei Schema, Wochentest bei "Wochentest", sonst eine Erklaerung."""

    def __init__(self, week_test=None):
        self.calls, self.prompts, self.week_test = 0, [], week_test

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import Completion
        self.calls += 1
        self.prompts.append(prompt)
        if schema is not None:
            return Completion(json.dumps({"cards": [{"question": "Was ist ein Grenzwert?", "answer": "Der Wert, dem sich die Folge naehert."}]}), 120, 40, "fake")
        if prompt.startswith("Bewerte diesen Wochentest"):
            return Completion(json.dumps({"total": 6, "max": 10, "per_question": [], "summary": "Gut.", "weak_topics": []}), 120, 40, "fake")
        if self.week_test is not None and "Wochentest" in prompt:
            return Completion(json.dumps(self.week_test.pop(0) if isinstance(self.week_test, list) else self.week_test), 120, 40, "fake")
        return Completion("**Erklärung:** Ein Grenzwert ist der Wert, dem sich eine Folge annähert [1].", 120, 40, "fake")


@pytest.fixture
def pc(app, monkeypatch, tmp_path):
    """Lokale App (Einzelplatz, wie die Windows-App) plus Dienst (gehostet) im selben Prozess."""
    from app import accounts, ai_backend, community, config, db, service_link, sync_client, test_library, vault
    monkeypatch.setattr(sync_client, "start_background", lambda *a, **k: None)
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.delenv("LERNAPP_AI_CLI", raising=False)
    dbs = (accounts.db_path(), community.db_path(), test_library.db_path())

    def wipe():
        for p in dbs:
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
        shutil.rmtree(config.BASE_DATA_DIR / "users", ignore_errors=True)
    wipe()
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    service_link.state_path().unlink(missing_ok=True)
    calls = []

    def transport(method, url, headers, body, timeout):
        assert url.startswith(SERVICE), url
        path = url[len(SERVICE):]
        calls.append((method, path.split("?")[0]))
        old = config.MODE
        config.MODE = "hosted"
        try:
            hdrs = {k: v for k, v in headers.items() if k.lower() in ("authorization", "x-studinow-client")}
            st, h, b = asgi_call(app, method, path, body=body or b"", headers=hdrs,
                                 content_type=headers.get("Content-Type", "application/json"))
        finally:
            config.MODE = old
        return st, {k.decode(): v.decode() for k, v in h}, b

    monkeypatch.setattr(service_link, "transport", transport)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "lernapp.db")
    db.init_db()

    def no_cli(*a, **k):
        raise AssertionError("claude -p darf am PC mit Konto nicht laufen")
    monkeypatch.setattr(subprocess, "run", no_cli)
    from app import ai
    monkeypatch.setattr(ai, "uses_chatgpt", lambda: False)
    fake = CardsAI()
    ai_backend.set_provider(fake)
    yield app, calls, fake
    from app import ai_relay
    ai_relay.take()
    ai_backend.set_provider(None)
    service_link.state_path().unlink(missing_ok=True)
    wipe()
    vault.reset_master()


def account(app, email, plan="pro_ai", verified=True, trial=False):
    from app import accounts, config
    from test_subscriptions import end_trial
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    finally:
        config.MODE = old
    assert st == 201, d
    if not trial:
        end_trial(d["user"]["id"])
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plan != "free":
        accounts.set_plan(d["user"]["id"], plan)
    return d["user"]


def link(app, email):
    st, d = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": email, "password": "sehr-geheim-123"})))
    assert st == 200, d
    return d


def cheap_calls(monkeypatch):
    """Ein Aufruf der Attrappe (120+40 Tokens) kostet 8 Credits, Schaetzung fest 10 (wie tests/test_credits.py)."""
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    monkeypatch.setattr(ai_prices, "estimate_credits", lambda *a, **k: 10)


def tutor(app, **body):
    return _j(asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"page": 1, **body})))


# ---------------------------------------------------------------- Weg der KI

def test_source_order_and_no_cli_for_end_users(pc, monkeypatch):
    app, _, _ = pc
    from app import ai, ai_relay
    st, d = _j(asgi_call(app, "GET", "/api/ai/source"))
    assert (st, d["source"], d["linked"]) == (200, "cli", False), "Entwicklungsserver ohne Konto: Kommandozeile wie bisher"
    monkeypatch.setenv("LERNAPP_ACCOUNT_REQUIRED", "1")          # Windows-App: Konto-Pflicht
    assert ai.source() == "none" and not ai_relay.cli_enabled()
    with pytest.raises(ai.AIError, match="StudiNow-Konto"):
        ai.ask("Hallo", "")
    monkeypatch.setenv("LERNAPP_AI_CLI", "1")                    # Entwickler-Schalter
    assert ai.source() == "cli"
    monkeypatch.delenv("LERNAPP_AI_CLI")
    monkeypatch.delenv("LERNAPP_ACCOUNT_REQUIRED")
    account(app, "quelle@beispiel.de")
    link(app, "quelle@beispiel.de")
    assert ai.source() == "studinow"
    monkeypatch.setattr(ai, "uses_chatgpt", lambda: True)
    assert ai.source() == "chatgpt", "eigenes ChatGPT geht vor den Credits"


# ---------------------------------------------------------------- KI-Hilfe ueber den Dienst

def test_tutor_question_goes_to_the_service_and_returns_credits(pc, monkeypatch):
    app, calls, fake = pc
    cheap_calls(monkeypatch)
    account(app, "pro@beispiel.de")
    link(app, "pro@beispiel.de")
    st, d = tutor(app, mode="ask", page_text="Folge a_n = 1/n konvergiert gegen 0.", question="Warum ist der Grenzwert 0?", request_id="t1")
    assert st == 200, d
    assert "Grenzwert" in d["answer"] and fake.calls == 1
    assert ("POST", "/api/ai/relay") in calls
    assert d["credits"]["charged"] == 8 and d["credits"]["remaining"] == 92 and d["credits"]["allowance"] == 100
    assert "MEINE FRAGE: Warum ist der Grenzwert 0?" in fake.prompts[0], "der Prompt kommt vom PC wie fuer die eigene KI"
    # dieselbe request_id noch einmal: nicht doppelt berechnet
    st, d = tutor(app, mode="ask", page_text="Folge a_n = 1/n konvergiert gegen 0.", question="Warum ist der Grenzwert 0?", request_id="t1")
    assert st == 200 and d["credits"]["replay"] is True and fake.calls == 1


def test_whole_page_is_shared_and_costs_nothing_the_second_time(pc, monkeypatch):
    app, _, fake = pc
    cheap_calls(monkeypatch)
    account(app, "erster@beispiel.de")
    link(app, "erster@beispiel.de")
    page = "Satz von Bolzano: stetige Funktion mit Vorzeichenwechsel hat eine Nullstelle. " + uuid.uuid4().hex
    st, d = tutor(app, mode="explain", page_text=page)
    assert st == 200 and d["credits"]["charged"] == 8 and d["explain"]["stored"] is False
    # derselbe PC: eigener Erklaerungsspeicher, ohne Dienst
    st, d = tutor(app, mode="explain", page_text=page)
    assert st == 200 and d["explain"] == {**d["explain"], "stored": True, "source": "local"} and fake.calls == 1
    # anderer PC (eigener Speicher leer), anderes Konto: Zwischenspeicher der StudiNow-KI, 0 Credits
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM page_explain_local")
    account(app, "zweiter@beispiel.de")
    link(app, "zweiter@beispiel.de")
    st, d = tutor(app, mode="explain", page_text=page)
    assert st == 200, d
    assert fake.calls == 1, "keine neue KI-Anfrage"
    assert d["explain"]["stored"] is True and d["explain"]["source"] == "cloud"
    assert d["credits"]["charged"] == 0 and d["credits"]["remaining"] == 100
    # "Neu erklaeren lassen" fragt live
    st, d = tutor(app, mode="explain", page_text=page, force=True)
    assert st == 200 and fake.calls == 2 and d["credits"]["charged"] == 8


@pytest.mark.parametrize("case,status,code", [
    ("plus", 403, "plan_required"),
    ("unverified", 403, "email_unverified"),
    ("no_credits", 429, "credits_exhausted"),
    ("trial_over", 402, "subscription_required"),
])
def test_service_errors_reach_the_pc_unchanged(pc, monkeypatch, case, status, code):
    app, _, fake = pc
    cheap_calls(monkeypatch)
    if case == "no_credits":
        monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "0")
    plan = {"plus": "plus", "trial_over": "free"}.get(case, "pro_ai")
    account(app, f"{case}@beispiel.de", plan=plan, verified=case != "unverified")
    link(app, f"{case}@beispiel.de")
    st, d = tutor(app, mode="ask", page_text="Seite", question="Was steht hier?")
    assert (st, d["code"]) == (status, code), d
    assert isinstance(d["detail"], str) and d["detail"]
    if case == "plus":
        assert d["required_plan"] == "pro_ai"
    if case == "no_credits":
        assert d["detail"] == "Credits für diesen Monat aufgebraucht – am 1. gibt es neue." and d["credits"]["remaining"] == 0
    assert fake.calls == 0, "ohne Recht, Credits oder Abo kein Aufruf der KI"


def test_quota_exhausted_is_429_with_counts(pc, monkeypatch):
    app, _, fake = pc
    from app import plans
    monkeypatch.setitem(plans.QUOTAS, "pro_ai", {**plans.QUOTAS["pro_ai"], "ai_assist": 1})
    account(app, "kontingent@beispiel.de")
    link(app, "kontingent@beispiel.de")
    assert tutor(app, mode="ask", page_text="Seite", question="Eins?")[0] == 200
    st, d = tutor(app, mode="ask", page_text="Seite", question="Zwei?")
    assert (st, d["code"], d["used"], d["limit"]) == (429, "quota_exhausted", 1, 1), d
    assert fake.calls == 1


def test_unknown_task_and_oversized_prompt_are_refused_by_the_service(pc):
    app, _, fake = pc
    from app import ai_relay
    account(app, "grenze@beispiel.de")
    link(app, "grenze@beispiel.de")
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("freier_prompt", "Schreib mir ein Gedicht")
    assert (e.value.status, e.value.code) == (400, "task_unknown")
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("tutor:ask", "x" * 70_000)
    assert (e.value.status, e.value.code) == (413, "prompt_too_large")
    from app import ai
    with pytest.raises(ai.AIError, match="nur mit deinem eigenen ChatGPT"):
        ai.ask("Ordne die Datei ein", ai.SYSTEM)                 # Aufgabe ohne Freigabe (z. B. Dateianalyse)
    assert fake.calls == 0


def test_relay_route_is_not_open_on_the_pc(pc):
    app, _, _ = pc
    st, d = _j(asgi_call(app, "POST", "/api/ai/relay", body=json.dumps({"task": "tutor:ask", "prompt": "x"})))
    assert (st, d["code"]) == (501, "not_hosted")


# ---------------------------------------------------------------- Karteikarten, Wochentest, Bewertung

def test_flashcards_from_document_via_service(pc, monkeypatch):
    app, calls, fake = pc
    from app import db, scriptsearch
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('rk', 'Analysis')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES ('rk-1', 'rk', 'vl.pdf', 'neu')")
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, fid, *a, **k: ["Grenzwerte von Folgen", "Cauchy-Folgen"])
    account(app, "karten@beispiel.de")
    link(app, "karten@beispiel.de")
    st, d = _j(asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "rk-1", "pages": [1, 2], "count": 5})))
    assert st == 200, d
    assert d["cards"][0]["question"] == "Was ist ein Grenzwert?" and d["credits"]["plan"] == "pro_ai"
    assert ("POST", "/api/ai/relay") in calls and fake.calls == 1


def test_week_test_is_checked_by_the_service_and_counts_on_new_tests(pc, monkeypatch):
    app, _, fake = pc
    from test_ai_pdf import valid_test
    bad = valid_test(); bad["questions"].pop()
    fake.week_test = [bad, valid_test("Wochentest Analysis")]
    account(app, "test@beispiel.de", plan="plus")
    link(app, "test@beispiel.de")
    from app import ai
    res = ai.generate_test("Analysis", 45, [{"title": "Folien", "name": "vl.pdf", "text": "Grenzwerte", "local_path": None}])
    assert res["title"] == "Wochentest Analysis" and len(res["questions"]) == 15
    assert fake.calls == 2, "falsche Form: der Dienst versucht es genau einmal neu"
    from app import billing
    conn = billing.connect()
    try:
        used = conn.execute("SELECT COUNT(*) FROM usage_requests WHERE feature='ai_tests_new'").fetchone()[0]
    finally:
        conn.close()
    assert used == 1, "ein Test = ein Kontingent, auch mit zweitem Versuch"
    # Bewertung ohne Credits
    graded = ai.grade_test("Analysis", [{"nr": 1, "points": 10, "type": "short", "question": "Q", "answer": "A"}], {"1": "A"})
    assert graded["total"] == 6


def test_free_account_gets_plan_required_for_grading(pc):
    app, _, fake = pc
    from app import ai
    from app.ai_relay import RelayError
    account(app, "gratis@beispiel.de", plan="free")
    link(app, "gratis@beispiel.de")
    with pytest.raises(RelayError) as e:
        ai.grade_test("Analysis", [{"nr": 1, "points": 10, "type": "short", "question": "Q", "answer": "A"}], {"1": "A"})
    assert e.value.status in (402, 403)
    assert fake.calls == 0


# ---------------------------------------------------------------- ganzes Dokument

def test_whole_document_runs_in_the_service_with_page_texts_from_the_pc(pc, monkeypatch):
    app, calls, fake = pc
    from app import db, scriptsearch
    from test_doc_explain import lecture_texts
    texts = lecture_texts(uuid.uuid4().hex)
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('rd', 'Lineare Algebra')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES ('rd-1', 'rd', 'vl.pdf', 'neu')")
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, fid, *a, **k: texts if fid == "rd-1" else [])
    account(app, "dok@beispiel.de")
    link(app, "dok@beispiel.de")
    st, plan = _j(asgi_call(app, "POST", "/api/ai/document/plan", body=json.dumps({"file_id": "rd-1", "question": "Erkläre die ganze Vorlesung"})))
    assert st == 200, plan
    assert plan["estimate"]["way"] == "credits" and plan["calls"] == 4 and ("POST", "/api/ai/document/plan") in calls
    body = {"file_id": "rd-1", "mode": "lecture", "scope": plan["scope"]}
    st, d = _j(asgi_call(app, "POST", "/api/ai/document/step", body=json.dumps({**body, "step": plan["steps"][0]["id"], "request_id": "d0"})))
    assert st == 200, d
    assert d["blocks"] and d["credits"]["plan"] == "pro_ai" and fake.calls == 1
    # zweites Konto mit demselben Dokument: schon erklaert, 0 Credits
    account(app, "dok2@beispiel.de")
    link(app, "dok2@beispiel.de")
    st, d = _j(asgi_call(app, "POST", "/api/ai/document/step", body=json.dumps({**body, "step": plan["steps"][0]["id"], "request_id": "e0"})))
    assert st == 200 and d["stored"]["source"] == "cache" and d["credits"]["charged"] == 0 and fake.calls == 1


# ---------------------------------------------------------------- Erklaerungsspeicher des Dienstes (/api/explain)

def test_explain_payload_roundtrip_and_binding():
    from app import doc_index, explain_service as es
    sha = "ab" * 32
    ph = doc_index.page_hash("Satz von Bolzano und Zwischenwertsatz fuer stetige Funktionen", sha, 3)
    fk = doc_index.file_key(sha)
    p = es.seal("Erklärung", file_sha=sha, page_hash=ph, file_key=fk, page=3, mode="explain", variant=1, model="m")
    assert p.startswith(("A", "B")) and len(p) % 4 == 0
    assert es.open_payload(p, file_sha=sha, page_hash=ph, file_key=fk, page=3, mode="explain", variant=1)["text"] == "Erklärung"
    for kw in ({"variant": 2}, {"mode": "summary"}, {"page": 4}, {"file_sha": "cd" * 32}):
        args = {"file_sha": sha, "page_hash": ph, "file_key": fk, "page": 3, "mode": "explain", "variant": 1, **kw}
        assert es.open_payload(p, **args) is None, kw


def test_explanation_is_shared_between_pcs_through_the_service(pc, monkeypatch):
    app, calls, fake = pc
    from app import db, explain_service
    monkeypatch.setattr(explain_service, "publish_later", explain_service.publish)     # ohne Hintergrund-Thread
    sha = uuid.uuid4().hex + uuid.uuid4().hex
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('re', 'Analysis')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, content_sha256) VALUES ('re-1', 're', 'vl3.pdf', 'neu', ?)", (sha,))
    page = "Zwischenwertsatz: Eine stetige Funktion nimmt jeden Wert zwischen f(a) und f(b) an. " * 3
    account(app, "pc1@beispiel.de")
    link(app, "pc1@beispiel.de")
    st, d = tutor(app, mode="summary", file_id="re-1", page=2, page_text=page)
    assert st == 200 and fake.calls == 1 and d["explain"]["stored"] is False
    assert ("POST", "/api/explain") in calls, "frische Antwort geht verschluesselt an den Dienst"
    from app import page_explain
    with page_explain.cursor() as conn:
        payload = conn.execute("SELECT payload FROM page_explain").fetchone()[0]
    assert "Grenzwert" not in payload and "Zwischenwertsatz" not in payload, "der Dienst sieht nur das Chiffrat"
    # anderer PC mit derselben Datei, anderes Konto
    with db.cursor() as conn:
        conn.execute("DELETE FROM page_explain_local")
    account(app, "pc2@beispiel.de")
    link(app, "pc2@beispiel.de")
    st, d = tutor(app, mode="summary", file_id="re-1", page=2, page_text=page)
    assert st == 200, d
    assert fake.calls == 1, "keine KI-Anfrage, keine Credits"
    assert d["explain"]["stored"] is True and d["explain"]["source"] == "cloud" and d["explain"]["variant"] == 1
    assert "Grenzwert" in d["answer"] and "[1]" not in d["answer"], "ohne Quellenmarken des ersten Fragenden"
    # eine Frage zur Seite bleibt live und ungeteilt
    st, d = tutor(app, mode="ask", file_id="re-1", page=2, page_text=page, question="Und wenn f nicht stetig ist?")
    assert st == 200 and fake.calls == 2 and d["explain"] is None


# ---------------------------------------------------------------- Gemeinsame Wochentests ueber den Dienst

def test_week_test_pool_via_service_adopts_without_ai(pc, monkeypatch):
    app, calls, _ = pc
    from app import testshare
    from test_ai_pdf import valid_test
    monkeypatch.setattr(testshare, "variant", lambda uid, key: 0)
    key = testshare.share_key("luh", 45, [{"content_sha256": "ef" * 32, "name": "vl.pdf"}])
    assert key
    made = []

    def generate():
        made.append(1)
        return valid_test("Wochentest Analysis")
    account(app, "pool1@beispiel.de", plan="plus")
    link(app, "pool1@beispiel.de")
    got = testshare.obtain(key, "lokal-1", generate, log=lambda *_: None, wait_s=0)
    assert made == [1] and got["share_variant"] == 0 and got["adopted_from"] is None
    assert ("POST", f"/api/v2/shared-tests/{key}/claim") in calls and ("POST", f"/api/v2/shared-tests/{key}/0") in calls
    # zweites Konto, anderer PC: uebernimmt, ohne KI
    account(app, "pool2@beispiel.de", plan="plus")
    link(app, "pool2@beispiel.de")
    got = testshare.obtain(key, "lokal-2", generate, log=lambda *_: None, wait_s=0)
    assert made == [1], "keine KI fuer den uebernommenen Test"
    assert got["adopted_from"] == testshare.ADOPTED_SERVICE and got["share_variant"] == 0 and len(got["questions"]) == 15


def test_week_test_pool_releases_the_slot_when_generation_fails_and_works_offline(pc, monkeypatch):
    app, calls, _ = pc
    from app import service_link, testshare
    monkeypatch.setattr(testshare, "variant", lambda uid, key: 1)
    key = testshare.share_key("luh", 45, [{"content_sha256": "ab" * 32, "name": "ue.pdf"}])
    account(app, "poolf@beispiel.de", plan="plus")
    link(app, "poolf@beispiel.de")

    def broken():
        raise RuntimeError("KI weg")
    with pytest.raises(RuntimeError):
        testshare.obtain(key, "x", broken, log=lambda *_: None, wait_s=0)
    assert ("DELETE", f"/api/v2/shared-tests/{key}/1") in calls, "Platz wieder frei"

    def offline(*a, **k):
        raise OSError("kein Netz")
    monkeypatch.setattr(service_link, "transport", offline)
    from test_ai_pdf import valid_test
    got = testshare.obtain(key, "x", lambda: valid_test(), log=lambda *_: None, wait_s=0)
    assert got["adopted_from"] is None and len(got["questions"]) == 15, "ohne Netz: eigener Test wie bisher"


# ---------------------------------------------------------------- Karteikarten-Stapel teilen und uebernehmen am PC

def test_card_stack_share_and_adopt_from_the_pc(pc):
    app, calls, _ = pc
    from app import community_cards, db

    def call(method, path, body=None, status=200):
        st, d = _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None))
        assert st == status, (path, d)
        return d
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, semester, color, created_at) VALUES ('Analysis I', 'WiSe 2026/27', '#123456', '2026-10-01')").lastrowid
        _, key = community_cards.module_key(conn, mid)
    s = call("POST", "/api/flashcard-stacks", {"name": "Woche 5", "subject": "Analysis I", "week": 5, "kind": "eigene"})
    call("POST", "/api/flashcards", {"cards": [{"question": "Was ist eine Reihe?", "answer": "Folge der Partialsummen"}], "stack_id": s["id"]})
    for email in ("ada-pc@beispiel.de", "ben-pc@beispiel.de"):
        account(app, email, plan="plus")
        link(app, email)
        call("POST", "/api/community/claims", {"fingerprints": [], "course_keys": [key]})
        call("POST", f"/api/community/communities/{key}/join", {"kind": "course"})
    link(app, "ada-pc@beispiel.de")
    sh = call("POST", f"/api/flashcard-stacks/{s['id']}/share", {})
    assert sh["stack"]["shared_id"] == sh["id"] and ("POST", "/api/community/card-stacks") in calls
    call("POST", "/api/flashcards", {"cards": [{"question": "Quotientenkriterium?", "answer": "lim |a_{n+1}/a_n| < 1"}], "stack_id": s["id"]})
    up = call("PUT", f"/api/flashcard-stacks/{s['id']}/share")
    assert up["stack"]["shared_id"] == sh["id"] and ("PUT", f"/api/community/card-stacks/{sh['id']}") in calls
    # Ben (anderer PC) uebernimmt: Stapel in der PC-Datenbank, nicht im Dienst
    link(app, "ben-pc@beispiel.de")
    ad = call("POST", f"/api/community/card-stacks/{sh['id']}/adopt")
    assert ad["already"] is False and ad["count"] == 2 and ad["stack"]["subject"] == "Analysis I"
    assert ("POST", f"/api/community/card-stacks/{sh['id']}/adopted") in calls
    assert ("POST", f"/api/community/card-stacks/{sh['id']}/adopt") not in calls, "nicht im Dienst-Konto angelegt"
    with db.cursor() as conn:
        n = conn.execute("SELECT COUNT(*) FROM flashcards WHERE stack_id=?", (ad["stack"]["id"],)).fetchone()[0]
    assert n == 2
    assert call("POST", f"/api/community/card-stacks/{sh['id']}/adopt")["already"] is True
    # Ada zieht zurueck
    link(app, "ada-pc@beispiel.de")
    out = call("DELETE", f"/api/flashcard-stacks/{s['id']}/share")
    assert out["stack"]["shared_id"] is None


# ---------------------------------------------------------------- Fertige Wochenfragen am PC (nach Schluessel)

def test_prepared_week_sets_are_read_and_started_on_the_pc(pc, monkeypatch):
    app, calls, _ = pc
    from app import ai_backend, config, db
    from test_week_library import SHA_LEC, SHA_SHEET, SHA_SOL, WeekFake, prepare, seed, week_of
    wf = WeekFake()
    ai_backend.set_provider(wf)
    account(app, "web@beispiel.de")
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, d = _j(asgi_call(app, "POST", "/api/account/login", body=json.dumps({"email": "web@beispiel.de", "password": "sehr-geheim-123"})))
        h = {"Authorization": f"Bearer {d['token']}"}
        mid_web = seed(app, h)
        w = week_of(app, h, mid_web)
        st, prep = prepare(app, h, mid_web, w)
        assert st == 200 and prep["status"] == "ready", prep
    finally:
        config.MODE = old
    made = wf.calls
    # derselbe Stoff auf dem PC (eigene Datenbank, gleiche Inhalts-Hashes und Wochen)
    import time
    now = int(time.time()) - 3600
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, created_at) VALUES ('Lineare Algebra I', '2026-10-01')").lastrowid
        conn.execute("INSERT INTO courses(id, title, kind, active, created_at, module_id) VALUES ('c-la', 'Lineare Algebra I', 'vorlesung', 1, '2026-10-01', ?)", (mid,))
        for fid, name, sha in ((f"f-vl{w}", f"Vorlesung {w:02d} Determinanten.pdf", SHA_LEC), (f"f-ub{w}", f"Uebungsblatt {w:02d}.pdf", SHA_SHEET),
                               (f"f-lo{w}", f"Loesung Uebungsblatt {w:02d}.pdf", SHA_SOL)):
            conn.execute("INSERT INTO files(id, course_id, name, kind, status, chdate, content_sha256) VALUES (?, 'c-la', ?, 'pdf', 'neu', ?, ?)",
                         (fid, name, now, sha))
    account(app, "pc-wl@beispiel.de")
    link(app, "pc-wl@beispiel.de")
    st, ov = _j(asgi_call(app, "GET", f"/api/library/week-sets/{mid}"))
    assert st == 200, ov
    assert [x["status"] for x in ov["weeks"] if x["week"] == w] == ["ready"], ov
    st, d = _j(asgi_call(app, "GET", f"/api/library/week-sets/{mid}/{w}"))
    assert st == 200 and d["status"] == "ready" and d["sets"], d
    st, s = _j(asgi_call(app, "POST", f"/api/library/week-sets/{mid}/{w}/sets/1/start", body="{}"))
    assert st == 200 and s["question_count"] == 15 and s["charged"] == "library_tests", s
    with db.cursor() as conn:
        row = conn.execute("SELECT questions FROM tests WHERE id=?", (s["test_id"],)).fetchone()
    q0 = json.loads(row[0])[0]
    st, e = _j(asgi_call(app, "GET", f"/api/library/week-sets/{mid}/{w}/explain?question_id={q0['library_id']}"))
    assert st == 200 and e["answer"] in e["options"], e
    st, p = _j(asgi_call(app, "POST", f"/api/library/week-sets/{mid}/{w}/prepare", body="{}"))
    assert st == 200 and p["started"] is False and "Dienst" in p["prepare_note"]
    assert wf.calls == made, "Lesen und Starten ohne KI"


def test_own_notes_go_along_and_never_use_the_shared_cache(pc, monkeypatch):
    app, calls, fake = pc
    from app import explain_service
    monkeypatch.setattr(explain_service, "publish_later", explain_service.publish)
    account(app, "notizen@beispiel.de")
    link(app, "notizen@beispiel.de")
    page = "Eigenwerte: det(A - λI) = 0 " + uuid.uuid4().hex
    for _ in range(2):
        st, d = tutor(app, mode="explain", page_text=page, own_notes="Merke: λ ist Eigenwert")
        assert st == 200 and d["explain"] is None
    assert fake.calls == 2, "persoenlich: jedes Mal live, nie aus einem Speicher"
    assert "MEINE NOTIZEN ZU DIESER SEITE" in fake.prompts[-1] and "Merke: λ ist Eigenwert" in fake.prompts[-1]
    assert not any(p == "/api/explain" for _, p in calls), "nichts in den Erklaerungsspeicher"


# ---------------------------------------------------------------- Bereich an KI: Bild in der KI-Hilfe (05.11.2026)

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64            # Kopf genuegt fuer image_mime; die Attrappe liest es nicht


class ImageAI(CardsAI):
    """Attrappe mit Optionen (wie die echten Anbieter): merkt sich das mitgeschickte Bild."""
    supports_options = True

    def __init__(self):
        super().__init__()
        self.images = []

    def complete(self, system, prompt, schema=None, **opts):
        self.images.append(opts.get("image"))
        return super().complete(system, prompt, schema)


def test_tutor_image_field_is_checked():
    import base64
    from app import ai
    b64 = base64.b64encode(JPEG).decode()
    assert ai.tutor_image(None) is None and ai.tutor_image("") is None
    assert ai.tutor_image(b64) == JPEG
    assert ai.tutor_image("data:image/jpeg;base64," + b64) == JPEG, "auch als data-URL"
    with pytest.raises(ai.TutorImageError, match="JPEG"):
        ai.tutor_image(base64.b64encode(b"kein bild").decode())
    with pytest.raises(ai.TutorImageError, match="groß"):
        ai.tutor_image("A" * (ai.TUTOR_IMAGE_MAX_BYTES * 2))
    with pytest.raises(ai.TutorImageError):
        ai.tutor_image(123)


def test_area_image_goes_through_the_service_with_image_tokens_and_never_shared(pc, monkeypatch):
    app, calls, _ = pc
    import base64
    from app import ai, ai_backend, ai_prices
    fake = ImageAI()
    ai_backend.set_provider(fake)
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    seen = []

    def estimate(model, system, prompt, out_tokens, images=None, **k):
        seen.append(images)
        return 10
    monkeypatch.setattr(ai_prices, "estimate_credits", estimate)
    account(app, "bild@beispiel.de")
    link(app, "bild@beispiel.de")
    page = "Fourier-Reihe " + uuid.uuid4().hex
    for _ in range(2):
        st, d = tutor(app, mode="explain", page_text=page, selection="x(t) = sum c_k e^{jkw0t}",
                      image=base64.b64encode(JPEG).decode())
        assert st == 200, d
        assert d["explain"] is None, "persoenlich: nie im Erklaerungsspeicher"
    assert fake.images == [JPEG, JPEG], "das Bild kommt beim Anbieter an, jedes Mal live"
    assert ai.TUTOR_IMAGE_NOTE in fake.prompts[-1]
    assert seen and all(s == [JPEG] for s in seen), "die Schaetzung der Credits zaehlt das Bild"
    assert not any(p == "/api/explain" for _, p in calls)
    # kaputtes Bild: klare Meldung statt KI-Aufruf
    st, d = tutor(app, mode="ask", page_text=page, question="Was?", image=base64.b64encode(b"kein bild").decode())
    assert st == 400 and (d.get("code") or d["detail"]["code"]) == "image_invalid", d
    assert len(fake.images) == 2


def test_relay_accepts_images_only_for_the_tutor(pc, monkeypatch):
    app, _, _ = pc
    from app import ai_backend, ai_relay
    fake = ImageAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    account(app, "relaybild@beispiel.de")
    link(app, "relaybild@beispiel.de")
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("flashcards", "Karten bitte", image=JPEG)
    assert (e.value.status, e.value.code) == (400, "image_not_allowed")
    with pytest.raises(ai_relay.RelayError) as e:
        ai_relay.complete("tutor:ask", "Frage", image=b"kein bild")
    assert e.value.code == "image_invalid"
    d = ai_relay.complete("tutor:ask", "Frage zum Bild", image=JPEG, cache=True)
    assert "Grenzwert" in d["answer"] and fake.images[-1] == JPEG and d["shared"] is False
