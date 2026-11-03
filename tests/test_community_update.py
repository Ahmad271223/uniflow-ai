"""Eine Loesung je Konto, PDF und Community (03.11.2026): erneutes Veroeffentlichen zu derselben PDF in derselben
Community antwortet 409 `already_published` mit der vorhandenen `solution_id`; der Client fuehrt zusammen und ersetzt
das Paket der eigenen Loesung mit PUT /api/community/solutions/{id}. ID, Likes, Kommentare und Sichtbarkeit bleiben."""
import json

from test_community import _user, hosted  # noqa: F401
from test_community_groups import ANDERER, FP, KURS, call, member, package


def _pkg(sid=None, fp=FP, pages=2):
    from app import community
    return community.sample_package(fp, pages=pages, solution_id=sid, key_material="community-secret")


def _publish(app, h, pkg, key=KURS, title="Blatt 3"):
    return call(app, "POST", "/solutions", h, {"package": pkg, "title": title, "community_key": key})


def test_second_solution_to_the_same_pdf_and_community_is_refused_with_its_id(hosted):  # noqa: F811
    autor = member(hosted, "autor@beispiel.de")
    first = _pkg()
    assert _publish(hosted, autor, first)[0] == 201
    st, d = _publish(hosted, autor, _pkg())
    assert (st, d["code"], d["solution_id"]) == (409, "already_published", first["header"]["solutionId"])
    assert "Aktualisieren" in d["detail"]
    # dieselbe Loesung (gleiche ID) erneut: wie bisher ersetzt, kein Doppel
    assert _publish(hosted, autor, first)[1]["republished"] is True
    # andere PDF oder andere Community: eigene Loesung erlaubt
    assert _publish(hosted, autor, _pkg(fp="e" * 64))[0] == 201
    call(hosted, "POST", "/claims", autor, {"fingerprints": [], "course_keys": [KURS, ANDERER]})
    assert call(hosted, "POST", f"/communities/{ANDERER}/join", autor, {"kind": "course"})[0] == 200
    assert _publish(hosted, autor, _pkg(), key=ANDERER)[0] == 201
    # ein anderes Konto teilt zu derselben PDF ganz normal
    assert _publish(hosted, member(hosted, "zweite@beispiel.de"), _pkg())[0] == 201
    # zurueckgezogen zaehlt nicht mehr
    assert call(hosted, "DELETE", f"/solutions/{first['header']['solutionId']}", autor)[0] == 200
    assert _publish(hosted, autor, _pkg())[0] == 201


def test_update_replaces_the_package_and_keeps_id_likes_comments(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    first = _pkg()
    sid = first["header"]["solutionId"]
    assert _publish(hosted, autor, first)[0] == 201
    before = call(hosted, "GET", f"/communities/{KURS}/solutions", leser)[1]["solutions"][0]
    assert before["updated_at"] is None
    assert call(hosted, "POST", f"/solutions/{sid}/like", leser)[0] == 200
    st, c = call(hosted, "POST", f"/solutions/{sid}/comments", leser, {"text": "Schritt 2?", "page_key": "p1", "anchor": {"x": 0.5, "y": 0.5}})
    assert st == 201
    merged = _pkg(sid=sid, pages=5)
    st, d = call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": merged, "title": "Blatt 3 (ergänzt)", "community_key": KURS})
    assert st == 200, d
    assert d["solution_id"] == sid and d["pages"] == 5 and d["updated_at"]
    after = call(hosted, "GET", f"/communities/{KURS}/solutions", leser)[1]["solutions"]
    assert len(after) == 1
    a = after[0]
    assert (a["solution_id"], a["likes"], a["comments"], a["pages"], a["title"]) == (sid, 1, 1, 5, "Blatt 3 (ergänzt)")
    assert a["published_at"] == before["published_at"] and a["updated_at"] == d["updated_at"]
    assert a["community_key"] == KURS and a["status"] == "active"
    assert call(hosted, "GET", f"/solutions/{sid}", leser)[1]["package"] == merged, "neues Paket beim Laden"
    assert [x["page_key"] for x in call(hosted, "GET", f"/solutions/{sid}/comments", leser)[1]["comments"]] == ["p1"]
    # ohne Titel bleibt der bisherige
    assert call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": _pkg(sid=sid, pages=6)})[0] == 200
    assert call(hosted, "GET", "/mine", autor)[1]["solutions"][0]["title"] == "Blatt 3 (ergänzt)"


def test_update_only_by_the_owner_and_with_the_same_checks(hosted, monkeypatch):  # noqa: F811
    from app import accounts, community
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    fremd = member(hosted, "fremd@beispiel.de", course=ANDERER)
    first = _pkg()
    sid = first["header"]["solutionId"]
    assert _publish(hosted, autor, first)[0] == 201
    put = lambda h, body: call(hosted, "PUT", f"/solutions/{sid}", h, body)  # noqa: E731
    st, d = put(leser, {"package": _pkg(sid=sid)})
    assert (st, d["code"]) == (403, "not_owner"), "Mitglied, aber nicht der Autor"
    assert put(fremd, {"package": _pkg(sid=sid)})[1]["code"] == "not_owner"
    st, d = call(hosted, "PUT", "/solutions/6f1c1c0e-0000-4000-8000-00000000ffff", autor, {"package": _pkg(sid="6f1c1c0e-0000-4000-8000-00000000ffff")})
    assert (st, d["code"]) == (404, "not_found")
    assert put(autor, {"package": _pkg()})[1]["code"] == "solution_mismatch", "andere Kopf-ID"
    assert put(autor, {"package": _pkg(sid=sid, fp="e" * 64)})[1]["code"] == "solution_mismatch", "andere PDF"
    assert put(autor, {"package": _pkg(sid=sid), "community_key": ANDERER})[1]["code"] == "solution_mismatch", "Community bleibt"
    st, d = put(autor, {"package": community.sample_package(FP, solution_id=sid)})
    assert (st, d["code"]) == (400, "package_invalid"), "Community-Paket bleibt Community-Paket"
    broken = _pkg(sid=sid)
    broken["header"]["contents"]["pages"] = 0
    assert put(autor, {"package": broken})[0] == 400
    assert put(autor, {"package": {**_pkg(sid=sid), "fremd": 1}})[1]["code"] == "package_invalid"
    # Tarif, bestaetigte Adresse, Mitgliedschaft
    st, _, b = __import__("conftest").asgi_call(hosted, "GET", "/api/account/me", headers=autor)
    uid = json.loads(b)["user"]["id"]
    accounts.set_plan(uid, "free")
    assert put(autor, {"package": _pkg(sid=sid)})[1]["code"] == "plan_required"
    accounts.set_plan(uid, "plus")
    call(hosted, "DELETE", f"/communities/{KURS}/join", autor)
    assert put(autor, {"package": _pkg(sid=sid)})[1]["code"] == "not_a_member"
    assert call(hosted, "POST", f"/communities/{KURS}/join", autor, {"kind": "course"})[0] == 200
    # Grenze je Tag
    monkeypatch.setitem(accounts.LIMITS, "update_user", (1, 1440))
    assert put(autor, {"package": _pkg(sid=sid)})[0] == 200
    assert put(autor, {"package": _pkg(sid=sid)})[0] == 429
    # gesperrte (verborgene) Loesung: kein neues Doppel und kein Aktualisieren
    monkeypatch.setitem(accounts.LIMITS, "update_user", (60, 1440))
    with community.cursor() as conn:
        conn.execute("UPDATE solutions SET status='hidden' WHERE id=?", (sid,))
    assert _publish(hosted, autor, _pkg())[1]["code"] == "already_published"
    assert put(autor, {"package": _pkg(sid=sid)})[1]["code"] == "solution_blocked"


def test_update_needs_a_confirmed_email(hosted):  # noqa: F811
    from app import accounts
    autor = member(hosted, "autor@beispiel.de")
    first = _pkg()
    sid = first["header"]["solutionId"]
    assert _publish(hosted, autor, first)[0] == 201
    st, _, b = __import__("conftest").asgi_call(hosted, "GET", "/api/account/me", headers=autor)
    with accounts.cursor() as conn:
        conn.execute("UPDATE users SET email_verified=0 WHERE id=?", (json.loads(b)["user"]["id"],))
    assert call(hosted, "PUT", f"/solutions/{sid}", autor, {"package": _pkg(sid=sid)})[1]["code"] == "email_unverified"


def test_existing_duplicates_stay_and_the_newest_one_is_named(hosted):  # noqa: F811
    from app import community
    autor = member(hosted, "autor@beispiel.de")
    a, b = _pkg(), _pkg()
    assert _publish(hosted, autor, a)[0] == 201
    # altes Doppel (vor dem 03.11.2026) direkt in der Datenbank nachbilden
    with community.cursor() as conn:
        row = dict(conn.execute("SELECT * FROM solutions WHERE id=?", (a["header"]["solutionId"],)).fetchone())
        row.update(id=b["header"]["solutionId"], published_at="2099-01-01T00:00:00Z")
        conn.execute(f"INSERT INTO solutions({','.join(row)}) VALUES ({','.join('?' * len(row))})", tuple(row.values()))
    st, d = _publish(hosted, autor, _pkg())
    assert (st, d["solution_id"]) == (409, b["header"]["solutionId"]), "die zuletzt veroeffentlichte"
    rows = call(hosted, "GET", f"/communities/{KURS}/solutions", autor)[1]["solutions"]
    assert sorted(r["solution_id"] for r in rows) == sorted([a["header"]["solutionId"], b["header"]["solutionId"]]), "nichts geloescht"
