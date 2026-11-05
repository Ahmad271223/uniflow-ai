"""Sicherheitspruefung 3.11.2026, Fund 2 und 1b: Lerngruppen duerfen keinen Kurs-/Modulschluessel besetzen, Gruppennamen
sehen nur Mitglieder, Beitritt nur mit bestaetigter E-Mail, neue Kursschluessel je Konto und Tag begrenzt."""
import json

from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401

KURS, GRUPPE = "1" * 64, "3" * 64


def call(app, method, path, headers, body=None):
    st, _, b = asgi_call(app, method, "/api/community" + path, body=json.dumps(body) if body is not None else None, headers=headers)
    return st, json.loads(b) if b else None


def test_group_cannot_squat_claimed_course_key(hosted):  # noqa: F811
    _, opfer = _user(hosted, "opfer@beispiel.de")
    call(hosted, "POST", "/claims", opfer, {"fingerprints": [], "course_keys": [KURS]})
    _, boese = _user(hosted, "boese@beispiel.de")
    st, d = call(hosted, "POST", "/groups", boese, {"group_key": KURS, "name": "Offizielle Musterloesungen"})
    assert st == 409, d
    rows = call(hosted, "GET", "/communities", opfer)[1]["communities"]
    assert [(r["community_key"], r["kind"], r["name"]) for r in rows] == [(KURS, "course", None)]


def test_group_cannot_squat_existing_course_community(hosted):  # noqa: F811
    _, a = _user(hosted, "a@beispiel.de")
    call(hosted, "POST", "/claims", a, {"fingerprints": [], "course_keys": [KURS]})
    assert call(hosted, "POST", f"/communities/{KURS}/join", a, {"kind": "course"})[0] == 200
    call(hosted, "POST", "/claims", a, {"fingerprints": [], "course_keys": [], "replace": True})   # Meldung weg, Community bleibt
    _, b = _user(hosted, "b@beispiel.de")
    assert call(hosted, "POST", "/groups", b, {"group_key": KURS, "name": "Kapern"})[0] == 409


def test_group_name_only_for_members_and_course_claim_ignores_group_keys(hosted):  # noqa: F811
    _, gruender = _user(hosted, "g@beispiel.de")
    assert call(hosted, "POST", "/groups", gruender, {"group_key": GRUPPE, "name": "Hier beitreten"})[0] == 201
    _, opfer = _user(hosted, "o@beispiel.de")
    d = call(hosted, "POST", "/claims", opfer, {"fingerprints": [], "course_keys": [GRUPPE]})[1]
    assert d["courses"] == 0, "Gruppenschluessel ist kein Kurs"
    assert call(hosted, "GET", "/communities", opfer)[1]["communities"] == []
    assert call(hosted, "POST", f"/communities/{GRUPPE}/join", opfer, {"kind": "course"})[0] == 403
    # Beitritt als Gruppe nur fuer bestehende Gruppen, danach sieht das Mitglied den Namen
    assert call(hosted, "POST", f"/communities/{'4' * 64}/join", opfer, {"kind": "group"})[0] == 404
    assert call(hosted, "POST", f"/communities/{GRUPPE}/join", opfer, {"kind": "group"})[0] == 200
    rows = call(hosted, "GET", "/communities", opfer)[1]["communities"]
    assert [(r["kind"], r["name"]) for r in rows] == [("group", "Hier beitreten")]


def test_group_join_with_kind_group_rejected_for_course_key(hosted):  # noqa: F811
    _, a = _user(hosted, "a@beispiel.de")
    call(hosted, "POST", "/claims", a, {"fingerprints": [], "course_keys": [KURS]})
    assert call(hosted, "POST", f"/communities/{KURS}/join", a, {"kind": "group"})[0] == 404


def test_join_needs_verified_email(hosted):  # noqa: F811
    _, h = _user(hosted, "unbestaetigt@beispiel.de", verified=False)
    call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": [KURS]})
    st, d = call(hosted, "POST", f"/communities/{KURS}/join", h, {"kind": "course"})
    assert st == 403 and "email_unverified" in json.dumps(d)


def test_new_course_keys_per_day_are_limited(hosted, monkeypatch):  # noqa: F811
    monkeypatch.setenv("LERNAPP_LIMIT_COURSE_KEYS_USER", "3/1440")
    _, h = _user(hosted, "viele@beispiel.de")
    keys = [f"{i:064x}" for i in range(1, 6)]
    d = call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": keys})[1]
    assert d["courses"] == 3 and d["courses_limited"] == 2
    # schon gemeldete zaehlen nicht erneut (voller Abgleich mit replace)
    d = call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": keys[:3], "replace": True})[1]
    assert d["courses"] == 3 and "courses_limited" not in d
    d = call(hosted, "POST", "/claims", h, {"fingerprints": [], "course_keys": keys})[1]
    assert d["courses"] == 3 and d["courses_limited"] == 2
    st, _ = call(hosted, "POST", f"/communities/{keys[4]}/join", h, {"kind": "course"})
    assert st == 403


def test_group_preview_before_joining(hosted):  # noqa: F811
    _, g = _user(hosted, "gruender@beispiel.de")
    assert call(hosted, "POST", "/groups", g, {"group_key": GRUPPE, "name": "Lernrunde Mathe"})[0] == 201
    _, free = _user(hosted, "free@beispiel.de", plus=False)
    assert call(hosted, "GET", f"/groups/{GRUPPE}", free)[1]["code"] == "plan_required", "Community ab Plus (05.11.2026)"
    _, neu = _user(hosted, "neu@beispiel.de")
    st, d = call(hosted, "GET", f"/groups/{GRUPPE}", neu)
    assert st == 200 and d["name"] == "Lernrunde Mathe" and d["members"] == 1
    assert call(hosted, "GET", "/communities", neu)[1]["communities"] == [], "Vorschau tritt nicht bei"
    # Kurs-/Modulschluessel liefern nie einen Namen
    call(hosted, "POST", "/claims", neu, {"fingerprints": [], "course_keys": [KURS]})
    assert call(hosted, "GET", f"/groups/{KURS}", neu)[0] == 404
    assert call(hosted, "GET", "/groups/kaputt", neu)[0] == 400


def test_solution_stroke_limits_python():
    import pytest
    from app import solution_format as sf
    assert (sf.MAX_STROKE_VALUES, sf.MAX_STROKE_NUMBERS) == (100_000, 10_000_000)

    def page(objs):
        return {"pages": [{"key": "p1", "objects": objs}]}
    sf.check_stroke_sizes(page([{"type": "stroke", "pointsDelta": [0] * 100_000}]))
    with pytest.raises(ValueError, match="tooLarge"):
        sf.check_stroke_sizes(page([{"type": "stroke", "widths": [0] * 100_001}]))
    with pytest.raises(ValueError, match="tooLarge"):
        sf.check_stroke_sizes(page([{"type": "stroke", "pointsDelta": [0] * 99_999}] * 101))
