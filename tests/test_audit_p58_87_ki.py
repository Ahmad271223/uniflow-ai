"""Externer Audit 09.11.2026, Pakete 63, 64, 65, 72, 73 (KI-Infrastruktur, Warteschlangen, Wochentests, Karteikarten,
Lernplan/Fristen) - Befund am aktuellen Code (docs/audit/AUDIT-2026-11-09-PAKET-63-65-72-73.md).

Keine echten KI-Aufrufe: Attrappen fuer den Anbieter, Test-Datenbanken. Je Befund entweder ein Test, der vor der
Behebung rot war (bestaetigt), oder einer, der das richtige Verhalten festnagelt (widerlegt / schon behandelt)."""
from __future__ import annotations

import json
import logging
import multiprocessing as mp
import sqlite3
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import asgi_call
from test_ai_abuse import trial_account
from test_subscriptions import _j, hosted, user  # noqa: F401 - Fixture
from test_weekly import env  # noqa: F401 - Fixture

ROOT = Path(__file__).resolve().parents[1]


# ====================================================================== P65-F7 Hochschule im System-Prompt

def test_p65_f7_luh_keeps_the_submitted_weekly_system_text_byte_for_byte():
    """1.0 (nur LUH): der Text des eingereichten Builds bleibt (gemeinsame Fixture, Zwischenspeicher der StudiNow-KI)."""
    from app import weekly
    assert weekly.system_text("luh") == weekly.SYSTEM
    assert weekly.SYSTEM.startswith("Du erstellst Pruefungsaufgaben fuer ein Ingenieur-/Informatikstudium an der Leibniz "
                                    "Universitaet Hannover. ")
    fixture = json.loads((ROOT / "packages/shared-contracts/fixtures/local-backend/weekly.json").read_text())
    systems = {a["system"] for a in fixture["ai"] if a["system"].startswith("Du erstellst Pruefungsaufgaben")}
    assert systems == {weekly.SYSTEM}, "Fixture (LUH) unveraendert"


@pytest.mark.parametrize("uni,name", [("hildesheim", "Universität Hildesheim"), ("hsh", "Hochschule Hannover")])
def test_p65_f7_other_universities_get_their_own_name_and_no_luh_engineering_context(uni, name):
    """1.0.1 (Hildesheim, HsH): kein "Leibniz Universitaet Hannover", kein fest vorgegebenes Ingenieurstudium; das Fach
    ergibt sich aus Modul und Material im Prompt. Regeln (JSON, Mathematik) bleiben gleich."""
    from app import weekly
    from app.math_style import MATH_STYLE_JSON
    s = weekly.system_text(uni)
    assert name in s and "Leibniz" not in s and "Ingenieur" not in s, s
    assert s.endswith("Antworte ausschliesslich mit gueltigem JSON ohne Markdown-Zaeune. " + MATH_STYLE_JSON)


def test_p65_f7_unknown_or_missing_university_falls_back_like_config():
    from app import weekly
    assert weekly.system_text("gibtsnicht") == weekly.SYSTEM       # config.normalize_university -> luh


def test_p65_f7_weekly_pipeline_uses_the_university_of_the_running_account(monkeypatch):
    """Dienst (Job je Konto) und PC: der Prompt richtet sich nach config.university() der laufenden Aufgabe."""
    from app import config, weekly
    seen = []

    def fake_ask(prompt, system=""):
        seen.append(system)
        raise RuntimeError("Attrappe: nur den System-Text ansehen")
    monkeypatch.setattr(weekly, "_ask", fake_ask)
    ctx = {"n": 3, "lecture": [], "prior": [], "tasks": [], "topic": "Test", "studip": [], "missing": [], "excluded": []}
    monkeypatch.setattr(weekly, "_gen_prompt", lambda *a, **k: "PROMPT")
    t = config.set_user_context("a" * 32, "hildesheim")
    try:
        with pytest.raises(weekly.WeeklyError):
            weekly._run_ai_pipeline(ctx, "WOCHENTEST", "wochentest", print)
    finally:
        config.reset_user_context(t)
    assert seen and "Universität Hildesheim" in seen[0] and "Leibniz" not in seen[0], seen


def test_p65_f7_relay_picks_the_weekly_system_text_of_the_account(hosted, monkeypatch):
    """iPad/PC schicken nur Aufgabe und Prompt; den System-Text waehlt der Dienst - jetzt nach der Hochschule des Kontos."""
    from app import ai_backend, ai_relay, weekly
    systems = []

    class Rec:
        def complete(self, system, prompt, schema=None):
            systems.append(system)
            return ai_backend.Completion('{"questions": []}', 100, 20, "fake")
    ai_backend.set_provider(Rec())
    for uni in ("luh", "hsh"):
        _, h = user(hosted, f"relay-{uni}@beispiel.de", plan="plus", uni=uni)
        st, d = _j(asgi_call(hosted, "POST", "/api/ai/relay", headers=h,
                             body=json.dumps({"task": "weekly", "prompt": "Erstelle den Wochentest", "request_id": f"wk-{uni}"})))
        assert st == 200, d
    assert systems[0] == weekly.SYSTEM
    assert "Hochschule Hannover" in systems[1] and "Leibniz" not in systems[1], systems[1]
    assert ai_relay._systems("hsh")["weekly"] == weekly.system_text("hsh")


def test_p65_f7_swift_counterpart_builds_the_same_text():
    """Swift (`Weekly.systemText(university:)`, nur mit eigenem ChatGPT; die StudiNow-KI waehlt den Text im Dienst) baut den
    Text aus denselben Teilen; die Swift-Tests pruefen die Werte (WeeklySystemTextTests)."""
    src = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Weekly/WeeklyPlans.swift").read_text()
    from app import weekly
    assert weekly.SYSTEM_OTHER_HEAD.format(name="X").startswith("Du erstellst Pruefungsaufgaben fuer ein Studium an der X.")
    assert weekly.SYSTEM_OTHER_HEAD.replace("{name}", "\\(name)") in src
    assert "Leibniz Universitaet Hannover" in src            # LUH-Text bleibt (1.0)


def test_p65_09_remaining_fixed_luh_prompts_are_known():
    """P65-09: weitere System-Texte nennen noch fest LUH bzw. Informatik/Elektrotechnik (Tutor, Karteikarten, JSON-Aufgaben,
    Dokumentindex). Sie sind fuer 1.0 (nur LUH) richtig und stehen im Bericht als offener Punkt fuer 1.0.1; dieser Test
    meldet, wenn ein NEUER fester Hochschulbezug dazukommt."""
    import re
    hits = set()
    for p in sorted((ROOT / "app").glob("*.py")):
        for m in re.finditer(r"^(\w*SYSTEM\w*) = \(?\s*\"([^\n]*)", p.read_text(), re.M):
            if "Leibniz" in m.group(2) or "Elektrotechnik" in m.group(2):
                hits.add(f"{p.stem}.{m.group(1)}")
    assert hits == {"ai.SYSTEM", "ai.TUTOR_SYSTEM", "doc_index.SYSTEM", "doc_explain.SYSTEM", "weekly.SYSTEM"}, hits


# ====================================================================== P63-F1 Budget im Dienst

def test_p63_f1_hosted_start_warns_when_no_ai_budget_is_set(monkeypatch, caplog):
    """Im Betrieb steht LERNAPP_AI_BUDGET_EUR=600; fehlt die Zeile (neue .env, Tippfehler), gilt still der Rueckfall
    50 EUR und die StudiNow-KI sperrt nach wenigen Tagen fuer alle. Der Start meldet das jetzt laut."""
    from app import config, server
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.delenv("LERNAPP_AI_BUDGET_EUR", raising=False)
    with caplog.at_level(logging.WARNING, logger="uniflow.ai"):
        server.wire_hosted_services()
    assert any("LERNAPP_AI_BUDGET_EUR" in r.getMessage() and "50" in r.getMessage() for r in caplog.records), caplog.text


@pytest.mark.parametrize("value", ["abc", "nan", "-5"])
def test_p63_f1_unusable_budget_value_also_warns(monkeypatch, caplog, value):
    from app import config, server
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", value)
    with caplog.at_level(logging.WARNING, logger="uniflow.ai"):
        server.wire_hosted_services()
    assert any("LERNAPP_AI_BUDGET_EUR" in r.getMessage() for r in caplog.records), caplog.text


def test_p63_f1_set_budget_or_pc_mode_stays_quiet(monkeypatch, caplog):
    from app import ai_backend, config, server
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "600")
    with caplog.at_level(logging.WARNING, logger="uniflow.ai"):
        server.wire_hosted_services()
    assert ai_backend.budget_microeur() == 600_000_000
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.delenv("LERNAPP_AI_BUDGET_EUR", raising=False)
    with caplog.at_level(logging.WARNING, logger="uniflow.ai"):
        server.wire_hosted_services()
    assert not [r for r in caplog.records if r.name == "uniflow.ai"], caplog.text


def test_p63_02_budget_boundary_is_exact(hosted, monkeypatch):
    """Grenze genau: Summe + Reservierung == Budget geht, ein Millionstel darueber nicht (paid-Becken)."""
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "0.04")                     # genau zwei Reservierungen zu 2 Cent
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "100")
    u, _ = user(hosted, "grenze@beispiel.de", plan="pro_ai")
    conn = ai_backend.connect()
    try:
        ai_backend.reserve(conn, u["id"], "tutor:explain")
        ai_backend.reserve(conn, u["id"], "tutor:explain")
        with pytest.raises(ai_backend.AIUnavailable) as e:
            ai_backend.reserve(conn, u["id"], "tutor:explain", amount_microeur=ai_backend.RESERVE_MICROEUR)
        assert e.value.code == "ai_budget_exhausted" and e.value.status == 503
    finally:
        conn.close()


# ====================================================================== P63-03 / P64-F1 mehrere Prozesse, ein Budget

def _reserve_worker(args):
    db_path, uid, n, env = args
    import os
    os.environ.update(env)
    from app import ai_backend
    ok = refused = 0
    for _ in range(n):
        conn = sqlite3.connect(db_path, timeout=30, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            ai_backend.reserve(conn, uid, "tutor:explain", rate_limit=False)
            ok += 1
        except ai_backend.AIUnavailable as e:
            assert e.code == "ai_budget_exhausted", e.code
            refused += 1
        finally:
            conn.close()
    return ok, refused


def test_p63_03_four_processes_never_book_past_the_shared_month_budget(hosted, monkeypatch):
    """Vier echte Prozesse (wie uvicorn-Worker) reservieren gleichzeitig auf derselben accounts.db: zusammen nie mehr als
    das Budget (BEGIN IMMEDIATE ist prozessuebergreifend). Damit ist das Budget die globale Kostenbremse ueber alle 12
    Prozesse, die Notbremse LERNAPP_AI_CONCURRENCY dagegen nur je Prozess (P64-F1)."""
    from app import accounts, ai_backend
    env = {"LERNAPP_AI_BUDGET_EUR": "1.00", "LERNAPP_AI_USER_BUDGET_EUR": "100", "LERNAPP_MODE": "hosted"}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    u, _ = user(hosted, "vierprozesse@beispiel.de", plan="pro_ai")
    ai_backend.connect().close()                      # Schema anlegen
    db_path = str(accounts.db_path())
    with mp.get_context("spawn").Pool(4) as pool:
        res = pool.map(_reserve_worker, [(db_path, u["id"], 20, env)] * 4)
    ok = sum(r[0] for r in res)
    assert ok == 1_000_000 // ai_backend.RESERVE_MICROEUR == 50, res      # genau 50 x 2 Cent = 1 EUR, nicht mehr
    conn = ai_backend.connect()
    try:
        total = ai_backend._pool_total(conn, datetime.now(timezone.utc).strftime("%Y-%m"), "paid")
    finally:
        conn.close()
    assert total <= ai_backend.budget_microeur(), total


def test_p64_f1_rate_limit_per_account_counts_across_processes(hosted, monkeypatch):
    """Ratenlimit je Konto liegt in accounts.db (ai_usage_log), nicht im Prozess: zwei Verbindungen (= zwei Prozesse)
    sehen dieselben Zaehler; die 7. Frage in einer Minute wird abgewiesen, egal welcher Prozess sie annimmt."""
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    u, _ = user(hosted, "rate@beispiel.de", plan="pro_ai")
    a, b = ai_backend.connect(), ai_backend.connect()
    try:
        for i in range(6):
            ai_backend.reserve(a if i % 2 else b, u["id"], "tutor:explain")
        with pytest.raises(ai_backend.AIUnavailable) as e:
            ai_backend.reserve(a, u["id"], "tutor:explain")
        assert e.value.code == "ai_rate_limited" and ai_backend.rate_per_minute() == 6
    finally:
        a.close()
        b.close()


def test_p64_f1_emergency_brake_is_per_process_and_documented():
    """Die Notbremse zaehlt je Prozess; global = Prozesse x Grenze. Dokumentiert in BETRIEB 14 und .env.example."""
    betrieb = (ROOT / "docs/release/BETRIEB.md").read_text()
    env = (ROOT / "deploy/.env.example").read_text()
    assert "je Prozess" in betrieb and "LERNAPP_AI_CONCURRENCY" in betrieb
    assert "je API-Prozess" in env and "LERNAPP_AI_CONCURRENCY" in env


# ====================================================================== P63-F7 unterscheidbare Fehler

def test_p63_f7_every_ai_refusal_has_its_own_code_and_status():
    """429/503, Budget, Credits, nicht eingerichtet, Zeitlimit: eigene Codes (die Clients zeigen je eigenen Text)."""
    src = "\n".join((ROOT / f"app/{n}.py").read_text() for n in ("ai_backend", "ai_async", "ai_providers", "credits"))
    for code in ("ai_overloaded", "ai_provider_busy", "ai_budget_exhausted", "ai_trial_budget_exhausted",
                 "ai_user_budget_exhausted", "ai_library_budget_exhausted", "ai_rate_limited", "credits_exhausted",
                 "ai_not_configured", "ai_not_configured_prices", "ai_provider_unreachable", "duplicate_request"):
        assert f'"{code}"' in src, code


# ====================================================================== P72-05 Leitner-Intervalle

@pytest.mark.parametrize("box,correct,new_box,days", [(1, True, 2, 2), (4, True, 5, 16), (5, True, 5, 16), (5, False, 1, 1),
                                                      (None, True, 2, 2), (3, False, 1, 1)])
def test_p72_05_leitner_boxes_and_intervals(app, monkeypatch, box, correct, new_box, days):
    """Leitner mit 5 Faechern (1, 2, 4, 8, 16 Tage), kein FSRS/SM-2; ueber Monats- und Jahresgrenze ab dem Kalendertag
    (Container TZ=Europe/Berlin, Swift BerlinClock)."""
    from app import db, server
    monkeypatch.setattr(server, "_require_flashcards", lambda request: None)

    class D(date):
        @classmethod
        def today(cls):
            return date(2026, 12, 31)
    monkeypatch.setattr(server, "date", D)
    with db.cursor() as conn:
        cid = conn.execute("INSERT INTO flashcards(subject, question, answer, created_at, box, due) VALUES "
                           "('M', 'F?', 'A', '2026-12-01', ?, '2026-12-31')", (box,)).lastrowid
    st, d = _j(asgi_call(app, "POST", f"/api/flashcards/{cid}/review", body=json.dumps({"correct": correct})))
    assert st == 200 and d == {"box": new_box, "due": (date(2026, 12, 31) + timedelta(days=days)).isoformat()}, d


def test_p72_05_python_and_swift_use_the_same_intervals():
    swift = (ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Endpoints/FlashcardEndpoints.swift").read_text()
    py = (ROOT / "app/server.py").read_text()
    assert "[1, 2, 4, 8, 16]" in py and "[1, 2, 4, 8, 16]" in swift.replace("intervals = ", "")
    assert "BerlinClock" in swift and "TZ=Europe/Berlin" in (ROOT / "deploy/Dockerfile").read_text()


# ====================================================================== P72-06 / P73-07 zwei Geraete offline

def _sync_conn(tmp_path):
    from app import db
    db.DB_PATH = tmp_path / "sync.db"
    db.init_db()
    return db.connect()


def test_p73_07_two_devices_change_different_fields_of_one_task_with_only_their_fields(app, tmp_path):
    """Schickt jedes Geraet nur sein geaendertes Feld, bleiben beide Aenderungen (Feld-Regel des Dienstes)."""
    from app import db, sync
    with db.cursor() as conn:
        pid = conn.execute("INSERT INTO study_packages(date, title, planned_minutes, status, sort, generated, created_at) "
                           "VALUES ('2026-11-10', 'P', 30, 'geplant', 0, 0, '2026-11-01')").lastrowid
        tid = conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) "
                           "VALUES (?, 'lesen', 'T', 0, 30, 'geplant', '2026-11-01')", (pid,)).lastrowid
        v = db.row(conn, "SELECT sync_version FROM study_tasks WHERE id=?", (tid,))["sync_version"]
        sync.push(conn, "windows", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T10:00:00.000Z",
                                     "data": {"status": "erledigt"}}], now="2026-11-09T10:30:00.000Z")
        sync.push(conn, "ipad", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T11:00:00.000Z",
                                  "data": {"est_minutes": 45}}], now="2026-11-09T11:30:00.000Z")
        row = db.row(conn, "SELECT status, est_minutes FROM study_tasks WHERE id=?", (tid,))
    assert (row["status"], row["est_minutes"]) == ("erledigt", 45)


@pytest.mark.xfail(strict=True, reason="P73-F6/P72-F4 bestaetigt: Geraete schicken ganze Zeilen (DeviceSync.collect, "
                                       "sync_client), bei Konflikt gewinnt der spaetere Schreiber auch in Feldern, die er "
                                       "gar nicht geaendert hat - eine Erledigung geht verloren. Sync-Agent/Inhaber, Bericht.")
def test_p73_07_done_on_one_device_survives_a_later_whole_row_push_from_the_other(app, tmp_path):
    from app import db, sync
    with db.cursor() as conn:
        pid = conn.execute("INSERT INTO study_packages(date, title, planned_minutes, status, sort, generated, created_at) "
                           "VALUES ('2026-11-10', 'P', 30, 'geplant', 0, 0, '2026-11-01')").lastrowid
        tid = conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) "
                           "VALUES (?, 'lesen', 'T', 0, 30, 'geplant', '2026-11-01')", (pid,)).lastrowid
        base = dict(db.row(conn, "SELECT * FROM study_tasks WHERE id=?", (tid,)))
        v = base["sync_version"]
        whole = {k: base[k] for k in ("package_id", "type", "title", "sort", "est_minutes", "status")}
        sync.push(conn, "windows", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T10:00:00.000Z",
                                     "data": {**whole, "status": "erledigt"}}], now="2026-11-09T10:30:00.000Z")
        sync.push(conn, "ipad", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T11:00:00.000Z",
                                  "data": {**whole, "est_minutes": 45}}], now="2026-11-09T11:30:00.000Z")
        row = db.row(conn, "SELECT status, est_minutes FROM study_tasks WHERE id=?", (tid,))
    assert (row["status"], row["est_minutes"]) == ("erledigt", 45)


# ====================================================================== P73-F4 / P73-06 Neuplanung

def test_p73_06_replace_keeps_started_moved_and_own_packages_is_pinned_elsewhere():
    """Schon behandelt: tests/test_study_plan.py::test_replace_keeps_started_packages und
    ::test_replace_keeps_own_and_moved_packages (study._replaceable: nur generated=1, alle Aufgaben 'geplant', keine
    verschoben)."""
    src = (ROOT / "tests/test_study_plan.py").read_text()
    assert "def test_replace_keeps_started_packages" in src and "def test_replace_keeps_own_and_moved_packages" in src


def test_p73_08_catch_up_never_moves_done_tasks_and_plans_each_task_once(app, monkeypatch):
    """50 ueberfaellige Aufgaben, wenig Platz: jede genau einmal vorgeschlagen; erledigte bleiben, wo sie sind.
    Reicht der Platz nicht, legt der Vorschlag den Rest auf den Tag mit dem meisten Platz (Absicht: Vorschlag mit
    Bestaetigung; Bericht P73-F5)."""
    from app import db, study
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 9))
    with db.cursor() as conn:
        pid = conn.execute("INSERT INTO study_packages(date, title, planned_minutes, status, sort, generated, created_at) "
                           "VALUES ('2026-11-02', 'Alt', 1500, 'geplant', 0, 1, '2026-11-01')").lastrowid
        ids = [conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) "
                            "VALUES (?, 'lesen', ?, ?, 30, 'geplant', '2026-11-01')", (pid, f"T{i}", i)).lastrowid for i in range(50)]
        conn.execute("UPDATE study_tasks SET status='erledigt' WHERE id=?", (ids[0],))
        study.refresh_statuses(conn)
        sug = study.suggest_reschedule(conn)
        moved = [m["task_id"] for m in sug["moves"]]
        assert len(moved) == len(set(moved)) == 49 and ids[0] not in moved
        n = study.apply_moves(conn, sug["moves"] + [{"task_id": ids[0], "to": "2026-11-12"}])
        assert n == 49
        assert db.row(conn, "SELECT status, package_id FROM study_tasks WHERE id=?", (ids[0],))["package_id"] == pid


# ====================================================================== P64-F2 / P64-05 Lease laeuft waehrend der KI ab

def test_p64_05_expired_lease_while_generating_never_pays_twice(env):
    """Plan-Lease 20 min laeuft ab, waehrend die KI noch arbeitet: ein zweiter Lauf darf den Plan uebernehmen, wartet aber
    auf _GEN_LOCK und nimmt dann die fertige Testversion (gleicher scope_key) - ein KI-Entwurf, eine Testversion. Im
    Dienst laufen alle Wochentests in EINEM Job-Prozess (deploy/docker-compose.yml, nie --scale jobs=2), am PC in einem
    Prozess: der prozesslokale Lock reicht fuer diese Topologie (mehrere Job-Prozesse: Fahrplan)."""
    import threading
    from app import db, weekly
    env.mark(36)
    env.tick("2026-10-20T09:00:00")                       # Plan anlegen, noch nicht faellig
    plan_id = env.plans()[0]["id"]
    inner, started, go = env.fake, threading.Event(), threading.Event()

    def slow(prompt, system=""):
        if "### AUFTRAG: PRUEFUNG" not in prompt and not started.is_set():
            started.set()
            assert go.wait(10)
        return inner(prompt, system)
    weekly._ask = slow                                    # env hat _ask per monkeypatch gesetzt; Aufraeumen dort
    t0 = datetime.fromisoformat("2026-10-20T11:31:00")
    out = {}
    a = threading.Thread(target=lambda: out.setdefault("a", weekly.process_plan(plan_id, t0, log=lambda *_: None)))
    a.start()
    assert started.wait(10)
    b = threading.Thread(target=lambda: out.setdefault("b", weekly.process_plan(plan_id, t0 + timedelta(minutes=21), log=lambda *_: None)))
    b.start()
    go.set()
    a.join(20); b.join(20)
    assert out["a"]["result"] == "published", out
    assert out["b"] is None or (out["b"]["result"] == "published" and out["b"]["def_id"] == out["a"]["def_id"]), out
    assert len(env.defs()) == 1 and len(inner.gen_prompts()) == 1
    with env.conn() as c:
        assert db.row(c, "SELECT COUNT(*) n FROM tests WHERE def_id IS NOT NULL")["n"] == 1


# ====================================================================== P72-F2 / P72-02 Karteikarten bis zum Marker

def test_p72_02_marker_at_slide_36_limits_ai_flashcards_to_slides_up_to_36(env):
    """KI-Karteikarten auf Auftrag (Modul, Woche): die markierte Vorlesung geht nur bis zum Marker in den Prompt, nie
    eine spaetere Folie. Ohne Marker nimmt der Auftrag die Dateien der Lehrwoche ganz (Wochenregel study.file_week)."""
    from app import flashcard_order, weekly
    from test_weekly import LEC, MOD
    env.mark(36)
    with env.conn() as c:
        week = next(s["week"] for s in weekly.coverage(c, MOD)["segments"] if s["file_id"] == LEC)
        m = flashcard_order.week_material(c, MOD, week)
    lec = [s for s in m["sources"] if s["file_id"] == LEC]
    assert m["markers"] and lec and lec[0]["marked"], m["sources"]
    assert max(lec[0]["pages"]) <= 36, lec[0]["pages"]


# ====================================================================== P64-07 / P64-F8 KI ausgelastet: kein Versuch weg

def test_p64_07_busy_ai_does_not_use_up_the_three_attempts(env):
    """Bestaetigt: Jeder KI-Fehler zaehlte einen von drei Versuchen. Am PC laeuft der Takt alle 10 Minuten - eine halbe
    Stunde "KI ausgelastet" (OpenAI 429 -> ai_provider_busy, Notbremse ai_overloaded, Ratenlimit) verbrauchte alle drei,
    der Wochentest kam nie (nur noch "Erneut versuchen" von Hand). Jetzt: nichts berechnet -> kein Versuch, naechster
    Takt versucht es wieder; echte Fehler (unbrauchbare Antwort) zaehlen weiter."""
    from app import weekly
    env.mark(36)
    inner = env.fake
    busy = {"n": 4}

    def flaky(prompt, system=""):
        if busy["n"] > 0:
            busy["n"] -= 1
            raise weekly.WeeklyBusy("StudiNow-KI: Die KI ist gerade ausgelastet, bitte gleich noch einmal.")
        return inner(prompt, system)
    weekly._ask = flaky                                   # env hat _ask per monkeypatch gesetzt; Aufraeumen dort
    for minute in (31, 41, 51, 59):
        r = env.tick(f"2026-10-20T11:{minute:02d}:00")
        assert not r["failed"] and not r["published"], r
    p = env.plans()[0]
    assert p["attempts"] == 0 and p["status"] in weekly.OPEN_STATES and "ausgelastet" in p["last_error"], dict(p)
    r = env.tick("2026-10-20T12:09:00")
    assert r["published"] and len(inner.gen_prompts()) == 1, r


def test_p64_07_busy_codes_of_the_service_become_weekly_busy(hosted, monkeypatch):
    """Dienst: AIUnavailable mit einem "nichts berechnet"-Code -> WeeklyBusy; Budget/Konfiguration bleiben echte Fehler."""
    from app import ai_backend, config, entitlements, weekly
    monkeypatch.setattr(entitlements, "email_verified", lambda uid: True)
    t = config.set_user_context("b" * 32, "luh")
    try:
        for code, busy in (("ai_provider_busy", True), ("ai_overloaded", True), ("ai_rate_limited", True),
                           ("ai_budget_exhausted", False), ("ai_not_configured", False)):
            def boom(*a, code=code, **k):
                raise ai_backend.AIUnavailable(code, "nein", 503)
            monkeypatch.setattr(ai_backend, "complete", boom)
            with pytest.raises(weekly.WeeklyError) as e:
                weekly._ask("P", "S")
            assert isinstance(e.value, weekly.WeeklyBusy) is busy, code
    finally:
        config.reset_user_context(t)


def test_p64_07_busy_relay_error_on_the_pc_becomes_weekly_busy(monkeypatch):
    from app import ai, ai_relay, weekly

    def raises(err):
        def f(*a, **k):
            raise err
        return f
    monkeypatch.setattr(ai, "ask", raises(ai_relay.RelayError(503, "ai_provider_busy", "ausgelastet")))
    with pytest.raises(weekly.WeeklyBusy):
        weekly._ask("P", "S")
    monkeypatch.setattr(ai, "ask", raises(ai_relay.RelayError(429, "credits_exhausted", "leer")))
    with pytest.raises(ai_relay.RelayError):
        weekly._ask("P", "S")
