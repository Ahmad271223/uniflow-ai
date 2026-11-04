"""Einladungen mit Angebotscodes (app/invites.py, app/invites_api.py, docs/EINLADUNGEN.md, Entscheidung des Inhabers
04.11.2026): Links nur in der Probewoche und hoechstens 20, 30 Tage gueltig, Einloesung nur durch neue Konten (nach dem
Link, einmal je Person, nie das eigene), Stufen 5/10/20 aus der gemeinsamen Fixture, Belohnung je Stufe einmal als
Angebotscode mit Apples Einloese-Adresse, leerer Vorrat 409, Vorrat nur fuer Admins, Loeschen des Kontos, Export."""
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import asgi_call
from test_ai_abuse import trial_account
from test_subscriptions import _j, end_trial, hosted, user  # noqa: F401 - hosted ist eine Fixture

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "invites" / "cases.json"


def get(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/invites", headers=headers))
    assert st == 200, d
    return d


def create(app, headers):
    return _j(asgi_call(app, "POST", "/api/invites", headers=headers))


def redeem(app, headers, code):
    return _j(asgi_call(app, "POST", "/api/invites/redeem", headers=headers, body=json.dumps({"code": code})))


def claim(app, headers, tier, choice="plus"):
    return _j(asgi_call(app, "POST", "/api/invites/claim", headers=headers, body=json.dumps({"tier": tier, "choice": choice})))


def upload(app, headers, product, tier, codes=None, text=None):
    body = {"product": product, "tier": tier}
    if codes is not None:
        body["codes"] = codes
    if text is not None:
        body["text"] = text
    return _j(asgi_call(app, "POST", "/api/billing/offer-codes", headers=headers, body=json.dumps(body)))


def invitees(app, inviter_headers, code, n, prefix="gast"):
    """n neue Konten (laufende Probe), jedes loest den Link einmal ein."""
    out = []
    for i in range(n):
        _, h = trial_account(app, f"{prefix}{i}@beispiel.de")
        st, d = redeem(app, h, code)
        assert (st, d["redeemed"], d["already"]) == (200, True, False), d
        out.append(h)
    return out


# ---------------------------------------------------------------- Stufen (reine Funktion, Fixture wie im Swift-Kern)

def test_reward_tiers_match_the_shared_fixture():
    from app import invites
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert len(fx["cases"]) >= 12
    for c in fx["cases"]:
        assert invites.reward_tier(c["count"]) == c["tier"], c
        assert invites.tiers_reached(c["count"]) == c["reached"], c
    contract = invites.contract()
    assert contract["tiers"] == fx["tiers"], "Stufen-Tabelle und Fixture muessen gleich sein"
    assert (contract["max_links"], contract["link_days"], contract["create_days"], contract["link_base"]) == \
        (fx["max_links"], fx["link_days"], fx["create_days"], fx["link_base"])
    assert invites.reward_tier(-3) is None


def test_codes_are_ten_unambiguous_characters_and_normalized():
    from app import invites
    codes = {invites.new_code() for _ in range(200)}
    assert len(codes) == 200
    for c in codes:
        assert len(c) == 10 and set(c) <= set(invites.CODE_ALPHABET)
    assert not set("0O1IL") & set(invites.CODE_ALPHABET)
    assert invites.normalize_code(" ab2c-d3ef gh ") == "AB2CD3EFGH"
    assert invites.normalize_code("https://studinow.app/i/AB2CD3EFGH") == "AB2CD3EFGH"
    assert invites.link_for("AB2CD3EFGH") == "https://studinow.app/i/AB2CD3EFGH"


# ---------------------------------------------------------------- Links anlegen

def test_create_only_in_the_trial_week_and_at_most_twenty(hosted):
    from app import invites
    u, h = trial_account(hosted, "ich@beispiel.de")
    d = get(hosted, h)
    assert (d["codes"], d["arrived"], d["max_links"], d["can_create"], d["tier"]) == ([], 0, 20, True, None)
    assert [t["count"] for t in d["tiers"]] == [5, 10, 20] and not any(t["reached"] or t["claimable"] for t in d["tiers"])
    assert "stock" not in d, "Vorrat nur fuer den Betrieb"
    st, d = create(hosted, h)
    assert st == 201 and d["invite"]["url"] == "https://studinow.app/i/" + d["invite"]["code"] and len(d["codes"]) == 1
    created, expires = datetime.fromisoformat(d["invite"]["created_at"]), datetime.fromisoformat(d["invite"]["expires_at"])
    assert expires - created == timedelta(days=30)
    for _ in range(19):
        assert create(hosted, h)[0] == 201
    st, d = create(hosted, h)
    assert (st, d["code"]) == (409, "invite_limit") and "20" in d["detail"]
    assert (get(hosted, h)["remaining_links"], get(hosted, h)["can_create"]) == (0, False)
    # Probe vorbei und Konto aelter als 7 Tage: keine neuen Links, bestehende bleiben
    u2, h2 = trial_account(hosted, "spaet@beispiel.de")
    assert create(hosted, h2)[0] == 201
    end_trial(u2["id"])
    assert create(hosted, h2)[0] == 201, "in den ersten 7 Tagen des Kontos geht es auch ohne Probe"
    conn = invites.connect()
    try:
        conn.execute("UPDATE users SET created_at=? WHERE id=?", ((datetime.now(UTC) - timedelta(days=8)).isoformat().replace("+00:00", "Z"), u2["id"]))
    finally:
        conn.close()
    st, d = create(hosted, h2)
    assert (st, d["code"]) == (403, "invite_window_closed")
    assert len(get(hosted, h2)["codes"]) == 2 and get(hosted, h2)["can_create"] is False


# ---------------------------------------------------------------- einloesen

def test_redeem_counts_new_accounts_once_never_self_and_only_in_the_window(hosted):
    from app import invites
    u, h = trial_account(hosted, "einlader@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    # selbst: nein
    st, d = redeem(hosted, h, code)
    assert (st, d["code"]) == (400, "invite_self")
    # unbekannt
    st, d = redeem(hosted, h, "ZZZZZZZZZZ")
    assert (st, d["code"]) == (404, "invite_unknown")
    assert redeem(hosted, h, "")[0] == 400
    # neues Konto: zaehlt; Klein- und Bindestrichschreibung wie vom QR/Tastatur; zweites Mal idempotent
    g, hg = trial_account(hosted, "gast@beispiel.de")
    st, d = redeem(hosted, hg, code[:5].lower() + "-" + code[5:])
    assert (st, d["redeemed"], d["already"], d["code"]) == (200, True, False, code)
    st, d = redeem(hosted, hg, code)
    assert (st, d["already"]) == (200, True)
    assert get(hosted, h)["arrived"] == 1 and get(hosted, h)["codes"][0]["redemptions"] == 1
    # dieselbe Person ueber einen zweiten Link eines anderen Einladenden: zaehlt nicht noch einmal
    u2, h2 = trial_account(hosted, "zweiter@beispiel.de")
    code2 = create(hosted, h2)[1]["invite"]["code"]
    st, d = redeem(hosted, hg, code2)
    assert (st, d["already"], d["code"]) == (200, True, code)
    assert get(hosted, h2)["arrived"] == 0
    # Konto aelter als der Link: nein (ein bestehender Nutzer ist keine neue Person)
    alt, halt = trial_account(hosted, "alt@beispiel.de")
    conn = invites.connect()
    try:
        conn.execute("UPDATE users SET created_at=? WHERE id=?", ((datetime.now(UTC) - timedelta(days=2)).isoformat().replace("+00:00", "Z"), alt["id"]))
    finally:
        conn.close()
    st, d = redeem(hosted, halt, code)
    assert (st, d["code"]) == (400, "invite_account_older")
    # abgelaufener Link (30 Tage)
    conn = invites.connect()
    try:
        conn.execute("UPDATE invites SET expires_at=? WHERE code=?", ((datetime.now(UTC) - timedelta(minutes=1)).isoformat(), code2))
    finally:
        conn.close()
    sp, hsp = trial_account(hosted, "spaeter@beispiel.de")
    st, d = redeem(hosted, hsp, code2)
    assert (st, d["code"]) == (410, "invite_expired")
    assert get(hosted, h2)["codes"][0]["expired"] is True
    # Einladender geloescht: Link gibt es nicht mehr
    from app import accounts
    accounts.delete_account(u2["id"], "sehr-geheim-123")
    st, d = redeem(hosted, hsp, code2)
    assert (st, d["code"]) == (404, "invite_unknown")


# ---------------------------------------------------------------- Stufen und Belohnungen

def test_tiers_and_claims_hand_out_offer_codes_once_per_tier(hosted, monkeypatch):
    monkeypatch.setenv("LERNAPP_APPLE_APP_ID", "6741234567")
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    st, d = upload(hosted, admin, "plus", 5, codes=["PLUS5-A", "PLUS5-B", "PLUS5-A"])
    assert (st, d["added"], d["skipped"]) == (200, 2, 1)
    assert upload(hosted, admin, "plus", 10, text="# Export aus App Store Connect\nPLUS10-A\n\n")[1]["added"] == 1
    assert upload(hosted, admin, "pro_ai", 20, codes=["PROAI20-A"])[1]["added"] == 1
    st, d = upload(hosted, admin, "pro_ai", 5, codes=["X"])
    assert (st, d["code"]) == (400, "offer_product_invalid"), "Pro AI gibt es nur in Stufe 20"
    assert upload(hosted, admin, "plus", 7, codes=["X"])[1]["code"] == "invite_tier_invalid"
    assert upload(hosted, admin, "plus", 5, codes=[])[1]["code"] == "offer_codes_missing"

    u, h = trial_account(hosted, "sammler@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    # noch nicht erreicht
    st, d = claim(hosted, h, 5)
    assert (st, d["code"]) == (403, "invite_tier_not_reached")
    invitees(hosted, h, code, 5)
    d = get(hosted, h)
    assert (d["arrived"], d["tier"]) == (5, 5)
    assert [(t["reached"], t["claimable"]) for t in d["tiers"]] == [(True, True), (False, False), (False, False)]
    # falsche Wahl oder Stufe
    assert claim(hosted, h, 5, "proai")[1]["code"] == "invite_choice_invalid"
    assert claim(hosted, h, 7)[1]["code"] == "invite_tier_invalid"
    # einloesen: Code aus dem Vorrat (der aelteste zuerst) mit Apples Adresse; nie ein Tarif im Dienst
    st, d = claim(hosted, h, 5)
    assert st == 200, d
    assert (d["offer_code"], d["already"], d["reward"]) == ("PLUS5-A", False, "1 Monat StudiNow Plus gratis")
    assert d["redeem_url"] == "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A"
    assert d["apple_product_id"] == "de.uniflow.plus.monthly"
    st, me = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=h))
    assert me["plan"] == "pro_ai" and me["source"] == "trial", "nur die Probe, kein von uns gesetzter Tarif"
    # zweites Mal: derselbe Code, kein zweiter aus dem Vorrat
    st, d = claim(hosted, h, 5)
    assert (st, d["offer_code"], d["already"]) == (200, "PLUS5-A", True)
    d = get(hosted, h)
    assert d["tiers"][0]["claimed"]["offer_code"] == "PLUS5-A" and d["tiers"][0]["claimable"] is False
    assert get(hosted, admin)["stock"]["plus"] == {"5": 1, "10": 1, "20": 0}
    # Stufe 10 und 20 (Stufe 20 mit Pro AI zum Plus-Preis)
    invitees(hosted, h, code, 15, prefix="mehr")
    d = get(hosted, h)
    assert (d["arrived"], d["tier"]) == (20, 20) and [t["claimable"] for t in d["tiers"]] == [False, True, True]
    assert claim(hosted, h, 10)[1]["offer_code"] == "PLUS10-A"
    st, d = claim(hosted, h, 20, "proai")
    assert (st, d["offer_code"], d["reward"]) == (200, "PROAI20-A", "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)")
    assert d["apple_product_id"] == "de.uniflow.proai.monthly"
    # Stufe 20 ist damit eingeloest: kein Wechsel auf Plus mehr
    st, d = claim(hosted, h, 20, "plus")
    assert (st, d["offer_code"], d["choice"], d["already"]) == (200, "PROAI20-A", "proai", True)


def test_empty_stock_is_a_409_with_german_text_and_admins_see_the_warning(hosted, monkeypatch):
    monkeypatch.delenv("LERNAPP_APPLE_APP_ID", raising=False)
    from app import invites
    u, h = trial_account(hosted, "leer@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    invitees(hosted, h, code, 5)
    st, d = claim(hosted, h, 5)
    assert (st, d["code"], d["detail"]) == (409, "offer_codes_exhausted", invites.EXHAUSTED_MESSAGE)
    assert "ä" in d["detail"] or "ü" in d["detail"]
    assert get(hosted, h)["tiers"][0]["claimable"] is True, "bleibt einloesbar, sobald Codes da sind"
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    d = get(hosted, admin)
    assert d["stock"] == {"plus": {"5": 0, "10": 0, "20": 0}, "pro_ai": {"20": 0}}
    assert sorted(d["stock_warning"]) == ["plus:10", "plus:20", "plus:5", "pro_ai:20"]
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/offer-codes", headers=admin))
    assert st == 200 and d["stock"]["plus"]["5"] == 0 and [t["count"] for t in d["tiers"]] == [5, 10, 20]
    assert upload(hosted, admin, "plus", 5, codes=["NEU-1"])[0] == 200
    st, d = claim(hosted, h, 5)
    assert (st, d["offer_code"], d["redeem_url"]) == (200, "NEU-1", None), "ohne Apple-ID nur der Code"
    assert get(hosted, admin)["stock_warning"] == ["plus:5", "plus:10", "plus:20", "pro_ai:20"]


def test_offer_code_upload_needs_an_admin(hosted):
    _, h = trial_account(hosted, "normal@beispiel.de")
    st, d = upload(hosted, h, "plus", 5, codes=["A"])
    assert (st, d["code"]) == (403, "admin_required")
    assert asgi_call(hosted, "GET", "/api/billing/offer-codes", headers=h)[0] == 403
    assert asgi_call(hosted, "GET", "/api/invites")[0] == 401
    assert asgi_call(hosted, "POST", "/api/billing/offer-codes", body=json.dumps({"product": "plus", "tier": 5, "codes": ["A"]}))[0] == 401


# ---------------------------------------------------------------- Loeschen und Export

def test_purge_removes_invites_redemptions_and_rewards_but_keeps_handed_out_codes(hosted):
    from app import accounts, invites
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    upload(hosted, admin, "plus", 5, codes=["P-1"])
    u, h = trial_account(hosted, "weg@beispiel.de")
    uid = u["id"]
    code = create(hosted, h)[1]["invite"]["code"]
    guests = invitees(hosted, h, code, 5)
    assert claim(hosted, h, 5)[1]["offer_code"] == "P-1"
    # der Einladende ist selbst ueber jemanden gekommen
    other, ho = trial_account(hosted, "anderer@beispiel.de")
    accounts.delete_account(uid, "sehr-geheim-123")
    with pytest.MonkeyPatch.context() as mp:          # 31 Tage spaeter nur fuer das Loeschen (sonst waeren alle Sitzungen abgelaufen)
        mp.setattr(accounts, "now", lambda: datetime.now(UTC) + timedelta(days=31))
        assert accounts.purge_deleted() == 1
    conn = invites.connect()
    try:
        for t in ("invites", "invite_rewards"):
            assert conn.execute(f"SELECT COUNT(*) FROM {t} WHERE user_id=?", (uid,)).fetchone()[0] == 0, t
        assert conn.execute("SELECT COUNT(*) FROM invite_redemptions WHERE inviter_id=? OR user_id=?", (uid, uid)).fetchone()[0] == 0
        row = conn.execute("SELECT assigned_to FROM offer_codes WHERE code='P-1'").fetchone()
        assert row[0].startswith("deleted:"), "ausgegebener Code bleibt ausgegeben, ohne Konto"
    finally:
        conn.close()
    # die Gaeste duerfen nun als neue Person bei jemand anderem zaehlen? Nein: ihre Einloesung ist mit dem Einladenden weg,
    # aber ihr Konto ist weiter nicht neu -> ein neuer Link eines anderen zaehlt sie nicht (Konto aelter als der Link)
    conn = invites.connect()
    try:    # der Gast ist aelter als der neue Link (die Zeitstempel haben Sekunden, im Test liegt alles in derselben)
        conn.execute("UPDATE users SET created_at=? WHERE email='gast0@beispiel.de'",
                     ((datetime.now(UTC) - timedelta(minutes=1)).isoformat().replace("+00:00", "Z"),))
    finally:
        conn.close()
    code2 = create(hosted, ho)[1]["invite"]["code"]
    st, d = redeem(hosted, guests[0], code2)
    assert (st, d["code"]) == (400, "invite_account_older")


def test_export_lists_own_invites_without_guest_identities(hosted):
    import io
    import zipfile
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    upload(hosted, admin, "plus", 5, codes=["E-1"])
    u, h = trial_account(hosted, "export@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    guests = invitees(hosted, h, code, 5)
    claim(hosted, h, 5)
    st, hdrs, raw = asgi_call(hosted, "GET", "/api/account/export", headers=h)
    assert st == 200
    konto = json.loads(zipfile.ZipFile(io.BytesIO(raw)).read("konto.json"))
    e = konto["einladungen"]
    assert [l["code"] for l in e["links"]] == [code] and len(e["angekommen"]) == 5 and e["eingeloest"] == []
    assert e["belohnungen"] == [{"tier": 5, "choice": "plus", "offer_code": "E-1", "claimed_at": e["belohnungen"][0]["claimed_at"]}]
    assert "gast0@beispiel.de" not in json.dumps(konto) and "user_id" not in json.dumps(e), "keine Kennungen der Gaeste"
    # der Gast sieht seine eigene Einloesung
    st, hdrs, raw = asgi_call(hosted, "GET", "/api/account/export", headers=guests[0])
    g = json.loads(zipfile.ZipFile(io.BytesIO(raw)).read("konto.json"))["einladungen"]
    assert [r["code"] for r in g["eingeloest"]] == [code] and g["links"] == [] and g["angekommen"] == []


# ---------------------------------------------------------------- Sicherheitspruefung 04.11.2026

def test_code_space_is_large_and_a_collision_draws_again(hosted, monkeypatch):
    """31^10 Codes (ueber 2^49) aus secrets; trifft ein gezogener Code einen vorhandenen, wird neu gezogen."""
    import math
    from app import invites
    assert math.log2(len(invites.CODE_ALPHABET) ** invites.CODE_LENGTH) > 49
    src = Path(invites.__file__).read_text(encoding="utf-8")
    assert "secrets.choice(CODE_ALPHABET)" in src and "import random" not in src
    assert len(set(invites.CODE_ALPHABET)) == len(invites.CODE_ALPHABET) == 31
    u, h = trial_account(hosted, "kollision@beispiel.de")
    first = create(hosted, h)[1]["invite"]["code"]
    draws = iter([first, first, "KKKKKKKKKK"])
    monkeypatch.setattr(invites, "new_code", lambda: next(draws))
    st, d = create(hosted, h)
    assert (st, d["invite"]["code"]) == (201, "KKKKKKKKKK")
    assert sorted(c["code"] for c in d["codes"]) == sorted([first, "KKKKKKKKKK"])


def test_rate_limits_on_create_redeem_and_claim(hosted, monkeypatch):
    """Je Konto gezaehlt, auch fehlgeschlagene Versuche (sonst liessen sich fremde Codes durchprobieren); 429 mit
    deutschem Text und Retry-After; ein anderes Konto ist nicht betroffen."""
    monkeypatch.setenv("LERNAPP_LIMIT_INVITE_REDEEM_USER", "3/60")
    monkeypatch.setenv("LERNAPP_LIMIT_INVITE_CREATE_USER", "2/60")
    monkeypatch.setenv("LERNAPP_LIMIT_INVITE_CLAIM_USER", "2/60")
    u, h = trial_account(hosted, "rate@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    assert create(hosted, h)[0] == 201
    st, hdrs, raw = asgi_call(hosted, "POST", "/api/invites", headers=h)
    d = json.loads(raw)
    assert (st, d["code"]) == (429, "rate_limited") and "Zu viele Versuche" in d["detail"]
    assert any(k == b"retry-after" and int(v) > 0 for k, v in hdrs)
    assert len(get(hosted, h)["codes"]) == 2, "abgewiesener Versuch legt keinen Link an"
    # Einloesen: drei falsche Codes, dann ist auch der richtige gesperrt
    g, hg = trial_account(hosted, "rater@beispiel.de")
    for guess in ("AAAAAAAAAA", "BBBBBBBBBB", "CCCCCCCCCC"):
        assert redeem(hosted, hg, guess)[1]["code"] == "invite_unknown"
    st, d = redeem(hosted, hg, code)
    assert (st, d["code"]) == (429, "rate_limited")
    assert get(hosted, h)["arrived"] == 0
    g2, hg2 = trial_account(hosted, "rater2@beispiel.de")
    assert redeem(hosted, hg2, code)[1]["redeemed"] is True, "eigene Grenze je Konto"
    # Belohnung abholen
    assert claim(hosted, h, 5)[0] == 403
    assert claim(hosted, h, 5)[0] == 403
    assert claim(hosted, h, 5)[1]["code"] == "rate_limited"
    # nach Ablauf des Fensters geht es wieder
    from app import invites
    conn = invites.connect()
    try:
        with pytest.raises(invites.InviteError):
            invites.hit_limit(conn, "invite_redeem_user", g["id"])                   # noch im Fenster: gesperrt
        later = datetime.now(UTC) + timedelta(minutes=61)
        invites.hit_limit(conn, "invite_redeem_user", g["id"], later)              # neues Fenster, kein Fehler
    finally:
        conn.close()
    # kaputte Umgebungswerte fallen auf den Standard zurueck
    monkeypatch.setenv("LERNAPP_LIMIT_INVITE_CLAIM_USER", "viele")
    assert invites.limit_of("invite_claim_user") == invites.LIMITS["invite_claim_user"]
    monkeypatch.setenv("LERNAPP_LIMIT_INVITE_CLAIM_USER", "0/60")
    assert invites.limit_of("invite_claim_user") == invites.LIMITS["invite_claim_user"]


def test_upload_ignores_malformed_lines_and_caps_the_batch(hosted):
    from app import invites
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    text = ("# Export\nOffer Code,Expiration\nGUT-CODE-1,2027-01-01\nGUTCODE2\n<script>x</script>\n"
            "x\n" + "Z" * 65 + "\n'; DROP TABLE offer_codes;--\nGUTCODE3\nGUTCODE2\n")
    st, d = upload(hosted, admin, "plus", 5, text=text)
    assert st == 200, d
    assert (d["added"], d["skipped"], d["ignored"]) == (2, 1, 6), d
    conn = invites.connect()
    try:
        assert sorted(r[0] for r in conn.execute("SELECT code FROM offer_codes")) == ["GUTCODE2", "GUTCODE3"]
    finally:
        conn.close()
    # Listeneintraege, die keine Zeichenketten sind, werden uebergangen, nie gespeichert
    st, d = upload(hosted, admin, "plus", 10, codes=[{"code": "OBJ-1"}, 12345, None, "LISTE-1"])
    assert (st, d["added"]) == (200, 1)
    st, d = upload(hosted, admin, "plus", 10, codes=["?", "!!"])
    assert (st, d["code"]) == (400, "offer_codes_missing") and "übergangen" in d["detail"]
    st, d = upload(hosted, admin, "plus", 5, codes=["C%05d" % i for i in range(invites.MAX_UPLOAD_LINES + 1)])
    assert (st, d["code"]) == (413, "offer_codes_too_many") and "groß" in d["detail"]
    with pytest.raises(invites.InviteError) as e:
        conn = invites.connect()
        try:
            invites.upload_codes(conn, "plus", 5, ["C"] * (invites.MAX_UPLOAD_LINES + 1))
        finally:
            conn.close()
    assert e.value.status == 413
    # Upload und Vorrat nur fuer Admins, auch fuer zahlende Konten nicht
    _, pro = user(hosted, "pro@beispiel.de", plan="pro_ai")
    assert upload(hosted, pro, "plus", 5, codes=["PRO-CODE"])[0] == 403
    assert asgi_call(hosted, "GET", "/api/billing/offer-codes", headers=pro)[0] == 403


def test_offer_codes_never_reach_others_errors_or_logs(hosted, caplog):
    """Ein Angebotscode erscheint nur in der Antwort an das Konto, das ihn abholt (und beim Admin nur als Zahl im
    Vorrat); nie in Fehlern, nie in der Uebersicht anderer, nie im Protokoll."""
    import logging
    from app import invites
    caplog.set_level(logging.DEBUG)
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    upload(hosted, admin, "plus", 5, codes=["GEHEIM-AAA", "GEHEIM-BBB"])
    u, h = trial_account(hosted, "holer@beispiel.de")
    code = create(hosted, h)[1]["invite"]["code"]
    guests = invitees(hosted, h, code, 5)
    seen = []
    for hh in (guests[0], admin):
        st, hdrs, raw = asgi_call(hosted, "GET", "/api/invites", headers=hh)
        seen.append(raw)
    st, mine = claim(hosted, h, 5)
    assert st == 200 and mine["offer_code"] == "GEHEIM-AAA"
    # andere: eigene (leere) Uebersicht, Fehler ohne Code
    for hh in guests[:2]:
        seen.append(asgi_call(hosted, "GET", "/api/invites", headers=hh)[2])
        seen.append(asgi_call(hosted, "POST", "/api/invites/claim", headers=hh, body=json.dumps({"tier": 5}))[2])
    seen.append(asgi_call(hosted, "GET", "/api/invites", headers=admin)[2])
    seen.append(asgi_call(hosted, "GET", "/api/billing/offer-codes", headers=admin)[2])
    blob = b"\n".join(seen).decode("utf-8")
    assert "GEHEIM-" not in blob, blob
    assert "GEHEIM-" not in caplog.text
    # Quelltext: kein Protokoll in invites.py / invites_api.py
    for mod in ("invites.py", "invites_api.py"):
        src = (ROOT / "app" / mod).read_text(encoding="utf-8")
        assert "logging" not in src and "print(" not in src, mod
    # leerer Vorrat: Text ohne Code
    with pytest.raises(invites.InviteError) as e:
        conn = invites.connect()
        try:
            conn.execute("UPDATE offer_codes SET assigned_to='x' WHERE assigned_to IS NULL")
            u2, h2 = trial_account(hosted, "zweiter@beispiel.de")
            c2 = create(hosted, h2)[1]["invite"]["code"]
            invitees(hosted, h2, c2, 5, prefix="zwei")
            invites.claim(conn, u2, 5, "plus")
        finally:
            conn.close()
    assert (e.value.status, e.value.code) == (409, "offer_codes_exhausted") and "GEHEIM" not in e.value.message


def test_no_enumeration_of_other_accounts_codes_or_counts(hosted):
    """Uebersicht und Export zeigen nur Eigenes; Antworten beim Einloesen nennen weder Einladenden noch dessen Zahlen."""
    a, ha = trial_account(hosted, "a@beispiel.de")
    b, hb = trial_account(hosted, "b@beispiel.de")
    code_a = create(hosted, ha)[1]["invite"]["code"]
    create(hosted, hb)
    da = get(hosted, ha)
    db_ = get(hosted, hb)
    assert [c["code"] for c in da["codes"]] == [code_a] and code_a not in json.dumps(db_)
    g, hg = trial_account(hosted, "g@beispiel.de")
    st, d = redeem(hosted, hg, code_a)
    assert st == 200 and set(d) == {"redeemed", "already", "code", "created_at"}
    assert a["id"] not in json.dumps(d) and "a@beispiel.de" not in json.dumps(d)
    assert get(hosted, hb)["arrived"] == 0 and get(hosted, ha)["arrived"] == 1
    # Fehlerantworten ohne Konto-Bezug
    for wrong in (code_a, "ZZZZZZZZZZ"):
        st, d = redeem(hosted, ha, wrong)
        assert a["id"] not in json.dumps(d) and set(d) <= {"detail", "code"}


def test_parallel_claims_hand_out_one_code_and_exhaust_cleanly(hosted):
    """Zwei gleichzeitige Abholungen desselben Kontos: ein Code, einer aus dem Vorrat; zwei Konten um den letzten Code:
    einer bekommt ihn, der andere 409 (BEGIN IMMEDIATE)."""
    import threading
    from app import invites
    _, admin = user(hosted, "betrieb@beispiel.de", admin=True)
    upload(hosted, admin, "plus", 5, codes=["PAR-ONE", "PAR-TWO"])
    people = []
    for i in range(3):
        u, h = trial_account(hosted, f"p{i}@beispiel.de")
        c = create(hosted, h)[1]["invite"]["code"]
        invitees(hosted, h, c, 5, prefix=f"p{i}gast")
        people.append(u)

    def run(u, out):
        conn = invites.connect()
        try:
            out.append(invites.claim(conn, u, 5, "plus")["offer_code"])
        except invites.InviteError as e:
            out.append(e.code)
        finally:
            conn.close()

    same: list = []
    ts = [threading.Thread(target=run, args=(people[0], same)) for _ in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert len(same) == 4 and len(set(same)) == 1 and same[0].startswith("PAR-"), same
    rest: list = []
    ts = [threading.Thread(target=run, args=(people[i], rest)) for i in (1, 2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(rest)[0].startswith("PAR-") and sorted(rest)[1] == "offer_codes_exhausted", rest
    conn = invites.connect()
    try:
        assert conn.execute("SELECT COUNT(*) FROM offer_codes WHERE assigned_to IS NULL").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(DISTINCT offer_code) FROM invite_rewards").fetchone()[0] == 2
    finally:
        conn.close()


def test_sql_is_parametrised():
    """Keine Werte per f-String oder % in SQL (Tabellennamen in accounts._purge_user sind feste Konstanten)."""
    import re
    for mod in ("invites.py", "credits.py", "page_explain.py"):
        src = (ROOT / "app" / mod).read_text(encoding="utf-8")
        assert not re.search(r"execute\(\s*f[\"']", src), mod
        assert not re.search(r"execute\([^)]*\"\s*%\s*", src), mod
        assert ".format(" not in src, mod
