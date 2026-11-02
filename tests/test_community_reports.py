"""Melden in der Community (Loesung, Kommentar, Frage/Antwort): bestaetigte E-Mail, Sichtbarkeit, Obergrenze je Konto,
nur solche Meldungen verbergen einen Beitrag; Moderation sieht den Meldenden und kann Verborgenes wiederherstellen."""
import hashlib
import json

import pytest
from conftest import asgi_call

FP = "a" * 64
KEY = hashlib.sha256(b"uniflow.community.course.v1\x00luh\x00kurs-analysis-1").hexdigest()


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


def call(app, method, path, h, body=None):
    return _j(asgi_call(app, method, "/api/community" + path, body=json.dumps(body) if body is not None else None, headers=h))


def _user(app, email, plus=True, admin=False, verified=True):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    accounts.end_trial(d["user"]["id"])
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    if admin:
        accounts.set_role(d["user"]["id"], "admin")
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _claim(app, h):
    assert call(app, "POST", "/claims", h, {"fingerprints": [FP]})[0] == 200


@pytest.fixture
def scene(hosted):
    """Autor mit Loesung, Kommentar (Leser), Frage (Autor) und Antwort (Leser); Meldende kommen aus den Tests."""
    from app import community
    app = hosted
    _, ha = _user(app, "autor@beispiel.de")
    _, hl = _user(app, "leser@beispiel.de")
    for h in (ha, hl):
        _claim(app, h)
    pkg = community.sample_package(FP, pages=2, page_count=12, display_name="Erika", solution_id="6f1c1c0e-0000-4000-8000-0000000000a1")
    sid = call(app, "POST", "/solutions", ha, {"package": pkg, "title": "Blatt 3"})[1]["solution_id"]
    cid = call(app, "POST", f"/solutions/{sid}/comments", hl, {"text": "Ein Kommentar"})[1]["id"]
    qid = call(app, "POST", f"/courses/{KEY}/questions", ha, {"title": "Eine Frage"})[1]["id"]
    aid = call(app, "POST", f"/questions/{qid}/answers", hl, {"body": "Eine Antwort"})[1]["id"]
    return {"app": app, "ha": ha, "hl": hl, "sid": sid, "cid": cid, "qid": qid, "aid": aid}


def _routes(s):
    return [f"/solutions/{s['sid']}/report", f"/comments/{s['cid']}/report",
            f"/questions/{s['qid']}/report-post", f"/answers/{s['aid']}/report-post"]


def _state(s):
    """Sicht eines unbeteiligten Lesers (Autor der Loesung): Loesung, Kommentar, Frage, Antwort noch sichtbar?"""
    app, h = s["app"], s["ha"]
    sols = call(app, "GET", f"/solutions?fingerprint={FP}", h)[1]["solutions"]
    comments = call(app, "GET", f"/solutions/{s['sid']}/comments", h)[1]["comments"]
    qs = call(app, "GET", f"/courses/{KEY}/questions", s["hl"])[1]["questions"]
    q = call(app, "GET", f"/questions/{s['qid']}", s["hl"])
    answers = q[1]["answer_list"] if q[0] == 200 else []
    return (len(sols) == 1 and sols[0]["status"] == "active", len(comments) == 1, len(qs) == 1, len(answers) == 1)


def test_unverified_accounts_are_refused_on_all_report_routes_and_cannot_hide(scene):
    app = scene["app"]
    throwaway = [_user(app, f"wegwerf{i}@beispiel.de", plus=False, verified=False)[1] for i in range(3)]
    for h in throwaway:
        _claim(app, h)                      # selbst behauptete Besitzmeldung reicht fuer die Sichtbarkeit, nicht fuer Meldungen
        for path in _routes(scene):
            st, d = call(app, "POST", path, h, {"reason": "spam"})
            assert (st, d["code"]) == (403, "email_unverified"), path
    assert _state(scene) == (True, True, True, True)
    st, d = call(app, "GET", f"/solutions/{scene['sid']}", scene["ha"])
    assert st == 200 and d["solution"]["status"] == "active"


def test_reports_need_visibility_like_liking_and_commenting(scene):
    app = scene["app"]
    _, outsider = _user(app, "fremd@beispiel.de")                  # bestaetigt, aber ohne die PDF
    for path in _routes(scene)[:2]:
        st, d = call(app, "POST", path, outsider, {"reason": "spam"})
        assert (st, d["code"]) == (403, "file_not_owned"), path
    # gesperrter Autor: seine Frage ist fuer mich unsichtbar, also auch nicht meldbar
    _, h = _user(app, "sperrt@beispiel.de")
    _claim(app, h)
    assert call(app, "POST", f"/solutions/{scene['sid']}/block", h)[0] == 200
    assert call(app, "POST", _routes(scene)[2], h, {"reason": "spam"})[1]["code"] == "not_found"


def test_reports_are_limited_per_account_and_day(scene):
    from app import accounts
    app = scene["app"]
    assert accounts.LIMITS["report_user"] == (10, 1440)
    accounts.LIMITS["report_user"] = (2, 1440)
    _, h = _user(app, "melder@beispiel.de")
    _claim(app, h)
    assert call(app, "POST", _routes(scene)[0], h, {"reason": "spam"})[0] == 200
    assert call(app, "POST", _routes(scene)[1], h, {"reason": "spam"})[0] == 200
    assert call(app, "POST", _routes(scene)[1], h, {"reason": "spam"})[1]["code"] == "already_reported", "doppelt zaehlt nicht"
    st, d = call(app, "POST", _routes(scene)[2], h, {"reason": "spam"})
    assert (st, d["code"]) == (429, "rate_limited")
    st, d = call(app, "POST", _routes(scene)[3], h, {"reason": "spam"})
    assert (st, d["code"]) == (429, "rate_limited")


def test_verified_reports_hide_and_admin_can_restore_with_reporter_info(scene):
    app = scene["app"]
    reporters = []
    for i in range(3):
        h = _user(app, f"melder{i}@beispiel.de")[1]
        _claim(app, h)
        reporters.append(h)
    for h in reporters:
        for path in reversed(_routes(scene)):         # innen zuerst: Beitraege unter einer verborgenen Loesung/Frage sind nicht mehr meldbar
            assert call(app, "POST", path, h, {"reason": "spam"})[0] == 200, path
    assert _state(scene) == (False, False, False, False)
    _, hadm = _user(app, "admin@beispiel.de", admin=True)
    st, d = call(app, "GET", "/moderation", hadm)
    assert st == 200
    rep = d["solutions"][0]["reports"][0]
    assert rep["reporter"]["pseudonym"].startswith("Studi-") and rep["reporter"]["email_verified"] is True
    assert rep["reporter"]["account_age_days"] == 0
    assert "id" not in rep["reporter"] and "email" not in rep["reporter"]
    for table in ("comments", "questions", "answers"):
        items = d[table]
        assert len(items) == 1 and items[0]["status"] == "hidden" and len(items[0]["reports"]) == 3, table
        r0 = items[0]["reports"][0]["reporter"]
        assert r0["pseudonym"].startswith("Studi-") and r0["email_verified"] is True and r0["account_age_days"] == 0
    # nur der Admin darf wiederherstellen
    st, d = call(app, "POST", f"/comments/{scene['cid']}/moderate", scene["ha"], {"action": "restore"})
    assert (st, d["code"]) == (403, "forbidden")
    assert call(app, "POST", f"/comments/{scene['cid']}/moderate", hadm, {"action": "loeschen"})[1]["code"] == "action_invalid"
    assert call(app, "POST", f"/unbekannt/{scene['cid']}/moderate", hadm, {"action": "restore"})[0] == 404
    for kind, key in (("comments", "cid"), ("questions", "qid"), ("answers", "aid")):
        st, d = call(app, "POST", f"/{kind}/{scene[key]}/moderate", hadm, {"action": "restore"})
        assert st == 200 and d["status"] == "active", kind
        assert call(app, "POST", f"/{kind}/{scene[key]}/moderate", hadm, {"action": "restore"})[0] == 404, "nicht mehr verborgen"
    assert call(app, "POST", f"/solutions/{scene['sid']}/moderate", hadm, {"action": "restore"})[0] == 200
    assert _state(scene) == (True, True, True, True)
    st, d = call(app, "GET", "/moderation", hadm)
    assert d["comments"] == d["questions"] == d["answers"] == []
    # die Meldungen sind geloescht: dieselben Konten koennen erneut melden
    assert call(app, "POST", _routes(scene)[1], reporters[0], {"reason": "spam"})[1] == {"reported": True, "hidden": False, "reports": 1}
