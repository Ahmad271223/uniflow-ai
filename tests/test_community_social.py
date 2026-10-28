"""Community fuer Windows und Apple (28.10.2026): Geraete melden ihre PDFs, Likes, Kommentare an einer Stelle der
Loesung, Rangliste fuer den Inhaber. Gleicher Ablauf fuer jedes Geraet: der Dienst kennt keine Plattform."""
import json

import pytest
from conftest import asgi_call

FP = "a" * 64
FP_OTHER = "e" * 64


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS))
    yield app
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def _user(app, email, plus=True, admin=False, verified=True, uni="luh"):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni})))
    assert st == 201, d
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    if admin:
        accounts.set_role(d["user"]["id"], "admin")
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _claim(app, h, *fps):
    return _j(asgi_call(app, "POST", "/api/community/claims", headers=h, body=json.dumps({"fingerprints": list(fps)})))


def _publish(app, h, fp=FP, title="Blatt 3", sid="6f1c1c0e-0000-4000-8000-0000000000a1"):
    from app import community
    pkg = community.sample_package(fp, pages=2, page_count=12, display_name="Erika", solution_id=sid)
    return _j(asgi_call(app, "POST", "/api/community/solutions", headers=h, body=json.dumps({"package": pkg, "title": title})))


def test_device_claims_let_windows_and_ipad_share_and_open(hosted):
    """Windows-App (Autor) und iPad (Leser) gleichen auf dem Geraet ab; beide melden ihre PDFs, dann klappt Teilen,
    Finden und Laden. Ohne Meldung: file_not_owned wie bisher."""
    a, ha = _user(hosted, "windows@beispiel.de")
    b, hb = _user(hosted, "ipad@beispiel.de")
    st, d = _publish(hosted, ha)
    assert (st, d["code"]) == (403, "file_not_owned")
    st, d = _claim(hosted, ha, FP, "kaputt", FP)
    assert st == 200 and d == {"accepted": 1, "ignored": 2, "total": 1}
    st, d = _publish(hosted, ha)
    assert st == 201, d
    sid = d["solution_id"]
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hb))
    assert (st, d["code"]) == (403, "file_not_owned"), "ohne eigene PDF nichts sehen"
    _claim(hosted, hb, FP)
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hb))
    assert st == 200 and [s["solution_id"] for s in d["solutions"]] == [sid]
    assert (d["solutions"][0]["likes"], d["solutions"][0]["comments"], d["solutions"][0]["liked_by_me"]) == (0, 0, False)
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions/{sid}", headers=hb))
    assert st == 200 and d["package"]["format"] == "uniflow-solution"
    # andere Hochschule sieht die Loesung nicht (Meldung gilt je Hochschule)
    c, hc = _user(hosted, "hildesheim@beispiel.de", uni="hildesheim")
    _claim(hosted, hc, FP)
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hc))
    assert st == 200 and d["solutions"] == []
    # replace: volle Meldung ersetzt die alte
    st, d = _j(asgi_call(hosted, "POST", "/api/community/claims", headers=hb, body=json.dumps({"fingerprints": [FP_OTHER], "replace": True})))
    assert d["total"] == 1
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hb))
    assert (st, d["code"]) == (403, "file_not_owned")


def test_likes_are_idempotent_not_for_own_and_need_a_confirmed_address(hosted):
    a, ha = _user(hosted, "autor@beispiel.de")
    b, hb = _user(hosted, "leser@beispiel.de", plus=False)              # liken geht auch mit Free
    u, hu = _user(hosted, "neu@beispiel.de", verified=False)
    for h in (ha, hb, hu):
        _claim(hosted, h, FP)
    sid = _publish(hosted, ha)[1]["solution_id"]
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/like", headers=ha))
    assert (st, d["code"]) == (400, "own_solution")
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/like", headers=hu))
    assert (st, d["code"]) == (403, "email_unverified")
    for _ in range(3):
        st, d = _j(asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/like", headers=hb))
    assert st == 200 and d == {"solution_id": sid, "liked": True, "likes": 1}
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hb))
    assert (d["solutions"][0]["likes"], d["solutions"][0]["liked_by_me"]) == (1, True)
    st, d = _j(asgi_call(hosted, "DELETE", f"/api/community/solutions/{sid}/like", headers=hb))
    assert d["likes"] == 0


def test_comments_with_anchor_replies_edit_delete_report(hosted):
    a, ha = _user(hosted, "autor@beispiel.de")
    b, hb = _user(hosted, "leser@beispiel.de")
    f, hf = _user(hosted, "free@beispiel.de", plus=False)
    for h in (ha, hb, hf):
        _claim(hosted, h, FP)
    sid = _publish(hosted, ha)[1]["solution_id"]
    base = f"/api/community/solutions/{sid}/comments"
    st, d = _j(asgi_call(hosted, "POST", base, headers=hf, body=json.dumps({"text": "Danke"})))
    assert (st, d["code"]) == (403, "plan_required"), "Kommentieren ab Plus, Lesen fuer alle"
    st, d = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "  "})))
    assert (st, d["code"]) == (400, "text_empty")
    st, d = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "x", "page_key": "p1", "anchor": {"x": 2, "y": 0.5}})))
    assert (st, d["code"]) == (400, "anchor_invalid")
    st, c1 = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps(
        {"text": "Hier fehlt die Begründung für Schritt 2.", "page_key": "p1", "anchor": {"x": 0.42, "y": 0.31}})))
    assert st == 201 and c1["anchor"] == {"x": 0.42, "y": 0.31} and c1["page_key"] == "p1" and c1["mine"]
    st, r1 = _j(asgi_call(hosted, "POST", base, headers=ha, body=json.dumps({"text": "Stimmt, ergänze ich.", "parent_id": c1["id"]})))
    assert st == 201 and r1["parent_id"] == c1["id"] and r1["by_author"] and r1["page_key"] == "p1", "Antwort erbt die Stelle"
    st, r2 = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "Danke!", "parent_id": r1["id"]})))
    assert r2["parent_id"] == c1["id"], "eine Ebene: Antwort auf Antwort haengt am ersten Kommentar"
    st, c2 = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "Allgemein: sehr übersichtlich."})))
    st, d = _j(asgi_call(hosted, "GET", base, headers=hf))
    assert st == 200 and [c["text"] for c in d["comments"]] == ["Hier fehlt die Begründung für Schritt 2.", "Stimmt, ergänze ich.", "Danke!",
                                                                 "Allgemein: sehr übersichtlich."]
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=hf))
    assert d["solutions"][0]["comments"] == 4
    # bearbeiten nur der Verfasser
    assert _j(asgi_call(hosted, "PATCH", f"/api/community/comments/{c1['id']}", headers=ha, body=json.dumps({"text": "x"})))[0] == 403
    st, d = _j(asgi_call(hosted, "PATCH", f"/api/community/comments/{c1['id']}", headers=hb, body=json.dumps({"text": "Hier fehlt die Begründung."})))
    assert st == 200 and d["edited_at"] and d["text"] == "Hier fehlt die Begründung."
    # loeschen: mit Antworten bleibt der Platzhalter, ohne Antworten verschwindet er
    assert _j(asgi_call(hosted, "DELETE", f"/api/community/comments/{c1['id']}", headers=hb))[0] == 200
    assert _j(asgi_call(hosted, "DELETE", f"/api/community/comments/{c2['id']}", headers=ha))[0] == 200, "Autor der Loesung darf entfernen"
    st, d = _j(asgi_call(hosted, "GET", base, headers=hb))
    assert [(c["deleted"], c["text"]) for c in d["comments"]] == [(True, ""), (False, "Stimmt, ergänze ich."), (False, "Danke!")]
    # melden: ab drei Meldungen verborgen
    st, d = _j(asgi_call(hosted, "POST", f"/api/community/comments/{r2['id']}/report", headers=hb, body=json.dumps({"reason": "spam"})))
    assert (st, d["code"]) == (400, "own_comment")
    users = [_user(hosted, f"m{i}@beispiel.de") for i in range(3)]
    for _, h in users:
        _claim(hosted, h, FP)
        st, d = _j(asgi_call(hosted, "POST", f"/api/community/comments/{r2['id']}/report", headers=h, body=json.dumps({"reason": "offensive"})))
    assert d["hidden"] is True
    st, d = _j(asgi_call(hosted, "GET", base, headers=hb))
    assert "Danke!" not in [c["text"] for c in d["comments"]]


def test_blocked_authors_comments_disappear_and_limits_apply(hosted):
    from app import accounts
    a, ha = _user(hosted, "autor@beispiel.de")
    b, hb = _user(hosted, "leser@beispiel.de")
    for h in (ha, hb):
        _claim(hosted, h, FP)
    sid = _publish(hosted, ha)[1]["solution_id"]
    base = f"/api/community/solutions/{sid}/comments"
    asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "nerviger Kommentar"}))
    sid2 = _publish(hosted, hb, sid="6f1c1c0e-0000-4000-8000-0000000000b2")[1]["solution_id"]
    asgi_call(hosted, "POST", f"/api/community/solutions/{sid2}/block", headers=ha)       # Autor sperrt den Leser
    st, d = _j(asgi_call(hosted, "GET", base, headers=ha))
    assert d["comments"] == []
    accounts.LIMITS["comment_user"] = (1, 60)
    st, d = _j(asgi_call(hosted, "POST", base, headers=hb, body=json.dumps({"text": "noch einer"})))
    assert (st, d["code"]) == (429, "rate_limited")


def test_leaderboard_only_for_the_owner_with_account_emails(hosted):
    from app import accounts
    boss, hboss = _user(hosted, "chef@beispiel.de", admin=True)
    a, ha = _user(hosted, "top@beispiel.de")
    b, hb = _user(hosted, "zweiter@beispiel.de")
    fans = [_user(hosted, f"fan{i}@beispiel.de", plus=False) for i in range(3)]
    for h in [ha, hb] + [h for _, h in fans]:
        _claim(hosted, h, FP)
    s1 = _publish(hosted, ha, sid="6f1c1c0e-0000-4000-8000-0000000000c1")[1]["solution_id"]
    s2 = _publish(hosted, hb, sid="6f1c1c0e-0000-4000-8000-0000000000c2")[1]["solution_id"]
    for _, h in fans:
        asgi_call(hosted, "POST", f"/api/community/solutions/{s1}/like", headers=h)
    asgi_call(hosted, "POST", f"/api/community/solutions/{s2}/like", headers=fans[0][1])
    asgi_call(hosted, "POST", f"/api/community/solutions/{s2}/like", headers=ha)
    st, d = _j(asgi_call(hosted, "GET", "/api/community/admin/leaderboard", headers=ha))
    assert (st, d["code"]) == (403, "forbidden")
    st, d = _j(asgi_call(hosted, "GET", "/api/community/admin/leaderboard", headers=hboss))
    assert st == 200
    top = d["authors"]
    assert [(x["rank"], x["email"], x["likes"], x["solutions"]) for x in top] == [(1, "top@beispiel.de", 3, 1), (2, "zweiter@beispiel.de", 2, 1)]
    assert top[0]["pseudonym"].startswith("Studi-") and top[0]["university"] == "luh"
    # die Suche zeigt die meistgelikte Loesung zuerst
    st, d = _j(asgi_call(hosted, "GET", f"/api/community/solutions?fingerprint={FP}", headers=fans[1][1]))
    assert [s["solution_id"] for s in d["solutions"]] == [s1, s2]


def test_account_deletion_removes_likes_comments_and_claims(hosted, monkeypatch):
    from datetime import timedelta
    from app import accounts, community
    a, ha = _user(hosted, "autor@beispiel.de")
    b, hb = _user(hosted, "weg@beispiel.de")
    for h in (ha, hb):
        _claim(hosted, h, FP)
    sid = _publish(hosted, ha)[1]["solution_id"]
    asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/like", headers=hb)
    asgi_call(hosted, "POST", f"/api/community/solutions/{sid}/comments", headers=hb, body=json.dumps({"text": "Kommentar von B"}))
    accounts.delete_account(b["id"], "sehr-geheim-123")
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM likes WHERE user_id=?", (b["id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM comments WHERE author_id=?", (b["id"],)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM claims WHERE user_id=?", (b["id"],)).fetchone()[0] == 0
