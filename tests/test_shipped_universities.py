"""Ausgelieferte Hochschulen (08.11.2026, Punkt 1 der Windows-Fertigstellung): Version 1.0 bietet in Web und Windows-App
wie auf dem iPad (UFReleaseUniversities) nur die LUH an. Schalter LERNAPP_SHIPPED_UNIVERSITIES; Tests laufen mit "all"
(tests/conftest.py), hier wird der Schalter je Test gesetzt."""
import json

import pytest
from conftest import asgi_call

from app import config, universities


@pytest.fixture
def unset(monkeypatch):
    monkeypatch.delenv(universities.SHIPPED_ENV, raising=False)
    monkeypatch.delenv("LERNAPP_DESKTOP", raising=False)
    monkeypatch.setattr(config, "MODE", "local")
    return monkeypatch


def _j(res):
    st, _, body = res
    return st, json.loads(body or b"{}")


def test_hosted_default_is_only_luh(unset):
    unset.setattr(config, "MODE", "hosted")
    assert universities.shipped() == ("luh",)
    assert universities.is_shipped("luh") and not universities.is_shipped("hildesheim") and not universities.is_shipped("hsh")
    assert universities.more_note() == "Weitere Hochschulen folgen mit einem Update."


def test_windows_app_default_is_only_luh(unset):
    unset.setenv("LERNAPP_DESKTOP", "1")
    assert universities.shipped() == ("luh",)


def test_development_and_tests_offer_all_three(unset):
    assert universities.shipped() == ("luh", "hildesheim", "hsh")
    assert universities.more_note() is None
    unset.setenv(universities.SHIPPED_ENV, "all")
    unset.setattr(config, "MODE", "hosted")
    assert universities.shipped() == ("luh", "hildesheim", "hsh")


def test_switch_lists_known_universities_only(unset):
    unset.setenv(universities.SHIPPED_ENV, "luh, hildesheim ,quatsch")
    assert universities.shipped() == ("luh", "hildesheim")
    unset.setenv(universities.SHIPPED_ENV, "quatsch")
    unset.setattr(config, "MODE", "hosted")
    assert universities.shipped() == ("luh",), "nur Unbekanntes: Standard der Auslieferung"


def test_choices_keep_the_running_university(unset):
    unset.setattr(config, "MODE", "hosted")
    assert [c["key"] for c in universities.choices("luh")] == ["luh"]
    assert [c["key"] for c in universities.choices("hsh")] == ["hsh", "luh"], "bestehende HsH-Daten bleiben waehlbar"


def test_account_info_in_hosted_mode_offers_only_luh(app, unset):
    unset.setattr(config, "MODE", "hosted")
    st, d = _j(asgi_call(app, "GET", "/api/account/info"))
    assert st == 200 and d["universities"] == ["luh"]
    assert d["universities_note"] == universities.MORE_NOTE


def test_registration_with_unshipped_university_is_refused(app, unset):
    unset.setattr(config, "MODE", "hosted")
    st, d = _j(asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": "nur-luh@example.org", "password": "x" * 12, "university": "hildesheim"})))
    assert (st, d["code"]) == (400, "university_not_shipped")
    assert universities.MORE_NOTE in d["detail"]


def test_services_and_settings_follow_the_switch(app, unset):
    """Wie die ausgelieferte Windows-App (dort LERNAPP_DESKTOP=1, hier der Schalter, weil die App-Pflicht sonst 401 gibt)."""
    unset.setenv(universities.SHIPPED_ENV, "luh")
    st, d = _j(asgi_call(app, "GET", "/api/services"))
    assert st == 200
    assert [u["key"] for u in d["universities"]] == ["luh"] or d["universities"][0]["key"] == config.configured_university()
    assert d["universities_note"] == universities.MORE_NOTE
    st, d = _j(asgi_call(app, "PUT", "/api/settings", body=json.dumps({"university": "hsh"})))
    assert (st, d["code"]) == (400, "university_not_shipped")
    # mit dem Schalter "all" (Debug) geht der Wechsel wieder
    unset.setenv(universities.SHIPPED_ENV, "all")
    st, d = _j(asgi_call(app, "GET", "/api/services"))
    assert st == 200 and len(d["universities"]) == 3 and d["universities_note"] is None
