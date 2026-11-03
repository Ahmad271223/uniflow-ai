"""Korrekturvorschlaege im Dienst (app/community_corrections.py, 03.11.2026): schicken (Tarif wie Teilen, bestaetigte
E-Mail, Mitglied, nie zur eigenen Loesung), Liste fuer Mitglieder, Posteingang mit Gesehen/Ignorieren und Zahl, Melden und
Verbergen, Zuruecknehmen, Grenzen, Konto loeschen, Datenexport, Chiffrat-Referenz gegen die gemeinsamen Vektoren."""
import json
import re
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_community_groups import FP, KURS, call, member, package

ROOT = Path(__file__).resolve().parents[1]
VECTORS = ROOT / "packages" / "shared-contracts" / "fixtures" / "community" / "correction-vectors.json"


def chiffrat(solution_id, correction_id, text="Aufgabe 2b: Vorzeichen", secret=b"s" * 32):
    """Ein echtes Chiffrat (Referenz) fuer die Tests: der Dienst prueft nur die Form."""
    from app import community_corrections as cc
    c = {"id": correction_id, "solution_id": solution_id, "pseudonym": "Ben", "created_at": "2026-11-03T10:00:00Z", "note": text,
         "pages": [{"pdfIndex": 3, "width": 595, "height": 842, "rotation": 0,
                    "strokes": [{"id": "s1", "type": "stroke", "tool": "pen", "color": "#e5322d", "width": 2.2, "opacity": 1,
                                 "points": [10.04, 20, 11.5, 20.75], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1}],
                    "notes": [{"id": "n1", "x": 0.25, "y": 0.75, "text": "hier fehlt ein Minus"}]}]}
    return cc.seal(c, secret, b"\x01" * 32, b"\x02" * 12)


def cid(n=1):
    return f"00000000-0000-4000-8000-{n:012d}"


@pytest.fixture
def world(hosted):  # noqa: F811
    """Autor einer Loesung in der Community, Leser (Mitglied), Fremder (nicht Mitglied), Free-Konto (Mitglied)."""
    app = hosted
    autor, leser = member(app, "autor@beispiel.de"), member(app, "leser@beispiel.de")
    fremd = member(app, "fremd@beispiel.de", course="2" * 64)
    free = member(app, "free@beispiel.de", plus=False)
    pkg = package()
    sid = pkg["header"]["solutionId"]
    assert call(app, "POST", "/solutions", autor, {"package": pkg, "title": "Blatt 4", "community_key": KURS})[0] == 201
    return type("W", (), dict(app=app, autor=autor, leser=leser, fremd=fremd, free=free, sid=sid))


def send(w, h, n=1, sid=None, payload=None):
    sid = sid or w.sid
    return call(w.app, "POST", f"/solutions/{sid}/corrections", h, {"id": cid(n), "payload": payload if payload is not None else chiffrat(sid, cid(n))})


def test_send_list_inbox_and_counter(world):
    w = world
    st, c = send(w, w.leser)
    assert st == 201, c
    assert c["id"] == cid(1) and c["solution_id"] == w.sid and c["mine"] and not c["for_me"] and c["status"] is None
    assert re.fullmatch(r"Studi-[0-9a-f]{8}", c["pseudonym"]) and c["payload"]
    # keine Konto-ID, keine E-Mail in der Antwort
    assert "beispiel.de" not in json.dumps(c) and not re.search(r"\b[0-9a-f]{32}\b", json.dumps({k: v for k, v in c.items() if k != "payload"}))
    # Mitglieder sehen die Korrektur unter der Diskussion; der Ersteller mit Zustand "offen"
    rows = call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.autor)[1]["corrections"]
    assert [r["id"] for r in rows] == [cid(1)] and rows[0]["for_me"] and rows[0]["status"] == "open" and not rows[0]["mine"]
    rows = call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.free)[1]["corrections"]
    assert [r["id"] for r in rows] == [cid(1)] and rows[0]["status"] is None, "Lesen duerfen alle Mitglieder"
    assert call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.fremd)[0] == 404, "Fremde sehen nichts"
    # Posteingang des Erstellers: ohne Chiffrat, mit Titel; die Zahl ist die am Menuepunkt
    box = call(w.app, "GET", "/corrections/inbox", w.autor)[1]
    assert box["open"] == 1 and box["seen"] == 0 and len(box["items"]) == 1
    it = box["items"][0]
    assert it["title"] == "Blatt 4" and it["fingerprint"] == FP and it["community_key"] == KURS and "payload" not in it
    assert call(w.app, "GET", "/corrections/inbox?count_only=true", w.autor)[1] == {"open": 1, "seen": 0}
    assert call(w.app, "GET", "/corrections/inbox", w.leser)[1] == {"open": 0, "seen": 0, "items": []}, "der Verfasser hat keinen Hinweis"
    # Benachrichtigung im Konto (Glocke)
    n = call(w.app, "GET", "/notifications", w.autor)[1]["notifications"]
    assert [(x["kind"], x["target_kind"], x["fingerprint"]) for x in n] == [("correction", "solution", FP)]
    # Chiffrat holen (Ansehen)
    full = call(w.app, "GET", f"/corrections/{cid(1)}", w.autor)[1]
    assert full["payload"] == c["payload"] and full["title"] == "Blatt 4"
    assert call(w.app, "GET", f"/corrections/{cid(1)}", w.fremd)[0] == 404


def test_seen_ignored_state_belongs_to_the_owner_and_changes_the_counter(world):
    w = world
    send(w, w.leser, 1)
    send(w, w.leser, 2)
    assert call(w.app, "GET", "/corrections/inbox?count_only=true", w.autor)[1] == {"open": 2, "seen": 0}
    st, r = call(w.app, "POST", f"/corrections/{cid(1)}/status", w.autor, {"status": "seen"})
    assert st == 200 and r == {"id": cid(1), "status": "seen", "open": 1, "seen": 1}
    assert call(w.app, "GET", "/corrections/inbox?count_only=true", w.autor)[1] == {"open": 1, "seen": 1}, "Oeffnen = gesehen, zaehlt nicht mehr"
    call(w.app, "POST", f"/corrections/{cid(2)}/status", w.autor, {"status": "ignored"})
    box = call(w.app, "GET", "/corrections/inbox", w.autor)[1]
    assert (box["open"], box["seen"]) == (0, 1) and [i["id"] for i in box["items"]] == [cid(1)] and box["items"][0]["status"] == "seen"
    # nur der Ersteller der Loesung; Fremde und der Verfasser nicht
    assert call(w.app, "POST", f"/corrections/{cid(1)}/status", w.leser, {"status": "seen"})[0] == 404
    assert call(w.app, "POST", f"/corrections/{cid(1)}/status", w.autor, {"status": "kaputt"})[0] == 400
    # Ignorieren gilt nur fuer den Posteingang: unter der Diskussion bleibt die Korrektur fuer alle
    rows = call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.leser)[1]["corrections"]
    assert {r["id"] for r in rows} == {cid(1), cid(2)}
    assert call(w.app, "POST", f"/corrections/{cid(2)}/status", w.autor, {"status": "open"})[1]["open"] == 1


def test_permissions_like_sharing(world):
    w = world
    assert send(w, w.free)[0] == 403 and send(w, w.free)[1]["code"] == "plan_required", "Tarif wie Teilen"
    assert send(w, w.fremd)[0] == 404, "nur Mitglieder der Community"
    st, d = send(w, w.autor)
    assert st == 400 and d["code"] == "own_solution", "nie zur eigenen Loesung"
    _, unverified = _user(w.app, "neu@beispiel.de", plus=True, verified=False)
    call(w.app, "POST", "/claims", unverified, {"fingerprints": [], "course_keys": [KURS]})
    assert send(w, unverified)[1]["code"] in ("email_unverified", "not_found")
    assert call(w.app, "POST", f"/solutions/{w.sid}/corrections", w.leser, {"id": "kaputt", "payload": chiffrat(w.sid, cid())})[1]["code"] == "id_invalid"
    for bad in ("", "kein base64!", "AAAA", "Zg==" * 40):
        st, d = send(w, w.leser, payload=bad)
        assert st in (400, 422) and d["code"] == "payload_invalid", bad
    assert send(w, w.leser, payload="A" * 750_004)[0] == 413
    assert call(w.app, "POST", f"/solutions/{w.sid}/corrections", w.leser, {"id": cid(), "payload": 5})[1]["code"] == "payload_invalid"
    assert send(w, w.leser)[0] == 201
    assert send(w, w.leser)[0] == 409, "dieselbe Kennung nicht doppelt"
    assert asgi_call(w.app, "POST", f"/api/community/solutions/{w.sid}/corrections", body=json.dumps({"id": cid(), "payload": "x"}))[0] == 401


def test_limits_per_user_solution_and_day(world, monkeypatch):
    from app import accounts, community_corrections as cc
    w = world
    for n in range(1, cc.MAX_PER_USER + 1):
        assert send(w, w.leser, n)[0] == 201
    st, d = send(w, w.leser, 99)
    assert st == 429 and d["code"] == "corrections_limit"
    other = member(w.app, "zweite@beispiel.de")
    assert send(w, other, 50)[0] == 201, "die Grenze gilt je Konto"
    # Tagesgrenze
    monkeypatch.setitem(accounts.LIMITS, "correction_user", (2, 1440))
    third = member(w.app, "dritte@beispiel.de")
    assert [send(w, third, n)[0] for n in (60, 61, 62)] == [201, 201, 429]
    # Gesamtgrenze je Loesung
    monkeypatch.setattr(cc, "MAX_PER_SOLUTION", 1)
    fourth = member(w.app, "vierte@beispiel.de")
    assert send(w, fourth, 70)[1]["code"] == "corrections_limit"


def test_withdraw_report_hide_and_moderation(world):
    w = world
    send(w, w.leser, 1)
    assert call(w.app, "DELETE", f"/corrections/{cid(1)}", w.autor)[0] == 403, "nur der Verfasser nimmt zurueck"
    assert call(w.app, "POST", f"/corrections/{cid(1)}/report", w.leser, {"reason": "spam"})[1]["code"] == "own_post"
    # drei verschiedene Meldungen verbergen die Korrektur
    reporters = [w.autor] + [member(w.app, f"melder{i}@beispiel.de") for i in range(2)]
    assert call(w.app, "POST", f"/corrections/{cid(1)}/report", reporters[0], {"reason": "kaputt"})[1]["code"] == "reason_invalid"
    assert call(w.app, "POST", f"/corrections/{cid(1)}/report", reporters[0], {"reason": "spam"})[1] == {"reported": True, "hidden": False, "reports": 1}
    assert call(w.app, "POST", f"/corrections/{cid(1)}/report", reporters[0], {"reason": "spam"})[0] == 409
    call(w.app, "POST", f"/corrections/{cid(1)}/report", reporters[1], {"reason": "spam"})
    assert call(w.app, "POST", f"/corrections/{cid(1)}/report", reporters[2], {"reason": "offensive"})[1]["hidden"] is True
    assert call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.autor)[1]["corrections"] == []
    assert call(w.app, "GET", "/corrections/inbox?count_only=true", w.autor)[1] == {"open": 0, "seen": 0}
    # Moderation sieht die Meldungen ohne Inhalt und kann freigeben
    _, h = _user(w.app, "admin@beispiel.de", admin=True)
    mod = call(w.app, "GET", "/moderation", h)[1]["corrections"]
    assert len(mod) == 1 and mod[0]["status"] == "hidden" and mod[0]["report_count"] == 3 and mod[0]["context"] == w.sid and mod[0]["text"] == ""
    assert all(set(r["reporter"]) == {"pseudonym", "account_age_days", "email_verified"} for r in mod[0]["reports"])
    assert call(w.app, "POST", f"/corrections/{cid(1)}/moderate", h, {"action": "restore"})[0] == 200
    assert [r["id"] for r in call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.autor)[1]["corrections"]] == [cid(1)]
    assert call(w.app, "POST", f"/corrections/{cid(1)}/moderate", w.leser, {"action": "restore"})[0] == 403
    # Zuruecknehmen: das Chiffrat wird geleert, die Korrektur ist weg
    assert call(w.app, "DELETE", f"/corrections/{cid(1)}", w.leser)[1] == {"deleted": True, "id": cid(1)}
    assert call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.autor)[1]["corrections"] == []
    assert call(w.app, "GET", f"/corrections/{cid(1)}", w.leser)[0] == 404
    from app import community
    with community.cursor() as conn:
        assert conn.execute("SELECT payload FROM corrections WHERE id=?", (cid(1),)).fetchone()[0] == ""


def test_blocked_author_and_banned_author_are_hidden(world):
    w = world
    send(w, w.leser, 1)
    third = member(w.app, "dritter@beispiel.de")
    # Autor der Korrektur sperren: der Dienst sperrt ueber eine Loesung des Autors
    pkg2 = package("b" * 64)
    assert call(w.app, "POST", "/solutions", w.leser, {"package": pkg2, "title": "Von Leser", "community_key": KURS})[0] == 201
    assert call(w.app, "POST", f"/solutions/{pkg2['header']['solutionId']}/block", w.autor)[0] == 200
    assert call(w.app, "GET", f"/solutions/{w.sid}/corrections", w.autor)[1]["corrections"] == [], "gesperrte Verfasser fallen weg"
    assert call(w.app, "GET", "/corrections/inbox?count_only=true", w.autor)[1] == {"open": 0, "seen": 0}
    assert call(w.app, "GET", f"/corrections/{cid(1)}", w.autor)[0] == 404
    assert [r["id"] for r in call(w.app, "GET", f"/solutions/{w.sid}/corrections", third)[1]["corrections"]] == [cid(1)]


def test_account_deletion_and_export(world):
    import io
    import zipfile

    from app import community
    w = world
    send(w, w.leser, 1)
    st, _, raw = asgi_call(w.app, "GET", "/api/account/export", headers=w.leser)
    assert st == 200
    z = zipfile.ZipFile(io.BytesIO(raw))
    mine = json.loads(z.read("community/meine-korrekturen.json"))
    assert [(r["id"], r["solution_id"]) for r in mine] == [(cid(1), w.sid)] and mine[0]["payload"]
    # Konto des Verfassers loeschen: seine Korrekturen sind weg
    leser_id = community_user_id(w, "leser@beispiel.de")
    community.forget_author(leser_id)
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM corrections").fetchone()[0] == 0
    send(w, member(w.app, "noch@beispiel.de"), 2)
    # Konto des Erstellers loeschen: Loesung samt Korrekturen weg, ohne Fremdschluesselfehler
    community.forget_author(community_user_id(w, "autor@beispiel.de"))
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM corrections").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM correction_reports").fetchone()[0] == 0


def community_user_id(w, email):
    from app import accounts
    with accounts.cursor() as conn:
        return conn.execute("SELECT id FROM users WHERE email=?", (email,)).fetchone()[0]


def test_question_likes_and_unanswered_filter(world):
    """Fragen der Community-Seite: Likes (nicht auf die eigene Frage) und Filter "Unbeantwortet"."""
    w = world
    key = KURS
    st, q1 = call(w.app, "POST", f"/courses/{key}/questions", w.leser, {"title": "Erste Frage?"})
    st, q2 = call(w.app, "POST", f"/courses/{key}/questions", w.leser, {"title": "Zweite Frage?"})
    assert q1["likes"] == 0 and q1["liked_by_me"] is False
    assert call(w.app, "POST", f"/questions/{q1['id']}/like", w.leser)[1]["code"] == "own_post"
    assert call(w.app, "POST", f"/questions/{q1['id']}/like", w.autor)[1] == {"question_id": q1["id"], "liked": True, "likes": 1}
    assert call(w.app, "POST", f"/questions/{q1['id']}/like", w.autor)[1]["likes"] == 1, "idempotent"
    rows = {r["id"]: r for r in call(w.app, "GET", f"/courses/{key}/questions", w.autor)[1]["questions"]}
    assert rows[q1["id"]]["likes"] == 1 and rows[q1["id"]]["liked_by_me"] and not rows[q2["id"]]["liked_by_me"]
    assert call(w.app, "POST", f"/questions/{q1['id']}/like", w.free)[0] == 200, "Liken ist nicht an den Tarif gebunden"
    call(w.app, "POST", f"/questions/{q2['id']}/answers", w.autor, {"body": "Antwort"})
    open_ = call(w.app, "GET", f"/courses/{key}/questions?unanswered=true", w.autor)[1]["questions"]
    assert [r["id"] for r in open_] == [q1["id"]], "nur ohne Antwort"
    assert call(w.app, "DELETE", f"/questions/{q1['id']}/like", w.autor)[1]["likes"] == 1
    _, unverified = _user(w.app, "u@beispiel.de", verified=False)
    assert call(w.app, "POST", f"/questions/{q1['id']}/like", unverified)[1]["code"] == "email_unverified"


# ---------------------------------------------------------------- Chiffrat: Gegenprobe zu Swift und Browser

def test_ciphertext_roundtrip_and_binding():
    from app import community_corrections as cc
    sid, c1 = "6f1c1c0e-0000-4000-8000-000000000003", cid(1)
    payload = chiffrat(sid, c1)
    opened = cc.open_payload(payload, c1, sid, b"s" * 32)
    assert opened["note"] == "Aufgabe 2b: Vorzeichen" and opened["pages"][0]["strokes"][0]["points"] == [10.0, 20.0, 11.5, 20.8]
    assert opened["pages"][0]["notes"][0]["text"] == "hier fehlt ein Minus"
    for args in ((payload, c1, sid, b"x" * 32), (payload, cid(2), sid, b"s" * 32), (payload, c1, "6f1c1c0e-0000-4000-8000-000000000009", b"s" * 32)):
        with pytest.raises(ValueError):
            cc.open_payload(*args)
    cc.check_payload(payload)


def test_shared_vectors_are_current():
    """Die gemeinsamen Vektoren (Browser und spaeter Swift) entsprechen der Referenz: `python tools/gen-correction-vectors.py`."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_correction_vectors", ROOT / "tools" / "gen-correction-vectors.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.build() == json.loads(VECTORS.read_text(encoding="utf-8")), "python tools/gen-correction-vectors.py neu ausfuehren"
