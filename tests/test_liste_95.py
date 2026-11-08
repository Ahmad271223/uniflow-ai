"""Externe Review-Liste mit 87 Pruefstellen (Nr. 1-80, 89-95), gegen den Stand 6937095a erstellt und am 09.11.2026 gegen
develop geprueft (docs/audit/LISTE-95-2026-11-09.md). Hier stehen die Tests der Nummern, die neu behoben wurden
(zuerst rot), und festnagelnde Tests fuer Nummern, die schon behoben oder widerlegt waren, aber keinen eigenen Test
hatten. Testnamen beginnen mit der Nummer der Liste."""
from __future__ import annotations

import base64
import json
import uuid
from datetime import datetime, timezone

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from test_subscriptions import IN_30, _j, apple, ent, hosted, notify, user, verify  # noqa: F401 (Fixtures)

UTC = timezone.utc
PLUS, PRO = "de.uniflow.plus.monthly", "de.uniflow.proai.monthly"


def _enc(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _sign_raw(signer, header: object, payload: object) -> str:
    """JWS mit beliebigem Kopf und beliebigen Nutzdaten (auch Liste statt Objekt), signiert mit dem Testblatt."""
    head = _enc(json.dumps(header).encode())
    body = _enc(json.dumps(payload).encode())
    der = signer.leaf_key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{head}.{body}.{_enc(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def _chain(signer) -> list[str]:
    return [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (signer.leaf, signer.inter, signer.root)]


def _tx(signer, product, otid, token):
    signer.seq += 1
    ms = lambda d: int(d.timestamp() * 1000)
    return signer.sign({"transactionId": f"{otid}-{signer.seq}", "originalTransactionId": otid, "productId": product,
                        "bundleId": "de.uniflow.ai", "type": "Auto-Renewable Subscription", "expiresDate": ms(IN_30),
                        "environment": "Sandbox", "signedDate": ms(datetime.now(UTC)) + signer.seq, "appAccountToken": token})


# ---------------------------------------------------------------- Nr. 1: ungueltige appAccountToken-UUID

@pytest.mark.parametrize("n, token", [(1, "kein-uuid"), (2, 12345), (3, "0123456789abcdef0123456789abcdeg"), (4, ["x"])])
def test_01_invalid_app_account_token_is_no_server_error(hosted, apple, n, token):
    """Vorher: `uuid.UUID(str(tok))` in verify_purchase warf ValueError -> 500. Ein ungueltiges Token gilt jetzt wie in
    `_owner` (Server-Benachrichtigung) als „kein Token“: das meldende Konto bekommt den Kauf, ein zweites Konto nie."""
    a, ha = user(hosted, f"l95-01a{n}@beispiel.de")
    b, hb = user(hosted, f"l95-01b{n}@beispiel.de")
    otid = f"950100000000000{n}"
    st, d = verify(hosted, ha, _tx(apple, PLUS, otid, token))
    assert st == 200, d
    assert ent(hosted, ha)["plan"] == "plus"
    st, d = verify(hosted, hb, _tx(apple, PLUS, otid, token))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    assert ent(hosted, hb)["plan"] == "free"


def test_01_valid_foreign_token_is_still_409(hosted, apple):
    a, _ = user(hosted, "l95-01c@beispiel.de")
    _, hb = user(hosted, "l95-01d@beispiel.de")
    st, d = verify(hosted, hb, _tx(apple, PLUS, "9501000000000099", str(uuid.UUID(hex=a["id"]))))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")


# ---------------------------------------------------------------- Nr. 4: fehlerhafte Zertifikatsketten kontrolliert abweisen

def _bad_tokens(signer) -> dict[str, str]:
    good = {"alg": "ES256", "x5c": _chain(signer)}
    return {
        "x5c mit Zahlen": _sign_raw(signer, {"alg": "ES256", "x5c": [1, 2, 3]}, {"a": 1}),
        "x5c mit null": _sign_raw(signer, {"alg": "ES256", "x5c": [None, None]}, {"a": 1}),
        "Kopf ist eine Liste": _sign_raw(signer, ["ES256"], {"a": 1}),
        "Kopf ist eine Zahl": _sign_raw(signer, 5, {"a": 1}),
        "Nutzdaten sind eine Liste": _sign_raw(signer, good, [1, 2]),
        "x5c kein Base64": _sign_raw(signer, {"alg": "ES256", "x5c": ["%%%", "&&&"]}, {"a": 1}),
        "x5c kein Zertifikat": _sign_raw(signer, {"alg": "ES256", "x5c": [base64.b64encode(b"kein zert").decode()] * 2}, {"a": 1}),
        "Kette ohne Apple-Kennzeichnung (Wurzel als Blatt)": _sign_raw(
            signer, {"alg": "ES256", "x5c": [_chain(signer)[2], _chain(signer)[1], _chain(signer)[2]]}, {"a": 1}),
        "nur zwei Teile": "abc.def",
        "Nicht-ASCII": "äöü.äöü.äöü",
    }


def test_04_broken_chains_headers_and_payloads_are_refused_with_400(hosted, apple):
    """Vorher: x5c mit Nicht-Text (TypeError), Kopf als Liste/Zahl (AttributeError), Nutzdaten als Liste oder ein riesiges
    signedDate (vor der Signaturpruefung ausgewertet: AttributeError/OverflowError) endeten am oeffentlichen
    Benachrichtigungs-Endpunkt mit 500. Jetzt immer 400 (jws_invalid/jws_untrusted), nie eine Ausnahme."""
    from app import apple_store
    for label, token in _bad_tokens(apple).items():
        with pytest.raises(apple_store.AppleError) as e:
            apple_store.verify_jws(token)
        assert e.value.status == 400 and e.value.code in ("jws_invalid", "jws_untrusted"), label
        st, d = notify(hosted, token)
        assert st == 400 and d["code"] in ("jws_invalid", "jws_untrusted"), (label, st, d)


def test_04_huge_signed_date_is_read_before_the_signature_without_crashing(hosted, apple):
    """signedDate wird vor der Signaturpruefung gelesen (Gueltigkeit der Zertifikate zum Signaturzeitpunkt). Ein riesiger
    Wert warf OverflowError (500); jetzt gilt er als unbekannt, die Pruefung laeuft mit der aktuellen Zeit weiter."""
    from app import apple_store
    good = {"alg": "ES256", "x5c": _chain(apple)}
    for ms in (1e300, -1e20, True, "2026"):
        token = _sign_raw(apple, good, {"signedDate": ms, "notificationType": "TEST"})
        assert apple_store.verify_jws(token)["signedDate"] == ms
        st, d = notify(hosted, token)
        assert st == 200 and d["applied"] is False, (ms, st, d)


# ---------------------------------------------------------------- Nr. 66-68, 74: Fragen und Benachrichtigungen

def _qa():
    import test_community_qa as qa
    return qa


def _ask(app, h, title):
    qa = _qa()
    st, q = qa.call(app, "POST", f"/courses/{qa.KEY}/questions", h, {"title": title})
    assert st == 201, q
    return q


def _set_activity(qid, ts):
    from app import community
    with community.cursor() as conn:
        conn.execute("UPDATE questions SET last_activity=? WHERE id=?", (ts, qid))


def _all_pages(app, h, limit):
    qa, seen, before = _qa(), [], None
    for _ in range(20):
        path = f"/courses/{qa.KEY}/questions?limit={limit}" + (f"&before={before}" if before else "")
        st, d = qa.call(app, "GET", path, h)
        assert st == 200, d
        seen += [q["title"] for q in d["questions"]]
        before = d["next"]
        if not before:
            return seen
    raise AssertionError("Seiten enden nicht")


def test_68_questions_with_the_same_last_activity_are_not_skipped_between_pages(hosted):
    """Vorher: Cursor = nur `last_activity`, Folgeseite mit `last_activity < before`. Fragen mit derselben Sekunde an
    der Seitengrenze fielen weg (hier 3 von 5). Jetzt Cursor `(last_activity, id)`; ein alter Cursor (nur Zeit) bleibt
    gueltig."""
    qa = _qa()
    _, a = qa._user(hosted, "l95-68@example.org")
    for i in range(5):
        _set_activity(_ask(hosted, a, f"F{i}")["id"], "2026-11-09T10:00:00Z")
    got = _all_pages(hosted, a, 2)
    assert sorted(got) == ["F0", "F1", "F2", "F3", "F4"], got
    st, d = qa.call(hosted, "GET", f"/courses/{qa.KEY}/questions?limit=2&before=2026-11-09T10:00:01Z", a)
    assert st == 200 and len(d["questions"]) == 2, "alter Cursor (nur Zeitstempel) gilt weiter"


def test_68_blocked_authors_do_not_end_the_paging_early(hosted):
    """Vorher: `more` wurde nach dem Herausfiltern gesperrter Autoren gezaehlt; war auf einer Seite einer gesperrt, kam
    `next: null`, obwohl aeltere Fragen folgten."""
    from app import community, community_qa
    qa = _qa()
    me, a = qa._user(hosted, "l95-68b@example.org")
    other, b = qa._user(hosted, "l95-68c@example.org")
    for i, h in enumerate([a, a, b, a]):
        _set_activity(_ask(hosted, h, f"G{i}")["id"], f"2026-11-0{i + 1}T10:00:00Z")
    with community.cursor() as conn:
        conn.execute("INSERT INTO blocks(user_id, pseudonym, created_at) VALUES (?,?,?)",
                     (me["id"], community_qa.pseudonym(other["id"]), "2026-11-09T00:00:00Z"))
    assert _all_pages(hosted, a, 2) == ["G3", "G1", "G0"]


def test_67_mark_read_takes_a_bounded_id_list(hosted):
    """Vorher: beliebig lange ID-Liste in einem IN (...) - auf dem Server (SQLite von Debian: hoechstens 32.766
    Platzhalter) endet eine laengere Liste mit 500. Die Liste zeigt hoechstens 200 Mitteilungen; mehr als 500 IDs je
    Aufruf: 422. Ohne ids: alles gelesen (wie bisher)."""
    qa = _qa()
    _, a = qa._user(hosted, "l95-67@example.org")
    st, d = qa.call(hosted, "POST", "/notifications/read", a, {"ids": [uuid.uuid4().hex for _ in range(500)]})
    assert st == 200 and d["unread"] == 0, d
    st, d = qa.call(hosted, "POST", "/notifications/read", a, {"ids": [uuid.uuid4().hex for _ in range(501)]})
    assert st == 422 and d["code"] == "ids_invalid", d
    st, d = qa.call(hosted, "POST", "/notifications/read", a, {"ids": [{"x": 1}, 5, None]})
    assert st == 200, d


def _notification(user_id, created_at, read_at=None):
    from app import community
    with community.cursor() as conn:
        conn.execute("INSERT INTO notifications(id, user_id, kind, target_kind, target_id, created_at, read_at) VALUES (?,?,?,?,?,?,?)",
                     (uuid.uuid4().hex, user_id, "answer", "question", "q", created_at, read_at))


def test_74_unread_notifications_do_not_grow_forever(hosted):
    """Vorher: `prune` loeschte nur gelesene Mitteilungen (nach 90 Tagen); ungelesene blieben fuer immer (ein Konto,
    das die App nicht mehr oeffnet, sammelt jede Antwort und jeden Like). Jetzt: ungelesene nach 365 Tagen
    (NOTIFY_UNREAD_KEEP_DAYS), gelesene weiter nach 90."""
    from datetime import timedelta
    from app import community, community_qa
    qa = _qa()
    me, _ = qa._user(hosted, "l95-74@example.org")
    now = datetime.now(UTC)
    iso = lambda d: d.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    _notification(me["id"], iso(now - timedelta(days=400)))                                   # ungelesen, alt -> weg
    _notification(me["id"], iso(now - timedelta(days=200)))                                   # ungelesen, juenger -> bleibt
    _notification(me["id"], iso(now - timedelta(days=100)), iso(now - timedelta(days=99)))    # gelesen, > 90 -> weg
    _notification(me["id"], iso(now - timedelta(days=10)), iso(now - timedelta(days=9)))      # gelesen, frisch -> bleibt
    assert community_qa.prune() == 2
    with community.cursor() as conn:
        left = sorted(r[0][:10] for r in conn.execute("SELECT created_at FROM notifications WHERE user_id=?", (me["id"],)))
    assert left == sorted([iso(now - timedelta(days=200))[:10], iso(now - timedelta(days=10))[:10]])


def test_66_notification_list_with_200_entries_is_fast(hosted):
    """Nr. 66 (N+1 beim Aufloesen der Ziele): hoechstens 200 Eintraege je Abruf, je Eintrag eine Abfrage auf den
    Primaerschluessel - gemessen weit unter einer Sekunde; kein Umbau."""
    import time as _time
    qa = _qa()
    me, h = qa._user(hosted, "l95-66@example.org")
    for i in range(250):
        _notification(me["id"], f"2026-11-09T10:{i // 60:02d}:{i % 60:02d}Z")
    t0 = _time.perf_counter()
    st, d = qa.call(hosted, "GET", "/notifications?limit=200", h)
    assert st == 200 and len(d["notifications"]) == 200 and d["unread"] == 250
    assert _time.perf_counter() - t0 < 1.0


# ---------------------------------------------------------------- Nr. 33: Pakete bis ~65 MB, viele parallele Abrufe

def _streamed(app, path, headers):
    """ASGI-Aufruf, der den Koerper nicht sammelt: Status, groesstes Stueck, Gesamtlaenge, SHA-256, Content-Length."""
    import asyncio
    import hashlib
    hdrs = [(b"host", b"test")] + [(k.lower().encode(), v.encode()) for k, v in headers.items()]
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": "GET",
             "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"", "headers": hdrs,
             "client": ("127.0.0.1", 5000), "server": ("test", 80)}
    out = {"status": None, "biggest": 0, "total": 0, "sha": hashlib.sha256(), "length": None}

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]
            out["length"] = dict(m["headers"]).get(b"content-length")
        elif m["type"] == "http.response.body":
            b = m.get("body", b"")
            out["biggest"], out["total"] = max(out["biggest"], len(b)), out["total"] + len(b)
            out["sha"].update(b)

    asyncio.run(app(scope, receive, send))
    return out


def test_33_solution_download_streams_the_package_instead_of_holding_it_twice(hosted):
    """Vorher: `get_package_raw` las die Paketdatei (bis ~65 MB) als Text, der Endpunkt baute daraus einen zweiten
    Text und eine Bytes-Kopie - je Abruf rund das Dreifache im Speicher, ein Stueck. Ein Mitglied konnte mit einem grossen
    Paket und parallelen Abrufen den App-Container (API_MEMORY=5G) an die Grenze bringen. Jetzt wird die Datei in
    Stuecken zu 1 MiB gestreamt; Antwort und Downloadzaehler bleiben gleich."""
    import shutil
    from app import community
    from test_community_groups import KURS, call, member, package
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    author = member(hosted, "l95-33a@beispiel.de")
    reader = member(hosted, "l95-33b@beispiel.de")
    pkg = package()
    st, d = call(hosted, "POST", "/solutions", author, {"package": pkg, "title": "Blatt 1", "community_key": KURS})
    assert st == 201, d
    sid = pkg["header"]["solutionId"]
    path = community.package_dir() / f"{sid}.uniflowsolution"
    small = path.read_bytes()
    st, d = call(hosted, "GET", f"/solutions/{sid}", reader)
    assert st == 200 and d["package"] == json.loads(small) and d["solution"]["solution_id"] == sid
    # grosses Paket (8 MiB Text): wird in Stuecken geliefert, Inhalt und Laenge stimmen
    big = json.dumps({**json.loads(small), "ciphertext": "A" * (8 << 20)}, separators=(",", ":")).encode()
    path.write_bytes(big)
    out = _streamed(hosted, f"/api/community/solutions/{sid}", reader)
    assert out["status"] == 200
    assert out["biggest"] <= (1 << 20), f"ein Stueck von {out['biggest']} Byte"
    st, d = call(hosted, "GET", f"/solutions/{sid}", reader)
    assert st == 200 and d["package"]["ciphertext"] == "A" * (8 << 20)
    assert out["total"] > len(big) and out["length"] is not None and int(out["length"]) == out["total"]
    # Datei fehlt: 404, Zaehler unveraendert
    path.unlink()
    st, d = call(hosted, "GET", f"/solutions/{sid}", reader)
    assert (st, d["code"]) == (404, "not_found")
    with community.cursor() as conn:
        assert conn.execute("SELECT downloads FROM solutions WHERE id=?", (sid,)).fetchone()[0] == 3
