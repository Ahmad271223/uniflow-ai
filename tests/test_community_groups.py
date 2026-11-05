"""Communities je Kurs und Lerngruppe (1.11.2026): Beitritt nur mit gemeldetem Kurs, Loesungen nur fuer Mitglieder, auch
ohne die PDF; Pakete ohne Community folgen weiter der PDF."""
import json

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401

KURS, ANDERER, GRUPPE = "1" * 64, "2" * 64, "3" * 64
FP = "a" * 64


def call(app, method, path, headers, body=None):
    st, _, b = asgi_call(app, method, "/api/community" + path, body=json.dumps(body) if body is not None else None, headers=headers)
    return st, json.loads(b) if b else None


def member(app, email, plus=True, course=KURS):
    _, h = _user(app, email, plus=plus)
    assert call(app, "POST", "/claims", h, {"fingerprints": [], "course_keys": [course]})[1]["courses"] == 1
    assert call(app, "POST", f"/communities/{course}/join", h, {"kind": "course"})[0] == 200
    return h


def package(fp=FP):
    from app import community
    return community.sample_package(fp, key_material="community-secret")


def test_join_only_for_own_course(hosted):  # noqa: F811
    _, h = _user(hosted, "a@beispiel.de")
    st, d = call(hosted, "POST", f"/communities/{KURS}/join", h, {"kind": "course"})
    assert st == 403 and "Kurs" in json.dumps(d, ensure_ascii=False)
    call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": [KURS]})
    rows = call(hosted, "GET", "/communities", h)[1]["communities"]
    assert [(r["community_key"], r["joined"], r["kind"]) for r in rows] == [(KURS, False, "course")]
    assert call(hosted, "POST", f"/communities/{KURS}/join", h, {"kind": "course"})[0] == 200
    assert call(hosted, "GET", "/communities", h)[1]["communities"][0]["joined"] is True
    assert call(hosted, "DELETE", f"/communities/{KURS}/join", h)[0] == 200
    assert call(hosted, "GET", "/communities", h)[1]["communities"][0]["joined"] is False


def test_solution_reaches_members_without_the_pdf_and_nobody_else(hosted):  # noqa: F811
    autor, leser = member(hosted, "autor@beispiel.de"), member(hosted, "leser@beispiel.de")
    fremd = member(hosted, "fremd@beispiel.de", course=ANDERER)
    pkg = package()
    sid = pkg["header"]["solutionId"]
    assert call(hosted, "POST", "/solutions", autor, {"package": pkg, "title": "Blatt", "community_key": KURS})[0] == 201
    rows = call(hosted, "GET", f"/communities/{KURS}/solutions", leser)[1]["solutions"]
    assert [r["solution_id"] for r in rows] == [sid]
    assert call(hosted, "GET", f"/solutions/{sid}", leser)[1]["package"] == pkg, "Mitglied laedt ohne die PDF"
    assert [r["solution_id"] for r in call(hosted, "GET", f"/solutions?fingerprint={FP}", leser)[1]["solutions"]] == [sid]
    assert call(hosted, "GET", f"/communities/{KURS}/solutions", fremd)[0] == 403
    assert call(hosted, "GET", f"/solutions/{sid}", fremd)[0] == 404
    assert call(hosted, "POST", f"/solutions/{sid}/like", fremd)[0] == 404
    assert call(hosted, "GET", f"/solutions?fingerprint={FP}", fremd)[1]["solutions"] == []
    call(hosted, "DELETE", f"/communities/{KURS}/join", leser)
    assert call(hosted, "GET", f"/solutions/{sid}", leser)[0] == 404, "nach dem Austritt ist die Loesung weg"


def test_publish_needs_membership_and_the_community_key_material(hosted, monkeypatch):  # noqa: F811
    from app import community
    monkeypatch.setattr(community, "LEGACY_PUBLISH", False)
    drin = member(hosted, "drin@beispiel.de")
    _, draussen = _user(hosted, "draussen@beispiel.de")
    assert call(hosted, "POST", "/solutions", draussen, {"package": package(), "community_key": KURS})[0] == 403
    assert call(hosted, "POST", "/solutions", drin, {"package": community.sample_package(FP), "community_key": KURS})[0] == 400
    assert call(hosted, "POST", "/solutions", drin, {"package": package()})[0] == 400, "Community-Paket braucht eine Community"
    assert call(hosted, "POST", "/solutions", drin, {"package": community.sample_package(FP)})[0] == 400, "ohne Community nichts Neues"
    assert call(hosted, "POST", "/solutions", drin, {"package": package(), "community_key": "kaputt"})[0] == 400


def test_study_group_lifecycle(hosted):  # noqa: F811
    _, a = _user(hosted, "a@beispiel.de")
    _, free = _user(hosted, "free@beispiel.de", plus=False)
    _, b = _user(hosted, "b@beispiel.de")
    st, d = call(hosted, "POST", f"/communities/{GRUPPE}/join", free, {"kind": "group"})
    assert (st, d["code"]) == (403, "plan_required"), "Community ab Plus, auch Beitreten (05.11.2026)"
    assert call(hosted, "POST", f"/communities/{GRUPPE}/join", a, {"kind": "group"})[0] == 404
    assert call(hosted, "POST", "/groups", free, {"group_key": GRUPPE, "name": "Runde"})[0] == 403, "anlegen ab Plus"
    assert call(hosted, "POST", "/groups", a, {"group_key": GRUPPE, "name": " "})[0] == 400
    assert call(hosted, "POST", "/groups", a, {"group_key": GRUPPE, "name": "Runde"})[0] == 201
    assert call(hosted, "POST", "/groups", a, {"group_key": GRUPPE, "name": "Andere"})[0] == 409
    assert call(hosted, "POST", f"/communities/{GRUPPE}/join", free, {"kind": "group"})[0] == 403, "beitreten ab Plus (05.11.2026)"
    assert call(hosted, "POST", f"/communities/{GRUPPE}/join", b, {"kind": "group"})[0] == 200
    rows = call(hosted, "GET", "/communities", b)[1]["communities"]
    assert [(r["name"], r["kind"], r["members"]) for r in rows] == [("Runde", "group", 2)]


def test_replace_claims_keeps_existing_memberships_but_drops_course_claim(hosted):  # noqa: F811
    h = member(hosted, "a@beispiel.de")
    call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": [ANDERER], "replace": True})
    rows = {r["community_key"]: r["joined"] for r in call(hosted, "GET", "/communities", h)[1]["communities"]}
    assert rows == {KURS: True, ANDERER: False}


def test_free_reads_no_community_but_withdraws_own_solutions(hosted):  # noqa: F811
    """Entscheidung 05.11.2026: Community ab Plus, auch das Lesen. Nach dem Herabstufen auf Free bleibt nichts geloescht,
    eigene Beitraege lassen sich auflisten und zurueckziehen; alles andere antwortet 403 plan_required."""
    from app import accounts
    u, autor = _user(hosted, "ab-plus@beispiel.de")
    call(hosted, "POST", "/claims", autor, {"fingerprints": [], "course_keys": [KURS]})
    assert call(hosted, "POST", f"/communities/{KURS}/join", autor, {"kind": "course"})[0] == 200
    pkg = package()
    sid = pkg["header"]["solutionId"]
    assert call(hosted, "POST", "/solutions", autor, {"package": pkg, "title": "Blatt", "community_key": KURS})[0] == 201
    accounts.set_plan(u["id"], "free")
    for method, path in (("GET", f"/communities/{KURS}/solutions"), ("GET", f"/solutions/{sid}"), ("GET", f"/solutions?fingerprint={FP}"),
                         ("GET", "/communities"), ("GET", f"/solutions/{sid}/comments"), ("GET", f"/courses/{KURS}/questions"),
                         ("GET", "/bookmarks"), ("GET", "/notifications"), ("GET", "/corrections/inbox")):
        st, d = call(hosted, method, path, autor)
        assert (st, d["code"], d["detail"]) == (403, "plan_required", "Die Community gibt es ab StudiNow Plus."), path
    info = call(hosted, "GET", "/info", autor)[1]
    assert (info["can_read"], info["can_share"]) == (False, False)
    assert [r["solution_id"] for r in call(hosted, "GET", "/mine", autor)[1]["solutions"]] == [sid], "eigene Beitraege bleiben sichtbar"
    assert call(hosted, "DELETE", f"/solutions/{sid}", autor)[1]["withdrawn"] is True, "zurueckziehen geht ohne Plus"
    assert call(hosted, "DELETE", f"/communities/{KURS}/join", autor)[0] == 200, "austreten geht ohne Plus"
