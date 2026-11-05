"""Tarif-Matrix im Dienst (docs/TARIF-MATRIX-2026-11-04.md): was Free, Plus, Pro AI und die 7-Tage-Probe bei Karteikarten
und Tests duerfen, mit den deutschen Meldungen der Sperren (403 plan_required, 403 email_unverified, 429 quota_exhausted,
501 not_available_hosted). Fixture `hosted` und Helfer aus tests/test_subscriptions.py; KI als Attrappe, kein Netz.

Die Tests pinnen den Stand des Codes nach dem Auftrag des Inhabers vom 04.11.2026: eigene Karteikarten (anlegen,
bearbeiten, ueben, Stapel, teilen, uebernehmen) ab Plus (`can_use_flashcards`), Lesen in jedem Tarif und nach der
Probe; Wochenstapel uebernehmen ab Plus ohne bestaetigte E-Mail, einen neuen erzeugen nur mit StudiNow-KI (Pro AI)."""
import json

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, add_file, end_trial, ent, hosted, library_test, user  # noqa: F401

PLAN_REQUIRED_PRO_AI = "Diese Funktion gibt es ab StudiNow Pro AI."
PLAN_REQUIRED_PLUS = "Diese Funktion gibt es ab StudiNow Plus."
FLASHCARDS_PLUS = "Karteikarten gibt es ab StudiNow Plus."
EMAIL_UNVERIFIED = "Bitte zuerst die E-Mail-Adresse bestätigen."
NOT_HOSTED = "KI-Funktionen kommen mit dem KI-Update."

# Tarife der Matrix: die drei verkauften plus die Probe (Konto frisch registriert, Probe laeuft)
KINDS = ("free", "plus", "pro_ai", "trial")


class FakeCards:
    """Attrappe fuer POST /api/ai/flashcards (Schema FLASHCARDS_SCHEMA): liefert zwei Karten, zaehlt die Aufrufe."""

    def __init__(self):
        self.calls = 0

    def complete(self, system, prompt, schema=None, **_options):
        from app.ai_backend import Completion
        self.calls += 1
        if schema is None:
            return Completion("Erklärung: Eine Folge ist eine Abbildung von N nach R.", 50, 20, "fake")
        return Completion(json.dumps({"cards": [{"question": "Was ist eine Folge?", "answer": "Eine Abbildung von N nach R."},
                                                {"question": "Was ist eine Cauchy-Folge?", "answer": "Glieder kommen sich beliebig nahe."}]}),
                          80, 60, "fake")


def account(app, kind, email):
    """Konto fuer einen Tarif der Matrix: `trial` = frisch registriert mit laufender Probe, sonst wie test_subscriptions.user."""
    from app import accounts
    if kind != "trial":
        return user(app, email, plan=kind)
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    d["user"] = accounts.mark_email_verified(d["user"]["id"])
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def effective_plan(kind):
    return "pro_ai" if kind == "trial" else kind


def post(app, headers, path, body):
    return _j(asgi_call(app, "POST", path, headers=headers, body=json.dumps(body)))


def in_user_db(app, headers, fn):
    """`fn(conn)` in der Datenbank des Kontos (wie add_file)."""
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


# ---------------------------------------------------------------- Vertrag: Probe = Pro AI, Kontingente je Tarif

def test_trial_is_pro_ai_in_contract_fixture_and_credits():
    from pathlib import Path
    from app import credits, plans
    assert plans.TRIAL == {"days": 7, "plan": "pro_ai"}
    fx = json.loads((Path(__file__).resolve().parents[1] / "packages/shared-contracts/fixtures/plans/plans.json").read_text(encoding="utf-8"))
    assert fx["trial"] == {**plans.TRIAL, "credits": 25}, "Fixture fuer die Apps (UFLocalTrial.days/plan) traegt dieselbe Probe mit 25 Credits"
    assert fx["order"] == ["free", "plus", "pro_ai"] and "pro_connect" not in fx["plans"], "drei Tarife (04.11.2026), Pro Connect nur noch als alter Schluessel"
    assert plans.LEGACY_PLANS == {"pro_connect": "pro_ai"} and plans.has("pro_connect", "can_use_ai_explanations")
    # Kontingente des Tarifs (app/plans.py QUOTAS, Tabelle des Inhabers 04.11.2026): Free nichts, Plus 4 KI-Tests und
    # 4 Bibliothekstests, Pro AI 20 KI-Tests, Bibliothek unbegrenzt (Fair Use 300), 150 KI-Aufrufe; Karteikarten-Stapel von
    # StudiNow (05.11.2026): Plus 4, Pro AI unbegrenzt (Fair Use 300)
    assert {k: plans.quota_limit("free", k) for k in plans.QUOTA_LABELS} == {"ai_tests_new": 0, "library_tests": 0, "ai_assist": 0, "card_stacks_adopted": 0}
    assert {k: plans.quota_limit("plus", k) for k in plans.QUOTA_LABELS} == {"ai_tests_new": 4, "library_tests": 4, "ai_assist": 0, "card_stacks_adopted": 4}
    assert {k: plans.quota_limit("pro_ai", k) for k in plans.QUOTA_LABELS} == {"ai_tests_new": 20, "library_tests": 300, "ai_assist": 150, "card_stacks_adopted": 300}
    # Credits (app/credits.py): Pro AI 100, Probe 25, Free und Plus 0 - die Probe hat also Pro-AI-Rechte und -Kontingente,
    # aber einen kleineren Credit-Rahmen (Entscheidung 04.11.2026, docs/ABO-SYSTEM.md 6a)
    assert credits.allowance("pro_ai", False) == 100 and credits.allowance("pro_ai", True) == 25
    assert credits.allowance("plus", False) == 0 and credits.allowance("free", False) == 0
    assert fx["credits"] == {"free": 0, "plus": 0, "pro_ai": 100, "trial": 25} and fx["plans"]["pro_ai"]["credits"] == 100


@pytest.mark.parametrize("kind", KINDS)
def test_entitlements_and_quotas_per_plan(hosted, kind):
    _, h = account(hosted, kind, f"matrix-{kind}@beispiel.de")
    e = ent(hosted, h)
    assert e["plan"] == effective_plan(kind)
    assert e["trial"]["active"] is (kind == "trial")
    rights = e["entitlements"]
    expect = {
        "free": {"can_read_community": False, "can_use_flashcards": False, "can_access_shared_tests": False, "can_generate_studora_ai_tests": False, "can_use_ai_generated_questions": False,
                 "can_use_ai_explanations": False, "can_use_advanced_analytics": False, "can_use_extended_test_history": False},
        "plus": {"can_read_community": True, "can_use_flashcards": True, "can_access_shared_tests": True, "can_generate_studora_ai_tests": True, "can_use_ai_generated_questions": False,
                 "can_use_ai_explanations": False, "can_use_advanced_analytics": False, "can_use_extended_test_history": False},
        "pro_ai": {"can_read_community": True, "can_use_flashcards": True, "can_access_shared_tests": True, "can_generate_studora_ai_tests": True, "can_use_ai_generated_questions": True,
                   "can_use_ai_explanations": True, "can_use_advanced_analytics": True, "can_use_extended_test_history": True},
    }[effective_plan(kind)]
    assert {k: rights[k] for k in expect} == expect, kind
    limits = {k: v["limit"] for k, v in e["quotas"].items()}
    assert limits == {"free": {"ai_tests_new": 0, "library_tests": 0, "ai_assist": 0, "card_stacks_adopted": 0},
                      "plus": {"ai_tests_new": 4, "library_tests": 4, "ai_assist": 0, "card_stacks_adopted": 4},
                      "pro_ai": {"ai_tests_new": 20, "library_tests": 300, "ai_assist": 150, "card_stacks_adopted": 300}}[effective_plan(kind)], kind
    assert e["entitlements"]["can_use_flashcards"] is (kind != "free"), "Karteikarten ab Plus, Probe = Pro AI"


# ---------------------------------------------------------------- Karteikarten von Hand: ab Plus, Lesen immer

def flashcard_writes(app, h, card, stack):
    """Alle schreibenden und uebenden Karteikarten-Routen einmal: [(Name, Status, Antwort)]"""
    calls = (("anlegen", "POST", "/api/flashcards", {"stack_id": stack, "cards": [{"question": "Neu?", "answer": "Ja"}]}),
             ("bearbeiten", "PATCH", f"/api/flashcards/{card}", {"answer": "Abbildung von N nach R"}),
             ("trainer", "PATCH", f"/api/flashcards/{card}", {"last_result": "right"}),
             ("wiederholen", "POST", f"/api/flashcards/{card}/review", {"correct": True}),
             ("stapel anlegen", "POST", "/api/flashcard-stacks", {"name": "Klausur"}),
             ("stapel aendern", "PATCH", f"/api/flashcard-stacks/{stack}", {"name": "Umbenannt"}),
             ("karte loeschen", "DELETE", f"/api/flashcards/{card}", None),
             ("stapel loeschen", "DELETE", f"/api/flashcard-stacks/{stack}", None))
    out = []
    for name, method, path, body in calls:
        st, d = _j(asgi_call(app, method, path, headers=h, body=json.dumps(body) if body is not None else None))
        out.append((name, st, d))
    return out


def seed_card(app, h):
    """Eine Karte in einem Stapel direkt in der Datenbank des Kontos (wie Karten aus der Probe): (Karte, Stapel)"""
    def ins(conn):
        sid = conn.execute("INSERT INTO flashcard_stacks(name, subject, created_at, kind) VALUES ('Folgen', 'Mathe I', '2026-11-01', 'eigene')").lastrowid
        cid = conn.execute("INSERT INTO flashcards(subject, question, answer, created_at, box, due, stack_id) "
                           "VALUES ('Mathe I', 'Was ist eine Folge?', 'Abbildung N -> R', '2026-11-01', 1, '2026-11-01', ?)", (sid,)).lastrowid
        return cid, sid
    return in_user_db(app, h, ins)


@pytest.mark.parametrize("kind", KINDS)
def test_own_flashcards_need_plus_and_stay_readable(hosted, kind):
    """Eigene Karteikarten schreiben und ueben ab Plus (can_use_flashcards; Probe = Pro AI): Free bekommt auf jeder
    schreibenden Route 403 "Karteikarten gibt es ab StudiNow Plus.", liest Karten und Stapel aber weiter."""
    _, h = account(hosted, kind, f"karten-{kind}@beispiel.de")
    card, stack = seed_card(hosted, h)
    st, cards = _j(asgi_call(hosted, "GET", "/api/flashcards", headers=h))
    assert st == 200 and [c["question"] for c in cards] == ["Was ist eine Folge?"], kind
    st, stacks = _j(asgi_call(hosted, "GET", "/api/flashcard-stacks", headers=h))
    assert st == 200 and [s["name"] for s in stacks] == ["Folgen"], kind
    assert asgi_call(hosted, "GET", f"/api/flashcards?stack_id={stack}&due=1", headers=h)[0] == 200
    for name, st, d in flashcard_writes(hosted, h, card, stack):
        if kind == "free":
            assert (st, d["code"], d["entitlement"], d["required_plan"], d["detail"]) == \
                (403, "plan_required", "can_use_flashcards", "plus", FLASHCARDS_PLUS), (name, d)
        else:
            assert st == 200, (kind, name, d)
    if kind == "free":
        st, cards = _j(asgi_call(hosted, "GET", "/api/flashcards", headers=h))
        assert [(c["question"], c["answer"], c["box"]) for c in cards] == [("Was ist eine Folge?", "Abbildung N -> R", 1)], "nichts veraendert"


def test_week_stack_adopt_is_plus_without_email_generate_is_pro_ai(hosted, monkeypatch):
    """Geteilter Wochenstapel (04.11.2026): Pro AI erzeugt ihn einmal (StudiNow-KI, Credits); Plus uebernimmt ihn ohne
    KI, ohne Credits und ohne bestaetigte E-Mail; Plus kann keinen neuen erzeugen (403 Pro AI); Free gar nichts."""
    from app import ai_backend, cardshare
    from test_flashcard_share import FakeCardsAI, _seed_user
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    monkeypatch.setattr(cardshare, "variant", lambda uid, key: 0)
    try:
        _, h_pro = user(hosted, "woche-pro@beispiel.de", plan="pro_ai")
        a = post(hosted, h_pro, f"/api/flashcard-stacks/week/{_seed_user(hosted, h_pro)}/5/vorlesung", {})[1]
        assert a["status"] == "generated" and fake.calls == 1, a
        _, h_plus = user(hosted, "woche-plus@beispiel.de", plan="plus", verified=False)
        mp = _seed_user(hosted, h_plus)
        st, b = post(hosted, h_plus, f"/api/flashcard-stacks/week/{mp}/5/vorlesung", {})
        assert st == 200 and (b["status"], b["credits"], b["stack"]["cards"], fake.calls) == ("adopted", None, 3, 1), b
        assert ent(hosted, h_plus)["quotas"]["ai_assist"]["used"] == 0
        # Stapel von StudiNow uebernehmen zaehlt im Kontingent card_stacks_adopted (05.11.2026: Plus 4 je Monat); selbst
        # erzeugt (Pro AI) zaehlt nicht
        assert (ent(hosted, h_plus)["quotas"]["card_stacks_adopted"]["used"], ent(hosted, h_pro)["quotas"]["card_stacks_adopted"]["used"]) == (1, 0)
        st, d = post(hosted, h_plus, f"/api/flashcard-stacks/week/{mp}/5/uebung", {})
        assert (st, d["entitlement"], d["detail"]) == (403, "can_use_ai_generated_questions", PLAN_REQUIRED_PRO_AI), d
        _, h_free = user(hosted, "woche-free@beispiel.de")
        st, d = post(hosted, h_free, f"/api/flashcard-stacks/week/{_seed_user(hosted, h_free)}/5/vorlesung", {})
        assert (st, d["entitlement"], d["detail"]) == (403, "can_use_flashcards", FLASHCARDS_PLUS), d
        assert fake.calls == 1
    finally:
        ai_backend.set_provider(None)


def test_after_the_trial_cards_and_tests_stay_readable_but_ai_locks(hosted):
    """Probe vorbei, keine Wahl: Free. Karten, Stapel und Tests bleiben lesbar (Daten bleiben), Karten ueben und anlegen
    sperrt mit "Karteikarten gibt es ab StudiNow Plus.", die StudiNow-KI mit dem Weg zum Tarif, die Aufforderung zur
    Tarifwahl erscheint einmal."""
    from app import ai_backend
    ai_backend.set_provider(FakeCards())
    u, h = account(hosted, "trial", "probe-ende@beispiel.de")
    add_file(hosted, h)
    assert post(hosted, h, "/api/flashcards", {"file_id": "f1", "cards": [{"question": "F", "answer": "A"}]})[0] == 200
    st, d = post(hosted, h, "/api/ai/tutor", {"mode": "explain", "page_text": "Folgen"})
    assert st == 200 and d["credits"]["allowance"] == 25, "Probe: StudiNow-KI mit 25 Credits"
    test_id = in_user_db(hosted, h, lambda conn: conn.execute(
        "INSERT INTO tests(subject, title, questions, created_at) VALUES ('Mathe I', 'Lehrwoche 3: Folgen', ?, '2026-11-01T10:00:00')",
        (json.dumps([{"nr": 1, "type": "mc", "question": "1+1?", "options": ["2", "3"], "answer": "2", "points": 10}]),)).lastrowid)
    end_trial(u["id"])
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["trial"]["expired"] and e["needs_plan_choice"], e
    st, cards = _j(asgi_call(hosted, "GET", "/api/flashcards", headers=h))
    assert st == 200 and len(cards) == 1, "eigene Karten bleiben lesbar"
    st, stacks = _j(asgi_call(hosted, "GET", "/api/flashcard-stacks", headers=h))
    assert st == 200 and len(stacks) == 1 and stacks[0]["cards"] == 1, "Stapel bleiben lesbar"
    st, d = post(hosted, h, f"/api/flashcards/{cards[0]['id']}/review", {"correct": True})
    assert (st, d["code"], d["detail"]) == (403, "plan_required", FLASHCARDS_PLUS), "nach der Probe: Ueben ab Plus"
    assert post(hosted, h, "/api/flashcards", {"file_id": "f1", "cards": [{"question": "F2", "answer": "A2"}]})[0] == 403
    st, tests = _j(asgi_call(hosted, "GET", "/api/tests", headers=h))
    assert st == 200 and [t["id"] for t in tests] == [test_id], "eigene Tests bleiben in der Liste"
    st, t = _j(asgi_call(hosted, "GET", f"/api/tests/{test_id}", headers=h))
    assert st == 200 and t["questions"][0]["question"] == "1+1?" and "answer" not in t["questions"][0], "Test laeuft auch in Free"
    st, r = post(hosted, h, f"/api/tests/{test_id}/submit", {"answers": {"1": "2"}})
    assert st == 200 and r["total"] == 10, "Abgabe und Ergebnis ohne Tarifsperre"
    st, d = post(hosted, h, "/api/ai/tutor", {"mode": "explain", "page_text": "Folgen"})
    assert (st, d["code"], d["required_plan"], d["detail"]) == (403, "plan_required", "pro_ai", PLAN_REQUIRED_PRO_AI), d
    st, d = post(hosted, h, "/api/billing/plan-choice", {"plan": "free"})
    assert st == 200 and not ent(hosted, h)["needs_plan_choice"]


# ---------------------------------------------------------------- StudiNow-KI: Tutor und Karteikarten aus Dokument

TUTOR_MODES = ("explain", "summary", "flashcards", "similar", "terms")


@pytest.mark.parametrize("kind", ("free", "plus"))
def test_ai_tutor_and_ai_flashcards_lock_below_pro_ai(hosted, kind):
    from app import ai_backend
    fake = FakeCards()
    ai_backend.set_provider(fake)
    _, h = account(hosted, kind, f"ki-{kind}@beispiel.de")
    add_file(hosted, h)
    for mode in TUTOR_MODES:
        st, d = post(hosted, h, "/api/ai/tutor", {"mode": mode, "file_id": "f1", "page_text": "Folgen"})
        assert (st, d["code"], d["required_plan"], d["detail"]) == (403, "plan_required", "pro_ai", PLAN_REQUIRED_PRO_AI), (kind, mode, d)
    st, d = post(hosted, h, "/api/ai/flashcards", {"file_id": "f1"})
    assert (st, d["code"], d["entitlement"], d["detail"]) == (403, "plan_required", "can_use_ai_generated_questions", PLAN_REQUIRED_PRO_AI), d
    assert fake.calls == 0, "ohne Recht kein KI-Aufruf"
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 0


@pytest.mark.parametrize("kind", ("pro_ai", "trial"))
def test_ai_tutor_and_ai_flashcards_work_with_pro_ai_and_trial(hosted, kind, monkeypatch):
    from app import ai_backend, scriptsearch
    fake = FakeCards()
    ai_backend.set_provider(fake)
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id: ["Seite eins Folgen", "Seite zwei Cauchy"])
    _, h = account(hosted, kind, f"ki-{kind}@beispiel.de")
    add_file(hosted, h)
    st, d = post(hosted, h, "/api/ai/tutor", {"mode": "explain", "file_id": "f1", "page_text": "Folgen"})
    assert st == 200 and d["answer"].startswith("Erklärung"), (kind, d)
    # Credits (app/credits.py): Probe 25 mit der Marke "pro_ai:trial", Pro AI 100
    assert (d["credits"]["plan"], d["credits"]["allowance"]) == (("pro_ai:trial", 25) if kind == "trial" else ("pro_ai", 100)), d["credits"]
    st, d = post(hosted, h, "/api/ai/flashcards", {"file_id": "f1", "count": 2})
    assert st == 200 and [c["question"] for c in d["cards"]] == ["Was ist eine Folge?", "Was ist eine Cauchy-Folge?"], (kind, d)
    assert fake.calls == 2
    q = ent(hosted, h)["quotas"]["ai_assist"]
    assert (q["used"], q["limit"]) == (2, 150), "beide Wege zaehlen auf ai_assist (150 im Monat wie Pro AI)"


def test_ai_needs_a_verified_email_even_with_pro_ai(hosted):
    from app import ai_backend
    ai_backend.set_provider(FakeCards())
    _, h = user(hosted, "unbestaetigt@beispiel.de", plan="pro_ai", verified=False)
    add_file(hosted, h)
    for path, body in (("/api/ai/tutor", {"mode": "explain", "page_text": "x"}), ("/api/ai/flashcards", {"file_id": "f1"})):
        st, d = post(hosted, h, path, body)
        assert (st, d["code"], d["detail"]) == (403, "email_unverified", EMAIL_UNVERIFIED), (path, d)


def test_ai_assist_quota_exhausted_gives_429_with_german_message(hosted, monkeypatch):
    from app import ai_backend, plans, scriptsearch
    ai_backend.set_provider(FakeCards())
    monkeypatch.setitem(plans.QUOTAS["pro_ai"], "ai_assist", 1)
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id: ["Seite eins Folgen"])
    _, h = user(hosted, "kontingent@beispiel.de", plan="pro_ai")
    add_file(hosted, h)
    assert post(hosted, h, "/api/ai/tutor", {"mode": "explain", "page_text": "x", "request_id": "r1"})[0] == 200
    st, d = post(hosted, h, "/api/ai/tutor", {"mode": "explain", "page_text": "y", "request_id": "r2"})
    assert (st, d["code"], d["feature"], d["used"], d["limit"]) == (429, "quota_exhausted", "ai_assist", 1, 1), d
    assert d["detail"] == "KI-Erklärungen, Lernfragen und Zusammenfassungen: Kontingent für diesen Monat aufgebraucht (1 von 1)."
    st, d = post(hosted, h, "/api/ai/flashcards", {"file_id": "f1", "request_id": "r3"})
    assert (st, d["code"]) == (429, "quota_exhausted"), "Karteikarten aus Dokument haengen am selben Kontingent"


# ---------------------------------------------------------------- Tests: Bibliothek, Wochentests, Verlauf

def test_library_tests_free_locked_plus_four_per_month_trial_unlimited(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    topics = ("Determinanten", "Basiswechsel", "Orthogonalprojektion", "Eigenwerte", "Spektralsatz")
    # Free: 403 mit dem Weg zu Plus, kein KI-Aufruf
    _, h_free = user(hosted, "bib-free@beispiel.de")
    st, d = library_test(hosted, h_free, topics[0])
    assert (st, d["code"], d["required_plan"], d["detail"]) == (403, "plan_required", "plus", PLAN_REQUIRED_PLUS), d
    assert fake.calls == 0
    # Pro AI fuellt den Pool (5 neue KI-Tests von 20)
    _, h_pro = user(hosted, "bib-pro@beispiel.de", plan="pro_ai")
    for t in topics:
        st, d = library_test(hosted, h_pro, t)
        assert st == 200 and d["charged"] == "ai_tests_new", (t, d)
    assert ent(hosted, h_pro)["quotas"]["ai_tests_new"]["used"] == 5
    # Plus uebernimmt vier Tests aus der Bibliothek, der fuenfte scheitert am Kontingent 4
    _, h_plus = user(hosted, "bib-plus@beispiel.de", plan="plus")
    for t in topics[:4]:
        st, d = library_test(hosted, h_plus, t)
        assert st == 200 and d["charged"] == "library_tests" and d["generated"] == 0, (t, d)
    st, d = library_test(hosted, h_plus, topics[4])
    assert (st, d["code"], d["feature"], d["used"], d["limit"]) == (429, "quota_exhausted", "library_tests", 4, 4), d
    assert d["detail"] == "Tests aus der Bibliothek: Kontingent für diesen Monat aufgebraucht (4 von 4)."
    q = ent(hosted, h_plus)["quotas"]
    assert (q["library_tests"]["used"], q["library_tests"]["limit"], q["ai_tests_new"]["used"]) == (4, 4, 0)
    # Probe: wie Pro AI, Bibliothek unbegrenzt (Fair Use 300)
    _, h_trial = account(hosted, "trial", "bib-probe@beispiel.de")
    for t in topics:
        st, d = library_test(hosted, h_trial, t)
        assert st == 200 and d["charged"] == "library_tests", (t, d)
    q = ent(hosted, h_trial)["quotas"]["library_tests"]
    assert (q["used"], q["limit"], q["unlimited"]) == (5, 300, True)
    assert fake.calls == 5, "nur die fuenf Generierungen von Pro AI"


@pytest.mark.parametrize("kind", KINDS)
def test_weekly_tests_quota_follows_the_plan(hosted, kind):
    """Wochentests im Dienst laufen als Job je Konto (POST /api/weekly/tick -> app/jobs.py HostedQuota, Kontingent
    ai_tests_new); ein gemeinsamer Test aus dem Pool kostet nichts (app/weekly.py, `reuse`)."""
    from app import accounts, jobs
    u, h = account(hosted, kind, f"woche-{kind}@beispiel.de")
    why = jobs.HostedQuota(accounts.get_user(u["id"])).check()
    if kind == "free":
        assert why == "Wochentests mit KI gibt es ab StudiNow Plus (dein Tarif: StudiNow Free)."
    else:
        assert why is None, (kind, why)
    st, d = _j(asgi_call(hosted, "POST", "/api/weekly/tick", headers=h, body="{}"))
    assert st == 200 and d["started"] == "Wochentests" and d["job_id"], (kind, d)


@pytest.mark.parametrize("kind", ("free", "pro_ai"))
def test_manual_test_generation_is_not_available_in_the_service(hosted, kind):
    """POST /api/tests/generate (Dialog "Wochentest erstellen" lokal mit eigenem ChatGPT) gibt es im Dienst fuer keinen
    Tarif (app/server.py HOSTED_UNAVAILABLE): 501 mit Hinweis, vor jeder Tarifpruefung."""
    _, h = account(hosted, kind, f"gen-{kind}@beispiel.de")
    for path in ("/api/tests/generate", "/api/tests/generate-week"):
        st, d = post(hosted, h, path, {"module_id": 1})
        assert (st, d["code"], d["detail"]) == (501, "not_available_hosted", NOT_HOSTED), (kind, path, d)


def test_test_history_shows_ten_without_extended_history(hosted):
    """GET /api/tests: ohne can_use_extended_test_history (ab Pro AI) die letzten 10; Plus sieht aeltere Tests nach der
    Probe nicht mehr in der Liste, gespeichert bleiben sie (docs/PREISLISTE.md, Nutzungsbedingungen 5a)."""
    def twelve(conn):
        for i in range(12):
            conn.execute("INSERT INTO tests(subject, title, questions, created_at) VALUES ('Mathe I', ?, '[]', ?)",
                         (f"Test {i}", f"2026-10-{i + 1:02d}T10:00:00"))
    for kind, n in (("plus", 10), ("pro_ai", 12), ("trial", 12)):
        _, h = account(hosted, kind, f"verlauf-{kind}@beispiel.de")
        in_user_db(hosted, h, twelve)
        st, rows = _j(asgi_call(hosted, "GET", "/api/tests", headers=h))
        assert st == 200 and len(rows) == n, (kind, len(rows))


def test_learning_stats_are_pro_ai_and_legacy_pro_connect_rows_count_as_pro_ai(hosted):
    """Lernstatistik, Wiederholung und Empfehlungen (can_use_advanced_analytics u. a.) gibt es ab Pro AI (04.11.2026,
    frueher Pro Connect): Pro AI und Probe haben sie, Plus bekommt die Meldung mit "Pro AI"; eine alte Zeile mit
    pro_connect gilt wie Pro AI (plans.LEGACY_PLANS, billing.normalize_plan) und erscheint nirgends als eigener Tarif."""
    _, h_plus = user(hosted, "stat-plus@beispiel.de", plan="plus")
    for path in ("/api/learning/stats", "/api/learning/review", "/api/learning/recommendations"):
        st, d = _j(asgi_call(hosted, "GET", path, headers=h_plus))
        assert (st, d["required_plan"], d["detail"]) == (403, "pro_ai", PLAN_REQUIRED_PRO_AI), (path, d)
    _, h_old = user(hosted, "stat-alt@beispiel.de", plan="pro_connect")
    e = ent(hosted, h_old)
    assert (e["plan"], e["plan_name"]) == ("pro_ai", "StudiNow Pro AI") and e["entitlements"]["can_use_advanced_analytics"]
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/plans", headers=h_old))
    assert st == 200 and d["order"] == ["free", "plus", "pro_ai"] and "pro_connect" not in d["plans"]
    assert d["purchase"]["web"]["plans"] == [] or "pro_connect" not in d["purchase"]["web"]["plans"]
    for kind in ("pro_ai", "trial"):
        _, h = account(hosted, kind, f"stat-{kind}@beispiel.de")
        for path in ("/api/learning/stats", "/api/learning/review", "/api/learning/recommendations"):
            assert asgi_call(hosted, "GET", path, headers=h)[0] == 200, (kind, path)
    # Lernstand je Modul (mastery in GET /api/modules) ist in jedem Tarif dabei
    _, h_free = user(hosted, "stat-free@beispiel.de")
    assert asgi_call(hosted, "GET", "/api/modules", headers=h_free)[0] == 200
