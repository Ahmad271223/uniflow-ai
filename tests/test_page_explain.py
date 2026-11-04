"""Erklaerungsspeicher, Dienst-Seite (app/page_explain.py, app/page_explain_api.py, 04.11.2026): Regeln (Datensatzname,
Plaetze 1..3, Groesse, Besitz), Endpunkte /api/explain mit Sitzung, Varianten nie ueberschreiben, 409 explain_full,
Loeschen nur durch Ersteller oder Inhaber, Grenze je Konto, Anonymisierung beim endgueltigen Loeschen des Kontos.
Dazu die CloudKit-Schemadatei (apps/apple/Config/cloudkit-schema.ckdb) offline: Klammern, Felder, Indexe, Rechte."""
import base64
import json
import os
import re
from datetime import timedelta
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401

ROOT = Path(__file__).resolve().parents[1]
FILE_KEY = "a" * 64
OTHER_KEY = "b" * 64


def _payload(version=1, extra=b"x" * 40):
    """Form eines Chiffrats (Versionsbyte, Salz 32, Nonce 12, Inhalt, Tag 16) als Base64; der Inhalt ist hier beliebig."""
    return base64.b64encode(bytes([version]) + os.urandom(32) + os.urandom(12) + extra + os.urandom(16)).decode("ascii")


def _store(app, headers, **over):
    body = {"file_key": FILE_KEY, "page": 3, "mode": "explain", "payload": _payload()}
    body.update(over)
    return asgi_call(app, "POST", "/api/explain", body=json.dumps(body), headers=headers)


# ---------------------------------------------------------------- Regeln (reine Funktionen)

def test_record_name_round_trip_and_rejects_foreign_forms():
    from app import page_explain as pe
    name = pe.record_name(FILE_KEY, 3, "explain", 2)
    assert name == FILE_KEY + "#3#explain#2"
    assert pe.parse_record_name(name) == (FILE_KEY, 3, "explain", 2)
    for bad in (FILE_KEY + "#0#explain#1", FILE_KEY + "#3#ask#1", FILE_KEY + "#3#explain#4", FILE_KEY + "#3#explain#0",
                "abc#3#explain#1", FILE_KEY + "#3#explain", FILE_KEY + "#3", None, ""):
        assert pe.parse_record_name(bad) is None, bad


def test_variant_slots_like_the_core():
    from app import page_explain as pe
    assert pe.MAX_VARIANTS == 3 and pe.VERSION == 1
    assert pe.SHARED_MODES == ("explain", "explain_simple", "summary", "terms", "steps", "hints")
    assert pe.free_variants([]) == [1, 2, 3]
    assert pe.free_variants([1, 3]) == [2]
    assert pe.free_variants([1, 2, 3]) == []
    assert pe.next_slot([]) == 1 and pe.next_slot([1]) == 2 and pe.next_slot([2]) == 1 and pe.next_slot([1, 2, 3]) is None
    assert pe.preferred_variant([3, 2]) == 2 and pe.preferred_variant([]) is None and pe.preferred_variant([0, 7]) is None


def test_checks_name_their_codes():
    from app import page_explain as pe
    assert pe.check_file_key(FILE_KEY) == FILE_KEY
    for bad in ("A" * 64, "a" * 63, 12, None):
        with pytest.raises(pe.PageExplainError) as e:
            pe.check_file_key(bad)
        assert e.value.code == "bad_file_key"
    assert pe.check_page("7") == 7 and pe.check_page(1) == 1
    for bad in (0, -1, "x", True, pe.MAX_PAGE + 1):
        with pytest.raises(pe.PageExplainError) as e:
            pe.check_page(bad)
        assert e.value.code == "bad_page"
    with pytest.raises(pe.PageExplainError) as e:
        pe.check_mode("ask")
    assert e.value.code == "bad_mode" and "explain_simple" in e.value.message
    for bad in (0, 4, "x"):
        with pytest.raises(pe.PageExplainError) as e:
            pe.check_variant(bad)
        assert e.value.code == "bad_variant"
    assert pe.check_version(None) == 1 and pe.check_version(2) == 2
    with pytest.raises(pe.PageExplainError) as e:
        pe.check_version(0)
    assert e.value.code == "bad_version"


def test_payload_size_and_form_like_doc_index():
    from app import page_explain as pe
    assert pe.MAX_PAYLOAD_CHARS == 256 * 1024                # DocIndexCrypto.maxPayloadChars
    good = _payload()
    assert pe.check_payload(good) == good
    with pytest.raises(pe.PageExplainError) as e:
        pe.check_payload("A" * (pe.MAX_PAYLOAD_CHARS + 4))
    assert e.value.code == "payload_too_large" and e.value.status == 413
    for bad in ("", None, "nicht base64!", "QUJD\nREVG", base64.b64encode(b"\x01" + b"k" * 30).decode()):
        with pytest.raises(pe.PageExplainError) as e:
            pe.check_payload(bad)
        assert e.value.code == "bad_payload", bad
    with pytest.raises(pe.PageExplainError) as e:
        pe.check_payload(_payload(version=2), 1)
    assert e.value.code == "version_mismatch"
    assert pe.check_payload(_payload(version=2), 2)
    # genau an der Grenze: hoechstens MAX_PAYLOAD_CHARS Zeichen Base64
    raw = bytes([1]) + b"\0" * (pe.MAX_PAYLOAD_CHARS // 4 * 3 - 1)
    assert len(pe.check_payload(base64.b64encode(raw).decode())) == pe.MAX_PAYLOAD_CHARS


def test_owner_rules():
    from app import page_explain as pe
    me, admin, other = {"id": "u1", "role": "user"}, {"id": "adm", "role": "admin"}, {"id": "u2", "role": "user"}
    assert pe.may_delete("u1", me) and pe.may_delete("u1", admin) and not pe.may_delete("u1", other)
    assert not pe.may_delete("deleted:abcd", {"id": "deleted:abcd", "role": "user"}) and pe.may_delete("deleted:abcd", admin)
    assert not pe.may_delete("u1", None) and not pe.may_delete("u1", {})
    row = {"record_name": "n", "file_key": FILE_KEY, "page": 1, "mode": "explain", "variant": 1, "payload": "x", "version": 1,
           "created_at": "t", "owner_id": "u1"}
    assert pe.public(row, me)["mine"] is True and "owner_id" not in pe.public(row, me)
    assert pe.public(row, other)["mine"] is False and pe.public(row, admin)["owner_id"] == "u1"
    assert pe.public(row, None)["mine"] is False


# ---------------------------------------------------------------- Endpunkte

def test_requires_hosted_mode_and_session(hosted, monkeypatch):
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}")
    assert st == 401 and json.loads(b)["code"] == "unauthenticated"
    from app import config
    monkeypatch.setattr(config, "MODE", "local")
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}")
    assert st == 501 and json.loads(b)["code"] == "not_hosted"


def test_store_list_get_delete_round_trip(hosted):
    u, h = _user(hosted, "erklaert@example.org", plus=False)
    st, _, b = _store(hosted, h)
    assert st == 201, b
    rec = json.loads(b)
    assert rec["variant"] == 1 and rec["record_name"] == FILE_KEY + "#3#explain#1" and rec["mine"] is True
    assert rec["version"] == 1 and rec["created_at"].endswith("Z") and "owner_id" not in rec
    # Liste: niedrigste zuerst, freie Plaetze, nicht voll
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}&page=3&mode=explain", headers=h)
    d = json.loads(b)
    assert st == 200 and [r["variant"] for r in d["records"]] == [1] and d["free"] == [2, 3] and d["full"] is False and d["preferred"] == 1
    # ohne Seite und Modus: alles zur Datei, ohne free/full
    st, _, b = _store(hosted, h, page=4, mode="summary")
    assert st == 201
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}", headers=h)
    d = json.loads(b)
    assert [(r["page"], r["mode"]) for r in d["records"]] == [(3, "explain"), (4, "summary")] and "free" not in d
    # einzeln
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h)
    assert st == 200 and json.loads(b)["payload"] == rec["payload"]
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/2", headers=h)
    assert st == 404 and json.loads(b)["code"] == "not_found"
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/ask/1", headers=h)
    assert st == 400 and json.loads(b)["code"] == "bad_mode"
    # loeschen durch den Ersteller
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h)
    assert st == 200 and json.loads(b) == {"deleted": True}
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h)
    assert st == 404


def test_three_variants_never_overwritten_then_full(hosted):
    _, h = _user(hosted, "drei@example.org", plus=False)
    payloads = [_payload() for _ in range(3)]
    for i, p in enumerate(payloads, start=1):
        st, _, b = _store(hosted, h, payload=p)
        assert st == 201 and json.loads(b)["variant"] == i, b
    st, _, b = _store(hosted, h)
    d = json.loads(b)
    assert st == 409 and d["code"] == "explain_full" and d["free"] == [] and d["max_variants"] == 3
    assert "drei geteilte Antworten" in d["detail"]
    # ausdruecklich benannter, belegter Platz: nie ueberschreiben, auch nicht vom Ersteller
    st, _, b = _store(hosted, h, variant=2)
    assert st == 409 and json.loads(b)["code"] == "explain_taken"
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}&page=3&mode=explain", headers=h)
    d = json.loads(b)
    assert [r["payload"] for r in d["records"]] == payloads and d["full"] is True and d["free"] == []
    # Luecke nach dem Loeschen: der naechste bekommt den niedrigsten freien Platz
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/2", headers=h)
    assert st == 200
    st, _, b = _store(hosted, h)
    assert st == 201 and json.loads(b)["variant"] == 2
    # gewuenschter freier Platz
    st, _, b = _store(hosted, h, page=9, variant=3)
    assert st == 201 and json.loads(b)["variant"] == 3
    st, _, b = _store(hosted, h, page=9)
    assert st == 201 and json.loads(b)["variant"] == 1


def test_store_validates_body(hosted):
    _, h = _user(hosted, "form@example.org", plus=False)
    for over, code, status in (({"file_key": "zu kurz"}, "bad_file_key", 400), ({"page": 0}, "bad_page", 400),
                               ({"mode": "ask"}, "bad_mode", 400), ({"payload": "???"}, "bad_payload", 400),
                               ({"payload": "A" * (256 * 1024 + 4)}, "payload_too_large", 413),
                               ({"version": 2}, "version_mismatch", 400), ({"variant": 4}, "bad_variant", 400)):
        st, _, b = _store(hosted, h, **over)
        assert (st, json.loads(b)["code"]) == (status, code), (over, b)
    st, _, b = asgi_call(hosted, "POST", "/api/explain", body="[]", headers=h)
    assert st == 422                                           # kein Objekt: FastAPI weist den Rumpf ab
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}&page=x&mode=explain", headers=h)
    assert st == 400 and json.loads(b)["code"] == "bad_page"
    # Dienst setzt created_at selbst, nimmt keinen Zeitstempel des Geraets
    st, _, b = _store(hosted, h, created_at="1999-01-01T00:00:00Z")
    assert st == 201 and json.loads(b)["created_at"] != "1999-01-01T00:00:00Z"


def test_store_needs_verified_email_reading_does_not(hosted):
    _, h = _user(hosted, "unbestaetigt@example.org", plus=False, verified=False)
    st, _, b = _store(hosted, h)
    assert st == 403 and json.loads(b)["code"] == "email_unverified"
    st, _, b = asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}", headers=h)
    assert st == 200 and json.loads(b)["records"] == []


def test_delete_only_owner_or_admin(hosted):
    _, h1 = _user(hosted, "besitzer@example.org", plus=False)
    _, h2 = _user(hosted, "fremd@example.org", plus=False)
    _, ha = _user(hosted, "inhaber@example.org", plus=False, admin=True)
    st, _, b = _store(hosted, h1)
    assert st == 201
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h2)
    assert st == 403 and json.loads(b)["code"] == "not_owner"
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h2)
    assert st == 200 and json.loads(b)["mine"] is False and "owner_id" not in json.loads(b)
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/1", headers=ha)
    assert st == 200 and json.loads(b)["owner_id"]                # Moderation sieht den Ersteller
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/1", headers=ha)
    assert st == 200
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/1", headers=ha)
    assert st == 404 and json.loads(b)["code"] == "not_found"


def test_rate_limit_per_account(hosted, monkeypatch):
    monkeypatch.setenv("LERNAPP_LIMIT_EXPLAIN_USER", "2/60")
    _, h = _user(hosted, "grenze@example.org", plus=False)
    assert _store(hosted, h, page=1)[0] == 201
    assert _store(hosted, h, page=2)[0] == 201
    st, hdrs, b = _store(hosted, h, page=3)
    assert st == 429 and json.loads(b)["code"] == "rate_limited" and any(k == b"retry-after" for k, _ in hdrs)
    # ein anderes Konto ist nicht betroffen; Lesen zaehlt nicht
    _, h2 = _user(hosted, "andere@example.org", plus=False)
    assert _store(hosted, h2, page=3)[0] == 201
    assert asgi_call(hosted, "GET", f"/api/explain?file_key={FILE_KEY}", headers=h)[0] == 200


def test_purge_anonymises_owner_but_keeps_ciphertext(hosted, monkeypatch):
    from app import accounts, page_explain as pe
    u, h = _user(hosted, "weg@example.org", plus=False)
    assert _store(hosted, h)[0] == 201
    assert pe.count_for_owner(u["id"]) == 1
    accounts.delete_account(u["id"], "sehr-geheim-123")
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1
    assert pe.count_for_owner(u["id"]) == 0
    with pe.cursor() as conn:
        rows = conn.execute("SELECT owner_id, payload FROM page_explain WHERE file_key=?", (FILE_KEY,)).fetchall()
    assert len(rows) == 1 and rows[0]["owner_id"].startswith("deleted:") and rows[0]["payload"]
    # die anderen lesen weiter, niemand kann loeschen ausser dem Inhaber
    _, h2 = _user(hosted, "bleibt@example.org", plus=False)
    st, _, b = asgi_call(hosted, "GET", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h2)
    assert st == 200 and json.loads(b)["mine"] is False
    assert asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/3/explain/1", headers=h2)[0] == 403


def test_forget_owner_without_table_is_harmless():
    import sqlite3
    from app import page_explain as pe
    conn = sqlite3.connect(":memory:")
    assert pe.forget_owner(conn, "wer") == 0


def test_env_example_mentions_limit():
    text = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    assert "LERNAPP_LIMIT_EXPLAIN_USER" in text


# ---------------------------------------------------------------- CloudKit-Schemadatei (offline)

CKDB = ROOT / "apps" / "apple" / "Config" / "cloudkit-schema.ckdb"
# Felder und Indexe laut docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md und den Swift-Datensaetzen (Services/*CloudKit.swift)
EXPECTED = {
    "Comment": {"solutionID": ("STRING", {"QUERYABLE"}), "parentID": ("STRING", set()), "status": ("STRING", set()),
                "createdAt": ("STRING", set()), "editedAt": ("STRING", set()), "payload": ("STRING", set()),
                "ownerRecordName": ("STRING", set()), "removedID": ("STRING", set()), "createdOrder": ("INT64", set())},
    "Like": {"solutionID": ("STRING", {"QUERYABLE"}), "ownerRecordName": ("STRING", set()), "createdAt": ("STRING", set())},
    "Correction": {"solutionID": ("STRING", {"QUERYABLE"}), "solutionOwner": ("STRING", {"QUERYABLE"}), "payload": ("STRING", set()),
                   "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set()), "createdOrder": ("INT64", set())},
    "WeeklyTest": {"shareKey": ("STRING", {"QUERYABLE"}), "status": ("STRING", set()), "payload": ("STRING", set()),
                   "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set()), "variant": ("INT64", set())},
    "DocIndex": {"fileKey": ("STRING", {"QUERYABLE"}), "payload": ("STRING", set()), "createdAt": ("STRING", set()),
                 "ownerRecordName": ("STRING", set()), "page": ("INT64", set()), "version": ("INT64", set())},
    "PageExplain": {"fileKey": ("STRING", {"QUERYABLE"}), "mode": ("STRING", set()), "payload": ("STRING", set()),
                    "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set()), "page": ("INT64", set()),
                    "variant": ("INT64", set()), "version": ("INT64", set())},
    # Karteikarten (docs/KARTEIKARTEN-STAPEL-2026-11-04.md): geteilte Wochenstapel wie WeeklyTest, eigene Stapel teilen
    "WeekCardStack": {"shareKey": ("STRING", {"QUERYABLE"}), "variant": ("INT64", set()), "status": ("STRING", set()),
                      "payload": ("STRING", set()), "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set())},
    "CardStackShare": {"communityKey": ("STRING", {"QUERYABLE"}), "kind": ("STRING", set()), "week": ("INT64", set()),
                       "name": ("STRING", set()), "cardCount": ("INT64", set()), "displayName": ("STRING", set()),
                       "payload": ("STRING", set()), "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set()),
                       "withdrawn": ("INT64", set())},
    # Studienverlauf (docs/STUDIENVERLAUF-2026-11-04.md): Fakten eines Modulkatalogs, einmal je Studiengang geteilt
    "StudyCatalog": {"catalogKey": ("STRING", {"QUERYABLE"}), "variant": ("INT64", set()), "payload": ("STRING", set()),
                     "version": ("INT64", set()), "createdAt": ("STRING", set()), "ownerRecordName": ("STRING", set())},
}
SYSTEM_FIELDS = {"___createTime": "TIMESTAMP", "___createdBy": "REFERENCE", "___etag": "STRING", "___modTime": "TIMESTAMP",
                 "___modifiedBy": "REFERENCE", "___recordID": "REFERENCE"}
FIELD_RE = re.compile(r'^(?:"(?P<q>[A-Za-z_]+)"|(?P<n>[A-Za-z_]+))\s+(?P<type>STRING|INT64|TIMESTAMP|REFERENCE|ASSET|DOUBLE|BYTES|LOCATION)'
                      r'(?P<idx>(?:\s+(?:QUERYABLE|SORTABLE|SEARCHABLE))*)$')
GRANT_RE = re.compile(r'^GRANT (READ|WRITE|CREATE) TO "(_world|_icloud|_creator)"$')


def parse_ckdb(text: str) -> dict:
    """Kleiner Leser fuer die Teilmenge der CloudKit-Schemasprache, die die Datei nutzt: DEFINE SCHEMA, RECORD TYPE ( Felder,
    GRANTs ); Kommentarzeilen mit // ueberliest er. Liefert je Typ die Felder (Typ, Indexe) und die Rechte."""
    body = "\n".join(l for l in text.splitlines() if not l.strip().startswith("//"))
    assert body.lstrip().startswith("DEFINE SCHEMA"), "Datei beginnt nicht mit DEFINE SCHEMA"
    assert body.count("(") == body.count(")"), "Klammern nicht ausgeglichen"
    types = {}
    for m in re.finditer(r"RECORD TYPE (\w+) \((.*?)\);", body, re.S):
        name, inner = m.group(1), m.group(2)
        assert name not in types, f"{name} doppelt"
        fields, grants = {}, set()
        for raw in (p.strip() for p in inner.split(",")):
            if not raw:
                continue
            g = GRANT_RE.match(raw)
            if g:
                grants.add((g.group(1), g.group(2)))
                continue
            f = FIELD_RE.match(raw)
            assert f, f"{name}: Zeile nicht verstanden: {raw!r}"
            fname = f.group("q") or f.group("n")
            assert fname not in fields, f"{name}.{fname} doppelt"
            fields[fname] = (f.group("type"), set(f.group("idx").split()))
        types[name] = {"fields": fields, "grants": grants}
    assert types, "keine RECORD TYPE gefunden"
    return types


def test_ckdb_parses_and_has_all_record_types():
    types = parse_ckdb(CKDB.read_text(encoding="utf-8"))
    assert set(types) == {"Solution", "Report", "StudyGroup", "Block", "Ban", *EXPECTED}
    for name, t in types.items():
        for sys_name, sys_type in SYSTEM_FIELDS.items():
            assert t["fields"].get(sys_name, (None,))[0] == sys_type, f"{name}: Systemfeld {sys_name}"
        assert "QUERYABLE" in t["fields"]["___recordID"][1], f"{name}: recordName muss Queryable sein"
        for fname, (ftype, idx) in t["fields"].items():
            assert idx <= {"QUERYABLE", "SORTABLE", "SEARCHABLE"}, (name, fname)
            if "SORTABLE" in idx or "SEARCHABLE" in idx:
                assert ftype in ("STRING", "INT64", "TIMESTAMP", "DOUBLE"), (name, fname)


def test_ckdb_new_types_match_the_production_doc_and_swift_records():
    types = parse_ckdb(CKDB.read_text(encoding="utf-8"))
    for name, expected in EXPECTED.items():
        fields = {k: v for k, v in types[name]["fields"].items() if not k.startswith("___")}
        assert fields == expected, name
        # Rechte: Lesen fuer alle, Erstellen fuer angemeldete iCloud-Nutzer, Aendern/Loeschen nur der Ersteller
        assert types[name]["grants"] == {("READ", "_world"), ("CREATE", "_icloud"), ("WRITE", "_creator")}, name
    # bestehender Typ Report: commentID ergaenzt, solutionID abfragbar (Meldungen zu Kommentaren)
    report = types["Report"]["fields"]
    assert report["commentID"] == ("STRING", set()) and "QUERYABLE" in report["solutionID"][1]
    # die Swift-Seite nennt dieselben Feldnamen
    services = ROOT / "apps" / "apple" / "UniFlow" / "Services"
    swift = "\n".join(p.read_text(encoding="utf-8") for p in services.glob("*Cloud*.swift"))   # Typnamen in CommunityCloud.swift
    for name, expected in EXPECTED.items():
        assert f'"{name}"' in swift, name
        for fname in expected:
            assert f'"{fname}"' in swift, (name, fname)


def test_ckdb_import_note_and_doc_pointer():
    text = CKDB.read_text(encoding="utf-8")
    head = text.split("DEFINE SCHEMA", 1)[0]
    assert "cktool import-schema" in head and "iCloud.de.uniflow.ai" in head and "--environment development" in head
    doc = (ROOT / "docs" / "CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md").read_text(encoding="utf-8")
    assert "apps/apple/Config/cloudkit-schema.ckdb" in doc and "cktool" in doc
    doc2 = (ROOT / "docs" / "ERKLAERUNGSSPEICHER-2026-11-04.md").read_text(encoding="utf-8")
    assert "/api/explain" in doc2 and "explain_full" in doc2


# ---------------------------------------------------------------- Sicherheitspruefung 04.11.2026

def test_parallel_stores_fill_distinct_slots_and_never_overwrite(hosted):
    """Sechs Faeden speichern gleichzeitig unter demselben Schluessel: genau drei Plaetze 1..3 mit drei verschiedenen
    Chiffraten, drei bekommen explain_full; ein gezielter Wettlauf um denselben Platz: einer gewinnt, der andere
    explain_taken, der Gewinner bleibt unveraendert."""
    import threading
    from app import page_explain as pe
    users = [_user(hosted, f"wett{i}@example.org", plus=False)[0] for i in range(6)]
    payloads = [_payload() for _ in users]
    start = threading.Barrier(len(users))
    out: list = []
    lock = threading.Lock()

    def run(i, variant=None, key=FILE_KEY):
        start.wait()
        try:
            r = pe.store(users[i], key, 4, "summary", payloads[i], variant=variant)["variant"]
        except pe.PageExplainError as e:
            r = e.code
        with lock:
            out.append((i, r))
    ts = [threading.Thread(target=run, args=(i,)) for i in range(len(users))]
    [t.start() for t in ts]
    [t.join(30) for t in ts]
    got = sorted(r for _, r in out if isinstance(r, int))
    assert got == [1, 2, 3] and sorted(r for _, r in out if isinstance(r, str)) == ["explain_full"] * 3, out
    stored = {r["variant"]: r["payload"] for r in pe.list_records(FILE_KEY, 4, "summary")}
    winners = {r: payloads[i] for i, r in out if isinstance(r, int)}
    assert stored == winners, "jeder Platz traegt das Chiffrat seines Gewinners"
    # gezielt derselbe Platz
    start = threading.Barrier(len(users))
    out.clear()
    ts = [threading.Thread(target=run, args=(i, 2, OTHER_KEY)) for i in range(len(users))]
    [t.start() for t in ts]
    [t.join(30) for t in ts]
    assert sorted(r for _, r in out if isinstance(r, int)) == [2]
    assert sorted(r for _, r in out if isinstance(r, str)) == ["explain_taken"] * 5
    winner = next(i for i, r in out if r == 2)
    assert pe.get_record(OTHER_KEY, 4, "summary", 2)["payload"] == payloads[winner]


def test_payload_never_logged_and_rejects_padding_tricks(hosted, caplog):
    import logging
    from app import page_explain as pe
    caplog.set_level(logging.DEBUG)
    _, h = _user(hosted, "still@example.org", plus=False)
    p = _payload()
    assert _store(hosted, h, payload=p)[0] == 201
    assert _store(hosted, h, payload="not base64!")[0] == 400
    assert p not in caplog.text and "still@example.org" not in caplog.text
    for mod in ("page_explain.py", "page_explain_api.py"):
        src = (ROOT / "app" / mod).read_text(encoding="utf-8")
        assert "logging" not in src and "print(" not in src, mod
    # Base64-Form streng: Zeilenumbruch, Leerzeichen, URL-Alphabet, falsche Laenge, Polsterung in der Mitte
    good = _payload()
    for bad in (good[:40] + "\n" + good[40:], " " + good, good[:-4] + "ab-_", good[:-1], good[:8] + "=" + good[9:]):
        with pytest.raises(pe.PageExplainError) as e:
            pe.check_payload(bad)
        assert e.value.code == "bad_payload", repr(bad[:20])
    # Groesse wird vor dem Dekodieren geprueft (413), nicht erst nach dem Speicherverbrauch
    with pytest.raises(pe.PageExplainError) as e:
        pe.check_payload("A" * (pe.MAX_PAYLOAD_CHARS + 4))
    assert (e.value.code, e.value.status) == ("payload_too_large", 413)


def test_delete_by_a_stranger_leaves_the_record_and_admin_may_delete(hosted):
    from app import page_explain as pe
    owner, h = _user(hosted, "besitz@example.org", plus=False)
    _, hx = _user(hosted, "fremd@example.org", plus=False)
    _, ha = _user(hosted, "chef@example.org", plus=False, admin=True)
    assert _store(hosted, h, page=7)[0] == 201
    st, _, b = asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/7/explain/1", headers=hx)
    assert st == 403 and json.loads(b)["code"] == "not_owner" and "löschen" in json.loads(b)["detail"]
    assert pe.get_record(FILE_KEY, 7, "explain", 1) is not None
    assert asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/7/explain/1")[0] == 401
    assert asgi_call(hosted, "DELETE", f"/api/explain/{FILE_KEY}/7/explain/1", headers=ha)[0] == 200
    assert pe.get_record(FILE_KEY, 7, "explain", 1) is None
