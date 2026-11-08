"""Externer statischer Audit vom 08.11.2026, Pakete 55-57 (docs/audit/AUDIT-2026-11-08-PAKET-55-57.md).

55 Login/Sitzungen/Reset/Social Login, 56 Mandantentrennung, 57 Datenschutz/Aufbewahrung/Export/Loeschung. Vieles
davon ist in frueheren Paketen schon geprueft (Verweise im Bericht); hier nur, was neu ist. Je Befund ein Test:
bestaetigte Fehler wurden zuerst rot nachgestellt und dann minimal behoben; alles auf leeren Datenbanken im
Temp-Datenordner der Testsuite.
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
PW = "sehr-geheim-123"


# ---------------------------------------------------------------- Hilfen

def _shared_dbs():
    from app import accounts, community, test_library
    return (accounts.db_path(), community.db_path(), test_library.db_path())


@pytest.fixture
def hosted(app, monkeypatch):
    """Dienstmodus mit frischen gemeinsamen Datenbanken (accounts, community, library); Mail aus."""
    from app import accounts, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_MAIL", "off")

    def wipe():
        for p in _shared_dbs():
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
        shutil.rmtree(community.package_dir(), ignore_errors=True)
    wipe()
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    monkeypatch.setattr(accounts, "verify_sender", None)
    yield app
    wipe()


def _j(resp):
    st, hdr, b = resp
    return st, (json.loads(b) if b and b[:1] in (b"{", b"[") else None), hdr


def _register(app, email):
    st, data, _ = _j(asgi_call(app, "POST", "/api/account/register",
                               body=json.dumps({"email": email, "password": PW, "university": "luh"})))
    assert st == 201, data
    return data["user"], data["token"]


def _cc(hdrs) -> str:
    return next((v.decode() for k, v in hdrs if k.lower() == b"cache-control"), "")


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _seed_shared(uid: str, other: str) -> dict:
    """Ein Konto mit Spuren in jeder gemeinsamen Datenbank, auch in den Tabellen, die `purge_deleted` vor diesem Audit
    nicht kannte. `other` ist ein zweites Konto, das mit den Beitraegen von `uid` zu tun hat."""
    from app import accounts, ai_backend, app_login_api, billing, cardshare, community, community_cards, test_library
    t = "2026-10-01T10:00:00Z"
    with community_cards.cursor() as conn:
        conn.execute("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                     (uid, "k" * 64, "luh", "course", t))
        conn.execute("INSERT INTO course_claims(user_id, course_key, university, claimed_at) VALUES (?,?,?,?)", (uid, "c" * 64, "luh", t))
        conn.execute("INSERT INTO claims(user_id, fingerprint, university, claimed_at) VALUES (?,?,?,?)", (uid, "f" * 64, "luh", t))
        conn.execute("INSERT INTO course_key_history(user_id, course_key, first_at) VALUES (?,?,?)", (uid, "c" * 64, t))
        conn.execute("INSERT INTO study_groups(group_key, university, name, created_by, created_at) VALUES (?,?,?,?,?)",
                     ("g" * 64, "luh", "Lerngruppe Mathe", uid, t))
        conn.execute("""INSERT INTO card_stacks(id, community_key, university, author_id, pseudonym, name, kind, week, cards, card_count,
                        created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                     ("s" * 32, "k" * 64, "luh", uid, community.pseudonym(uid), "Mein Stapel", "eigene", 1,
                      json.dumps([{"question": "F", "answer": "A"}]), 1, t))
        conn.execute("INSERT INTO card_stack_likes(stack_id, user_id, created_at) VALUES (?,?,?)", ("s" * 32, other, t))
    with cardshare.cursor() as conn:
        conn.execute("INSERT INTO shared_card_stacks(share_key, variant, status, cards, owner_hash, created_at) VALUES (?,?,?,?,?,?)",
                     ("w" * 64, 0, "ready", "[]", test_library.owner_hash(uid), t))
    c = billing.connect()
    try:
        c.execute("INSERT INTO plan_choices(user_id, plan, chosen_at) VALUES (?,?,?)", (uid, "free", t))
        c.execute("INSERT INTO stripe_customers(user_id, customer_id, created_at) VALUES (?,?,?)", (uid, "cus_" + uid[:10], t))
        c.execute("INSERT INTO stripe_subscription_state(user_id, subscription_id, event_created) VALUES (?,?,?)", (uid, "sub_" + uid[:10], 1))
        c.commit()
    finally:
        c.close()
    conn = ai_backend.connect()
    try:
        conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, state, created_at) VALUES (?,?,?,?,?,?)",
                     (uid, "2026-10", "explain", 1200, "done", t))
        conn.commit()
    finally:
        conn.close()
    with accounts.cursor() as conn:
        conn.execute(app_login_api.SCHEMA)
        conn.execute("INSERT INTO app_login_codes(code_hash, user_id, challenge, redirect_uri, client, created_at, expires_at) "
                     "VALUES (?,?,?,?,?,?,?)", ("h" * 64, uid, "x" * 43, "http://127.0.0.1:1/konto/rueckkehr", "windows", t, t))
    return {"owner_hash": test_library.owner_hash(uid)}


def _traces(needles: tuple[str, ...]) -> list[str]:
    """Jede Zelle in accounts.db, community.db und library.db, die eine der Zeichenketten enthaelt."""
    hits = []
    for p in _shared_dbs():
        if not p.exists():
            continue
        conn = sqlite3.connect(p)
        try:
            for (t,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
                cols = [r[1] for r in conn.execute(f"PRAGMA table_info({t})")]
                for col in cols:
                    for n in needles:
                        k = conn.execute(f'SELECT COUNT(*) FROM "{t}" WHERE CAST("{col}" AS TEXT) LIKE ?', (f"%{n}%",)).fetchone()[0]
                        if k:
                            hits.append(f"{p.name}:{t}.{col} ({k})")
        finally:
            conn.close()
    return hits


# ---------------------------------------------------------------- P57-04/05 Loeschung vollstaendig

def test_p57_05_purge_leaves_no_trace_of_the_account_in_the_shared_databases(hosted, monkeypatch):
    """Bestaetigt: `purge_deleted` liess Mitgliedschaften, Kurs-Meldungen, die Erstmeldungs-Liste, angelegte
    Lerngruppen, geteilte Karteikarten-Stapel (Name, Pseudonym, Konto-ID), Wochenstapel (Kurzwert), Stripe-Kunde und
    -Abo, Tarifauswahl, App-Anmeldecodes und die Monatssumme der KI-Kosten mit der Konto-ID stehen - die
    Datenschutzerklaerung sagt "endgueltig geloescht ... spaetestens 30 Tage nach dessen Loeschung". Danach: keine
    Zelle in accounts.db, community.db oder library.db enthaelt die Konto-ID oder ihren Kurzwert."""
    from app import accounts, community
    u, _ = _register(hosted, "weg@beispiel.de")
    other, _ = _register(hosted, "bleibt@beispiel.de")
    seeded = _seed_shared(u["id"], other["id"])
    accounts.delete_account(u["id"], PW)
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1
    traces = _traces((u["id"], seeded["owner_hash"], community.pseudonym(u["id"])))
    assert traces == [], "\n".join(traces)
    # die Lerngruppe gehoert auch den anderen Mitgliedern: sie bleibt, nur ohne Ersteller
    with community.cursor() as conn:
        assert conn.execute("SELECT name FROM study_groups WHERE group_key=?", ("g" * 64,)).fetchone()[0] == "Lerngruppe Mathe"
    with accounts.cursor() as conn:                       # das zweite Konto ist unberuehrt
        assert conn.execute("SELECT status FROM users WHERE id=?", (other["id"],)).fetchone()[0] == "active"


def test_p56_09_late_write_after_deletion_is_retired_and_purged(hosted, monkeypatch):
    """Festgenagelt: schreibt ein laufender Job oder Upload nach dem Loeschen noch in `users/<id>/`, legt der naechste
    Tageslauf den neuen Ordner wieder beiseite und das endgueltige Loeschen entfernt ihn (kein Wiederaufleben)."""
    from app import accounts, config
    u, _ = _register(hosted, "spaet@beispiel.de")
    accounts.delete_account(u["id"], PW)
    late = config.user_data_dir(u["id"], "luh")
    late.mkdir(parents=True, exist_ok=True)
    (late / "notiz.txt").write_text("nach dem Loeschen geschrieben", encoding="utf-8")
    assert accounts.purge_deleted() == 0                 # noch nicht faellig, aber beiseitegelegt
    assert not (config.BASE_DATA_DIR / "users" / u["id"]).exists()
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1
    assert not (config.BASE_DATA_DIR / "users" / u["id"]).exists() and not config.retired_user_data_dirs(u["id"])


# ---------------------------------------------------------------- P57-11 Export vollstaendig (Art. 15/20)

def test_p57_11_export_contains_community_contributions_and_billing_links(hosted):
    """Bestaetigt: der Export enthielt Loesungen, Korrekturen, Stapel, Meldungen und Sperrliste, aber nicht
    Kommentare, Fragen, Antworten, Stimmen, Likes, Lesezeichen, Mitteilungen, Mitgliedschaften, angelegte
    Lerngruppen, gemeldete PDF-Fingerabdruecke und Kurs-Schluessel, Tarifauswahl und Stripe-Kennungen - alles
    Daten, die die Datenschutzerklaerung (Abschnitte 8, 9, 15) als gespeichert nennt."""
    from app import account_export, accounts, community, community_qa
    u, _ = _register(hosted, "export@beispiel.de")
    other, _ = _register(hosted, "andere@beispiel.de")
    uid, t = u["id"], "2026-10-01T10:00:00Z"
    _seed_shared(uid, other["id"])
    sol = "a" * 8 + "-0000-4000-8000-000000000001"
    with community.cursor() as conn:
        conn.execute("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, title, created_at,
                        published_at, page_count, pages, size) VALUES (?,?,'luh',?,'Studi-x','Studi-x','Blatt',?,?,1,1,1)""",
                     (sol, "b" * 64, other["id"], t, t))
        conn.execute("INSERT INTO comments(id, solution_id, author_id, pseudonym, text, created_at) VALUES (?,?,?,?,?,?)",
                     ("c1", sol, uid, community.pseudonym(uid), "Mein Kommentar", t))
        conn.execute("INSERT INTO likes(solution_id, user_id, created_at) VALUES (?,?,?)", (sol, uid, t))
        conn.execute("""INSERT INTO questions(id, course_key, university, author_id, pseudonym, title, body, created_at, last_activity)
                        VALUES (?,?,?,?,?,?,?,?,?)""", ("q1", "c" * 64, "luh", uid, "Studi-y", "Meine Frage", "Text der Frage", t, t))
        conn.execute("INSERT INTO answers(id, question_id, author_id, pseudonym, body, created_at) VALUES (?,?,?,?,?,?)",
                     ("a1", "q1", uid, "Studi-y", "Meine Antwort", t))
        conn.execute("INSERT INTO bookmarks(user_id, kind, target_id, created_at) VALUES (?,?,?,?)", (uid, "question", "q1", t))
        community_qa.notify(conn, uid, "answer", "question", "q1", "Studi-z", "hat geantwortet", "a1")
    path = account_export.build(accounts.get_user(uid) | {"email": "export@beispiel.de"})
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            konto = json.loads(z.read("konto.json"))
            assert "community/meine-beitraege.json" in names
            b = json.loads(z.read("community/meine-beitraege.json"))
    finally:
        path.unlink(missing_ok=True)
    assert [c["text"] for c in b["kommentare"]] == ["Mein Kommentar"]
    assert [q["title"] for q in b["fragen"]] == ["Meine Frage"] and [a["body"] for a in b["antworten"]] == ["Meine Antwort"]
    assert [x["solution_id"] for x in b["likes_loesungen"]] == [sol]
    assert b["lesezeichen"] and b["mitteilungen"]
    assert [m["community_key"] for m in b["mitgliedschaften"]] == ["k" * 64]
    assert [g["name"] for g in b["lerngruppen_angelegt"]] == ["Lerngruppe Mathe"]
    assert [f["fingerprint"] for f in b["pdf_fingerabdruecke"]] == ["f" * 64]
    assert [k["course_key"] for k in b["kurs_schluessel"]] == ["c" * 64]
    assert konto["tarif_auswahl"][0]["plan"] == "free"
    assert konto["stripe"]["kunde"][0]["customer_id"].startswith("cus_")
    assert konto["stripe"]["abos"][0]["subscription_id"].startswith("sub_")
    dumped = json.dumps(b)
    assert other["id"] not in dumped, "keine fremden Konto-IDs im Export"


# ---------------------------------------------------------------- P57-06/10 Fristen wirklich angewendet

def test_p57_10_ai_cache_older_than_30_days_is_deleted(hosted):
    """Bestaetigt: `ai_cache` (Antworten ohne Kontobezug, laut Erklaerung "bis zu 30 Tage") wurde nach 30 Tagen nur
    nicht mehr benutzt, aber nie geloescht. Jetzt entfernt der Tageslauf aeltere Eintraege."""
    from app import ai_backend, retention
    now = datetime(2026, 11, 8, 4, 0, tzinfo=timezone.utc)
    conn = ai_backend.connect()
    try:
        conn.execute("INSERT INTO ai_cache(key, result, created_at) VALUES ('alt', 'x', ?)", ((now - timedelta(days=31)).isoformat(),))
        conn.execute("INSERT INTO ai_cache(key, result, created_at) VALUES ('neu', 'y', ?)", ((now - timedelta(days=29)).isoformat(),))
        conn.commit()
    finally:
        conn.close()
    out = retention.run(now)
    assert out["ai_cache"] == 1
    conn = ai_backend.connect()
    try:
        assert [r[0] for r in conn.execute("SELECT key FROM ai_cache")] == ["neu"]
    finally:
        conn.close()


def test_p57_10_stored_ai_answers_are_cleared_after_24h_for_every_account(hosted):
    """Bestaetigt: die gespeicherte Antwort in `credit_ledger.result` ("24 Stunden lang") wurde nur geleert, wenn
    dasselbe Konto wieder eine KI-Anfrage stellte; wer danach nichts mehr fragte, behielt sie unbegrenzt."""
    from app import credits, retention
    now = datetime(2026, 11, 8, 4, 0, tzinfo=timezone.utc)
    conn = credits.connect()
    try:
        for uid, rid, age in (("u1", "r-alt", 30), ("u2", "r-neu", 2)):
            conn.execute("""INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, created_at, settled_at, result)
                            VALUES (?,?,?,?,?,?,?,?,?,?)""",
                         (uid, rid, "2026-11", "2026-11-08", "tutor", "credits", "settled", (now - timedelta(hours=age)).isoformat(),
                          (now - timedelta(hours=age)).isoformat(), "Antwort"))
        conn.commit()
    finally:
        conn.close()
    out = retention.run(now)
    assert out["ai_answers"] == 1
    conn = credits.connect()
    try:
        got = dict(conn.execute("SELECT request_id, result FROM credit_ledger").fetchall())
    finally:
        conn.close()
    assert got == {"r-alt": None, "r-neu": "Antwort"}


def test_p57_10_mail_log_is_trimmed_after_14_days(hosted, monkeypatch):
    """Bestaetigt: mail.log (je Mail Empfaengeradresse und Betreff, im Modus `log` die ganze Mail mit Reset-Link)
    wuchs unbegrenzt; keine Frist im Code, keine Angabe in der Datenschutzerklaerung. Jetzt 14 Tage wie das
    Zugriffsprotokoll (LERNAPP_RETENTION_MAIL_DAYS)."""
    from app import mail, retention
    now = datetime(2026, 11, 8, 4, 0, tzinfo=timezone.utc)
    p = mail.log_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("[2026-10-01T10:00:00Z] MAIL an alt@beispiel.de | Betreff: Reset\nhttps://x/login?reset=geheim\n--- Ende der Mail ---\n"
                 "[2026-11-07T10:00:00Z] verschickt an neu@beispiel.de | Betreff: Willkommen\n", encoding="utf-8")
    try:
        out = retention.run(now)
        text = p.read_text(encoding="utf-8")
    finally:
        p.unlink(missing_ok=True)
    assert out["mail_log_lines"] == 3
    assert "alt@beispiel.de" not in text and "geheim" not in text and "neu@beispiel.de" in text


def test_p57_03_left_over_export_zips_are_removed(hosted):
    """Bestaetigt (Restfenster): das Export-ZIP loescht die Antwort im Hintergrund nach dem Senden. Bricht die
    Verbindung ab (ASGI 2.4: `send` wirft) oder stirbt der Prozess, bleibt es im Temp-Ordner. Der Tageslauf entfernt
    jetzt Export-ZIPs, die aelter als eine Stunde sind; frische bleiben (ein Download kann noch laufen)."""
    from app import retention
    now = datetime.now(timezone.utc)
    tmp = Path(tempfile.gettempdir())
    old = tmp / "studora-export-audit5557alt.zip"
    new = tmp / "studora-export-audit5557neu.zip"
    for p in (old, new):
        p.write_bytes(b"PK")
    os.utime(old, (time.time() - 7200, time.time() - 7200))
    try:
        out = retention.run(now)
        assert out["export_zips"] >= 1
        assert not old.exists() and new.exists()
    finally:
        old.unlink(missing_ok=True)
        new.unlink(missing_ok=True)


# ---------------------------------------------------------------- P57 Texte: Willkommensmail und Anmeldeseite

def test_p57_09_welcome_mail_and_login_page_do_not_claim_server_side_credentials():
    """Bestaetigt: Willkommensmail und Anmeldeseite sagten noch "Zugangsdaten deiner Hochschule ... verschluesselt am
    Konto, nur fuer den Abgleich" - seit 06.11.2026 speichert der Dienst keine Hochschul-Zugangsdaten mehr
    (Datenschutzerklaerung Abschnitt 6, `vault.purge_at_startup`)."""
    from app import mail
    texts = {"mail": mail.welcome_text("a@b.de", "https://x/login?verify=t"),
             "login.html": (ROOT / "app" / "static" / "login.html").read_text(encoding="utf-8")}
    for name, text in texts.items():
        assert "verschlüsselt am Konto" not in text and "liegen verschlüsselt am Konto" not in text, name
    assert "nie auf unseren Servern" in texts["mail"]


# ---------------------------------------------------------------- P57-01 Mailmodus im Dienst

def test_p57_01_hosted_start_warns_when_mails_only_go_to_the_log(hosted, monkeypatch, caplog):
    """Konfigurationsbefund (Server nicht einsehbar): ohne LERNAPP_SMTP_HOST faellt der Dienst auf `log` zurueck,
    Reset-Links stehen dann in mail.log. `deploy/.env.example` setzt den Host (Modus smtp). Neu: der Start warnt
    laut im Dienst-Protokoll, statt still zu protokollieren."""
    import logging
    from app import server
    monkeypatch.delenv("LERNAPP_MAIL", raising=False)
    monkeypatch.delenv("LERNAPP_SMTP_HOST", raising=False)
    with caplog.at_level(logging.WARNING, logger="uniflow.mail"):
        server.wire_hosted_services()
    assert any("mail.log" in r.getMessage() for r in caplog.records)
    caplog.clear()
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")
    with caplog.at_level(logging.WARNING, logger="uniflow.mail"):
        server.wire_hosted_services()
    assert not caplog.records
    env = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    assert "LERNAPP_SMTP_HOST=smtp.strato.de" in env


# ---------------------------------------------------------------- P57 Geheimnisse nie im Protokoll

def test_p57_10_tokens_and_hashes_never_reach_access_log_or_mail_log(hosted, monkeypatch):
    """Festgenagelt: ein ganzer Ablauf (Registrieren, Anmelden, Reset anfordern und einloesen, Sitzungen, Export,
    Loeschen) schreibt weder Sitzungs-Token, Reset-Token noch Passwort oder Passwort-Hash ins Zugriffsprotokoll; im
    Modus smtp steht in mail.log nur Adresse und Betreff (kein Link)."""
    from app import accounts, mail, retention
    sent = []
    monkeypatch.setenv("LERNAPP_MAIL", "smtp")
    monkeypatch.setenv("LERNAPP_MAIL_DEFER", "0")
    monkeypatch.setattr(mail, "_send_smtp", lambda msg: sent.append(msg.get_content()))
    monkeypatch.setattr(accounts, "reset_sender", mail.send_reset)
    shutil.rmtree(retention.access_log_dir(), ignore_errors=True)
    mail.log_path().unlink(missing_ok=True)
    app = hosted
    u, token = _register(app, "log@beispiel.de")
    st, data, _ = _j(asgi_call(app, "POST", "/api/account/login", body=json.dumps({"email": "log@beispiel.de", "password": PW})))
    assert st == 200
    asgi_call(app, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "log@beispiel.de"}))
    reset_tok = next(t.split("reset=")[1].split()[0] for t in sent if "reset=" in t)
    new_pw = "noch-geheimer-456"
    assert asgi_call(app, "POST", "/api/account/password/reset", body=json.dumps({"token": reset_tok, "new_password": new_pw}))[0] == 200
    st, data, _ = _j(asgi_call(app, "POST", "/api/account/login", body=json.dumps({"email": "log@beispiel.de", "password": new_pw})))
    tok2 = data["token"]
    asgi_call(app, "GET", "/api/account/me", headers=_auth(tok2))
    asgi_call(app, "GET", "/api/account/export", headers=_auth(tok2))
    asgi_call(app, "POST", "/api/account/delete", headers=_auth(tok2), body=json.dumps({"password": new_pw}))
    with accounts.cursor() as conn:
        pw_hash = conn.execute("SELECT pw_hash FROM users WHERE id=?", (u["id"],)).fetchone()[0]
    logs = "".join(p.read_text(encoding="utf-8") for p in retention.access_log_dir().glob("*.log"))
    mail_log = mail.log_path().read_text(encoding="utf-8")
    assert "/api/account/login" in logs, "Zugriffsprotokoll wurde geschrieben"
    for secret in (token, tok2, reset_tok, PW, new_pw) + ((pw_hash,) if pw_hash else ()):
        assert secret not in logs and secret not in mail_log
    assert "reset=" not in mail_log and "verschickt an log@beispiel.de" in mail_log


# ---------------------------------------------------------------- P55-11 Antworten mit Token nicht zwischenspeichern

@pytest.mark.parametrize("method, path, body, auth", [
    ("POST", "/api/account/register", {"email": "neu2@beispiel.de", "password": PW, "university": "luh"}, False),
    ("POST", "/api/account/login", {"email": "cache@beispiel.de", "password": PW}, False),
    ("GET", "/api/account/me", None, True),
    ("GET", "/api/account/identities", None, True),
    ("GET", "/api/account/export", None, True),
])
def test_p55_11_account_responses_are_not_cacheable(hosted, method, path, body, auth):
    """Bestaetigt (Haertung): Antworten mit Sitzungs-Token (login, register: Token im JSON) und mit personenbezogenen
    Daten (me, sessions, export) hatten kein `Cache-Control`. RFC 6749 5.1 verlangt fuer Token-Antworten `no-store`;
    ein Browser-/Proxy-Cache haette sie sonst ablegen duerfen. Jetzt `no-store` fuer alle /api/account- und
    /api/app-login-Antworten."""
    _, token = _register(hosted, "cache@beispiel.de")
    hdr = _auth(token) if auth else None
    st, hdrs, _ = asgi_call(hosted, method, path, body=json.dumps(body) if body else None, headers=hdr)
    assert st in (200, 201), (path, st)
    assert "no-store" in _cc(hdrs), (path, hdrs)


def test_p55_11_error_and_app_login_responses_are_not_cacheable_either(hosted):
    st, hdrs, _ = asgi_call(hosted, "POST", "/api/app-login/token", body=json.dumps({"code": "x", "code_verifier": "y" * 43}))
    assert st == 400
    assert "no-store" in _cc(hdrs)
    st, hdrs, _ = asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "x@y.de", "password": "falsch-falsch"}))
    assert st == 401 and "no-store" in _cc(hdrs)


# ---------------------------------------------------------------- P56-03/04 Hintergrundlauf je Konto

def test_p56_04_background_run_of_account_a_does_not_block_account_b(hosted, monkeypatch):
    """Bestaetigt (Verfuegbarkeit, kein Datenabfluss): `_run_bg` (im Dienst noch erreichbar ueber
    POST /api/weekly/mock-exam) hatte EINE Sperre je Prozess. Lief bei Konto A eine Probeklausur, bekam jedes andere
    Konto im selben Prozess 409 "Es laeuft bereits: Probeklausur". Jetzt im Dienst eine Sperre je Konto; dasselbe
    Konto zweimal bleibt 409. Am PC unveraendert eine Sperre."""
    from fastapi import HTTPException
    from app import config, server
    gate = threading.Event()
    seen = {}

    def job(name):
        def run():
            seen[name] = config.current_user_id()
            gate.wait(5)
            return name
        return run

    a, b = "a" * 32, "b" * 32
    tok_a = config.set_user_context(a, "luh")
    try:
        assert server._run_bg("Probeklausur", job("a")) == {"started": "Probeklausur"}
        with pytest.raises(HTTPException) as e:
            server._run_bg("Probeklausur", job("a2"))
        assert e.value.status_code == 409
    finally:
        config.reset_user_context(tok_a)
    tok_b = config.set_user_context(b, "luh")
    try:
        assert server._run_bg("Probeklausur", job("b")) == {"started": "Probeklausur"}
    finally:
        config.reset_user_context(tok_b)
        gate.set()
    deadline = time.time() + 5
    while server._bg_running_any() and time.time() < deadline:
        time.sleep(0.02)
    assert seen == {"a": a, "b": b}
    assert not server._bg_running_any()


# ---------------------------------------------------------------- P57-06 Sicherungen: Frist und Zurueckspielen

def test_p57_06_backup_retention_keeps_at_most_14_days():
    """Bestaetigt (klein): `find -mtime +14` loescht erst ab 15 ganzen Tagen - jedes Archiv blieb einen Tag laenger
    als die 14 Tage, die jetzt in der Datenschutzerklaerung stehen. Jetzt in Minuten (14 x 24 h, 30 min Puffer fuer
    die Laufzeit des taeglichen Laufs)."""
    sh = (ROOT / "deploy" / "backup.sh").read_text(encoding="utf-8")
    assert '-mmin "+$((KEEP_DAYS * 1440 - 30))" -delete' in sh and "-type f -mtime" not in sh
    assert 'KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"' in sh
    t = (ROOT / "docs" / "release" / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert "Jede Sicherung wird nach 14 Tagen gelöscht" in t


def test_p57_06_deletions_after_a_backup_are_reapplied_after_restore(hosted, capsys):
    """Bestaetigt (Prozess): wurde eine Sicherung zurueckgespielt, waren Konten, die danach geloescht wurden, wieder
    aktiv (mit E-Mail-Adresse und Sitzungen). Jetzt: `python -m app.accounts deleted` vorher sichern,
    `redelete <id> <zeitpunkt>` danach (docs/release/BETRIEB.md) - mit dem urspruenglichen Loeschzeitpunkt."""
    from app import accounts
    u, token = _register(hosted, "zurueck@beispiel.de")
    snapshot = accounts.db_path().read_bytes()
    accounts.delete_account(u["id"], PW)
    capsys.readouterr()
    assert accounts.main(["deleted"]) == 0
    uid, deleted_at = capsys.readouterr().out.strip().split()
    assert uid == u["id"]
    for suffix in ("-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    accounts.db_path().write_bytes(snapshot)                        # Sicherung von vor der Loeschung zurueck
    assert accounts.authenticate(token) is not None, "nach dem Zurueckspielen waere das Konto wieder da"
    assert accounts.main(["redelete", uid, deleted_at]) == 0
    assert accounts.authenticate(token) is None
    with accounts.cursor() as conn:
        r = conn.execute("SELECT status, deleted_at, email, pw_hash FROM users WHERE id=?", (uid,)).fetchone()
    assert tuple(r) == ("deleted", deleted_at, f"deleted-{uid}@invalid", None)
    assert accounts.redelete(uid) is False, "zweimal ist harmlos"
    bet = (ROOT / "docs" / "release" / "BETRIEB.md").read_text(encoding="utf-8")
    assert "python -m app.accounts deleted" in bet and "app.accounts redelete" in bet


# ---------------------------------------------------------------- P57-10/11 Erklaerung = Code

def test_p57_10_privacy_policy_names_the_retention_the_code_applies():
    """Bestaetigt (Text): Fehlversuche standen mit "10 Minuten" (wirksam 10 min, geloescht erst nach 24 h, auch je
    IP-Adresse), Missbrauchszaehler (IP-, E-Mail-Adressen, 2 Tage), Mail-Protokoll, Fehlerprotokolle und
    Sicherungskopien fehlten ganz, der Abgleich nannte noch Bildschirmfotos (Dienst gleicht seit 06.11. nicht mehr
    ab), die Loeschung versprach eine Ruecknahme, die es nicht gibt. Jetzt stehen die Zahlen aus dem Code darin."""
    from app import accounts, ai_backend, credits, retention
    t = (ROOT / "docs" / "release" / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert retention.ATTEMPT_HOURS == 24 and "gelöscht spätestens nach 24 Stunden" in t and "je IP-Adresse" in t
    assert "höchstens 2 Tage" in t                                    # rate_limits: window_start < now - 2 Tage
    assert f"{accounts.VERIFY_HOURS} Stunden" in t
    assert retention.MAIL_DAYS == 14 and "Protokoll des Mailversands" in t and "gelöscht nach 14 Tagen" in t
    assert ai_backend.CACHE_DAYS == 30 and "bis zu 30 Tage" in t and credits.REPLAY_HOURS == 24 and "24 Stunden lang" in t
    assert "Sicherungskopien" in t and "Fehlerprotokolle des Dienstes" in t
    assert "Bildschirmfoto der Anmeldeseite deiner Hochschule zur Fehlersuche" not in t
    assert "Frist für versehentliche Löschung" not in t and "Rückgängig machen\n  lässt sich die Löschung nicht" in t
    k = (ROOT / "docs" / "release" / "KONTO-LOESCHEN.md").read_text(encoding="utf-8")
    assert "zurücknehmen" not in k and "gespeicherte Hochschul-Zugangsdaten)" not in k
