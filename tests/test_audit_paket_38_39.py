"""Audit-Pakete 38/39 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-38-39.md): serverseitige Kontotrennung und
API-Rechte (Teil 38) sowie Community, Eigentuemerrechte und geteilte Tests (Teil 39). Der Durchlauf ueber alle Routen
steht in tests/test_rechte_alle_routen.py; hier die einzelnen Befunde, Rollen-Matrizen und Wettlaeufe.
Konten: A (Autor), B (fremd, kein Mitglied), C (Mitglied in A's Kurs), Admin. Keine echten Hochschul- oder KI-Dienste."""
from __future__ import annotations

import base64
import json
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import asgi_call
from test_rechte_alle_routen import (A_MARK, FP_A, KEY_A, SHARE_KEY_A, _package, _week_test, in_user, world)  # noqa: F401
from test_subscriptions import _j, hosted, user  # noqa: F401 - Fixtures


def call(app, h, m, p, body=None):
    return _j(asgi_call(app, m, p, headers=h, body=json.dumps(body) if body is not None else None))


def _cm(w, h, m, p, body=None):
    return call(w["app"], h, m, "/api/community" + p, body)


# ================================================================ Zusatzfunde aus dem Durchlauf (rote Tests zuerst)

def test_z1_block_needs_a_visible_solution(world):
    """POST /solutions/{id}/block prueft keine Sichtbarkeit: B (kein Mitglied) erfuhr mit A's Loesungs-ID A's Pseudonym
    und legte eine Sperre an - auch fuer zurueckgezogene Loesungen. Erwartet 404 wie bei Like/Kommentar/Melden."""
    sid = world["ids"]["solution_id"]
    st, d = _cm(world, world["hb"], "POST", f"/solutions/{sid}/block")
    assert st == 404 and world["ids"]["pseudonym"] not in json.dumps(d), (st, d)
    assert _cm(world, world["hb"], "GET", "/blocks")[1]["blocked"] == []
    # Mitglied C sperrt A wie bisher
    st, d = _cm(world, world["hc"], "POST", f"/solutions/{sid}/block")
    assert st == 200 and d["blocked"] == world["ids"]["pseudonym"]
    # eigene Loesung: weiterhin "own_solution"
    assert _cm(world, world["ha"], "POST", f"/solutions/{sid}/block")[1]["code"] == "own_solution"


def test_z2_bookmark_needs_a_visible_solution(world):
    """Lesezeichen auf eine Loesung prueften nur, ob es sie gibt: B legte eines auf A's Loesung in einem fremden Kurs
    an und GET /bookmarks lieferte Titel und Fingerabdruck. Fragen pruefen die Sichtbarkeit schon."""
    from app import community
    sid = world["ids"]["solution_id"]
    st, d = _cm(world, world["hb"], "POST", f"/bookmarks/solution/{sid}")
    assert st == 404, (st, d)
    # aelteres Lesezeichen (vor dem Fix angelegt) oder Austritt aus der Community: die Liste zeigt es nicht mehr
    with community.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO bookmarks(user_id, kind, target_id, created_at) VALUES (?,?,?,?)",
                     (world["b"]["id"], "solution", sid, "2026-11-08T00:00:00Z"))
    out = _cm(world, world["hb"], "GET", "/bookmarks")[1]
    assert out["bookmarks"] == [] and A_MARK not in json.dumps(out), out
    # Mitglied C: Lesezeichen wie bisher
    assert _cm(world, world["hc"], "POST", f"/bookmarks/solution/{sid}")[0] == 200
    assert [b["id"] for b in _cm(world, world["hc"], "GET", "/bookmarks")[1]["bookmarks"]] == [sid]


def test_z3_index_job_belongs_to_its_account(world):
    """GET /api/index/jobs/{id} las den Auftrag aus dem gemeinsamen Upload-Ordner ohne Konto: B sah mit A's Auftrags-ID
    Zustand, Datei-Schluessel und Seiten-Abdruecke. Die ID ist zufaellig (128 Bit), trotzdem gehoert der Auftrag A."""
    jid = world["ids"]["job_id"]
    assert call(world["app"], world["ha"], "GET", f"/api/index/jobs/{jid}")[0] == 200
    st, d = call(world["app"], world["hb"], "GET", f"/api/index/jobs/{jid}")
    assert (st, d.get("code")) == (404, "not_found"), (st, d)


def test_z4_annotations_for_an_unknown_file_are_404_not_500(world):
    """PUT /api/files/{id}/annotations fuer eine Datei, die es im eigenen Konto nicht gibt (z. B. A's Datei-ID): 500
    `FOREIGN KEY constraint failed`. Lesen gab schon 404 (G6)."""
    st, d = call(world["app"], world["hb"], "PUT", "/api/files/r-files/annotations", {"version": 2, "pages": {}})
    assert (st, d) == (404, {"detail": "Datei nicht gefunden"}), (st, d)        # wie GET (server._found)
    # A's Notizen und eigene Dateien von B wie bisher
    assert call(world["app"], world["ha"], "PUT", "/api/files/r-files/annotations", {"version": 2, "pages": {}})[0] == 200


def test_z5_adopted_counter_counts_each_account_once(world):
    """POST /card-stacks/{id}/adopted (Windows-App) erhoehte `adopt_count` bei jedem Aufruf; das Kontingent zaehlt
    denselben Stapel im Monat nur einmal (once=True). Ein Mitglied konnte die Uebernahmen beliebig hochtreiben."""
    from app import community
    sid = world["ids"]["card_stack"]
    for _ in range(3):
        assert call(world["app"], world["hc"], "POST", f"/api/community/card-stacks/{sid}/adopted")[0] == 200
    with community.cursor() as conn:
        n = conn.execute("SELECT adopt_count FROM card_stacks WHERE id=?", (sid,)).fetchone()[0]
    assert n == 1, n
    # B (kein Mitglied) zaehlt gar nicht
    assert call(world["app"], world["hb"], "POST", f"/api/community/card-stacks/{sid}/adopted")[0] == 403


# ================================================================ Teil 38

def test_p38_01_jobs_run_in_the_context_of_their_account_also_in_parallel(hosted, monkeypatch):
    """Hintergrund-Jobs (app/jobs.py) setzen den Kontext aus `job.user_id` und setzen ihn danach zurueck - auch wenn
    zwei Jobs gleichzeitig in zwei Arbeiter-Threads laufen."""
    from app import config, jobs
    ua, _ = user(hosted, "job-a@beispiel.de", plan="pro_ai")
    ub, _ = user(hosted, "job-b@beispiel.de", plan="pro_ai")
    seen, gate = [], threading.Barrier(2, timeout=10)

    def fake_weekly(u):
        gate.wait()                                            # beide Jobs laufen wirklich gleichzeitig
        seen.append((u["id"], config.current_user_id(), str(config.db_path())))
        return {"published": [], "waiting": [], "failed": [], "nachtraege": []}
    monkeypatch.setattr(jobs, "run_weekly", fake_weekly)
    js = [jobs.enqueue(u["id"], "weekly") for u in (ua, ub)]
    ts = [threading.Thread(target=jobs.run_job, args=(j,)) for j in js]
    [t.start() for t in ts]
    [t.join(20) for t in ts]
    assert len(seen) == 2
    for job_user, ctx_user, path in seen:
        assert job_user == ctx_user and f"/users/{job_user}/" in path, (job_user, ctx_user, path)
    assert config.current_user_id() is None


def test_p38_01_parallel_requests_keep_their_accounts(hosted):
    """Parallele Anfragen zweier Konten mit denselben lokalen IDs: jede sieht nur die eigene Datenbank."""
    _, ha = user(hosted, "par-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "par-b@beispiel.de", plan="pro_ai")
    for h, name in ((ha, "Stapel-A"), (hb, "Stapel-B")):
        assert call(hosted, h, "POST", "/api/flashcard-stacks", {"name": name})[0] == 200
    wrong = []

    def run(h, mine, other):
        for _ in range(15):
            st, d = call(hosted, h, "GET", "/api/flashcard-stacks")
            names = json.dumps(d)
            if st != 200 or mine not in names or other in names:
                wrong.append((mine, st, names[:200]))
    ts = [threading.Thread(target=run, args=(ha, "Stapel-A", "Stapel-B")), threading.Thread(target=run, args=(hb, "Stapel-B", "Stapel-A"))]
    [t.start() for t in ts]
    [t.join(60) for t in ts]
    assert not wrong, wrong[:3]


def test_p38_04_without_account_context_the_service_would_use_the_pc_database_documented():
    """Festgenagelt (Designfrage): db.connect faellt ohne Konto-Kontext auf DB_PATH zurueck, auch im Dienst (Start des
    Dienstes, Werkzeuge). Dass keine Anfrage dorthin gelangt, prueft der Durchlauf ueber alle Routen
    (test_rechte_alle_routen: "oeffnet die Datenbank des Einzelplatzes")."""
    from app import config, db
    assert config.current_user_id() is None
    conn = db.connect()
    try:
        path = conn.execute("PRAGMA database_list").fetchone()[2]
    finally:
        conn.close()
    assert Path(path).resolve() == Path(db.DB_PATH).resolve()


def test_p38_05_no_api_sets_a_local_path(world):
    """Dateipfade (`files.local_path`) schreibt nur der Dienst selbst (Hochladen, Kopie). Sync kennt `files` nicht,
    PATCH nimmt nur Status/Schwierigkeit. Ein manipulierter Pfad ist daher nicht von aussen erreichbar."""
    from app import config, db
    app, hb = world["app"], world["hb"]
    in_user(app, hb, lambda conn: conn.execute(
        "INSERT INTO files(id, course_id, name, kind, status) VALUES ('b-datei', '__user__', 'b.pdf', 'pdf', 'neu')"))
    st, d = call(app, hb, "PATCH", "/api/files/b-datei", {"local_path": "/etc/passwd", "status": "gelesen"})
    assert st == 200 and d["local_path"] is None
    st, d = call(app, hb, "POST", "/api/sync/push", {"device_id": "b", "items": [
        {"entity": "files", "id": "b-datei", "data": {"local_path": "/etc/passwd"}}]})
    assert st == 200 and d["results"][0]["status"] == "unknown_entity", d
    assert in_user(app, hb, lambda conn: db.row(conn, "SELECT local_path FROM files WHERE id='b-datei'"))["local_path"] is None
    assert call(app, hb, "GET", "/api/files/b-datei/content")[0] == 404


def test_p38_06_same_op_ids_and_ids_in_two_accounts_stay_apart(hosted):
    """Sync: dieselbe op_id, dieselbe local_id und dieselbe Zeilen-ID in A und B - jede Datenbank fuer sich."""
    _, ha = user(hosted, "sync-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "sync-b@beispiel.de", plan="pro_ai")
    op = "op-gleich-0001"
    out = {}
    for h, q in ((ha, "Frage A"), (hb, "Frage B")):
        st, d = call(hosted, h, "POST", "/api/sync/push", {"device_id": "geraet", "items": [
            {"entity": "flashcard_stacks", "local_id": -1, "op_id": op, "data": {"name": f"Stapel {q}"}}]})
        assert st == 200 and d["results"][0].get("repeated") is not True, d
        out[q] = d["results"][0]["id"]
    assert out["Frage A"] == out["Frage B"], "gleiche Zeilen-ID in beiden Konten (je eigene Datenbank)"
    st, d = call(hosted, hb, "POST", "/api/sync/push", {"device_id": "geraet", "items": [],
                                                       "deletes": [{"entity": "flashcard_stacks", "id": out["Frage B"]}]})
    assert st == 200
    names_a = [s["name"] for s in call(hosted, ha, "GET", "/api/flashcard-stacks")[1]]
    names_b = [s["name"] for s in call(hosted, hb, "GET", "/api/flashcard-stacks")[1]]
    assert "Stapel Frage A" in names_a and "Stapel Frage B" not in names_b and "Stapel Frage A" not in names_b


def test_p38_07_free_account_may_delete_own_synced_entries_documented(hosted):
    """Teilweise zutreffend, festgenagelt: `deletes` im Sync laufen ohne Tarifpruefung - ein Free-Konto loescht eigene
    Karten/Stapel ueber den Abgleich, ueber REST (DELETE /api/flashcards/{id}) aber nicht (403 plan_required).
    Notizen lassen sich ueber `deletes` gar nicht loeschen (`unknown_entity`, in jedem Tarif). Alles nur in der eigenen
    Konto-Datenbank; Regel (Loeschen eigener Daten immer erlaubt?) ist eine Designfrage im Bericht."""
    from app import accounts
    u, h = user(hosted, "sync-free@beispiel.de", plan="pro_ai")
    st, stack = call(hosted, h, "POST", "/api/flashcard-stacks", {"name": "Eigene"})
    assert call(hosted, h, "POST", "/api/flashcards", {"stack_id": stack["id"], "cards": [{"question": "q1", "answer": "a"},
                                                                                       {"question": "q2", "answer": "a"}]})[0] == 200
    c1, c2 = [c["id"] for c in call(hosted, h, "GET", "/api/flashcards")[1]]
    accounts.set_plan(u["id"], "free")
    assert call(hosted, h, "DELETE", f"/api/flashcards/{c1}")[1]["code"] == "plan_required"
    st, d = call(hosted, h, "POST", "/api/sync/push", {"device_id": "ipad", "items": [], "deletes": [
        {"entity": "flashcards", "id": c1}, {"entity": "annotations", "id": "f-notiz"}]})
    assert st == 200 and [r["status"] for r in d["results"]] == ["deleted", "unknown_entity"], d
    assert [c["id"] for c in call(hosted, h, "GET", "/api/flashcards")[1]] == [c2]


def test_p38_08_library_tests_with_the_same_id_stay_in_their_account(hosted):
    """`_user_test(test_id)` sucht nur nach ID - in der Konto-Datenbank. Gleiche Test-ID in A und B: GET, Abgeben und
    Teilen treffen nur den eigenen Test."""
    _, ha = user(hosted, "lib-a@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "lib-b@beispiel.de", plan="pro_ai")
    qs = lambda who: json.dumps([{"nr": 1, "type": "mc", "question": f"{who}: Was ergibt zwei plus zwei?", "options": ["3", "4", "5", "6"],  # noqa: E731
                                  "answer": "4", "explanation": "Rechnen", "difficulty": 2, "points": 1}])
    for h, who in ((ha, "A-Test"), (hb, "B-Test")):
        tid = in_user(hosted, h, lambda conn: conn.execute("INSERT INTO tests(subject, title, questions, created_at) VALUES ('M', ?, ?, '2026-11-08')",
                                                           (who, qs(who))).lastrowid)
        assert tid == 1
    st, d = call(hosted, hb, "POST", "/api/library/tests/1/submit", {"answers": {"1": "4"}})
    assert st == 200 and d["total"] == d["max"]
    a = call(hosted, ha, "GET", "/api/tests/1")[1]
    assert a["title"] == "A-Test" and a["submitted_at"] is None and a["answers"] == {}
    st, d = call(hosted, hb, "POST", "/api/library/tests/1/share", {"confirm": True, "topic": "Addition"})
    assert st == 200 and d["submitted"] == 1, d
    from app import test_library
    with test_library.cursor() as conn:
        texts = [r[0] for r in conn.execute("SELECT question FROM questions")]
    assert texts and all("B-Test" in t for t in texts), texts


def test_p38_09_sessions_export_password_and_deletion_are_bound_to_the_own_account(world):
    from app import accounts
    app, ha, hb = world["app"], world["ha"], world["hb"]
    for sid in world["ids"]["session_ids"]:
        assert call(app, hb, "DELETE", f"/api/account/sessions/{sid}")[0] == 404
    assert call(app, ha, "GET", "/api/account/me")[0] == 200 and call(app, world["ha2"], "GET", "/api/account/me")[0] == 200
    exp = asgi_call(app, "GET", "/api/account/export", headers=hb)
    assert exp[0] == 200 and A_MARK.encode() not in exp[2] and world["a"]["email"].encode() not in exp[2]
    assert call(app, hb, "POST", "/api/account/password", {"old_password": "falsch", "new_password": "neu-sehr-geheim-1"})[0] == 401
    assert call(app, hb, "POST", "/api/account/logout-all", {"user_id": world["a"]["id"]})[0] == 200
    assert call(app, ha, "GET", "/api/account/me")[0] == 200 and call(app, world["ha2"], "GET", "/api/account/me")[0] == 200
    assert call(app, hb, "POST", "/api/account/delete", {"password": "sehr-geheim-123", "user_id": world["a"]["id"]})[0] == 200
    with accounts.cursor() as conn:
        assert conn.execute("SELECT status FROM users WHERE id=?", (world["a"]["id"],)).fetchone()[0] == "active"
        assert conn.execute("SELECT status FROM users WHERE id=?", (world["b"]["id"],)).fetchone()[0] == "deleted"
    assert call(app, ha, "GET", "/api/flashcards")[1][0]["question"].startswith(A_MARK)
    assert call(app, ha, "GET", f"/api/community/solutions/{world['ids']['solution_id']}")[0] == 200


def test_p38_10_rate_limit_is_per_account(hosted, monkeypatch):
    """`_api_rate` zaehlt je Konto (und je Prozess, Designfrage im Bericht): ein Konto am Limit bremst kein anderes."""
    from app import server
    monkeypatch.setenv("LERNAPP_LIMIT_API_PER_MIN", "3")
    server._API_HITS.clear()
    _, ha = user(hosted, "rate-a@beispiel.de")
    _, hb = user(hosted, "rate-b@beispiel.de")
    codes = [asgi_call(hosted, "GET", "/api/files", headers=ha)[0] for _ in range(5)]
    assert codes[-1] == 429 and asgi_call(hosted, "GET", "/api/files", headers=hb)[0] == 200
    server._API_HITS.clear()


# ================================================================ Teil 39

def test_p39_03_shared_test_lookup_reveals_no_account(world):
    """Produktentscheidung festgenagelt: Wer den Schluessel kennt (Hochschule + SHA-256 der Dateien), bekommt den
    fertigen Test - ohne Konto-ID, ohne owner_hash, nur bereinigte Aufgaben."""
    from app import test_library
    st, d = call(world["app"], world["hb"], "GET", f"/api/v2/shared-tests/{SHARE_KEY_A}")
    assert st == 200
    text = json.dumps(d)
    assert world["a"]["id"] not in text and test_library.owner_hash(world["a"]["id"]) not in text and "owner" not in text
    assert call(world["app"], world["hb"], "GET", "/api/v2/shared-tests/wt3:kurz")[0] == 400


def test_p39_04_expired_claim_and_parallel_claims(world):
    """A belegt, die Belegung verfaellt, B belegt: A's spaete Veroeffentlichung 409, B's gelingt. Acht gleichzeitige
    Belegungen desselben Platzes: genau eine gewinnt."""
    from app import test_library, testshare
    key = "wt3:" + "e" * 64
    a, b = world["a"]["id"], world["b"]["id"]
    t0 = datetime.now(timezone.utc)
    assert test_library.shared_claim(key, 2, a, now=t0 - timedelta(seconds=testshare.PENDING_STALE_S + 5))
    assert test_library.shared_claim(key, 2, b), "verwaister Platz wird frei"
    with pytest.raises(KeyError):
        test_library.shared_publish(key, 2, a, "A spaet", [{"q": 1}])
    test_library.shared_publish(key, 2, b, "B", [{"q": 1}])
    assert test_library.shared_get(key, 2, count_use=False)["title"] == "B"
    key2, wins = "wt3:" + "f" * 64, []
    gate = threading.Barrier(8, timeout=10)

    def go(i):
        gate.wait()
        wins.append(test_library.shared_claim(key2, 0, f"{i:032x}"))
    ts = [threading.Thread(target=go, args=(i,)) for i in range(8)]
    [t.start() for t in ts]
    [t.join(20) for t in ts]
    assert sorted(wins) == [False] * 7 + [True]


def test_p39_05_12_comment_roles(world):
    """Kommentar von A unter C's Loesung: C (Loesungsautor) darf loeschen, nicht bearbeiten; B (kein Mitglied) weder
    noch; Admin loescht. Die Ausgabe unterscheidet nicht, wer geloescht hat (P39-12, Designfrage)."""
    app = world["app"]
    sol_c = world["ids"]["c_solution"]
    _, hadm = user(app, "admin@beispiel.de", plan="free", admin=True)
    mk = lambda: _cm(world, world["ha"], "POST", f"/solutions/{sol_c}/comments", {"text": "A unter C"})[1]["id"]  # noqa: E731
    c1, c2, c3 = mk(), mk(), mk()
    assert _cm(world, world["hc"], "PATCH", f"/comments/{c1}", {"text": "C aendert"})[0] == 403
    assert _cm(world, world["hb"], "PATCH", f"/comments/{c1}", {"text": "B"})[0] == 403
    assert _cm(world, world["hb"], "DELETE", f"/comments/{c1}")[0] == 403
    assert _cm(world, world["hc"], "DELETE", f"/comments/{c1}")[0] == 200            # Loesungsautor
    assert _cm(world, world["ha"], "DELETE", f"/comments/{c2}")[0] == 200            # Verfasser
    assert _cm(world, hadm, "DELETE", f"/comments/{c3}")[0] == 200                    # Moderation ohne Tarif
    out = {c["id"]: c for c in _cm(world, world["hc"], "GET", f"/solutions/{sol_c}/comments")[1]["comments"]}
    assert all(cid not in out for cid in (c1, c2, c3)), "geloeschte ohne Antworten verschwinden"


def test_p39_06_question_and_answer_roles(world):
    """Frage von A, Antwort von C: A (Fragesteller) darf C's Antwort entfernen, nicht bearbeiten; Mitglied D und
    Nichtmitglied B weder noch; Admin entfernt; C bearbeitet die eigene Antwort."""
    from test_community_qa import _member
    app = world["app"]
    ud, hd = user(app, "konto-d@beispiel.de", plan="pro_ai")
    _member(ud["id"], key=KEY_A)
    _, hadm = user(app, "admin2@beispiel.de", plan="free", admin=True)
    qid = world["ids"]["qid"]
    a1 = _cm(world, world["hc"], "POST", f"/questions/{qid}/answers", {"body": "C eins"})[1]["id"]
    a2 = _cm(world, world["hc"], "POST", f"/questions/{qid}/answers", {"body": "C zwei"})[1]["id"]
    assert _cm(world, world["ha"], "PATCH", f"/answers/{a1}", {"body": "A aendert"})[0] == 403
    assert _cm(world, world["hc"], "PATCH", f"/answers/{a1}", {"body": "C eins, korrigiert"})[0] == 200
    for h in (hd, world["hb"]):
        assert _cm(world, h, "DELETE", f"/answers/{a1}")[0] == 403
        assert _cm(world, h, "DELETE", f"/questions/{qid}")[0] == 403
        assert _cm(world, h, "PATCH", f"/questions/{qid}", {"title": "fremd"})[0] == 403
    assert _cm(world, world["hb"], "GET", f"/questions/{qid}")[0] == 404              # Nichtmitglied sieht nichts
    assert _cm(world, world["ha"], "DELETE", f"/answers/{a1}")[0] == 200              # Fragesteller
    assert _cm(world, hadm, "DELETE", f"/answers/{a2}")[0] == 200                      # Moderation
    assert _cm(world, hd, "POST", f"/questions/{qid}/accept", {"answer_id": world["ids"]["aid"]})[0] == 403


def test_p39_07_corrections_only_for_author_owner_and_members(world):
    """Korrektur von A an C's Loesung: B (kein Mitglied) liest, meldet, setzt Status, loescht nichts; C (Empfaenger)
    setzt den Status, loescht nicht; A nimmt sie zurueck. Posteingaenge getrennt."""
    cid = world["ids"]["correction_id"]
    hb, hc, ha = world["hb"], world["hc"], world["ha"]
    assert _cm(world, hb, "GET", f"/corrections/{cid}")[0] == 404
    assert _cm(world, hb, "POST", f"/corrections/{cid}/report", {"reason": "spam"})[0] == 404
    assert _cm(world, hb, "POST", f"/corrections/{cid}/status", {"status": "ignored"})[0] == 404
    assert _cm(world, hb, "DELETE", f"/corrections/{cid}")[0] == 403
    assert _cm(world, hb, "GET", "/corrections/inbox")[1]["open"] == 0
    assert _cm(world, ha, "POST", f"/corrections/{cid}/status", {"status": "seen"})[0] == 404, "Absender ist nicht Empfaenger"
    assert _cm(world, hc, "GET", "/corrections/inbox")[1]["open"] == 1
    assert _cm(world, hc, "POST", f"/corrections/{cid}/status", {"status": "seen"})[0] == 200
    assert _cm(world, hc, "DELETE", f"/corrections/{cid}")[0] == 403
    assert _cm(world, ha, "DELETE", f"/corrections/{cid}")[0] == 200


def test_p39_09_roles_are_not_self_assignable(world):
    """Rolle `admin` vergibt nur der Betrieb (accounts.set_role, keine Route). Felder wie role/plan im Rumpf aendern
    nichts; Moderation ist fuer normale Konten 403, fuer Admins auch ohne Tarif erreichbar."""
    from app import accounts
    app, hb = world["app"], world["hb"]
    for m, p in (("PUT", "/api/settings"), ("POST", "/api/account/verify-email/resend"), ("POST", "/api/sync/push")):
        call(app, hb, m, p, {"role": "admin", "plan": "pro_ai", "items": [{"entity": "settings", "id": "role", "data": {"value": "admin"}}]})
    me = call(app, hb, "GET", "/api/account/me")[1]["user"]
    assert me.get("role") in (None, "user") and accounts.get_user(world["b"]["id"])["role"] != "admin"
    sid = world["ids"]["solution_id"]
    assert _cm(world, hb, "GET", "/moderation")[0] == 403
    assert _cm(world, hb, "POST", f"/solutions/{sid}/moderate", {"action": "hide"})[0] == 403
    assert call(app, hb, "GET", "/api/library/moderation")[0] == 403
    _, hadm = user(app, "admin3@beispiel.de", plan="free", admin=True)
    assert _cm(world, hadm, "GET", "/moderation")[0] == 200


def test_p39_10_claims_have_a_total_limit_per_account(world, monkeypatch):
    """Je Meldung hoechstens 5.000 Fingerabdruecke (Paket 3-4 Nr. 106), aber ohne Obergrenze insgesamt: wiederholte
    ergaenzende Meldungen liessen claims je Konto beliebig wachsen (600 Anfragen/Minute x 5.000 Zeilen)."""
    from app import community
    monkeypatch.setattr(community, "MAX_CLAIMS_TOTAL", 12)
    h = world["hb"]
    fps = lambda start: [f"{i:064x}" for i in range(start, start + 5)]  # noqa: E731
    assert _cm(world, h, "POST", "/claims", {"fingerprints": fps(100)})[0] == 200
    assert _cm(world, h, "POST", "/claims", {"fingerprints": fps(200)})[0] == 200
    st, d = _cm(world, h, "POST", "/claims", {"fingerprints": fps(300)})
    assert (st, d["code"]) == (429, "claims_limit"), (st, d)
    assert _cm(world, h, "POST", "/claims", {"fingerprints": fps(100)})[0] == 200, "schon gemeldete zaehlen nicht neu"
    st, d = _cm(world, h, "POST", "/claims", {"fingerprints": fps(300), "replace": True})
    assert st == 200 and d["total"] == 5, "voller Abgleich (replace) ersetzt"


def test_p39_11_release_says_whether_a_slot_was_freed(world):
    """DELETE /api/v2/shared-tests/{key}/{v} meldete immer `released: true`, auch fuer A's Platz, einen fertigen Test
    oder einen leeren Platz. Jetzt: true nur, wenn ein eigener leerer Platz frei wurde; A's Platz bleibt."""
    from app import test_library
    app = world["app"]
    st, d = call(app, world["hb"], "DELETE", f"/api/v2/shared-tests/{SHARE_KEY_A}/1")
    assert st == 200 and d["released"] is False, d
    assert test_library.shared_slots(SHARE_KEY_A)[1]["status"] == "pending"
    assert call(app, world["ha"], "DELETE", f"/api/v2/shared-tests/{SHARE_KEY_A}/0")[1]["released"] is False, "fertiger Test bleibt"
    assert call(app, world["ha"], "DELETE", f"/api/v2/shared-tests/{SHARE_KEY_A}/1")[1]["released"] is True
    assert 1 not in test_library.shared_slots(SHARE_KEY_A)
