"""Einladungen in der Windows-App (app/invites_api.py `_forward`, 05.11.2026): ohne StudiNow-Konto 501 not_hosted wie
bisher; mit angemeldetem Konto reicht der lokale Server Uebersicht, neuen Link, Einloesen und Belohnung mit dem Token
an den Dienst weiter. Der "Dienst" ist dieselbe App im gehosteten Modus (Fixture aus test_service_link)."""
import json

from conftest import asgi_call
from test_service_link import SERVICE, _account, _j, service  # noqa: F401 - service ist eine Fixture


def test_invites_forwarded_with_account(service):
    app, calls, _ = service
    st, e = _j(asgi_call(app, "GET", "/api/invites"))
    assert st == 501 and e["code"] == "not_hosted"
    _account(app, "einladen@example.org", plus=False)            # neues Konto: in der Probewoche
    st, d = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "einladen@example.org", "password": "sehr-geheim-123"})))
    assert st == 200, d
    calls.clear()
    st, ov = _j(asgi_call(app, "GET", "/api/invites"))
    assert st == 200, ov
    assert ov["codes"] == [] and ov["arrived"] == 0 and ov["can_create"] is True
    assert calls and calls[-1][0] == "GET" and calls[-1][1] == "/api/invites" and calls[-1][2].startswith("Bearer ")
    st, r = _j(asgi_call(app, "POST", "/api/invites", body="{}"))
    assert st == 201, r
    assert r["invite"]["url"].startswith("https://studinow.app/i/") and len(r["codes"]) == 1
    st, r = _j(asgi_call(app, "POST", "/api/invites/redeem", body=json.dumps({"code": r["invite"]["code"]})))
    assert st == 400 and r["code"] == "invite_self"                     # Fehler des Dienstes kommen unveraendert an
    st, r = _j(asgi_call(app, "POST", "/api/invites/claim", body=json.dumps({"tier": 5})))
    assert st == 403 and r["code"] == "invite_tier_not_reached"
    # Vorrat der Angebotscodes gibt es nur im Dienst
    assert _j(asgi_call(app, "GET", "/api/billing/offer-codes"))[0] == 501
