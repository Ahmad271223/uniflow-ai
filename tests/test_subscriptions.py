"""Studora-Abosystem: vier Tarife, Rechte und Kontingente serverseitig, App-Store-Pruefung, gemeinsame Testbibliothek,
KI-Kostenkontrolle und die ehrlich ausgeschaltete ChatGPT-Verbindung (docs/ABO-SYSTEM.md, Testfaelle 1–14 des Auftrags)."""
import base64
import datetime as dt
import json
import re
import shutil
import threading
import time
import uuid

import pytest
from conftest import asgi_call
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

UTC = dt.timezone.utc


# ---------------------------------------------------------------- Umgebung

@pytest.fixture
def hosted(app, monkeypatch, tmp_path):
    from app import accounts, ai_backend, community, config, test_library, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    dbs = (accounts.db_path(), community.db_path(), test_library.db_path())

    def wipe():
        for p in dbs:
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
        shutil.rmtree(config.BASE_DATA_DIR / "users", ignore_errors=True)
    wipe()
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    yield app
    ai_backend.set_provider(None)
    wipe()
    vault.reset_master()


def _j(resp):
    st, _, b = resp
    return st, (json.loads(b) if b else None)


def user(app, email, plan="free", uni="luh", admin=False):
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni})))
    assert st == 201, d
    if plan != "free":
        accounts.set_plan(d["user"]["id"], plan)
    if admin:
        accounts.set_role(d["user"]["id"], "admin")
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def add_file(app, headers, file_id="f1"):
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', 1, '2026-10-26')")
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?, 'c1', 'Blatt.pdf', 'pdf', 'neu')", (file_id,))
    finally:
        config.reset_user_context(t)


def put_note(app, headers, file_id="f1", text="Notiz"):
    return _j(asgi_call(app, "PUT", f"/api/files/{file_id}/annotations", headers=headers,
                        body=json.dumps({"version": 2, "pages": {"1": {"objects": [{"id": "s1", "type": "text", "text": text}]}}})))


def ent(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))
    assert st == 200, d
    return d


class FakeAI:
    """Attrappe fuer die Studora-KI: liefert gueltige Multiple-Choice-Fragen und zaehlt die Aufrufe."""

    def __init__(self, delay=0.0):
        self.calls, self.delay, self.lock = 0, delay, threading.Lock()

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import Completion
        with self.lock:
            self.calls += 1
            n_call = self.calls
        time.sleep(self.delay)
        if schema is None:
            return Completion("Erklärung: Eine Matrix ist ein rechteckiges Zahlenschema.", 120, 40, "fake")
        n = int(re.search(r"Erstelle (\d+)", prompt).group(1))
        topic = re.search(r"Thema: (.+)", prompt).group(1).strip()
        qs = [{"question": f"Frage {i} zu {topic} (Lauf {n_call}): Welche Aussage ist richtig?",
               "options": [f"Aussage A{i}", f"Aussage B{i}", f"Aussage C{i}", f"Aussage D{i}"],
               "answer": f"Aussage B{i}", "explanation": "Weil B stimmt.", "difficulty": 3} for i in range(n)]
        return Completion(json.dumps({"questions": qs}), 300, 900, "fake")


def library_test(app, headers, topic, count=5, **extra):
    body = {"subject": "Lineare Algebra", "topic": topic, "count": count, **extra}
    return _j(asgi_call(app, "POST", "/api/library/tests", headers=headers, body=json.dumps(body)))


# ---------------------------------------------------------------- App-Store-Signaturen (selbst erzeugte Kette)

class AppleSigner:
    """Kette Wurzel -> Zwischenzertifikat (Apple-OID) -> Blatt (Apple-OID) wie bei Apple, nur selbst erzeugt."""

    def __init__(self, tmp_path):
        now = dt.datetime.now(UTC)
        self.root_key = ec.generate_private_key(ec.SECP256R1())
        self.root = self._cert("Test Root", self.root_key.public_key(), self.root_key, None, ca=True, now=now)
        inter_key = ec.generate_private_key(ec.SECP256R1())
        self.inter = self._cert("Test WWDR", inter_key.public_key(), self.root_key, self.root, ca=True, now=now,
                                oid="1.2.840.113635.100.6.2.1")
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf = self._cert("Test Signing", self.leaf_key.public_key(), inter_key, self.inter, ca=False, now=now,
                               oid="1.2.840.113635.100.6.11.1")
        self.root_path = tmp_path / "root.pem"
        self.root_path.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        self.seq = 0

    @staticmethod
    def _cert(cn, pub, signer_key, issuer, ca, now, oid=None):
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
        b = (x509.CertificateBuilder().subject_name(name).issuer_name(issuer.subject if issuer else name).public_key(pub)
             .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(days=1))
             .not_valid_after(now + dt.timedelta(days=365))
             .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
        if oid:
            b = b.add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier(oid), b"\x05\x00"), critical=False)
        return b.sign(signer_key, hashes.SHA256())

    def sign(self, payload: dict) -> str:
        enc = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
        chain = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (self.leaf, self.inter, self.root)]
        head = enc(json.dumps({"alg": "ES256", "x5c": chain}).encode())
        body = enc(json.dumps(payload).encode())
        der = self.leaf_key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        return f"{head}.{body}.{enc(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"

    def tx(self, user_id, product, expires, otid="2000000000000001", revoked=False, token=True):
        self.seq += 1
        ms = lambda d: int(d.timestamp() * 1000)
        p = {"transactionId": f"{otid}-{self.seq}", "originalTransactionId": otid, "productId": product, "bundleId": "de.uniflow.ai",
             "type": "Auto-Renewable Subscription", "expiresDate": ms(expires), "environment": "Sandbox",
             "signedDate": ms(dt.datetime.now(UTC)) + self.seq}
        if token:
            p["appAccountToken"] = str(uuid.UUID(hex=user_id))
        if revoked:
            p["revocationDate"] = ms(dt.datetime.now(UTC))
        return self.sign(p)

    def renewal(self, otid, auto_product, auto_renew=True):
        self.seq += 1
        return self.sign({"originalTransactionId": otid, "autoRenewProductId": auto_product, "autoRenewStatus": 1 if auto_renew else 0,
                          "signedDate": int(dt.datetime.now(UTC).timestamp() * 1000) + self.seq})

    def notification(self, ntype, tx, renewal=None, subtype=None):
        self.seq += 1
        data = {"bundleId": "de.uniflow.ai", "environment": "Sandbox", "signedTransactionInfo": tx}
        if renewal:
            data["signedRenewalInfo"] = renewal
        return self.sign({"notificationType": ntype, "subtype": subtype, "notificationUUID": str(uuid.uuid4()), "data": data,
                          "signedDate": int(dt.datetime.now(UTC).timestamp() * 1000) + self.seq})


@pytest.fixture
def apple(tmp_path, monkeypatch):
    s = AppleSigner(tmp_path)
    monkeypatch.setenv("LERNAPP_APPLE_ROOT_CERTS", str(s.root_path))
    return s


def verify(app, headers, signed, renewal=None):
    return _j(asgi_call(app, "POST", "/api/billing/apple/verify", headers=headers,
                        body=json.dumps({"signed_transaction": signed, **({"signed_renewal": renewal} if renewal else {})})))


def notify(app, payload):
    return _j(asgi_call(app, "POST", "/api/billing/apple/notifications", body=json.dumps({"signedPayload": payload})))


IN_30 = dt.datetime.now(UTC) + dt.timedelta(days=30)


# ---------------------------------------------------------------- 1, 2: Notizen nur ab Plus

def test_01_free_cannot_save_annotations(hosted):
    u, h = user(hosted, "free@beispiel.de")
    add_file(hosted, h)
    st, d = put_note(hosted, h)
    assert (st, d["code"], d["entitlement"], d["required_plan"]) == (403, "plan_required", "can_annotate_pdf", "plus"), d
    st, d = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=h, body=json.dumps({"device_id": "ipad", "items": [
        {"entity": "annotations", "id": "f1", "data": {"pages": {}}}, {"entity": "modules", "local_id": -1, "data": {"name": "M"}}]})))
    assert st == 200
    statuses = {r["entity"]: r["status"] for r in d["results"]}
    assert statuses == {"annotations": "plan_required", "modules": "created"}, "nur die Notizen werden abgewiesen"
    st, d = _j(asgi_call(hosted, "GET", "/api/files/f1/annotations", headers=h))
    assert st == 200 and d["version"] == 0, "nichts gespeichert"


def test_02_plus_can_annotate_and_sync(hosted):
    u, h = user(hosted, "plus@beispiel.de", plan="plus")
    add_file(hosted, h)
    st, d = put_note(hosted, h)
    assert st == 200 and d["version"] == 1
    st, d = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=h, body=json.dumps({"device_id": "ipad", "items": [
        {"entity": "annotations", "id": "f1", "base_version": 1, "data": {"pages": {"1": {"objects": [{"id": "s2"}]}}}}]})))
    assert d["results"][0]["status"] == "applied"


# ---------------------------------------------------------------- 3, 4, 5: Kontingente und Rechte je Tarif

def test_03_plus_gets_three_new_ai_tests_per_month(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    u, h = user(hosted, "plus3@beispiel.de", plan="plus")
    for topic in ("Determinanten", "Basiswechsel", "Orthogonalprojektion"):
        st, d = library_test(hosted, h, topic)
        assert st == 200 and d["charged"] == "ai_tests_new" and d["generated"] >= 5, d
    st, d = library_test(hosted, h, "Eigenwerte")
    assert (st, d["code"], d["limit"]) == (429, "quota_exhausted", 3), d
    assert fake.calls == 3, "nach dem Kontingent keine weitere bezahlte Generierung"
    q = ent(hosted, h)["quotas"]["ai_tests_new"]
    assert (q["used"], q["limit"]) == (3, 3)


def test_04_pro_connect_entitlements(hosted):
    _, h_plus = user(hosted, "p@beispiel.de", plan="plus")
    _, h = user(hosted, "pc@beispiel.de", plan="pro_connect")
    e = ent(hosted, h)
    assert e["plan"] == "pro_connect" and e["plan_name"] == "Studora Pro Connect"
    for name in ("can_annotate_pdf", "can_use_advanced_analytics", "can_use_advanced_planner", "can_review_wrong_answers",
                 "can_use_extended_test_history", "can_get_recommendations", "can_access_shared_tests"):
        assert e["entitlements"][name], name
    assert not e["entitlements"]["can_use_ai_explanations"], "Studora-KI erst mit Pro AI"
    assert e["quotas"]["library_tests"]["unlimited"] and e["quotas"]["ai_tests_new"]["limit"] == 3
    for path in ("/api/learning/stats", "/api/learning/review", "/api/learning/recommendations"):
        assert asgi_call(hosted, "GET", path, headers=h)[0] == 200, path
        st, d = _j(asgi_call(hosted, "GET", path, headers=h_plus))
        assert (st, d["required_plan"]) == (403, "pro_connect"), path


def test_05_pro_ai_gets_forty_tests_and_studora_ai(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, h = user(hosted, "ai@beispiel.de", plan="pro_ai")
    e = ent(hosted, h)
    assert e["quotas"]["ai_tests_new"]["limit"] == 40 and e["entitlements"]["can_use_ai_explanations"]
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({"mode": "explain", "page_text": "Matrizen"})))
    assert st == 200 and "Matrix" in d["answer"], d
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 1
    _, h_plus = user(hosted, "noai@beispiel.de", plan="plus")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h_plus, body=json.dumps({"mode": "explain"})))
    assert (st, d["required_plan"]) == (403, "pro_ai")


def test_06_all_plans_keep_basic_functions(hosted):
    for plan in ("free", "plus", "pro_connect", "pro_ai"):
        _, h = user(hosted, f"basis-{plan}@beispiel.de", plan=plan)
        add_file(hosted, h)
        for path in ("/api/modules", "/api/library", "/api/files/f1/annotations", "/api/timetable/week?start=2026-10-26",
                     "/api/community/info", "/api/entitlements", "/api/billing/plans"):
            assert asgi_call(hosted, "GET", path, headers=h)[0] == 200, (plan, path)
        e = ent(hosted, h)
        for name in ("can_view_pdf", "can_view_timetable", "can_read_community", "can_manage_courses"):
            assert e["entitlements"][name], (plan, name)


# ---------------------------------------------------------------- 7, 8, 9, 10: Upgrade, Downgrade, Ablauf, Daten bleiben

def test_07_upgrade_activates_immediately(hosted, apple):
    u, h = user(hosted, "up@beispiel.de")
    st, d = verify(hosted, h, apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30))
    assert st == 200 and d["plan"] == "plus" and d["status"] == "active", d
    assert ent(hosted, h)["entitlements"]["can_annotate_pdf"]
    st, d = verify(hosted, h, apple.tx(u["id"], "de.uniflow.proai.monthly", IN_30))
    assert st == 200 and d["plan"] == "pro_ai", "Upgrade wirkt sofort (Apple stellt eine neue Transaktion aus)"
    assert ent(hosted, h)["entitlements"]["can_use_ai_explanations"]


def test_08_downgrade_takes_effect_at_renewal(hosted, apple):
    from app import billing
    u, h = user(hosted, "down@beispiel.de")
    otid = "2000000000000008"
    verify(hosted, h, apple.tx(u["id"], "de.uniflow.proai.monthly", IN_30, otid=otid))
    # Nutzer waehlt Plus fuer die naechste Verlaengerung
    st, d = notify(hosted, apple.notification("DID_CHANGE_RENEWAL_PREF", apple.tx(u["id"], "de.uniflow.proai.monthly", IN_30, otid=otid),
                                              apple.renewal(otid, "de.uniflow.plus.monthly"), subtype="DOWNGRADE"))
    assert st == 200 and d["plan"] == "pro_ai" and d["pending_plan"] == "plus", d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["pending_plan"] == "plus", "bis zum Ende des bezahlten Monats bleibt Pro AI"
    conn = billing.connect()
    try:
        later = IN_30 + dt.timedelta(minutes=1)
        assert billing.current_plan(conn, u["id"], later) == "free", "ohne Verlaengerung endet der Tarif zum Ablauf"
    finally:
        conn.close()
    st, d = notify(hosted, apple.notification("DID_RENEW", apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30 + dt.timedelta(days=30), otid=otid),
                                              apple.renewal(otid, "de.uniflow.plus.monthly")))
    assert st == 200 and d["plan"] == "plus" and d["pending_plan"] is None
    e = ent(hosted, h)
    assert e["plan"] == "plus" and not e["entitlements"]["can_use_ai_explanations"] and e["entitlements"]["can_annotate_pdf"]


def test_09_10_expiry_disables_premium_but_keeps_notes(hosted, apple):
    u, h = user(hosted, "ablauf@beispiel.de")
    add_file(hosted, h)
    otid = "2000000000000009"
    verify(hosted, h, apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30, otid=otid))
    assert put_note(hosted, h, text="Meine Herleitung")[0] == 200
    # Kuendigung: laeuft bis zum Ablauf weiter
    st, d = notify(hosted, apple.notification("DID_CHANGE_RENEWAL_STATUS", apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30, otid=otid),
                                              apple.renewal(otid, "de.uniflow.plus.monthly", auto_renew=False), subtype="AUTO_RENEW_DISABLED"))
    assert d["plan"] == "plus" and d["will_renew"] is False and ent(hosted, h)["plan"] == "plus"
    past = dt.datetime.now(UTC) - dt.timedelta(minutes=5)
    st, d = notify(hosted, apple.notification("EXPIRED", apple.tx(u["id"], "de.uniflow.plus.monthly", past, otid=otid),
                                              apple.renewal(otid, "de.uniflow.plus.monthly", auto_renew=False), subtype="VOLUNTARY"))
    assert st == 200 and d["status"] == "expired"
    assert ent(hosted, h)["plan"] == "free"
    st, d = put_note(hosted, h, text="neu")
    assert (st, d["code"]) == (403, "plan_required"), "Premium aus"
    st, d = _j(asgi_call(hosted, "GET", "/api/files/f1/annotations", headers=h))
    assert st == 200 and "Meine Herleitung" in json.dumps(d["data"]), "private Notizen bleiben lesbar"


def test_revoked_refund_and_duplicates(hosted, apple):
    u, h = user(hosted, "refund@beispiel.de")
    v, hv = user(hosted, "andere@beispiel.de")
    otid = "2000000000000010"
    first = apple.notification("SUBSCRIBED", apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30, otid=otid))
    assert notify(hosted, first)[1]["plan"] == "plus"
    assert notify(hosted, first)[1]["duplicate"], "gleiche Meldung zaehlt einmal"
    # dasselbe Abo kann kein zweites Konto freischalten (Token des ersten Kontos, oder ohne Token)
    st, d = verify(hosted, hv, apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30, otid=otid))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    st, d = verify(hosted, hv, apple.tx(v["id"], "de.uniflow.plus.monthly", IN_30, otid=otid, token=False))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    assert ent(hosted, hv)["plan"] == "free"
    st, d = notify(hosted, apple.notification("REFUND", apple.tx(u["id"], "de.uniflow.plus.monthly", IN_30, otid=otid, revoked=True)))
    assert d["status"] == "revoked" and ent(hosted, h)["plan"] == "free"


def test_apple_signatures_are_checked(hosted, apple, tmp_path, monkeypatch):
    u, h = user(hosted, "sig@beispiel.de")
    forger = AppleSigner(tmp_path / "x") if (tmp_path / "x").mkdir() is None else None
    st, d = verify(hosted, h, forger.tx(u["id"], "de.uniflow.proai.monthly", IN_30))
    assert (st, d["code"]) == (400, "jws_untrusted"), "fremde Wurzel"
    good = apple.tx(u["id"], "de.uniflow.proai.monthly", IN_30)
    head, body, sig = good.split(".")
    payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    payload["productId"] = "de.uniflow.proai.monthly"
    payload["expiresDate"] += 10 ** 12
    tampered = f"{head}.{base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b'=').decode()}.{sig}"
    assert verify(hosted, h, tampered)[1]["code"] == "jws_untrusted", "veraenderte Nutzdaten"
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/apple/verify", headers=h, body=json.dumps({"plan": "pro_ai"})))
    assert st == 400 and ent(hosted, h)["plan"] == "free", "ein Tarif aus der Anfrage wird nie angenommen"
    monkeypatch.setenv("LERNAPP_APPLE_ROOT_CERTS", "")
    st, d = verify(hosted, h, good)
    assert (st, d["code"]) == (503, "apple_not_configured")


# ---------------------------------------------------------------- 11, 12, 13: Testbibliothek

def test_11_private_tests_never_become_public(hosted):
    from app import test_library
    owner = "o" * 24
    q = {"type": "mc", "question": "Was ist die Determinante einer 2x2-Einheitsmatrix?", "options": ["0", "1", "2", "4"], "answer": "1"}
    test_library.add([q], {"subject": "Lineare Algebra", "topic": "Determinanten"}, "chatgpt_user", "private", owner)
    test_library.submit_for_sharing(owner, [{**q, "question": q["question"] + " (zweite Fassung)"}],
                                    {"subject": "Lineare Algebra", "topic": "Determinanten"})
    assert test_library.find({"subject": "Lineare Algebra", "topic": "Determinanten"}) == [], "privat und wartend sind nie im Pool"
    _, h = user(hosted, "teilen@beispiel.de", plan="plus")
    st, d = _j(asgi_call(hosted, "POST", "/api/library/tests/1/share", headers=h, body=json.dumps({"topic": "X"})))
    assert st in (400, 404) and d["code"] in ("confirm_required", "not_found")


def _own_test(app, headers, subject, questions):
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            return conn.execute("INSERT INTO tests(subject, title, questions, created_at) VALUES (?,?,?,?)",
                                (subject, "Eigener Test", json.dumps(questions), "2026-10-27")).lastrowid
    finally:
        config.reset_user_context(t)


def test_12_shared_and_approved_tests_are_reused(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, ha = user(hosted, "a@beispiel.de", plan="plus", uni="luh")
    _, hadmin = user(hosted, "mod@beispiel.de", admin=True)
    qs = [{"nr": i, "type": "mc", "question": f"Matrizen Aufgabe {i}: Welches Produkt ergibt die Einheitsmatrix? Kontakt: anna@uni.de",
           "options": ["A mal A", "A mal A invers", "A plus A", "Null"], "answer": "A mal A invers", "points": 10} for i in range(6)]
    tid = _own_test(hosted, ha, "Lineare Algebra", qs)
    st, d = _j(asgi_call(hosted, "POST", f"/api/library/tests/{tid}/share", headers=ha,
                         body=json.dumps({"confirm": True, "topic": "Matrizen Multiplikation Inverse"})))
    assert st == 200 and d["submitted"] == 6 and d["review"] == "pending", d
    st, queue = _j(asgi_call(hosted, "GET", "/api/library/moderation", headers=hadmin))
    assert len(queue["questions"]) == 6 and all("anna@uni.de" not in q["question"] for q in queue["questions"]), "private Daten entfernt"
    assert asgi_call(hosted, "GET", "/api/library/moderation", headers=ha)[0] == 403
    for q in queue["questions"]:
        assert _j(asgi_call(hosted, "POST", f"/api/library/questions/{q['id']}/moderate", headers=hadmin,
                            body=json.dumps({"action": "approve"})))[0] == 200
    # Studentin aus Hildesheim, anderes Dokument, gleiches Thema: Test nur aus dem Pool, keine KI
    _, hb = user(hosted, "b@beispiel.de", plan="plus", uni="hildesheim")
    st, d = library_test(hosted, hb, "Matrizen Inverse", count=5)
    assert st == 200 and d["charged"] == "library_tests" and d["reused"] == 5 and d["generated"] == 0, d
    assert fake.calls == 0
    assert ent(hosted, hb)["quotas"]["library_tests"]["used"] == 1


def test_13_parallel_generation_creates_no_duplicates(hosted):
    from app import ai_backend, test_library
    fake = FakeAI(delay=0.6)
    ai_backend.set_provider(fake)
    heads = [user(hosted, f"par{i}@beispiel.de", plan="plus")[1] for i in range(2)]
    results = []

    def run(h):
        results.append(library_test(hosted, h, "Matrizen Rang", count=5))
    threads = [threading.Thread(target=run, args=(h,)) for h in heads]
    [t.start() for t in threads]
    [t.join(30) for t in threads]
    assert all(st == 200 for st, _ in results), results
    assert fake.calls == 1, "die zweite Anfrage wartet und nutzt die Fragen der ersten"
    assert sorted(d["charged"] for _, d in results) == ["ai_tests_new", "library_tests"]
    with test_library.cursor() as conn:
        n = conn.execute("SELECT COUNT(*), COUNT(DISTINCT fingerprint) FROM questions").fetchone()
    assert n[0] == n[1], "keine doppelten Fragen im Pool"


def test_harder_test_uses_harder_questions_or_generates_only_missing(hosted):
    from app import ai_backend, test_library
    fake = FakeAI()
    ai_backend.set_provider(fake)
    meta = {"subject": "Lineare Algebra", "topic": "Matrizen Spur", "difficulty": 2}
    easy = [{"type": "mc", "question": f"Leichte Frage {i} zur Spur einer Matrix?", "options": ["1", "2", "3", "4"], "answer": "2",
             "difficulty": 2} for i in range(6)]
    hard = [{"type": "mc", "question": f"Schwere Frage {i} zur Spur einer Matrix?", "options": ["1", "2", "3", "4"], "answer": "3",
             "difficulty": 5} for i in range(3)]
    test_library.add(easy, meta, "studora_ai", "auto_checked")
    test_library.add(hard, {**meta, "difficulty": 5}, "studora_ai", "auto_checked")
    _, h = user(hosted, "hart@beispiel.de", plan="plus")
    st, d = library_test(hosted, h, "Matrizen Spur", count=5, difficulty=4, harder=True)
    assert st == 200 and d["charged"] == "ai_tests_new" and fake.calls == 1, d
    st, t = _j(asgi_call(hosted, "GET", f"/api/tests/{d['test_id']}", headers=h))
    assert all(q["difficulty"] >= 4 for q in t["questions"]), "nur schwierige Fragen"


# ---------------------------------------------------------------- 14: ChatGPT ohne Partnerfreigabe

def test_14_missing_chatgpt_approval_is_never_faked(hosted):
    _, h = user(hosted, "gpt@beispiel.de", plan="pro_ai")
    st, d = _j(asgi_call(hosted, "GET", "/api/integrations/chatgpt", headers=h))
    assert st == 200 and d["available"] is False and d["connected"] is False and d["status"] == "disabled"
    assert d["plan_gating_allowed"] is False and d["shown_in_ui"] is False
    st, d = _j(asgi_call(hosted, "POST", "/api/integrations/chatgpt/connect", headers=h))
    assert (st, d["code"]) == (503, "chatgpt_not_available")
    assert ent(hosted, h)["entitlements"]["chatgpt_connection_premium"] is False


# ---------------------------------------------------------------- Kostenkontrolle, Datenschutz, Vertrag

def test_budget_and_rate_limit_refund_the_quota(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, h = user(hosted, "budget@beispiel.de", plan="pro_ai")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "0.01")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({"mode": "explain", "page_text": "x"})))
    assert (st, d["code"]) == (503, "ai_budget_exhausted")
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 0, "nicht geleistet = nicht berechnet"
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "50")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "2")
    codes = [_j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({"mode": "explain", "page_text": f"Seite {i}"})))
             for i in range(3)]
    assert [c[0] for c in codes] == [200, 200, 429] and codes[2][1]["code"] == "ai_rate_limited"


def test_cost_is_logged_with_tokens(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "1.0")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "4.0")
    _, h = user(hosted, "kosten@beispiel.de", plan="pro_ai")
    _, hadmin = user(hosted, "betrieb@beispiel.de", admin=True)
    asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({"mode": "summary", "page_text": "Seite"}))
    st, rep = _j(asgi_call(hosted, "GET", "/api/billing/ai-usage", headers=hadmin))
    assert st == 200 and rep["requests"] == 1 and rep["input_tokens"] == 120 and rep["output_tokens"] == 40
    assert rep["cost_eur"] == pytest.approx((120 * 1.0 + 40 * 4.0) / 1_000_000)
    assert asgi_call(hosted, "GET", "/api/billing/ai-usage", headers=h)[0] == 403


def test_ai_not_configured_is_honest(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(None)
    monkeypatch.delenv("LERNAPP_OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("LERNAPP_AI_PROVIDER", raising=False)
    _, h = user(hosted, "ohne@beispiel.de", plan="pro_ai")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({"mode": "explain"})))
    assert (st, d["code"]) == (503, "ai_not_configured")
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 0
    st, plans_ = _j(asgi_call(hosted, "GET", "/api/billing/plans"))
    assert st == 200 and plans_["studora_ai_configured"] is False and plans_["purchase"]["web"]["available"] is False


def test_scrub_removes_personal_data():
    from app import test_library
    s = test_library.scrub("Name: Anna Beispiel, Matrikelnummer 1234567, anna@uni-hannover.de, Tel. 0511 123456, Musterstraße 5")
    for leak in ("Anna", "1234567", "anna@", "0511", "Musterstraße"):
        assert leak not in s, (leak, s)
    assert test_library.scrub("Berechne 3 + 4 = 7") == "Berechne 3 + 4 = 7", "Rechnungen bleiben"


def test_local_mode_has_everything_without_plans(app):
    from app import billing
    st, d = _j(asgi_call(app, "GET", "/api/entitlements"))
    assert st == 200 and d["plan"] == billing.LOCAL_PLAN and d["entitlements"]["can_annotate_pdf"]
    assert d["entitlements"]["chatgpt_connection_premium"] is False, "auch lokal keine vorgetaeuschte ChatGPT-Verbindung"


def test_plans_fixture_is_current():
    import importlib.util
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("gen", root / "tools" / "gen-plans-fixture.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    stored = (root / "packages" / "shared-contracts" / "fixtures" / "plans" / "plans.json").read_text(encoding="utf-8")
    assert stored == gen.render(), "python tools/gen-plans-fixture.py ausfuehren"


def test_plan_table_matches_the_order():
    from app import plans
    assert [plans.PLANS[k]["price_cents"] for k in plans.ORDER] == [0, 199, 299, 399]
    for low, high in zip(plans.ORDER, plans.ORDER[1:]):
        assert all(plans.has(high, e) for e in plans.ENTITLEMENTS if plans.has(low, e)), f"{high} enthält alles aus {low}"
    assert not plans.INTEGRATIONS["chatgpt"]["plan_gating_allowed"]
