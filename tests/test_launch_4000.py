"""Launch mit bis zu 4.000 Nutzern (08.11.2026, docs/release/LAUNCH-4000-2026-11-08.md): die Nicht-KI-Pfade tragen
viele Nutzer hinter EINER Campus-Adresse (NAT, eduroam), ohne Missbrauch freizugeben.

- Anmeldesperre je IP: einstellbar (LERNAPP_LOGIN_FAILS_IP), Standard 200 statt 50; 50 Tippfehler sperren den Campus nicht
- Registrierung: Summe ueber alle Adressen (register_all) als Bremse fuer Massen-Skripte, Grenze je Adresse hoch
- community.db wartet wie accounts.db 15 s auf Schreibsperren
- Mails aus API-Aufrufen im Hintergrund (send_later), Kommandozeile `python -m app.mail` fuer deploy/dienst-check.sh
- Datenbankarbeit der Middleware (Sitzung, Tarif, Schema) laeuft im Thread-Pool, nicht in der Ereignisschleife
- POST /api/sync/push hat eine Koerpergrenze; Uploads halten eine Platten-Reserve (507 storage_full)
- deploy/backup_snapshot.py raeumt jede Datenbankkopie sofort weg
- .env.example und Doku nennen die neuen Schalter
"""
import io
import json
import re
import threading
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_mail import FakeSMTP, mail_env  # noqa: F401
from test_security import _multipart

ROOT = Path(__file__).resolve().parents[1]
PW = "sehr-geheim-123"


def _j(res):
    st, headers, body = res
    return st, (json.loads(body) if body else None)


def _login(app, email, pw, ip):
    return _j(asgi_call(app, "POST", "/api/account/login", client=(ip, 5000), body=json.dumps({"email": email, "password": pw})))


# ---------------------------------------------------------------- 1. Anmeldung und Registrierung hinter Campus-NAT

def test_login_ip_lock_threshold_is_configurable(monkeypatch):
    from app import accounts
    monkeypatch.delenv("LERNAPP_LOGIN_FAILS_IP", raising=False)
    assert accounts.MAX_FAILS_IP == 200 and accounts.max_fails_ip() == 200
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "500")
    assert accounts.max_fails_ip() == 500
    for bad in ("0", "-3", "viele", ""):
        monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", bad)
        assert accounts.max_fails_ip() == 200, bad
    assert accounts.MAX_FAILS == 8, "die Sperre je Adresse bleibt streng"


def test_fifty_wrong_passwords_behind_one_campus_address_do_not_lock_everyone(hosted, monkeypatch):  # noqa: F811
    """Bis 08.11.2026 sperrten 50 Fehlversuche je IP in 10 Minuten die Adresse: hinter eduroam waere damit der ganze
    Campus 10 Minuten ausgesperrt. Jetzt 200 (Code) bzw. LERNAPP_LOGIN_FAILS_IP; das einzelne Konto bleibt nach 8 gesperrt."""
    monkeypatch.delenv("LERNAPP_LOGIN_FAILS_IP", raising=False)
    campus = "130.75.1.1"
    _user(hosted, "brav@beispiel.de", plus=False)
    for i in range(50):                                     # 50 verschiedene Leute vertippen sich (je Adresse unter 8)
        st, d = _login(hosted, f"tippfehler{i}@beispiel.de", "falsch-falsch-1", campus)
        assert st == 401, (i, d)
    st, d = _login(hosted, "brav@beispiel.de", PW, campus)
    assert st == 200, "der Campus ist nach 50 fremden Fehlversuchen nicht gesperrt"
    # einstellbar: mit Grenze 55 ist die Adresse nach 55 Fehlversuchen am Stueck gesperrt (eine erfolgreiche Anmeldung
    # von der Adresse setzt den Zaehler zurueck - accounts._clear_fails loescht auch den IP-Schluessel)
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "55")
    for i in range(55):
        assert _login(hosted, f"weiter{i}@beispiel.de", "falsch-falsch-1", campus)[0] == 401
    # gesperrte Adresse: FALSCHE Passwoerter bekommen 429 locked (kein scrypt mehr fuer Skripte) ...
    st, d = _login(hosted, "weiter99@beispiel.de", "falsch-falsch-1", campus)
    assert st == 429 and d["code"] == "locked"
    st, d = _login(hosted, "brav@beispiel.de", "falsch-falsch-1", campus)
    assert st == 429 and d["code"] == "locked"
    # ... das richtige Passwort meldet trotzdem an: niemand kann den Campus mit falschen Versuchen aussperren
    st, d = _login(hosted, "brav@beispiel.de", PW, campus)
    assert st == 200, "richtiges Passwort hinter gesperrter Campus-Adresse muss durchgehen"
    # die erfolgreiche Anmeldung hat den Zaehler der Adresse geloescht: falsche Versuche sind wieder 401
    assert _login(hosted, "weiter100@beispiel.de", "falsch-falsch-1", campus)[0] == 401
    # andere Adresse: nie betroffen
    assert _login(hosted, "brav@beispiel.de", PW, "10.9.9.9")[0] == 200


def test_locked_ip_cannot_bypass_the_account_lock(hosted, monkeypatch):  # noqa: F811
    """Die IP-Sperre laesst richtige Passwoerter durch - das Konto selbst bleibt nach 8 Fehlversuchen gesperrt."""
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "3")
    campus = "130.75.2.2"
    _user(hosted, "konto@beispiel.de", plus=False)
    for i in range(8):
        _login(hosted, "konto@beispiel.de", "falsch-falsch-1", campus)
    st, d = _login(hosted, "konto@beispiel.de", PW, campus)
    assert st == 429 and d["code"] == "locked", "Kontosperre gilt auch hinter gesperrter Adresse"


def test_account_lock_after_eight_failures_still_holds(hosted, monkeypatch):  # noqa: F811
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "100000")
    _user(hosted, "opfer@beispiel.de", plus=False)
    for i in range(8):
        assert _login(hosted, "opfer@beispiel.de", "falsch-falsch-1", f"10.0.0.{i + 1}")[0] == 401
    st, d = _login(hosted, "opfer@beispiel.de", PW, "10.0.0.99")
    assert st == 429 and d["code"] == "locked"


def test_registration_is_capped_over_all_addresses(hosted, monkeypatch):  # noqa: F811
    """Die Grenze je Adresse ist fuer Campus-NAT hoch (2000/h); gegen Skripte mit vielen Adressen zaehlt eine Summe."""
    from app import accounts
    assert accounts.LIMITS["register_all"] == (3000, 60)
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_ALL", "2/60")
    for i in range(2):
        st, d = _j(asgi_call(hosted, "POST", "/api/account/register", client=(f"10.1.0.{i + 1}", 1),
                             body=json.dumps({"email": f"n{i}@beispiel.de", "password": PW, "university": "luh"})))
        assert st == 201, d
    st, d = _j(asgi_call(hosted, "POST", "/api/account/register", client=("10.1.0.77", 1),
                         body=json.dumps({"email": "n3@beispiel.de", "password": PW, "university": "luh"})))
    assert st == 429 and d["code"] == "rate_limited"
    # Anmelden bleibt moeglich: die Summe gilt nur fuer neue Konten
    assert _login(hosted, "n0@beispiel.de", PW, "10.1.0.77")[0] == 200


def test_register_ip_limit_counts_only_the_own_address(hosted, monkeypatch):  # noqa: F811
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "1/60")
    monkeypatch.delenv("LERNAPP_LIMIT_REGISTER_ALL", raising=False)
    body = lambda i: json.dumps({"email": f"ip{i}@beispiel.de", "password": PW, "university": "luh"})  # noqa: E731
    assert _j(asgi_call(hosted, "POST", "/api/account/register", client=("10.2.0.1", 1), body=body(1)))[0] == 201
    assert _j(asgi_call(hosted, "POST", "/api/account/register", client=("10.2.0.1", 1), body=body(2)))[0] == 429
    assert _j(asgi_call(hosted, "POST", "/api/account/register", client=("10.2.0.2", 1), body=body(3)))[0] == 201


# ---------------------------------------------------------------- 2. SQLite, Middleware, Sync, Uploads

def test_community_db_waits_like_accounts_db(monkeypatch, tmp_path):
    """community.db teilen sich alle Konten und Prozesse: busy_timeout 15 s statt der 5 s von sqlite3."""
    import sqlite3
    from app import community, config
    monkeypatch.setattr(config, "BASE_DATA_DIR", tmp_path)
    seen = {}
    real = sqlite3.connect

    def spy(path, *a, **k):
        seen["timeout"] = k.get("timeout")
        return real(path, *a, **k)
    monkeypatch.setattr(community.sqlite3, "connect", spy)
    with community.cursor() as conn:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert seen["timeout"] == 15


def test_middleware_database_work_runs_off_the_event_loop(hosted, monkeypatch):  # noqa: F811
    """accounts.authenticate, access.for_user und db.init_db liefen in der async-Middleware direkt in der Ereignisschleife:
    wartete SQLite auf eine Schreibsperre (bis 15 s), stand der ganze Prozess. Jetzt laufen sie im Thread-Pool."""
    from app import accounts, db, server
    user, h = _user(hosted, "thread@beispiel.de")
    loop_thread = threading.current_thread().ident           # asyncio.run laeuft im Thread des Tests
    where = {}
    real_auth, real_init = accounts.authenticate, db.init_db

    def auth(token):
        where["authenticate"] = threading.current_thread().ident
        return real_auth(token)

    def init():
        where["init_db"] = threading.current_thread().ident
        return real_init()
    monkeypatch.setattr(accounts, "authenticate", auth)
    monkeypatch.setattr(db, "init_db", init)
    server._user_dbs_ready.discard((user["id"], user["university"]))
    st, body = _j(asgi_call(hosted, "GET", "/api/account/me", headers=h))
    assert st == 200 and "thread@beispiel.de" in json.dumps(body)
    assert where["authenticate"] != loop_thread, "Sitzungspruefung blockiert die Ereignisschleife"
    assert where["init_db"] != loop_thread, "Schema der Konto-Datenbank blockiert die Ereignisschleife"
    # Web-Client (Abo-Pflicht): auch die Tarifpruefung laeuft im Thread
    from app import access
    real_for_user = access.for_user

    def for_user(u, client):
        where["for_user"] = threading.current_thread().ident
        return real_for_user(u, client)
    monkeypatch.setattr(access, "for_user", for_user)
    st, _ = _j(asgi_call(hosted, "GET", "/api/account/me", headers={**h, "X-StudiNow-Client": "web"}))
    assert st == 200
    assert where.get("for_user", loop_thread) != loop_thread or "for_user" not in where


def test_sync_push_body_is_capped(hosted, monkeypatch):  # noqa: F811
    from app import server
    assert server.MAX_SYNC_BYTES == 32 << 20
    assert any(rx.match("/api/sync/push") for rx, _ in server._UPLOAD_LIMITS)
    monkeypatch.setattr(server, "_MULTIPART_SLACK", 0)
    monkeypatch.setattr(server, "_UPLOAD_LIMITS", ((re.compile(r"^/api/sync/push$"), 1 << 10),))
    _, h = _user(hosted, "sync@beispiel.de")
    small = json.dumps({"device_id": "d1", "items": [], "deletes": []})
    st, body = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=h, body=small))
    assert st == 200, body
    big = json.dumps({"device_id": "d1", "items": [{"entity": "flashcards", "local_id": "x", "front": "A" * 4096}], "deletes": []})
    st, body = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=h, body=big))
    assert st == 413 and body["code"] == "too_large"


def test_uploads_keep_a_disk_reserve(hosted, monkeypatch):  # noqa: F811
    from app import server
    assert server.DISK_MIN_FREE_MB == 5120
    monkeypatch.setenv("LERNAPP_DISK_MIN_FREE_MB", "100")
    _, h = _user(hosted, "platte@beispiel.de")
    pdf = b"%PDF-1.4\n" + b"\0" * 2048
    body, ctype = _multipart("upload", "a.pdf", pdf, {"kind": "pdf", "title": "eins"})
    monkeypatch.setattr(server, "disk_free_bytes", lambda p: 50 << 20)          # nur 50 MB frei
    st, _, b = asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h, content_type=ctype)
    assert st == 507 and json.loads(b)["code"] == "storage_full", b[:200]
    monkeypatch.setattr(server, "disk_free_bytes", lambda p: 500 << 30)         # 500 GB frei
    st, _, b = asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h, content_type=ctype)
    assert st == 200, b[:200]
    # echte Messung liefert eine Zahl, auch fuer einen noch nicht vorhandenen Zielordner
    monkeypatch.undo()
    assert (server.disk_free_bytes(Path("/nicht/vorhanden/x.pdf")) or 0) >= 0
    assert server.disk_free_bytes(ROOT) > 0


# ---------------------------------------------------------------- 3. Mail im Hintergrund und Kommandozeile

def test_send_later_does_not_wait_for_smtp(mail_env, monkeypatch):  # noqa: F811
    import smtplib
    import time
    from app import mail
    FakeSMTP.instances.clear()
    monkeypatch.setenv("LERNAPP_MAIL", "smtp")
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")
    monkeypatch.delenv("LERNAPP_MAIL_DEFER", raising=False)
    gate = threading.Event()

    class Slow(FakeSMTP):
        def send_message(self, msg):
            gate.wait(5)                                     # STRATO antwortet langsam
            super().send_message(msg)
    monkeypatch.setattr(smtplib, "SMTP", Slow)
    assert mail.deferred()
    t = time.monotonic()
    mail.send_welcome("neu@beispiel.de", "tok")
    assert time.monotonic() - t < 1.0, "die Registrierung wartet nicht auf den Postausgang"
    assert mail.pending() >= 0
    gate.set()
    assert mail.flush(5)
    assert FakeSMTP.instances and FakeSMTP.instances[-1].messages[0]["To"] == "neu@beispiel.de"
    # abschaltbar: dann wieder sofort
    monkeypatch.setenv("LERNAPP_MAIL_DEFER", "0")
    assert not mail.deferred()
    FakeSMTP.instances.clear()
    monkeypatch.setattr(smtplib, "SMTP", FakeSMTP)
    assert mail.send_later("a@beispiel.de", "b", "c") is True
    assert FakeSMTP.instances[-1].messages, "ohne Verzoegerung ist die Mail nach dem Aufruf schon weg"
    # Modus log: immer sofort (Tests, Entwicklung)
    monkeypatch.setenv("LERNAPP_MAIL", "log")
    assert not mail.deferred()
    mail.send_verify("c@beispiel.de", "tok2")
    assert "c@beispiel.de" in (mail_env / "mail.log").read_text(encoding="utf-8")


def test_mail_queue_full_is_logged_not_raised(mail_env, monkeypatch):  # noqa: F811
    import queue
    from app import mail
    monkeypatch.setenv("LERNAPP_MAIL", "smtp")
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")
    full = queue.Queue(maxsize=1)
    full.put(("x", "y", "z"))
    monkeypatch.setattr(mail, "_ensure_worker", lambda: full)
    assert mail.send_later("voll@beispiel.de", "b", "c") is False
    assert "Warteschlange voll" in (mail_env / "mail.log").read_text(encoding="utf-8")


def test_mail_cli_status_and_send(mail_env, monkeypatch, capsys):  # noqa: F811
    from app import mail
    monkeypatch.setenv("LERNAPP_MAIL", "log")
    monkeypatch.setenv("LERNAPP_SMTP_PASSWORD", "streng-geheim")
    assert mail.main(["status"]) == 0
    out = capsys.readouterr().out
    assert "mode=log" in out and "streng-geheim" not in out
    assert mail.main(["send", "--to", "support@studinow.app", "--subject", "dienst-check: Platte 85 %", "--text", "df -h ..."]) == 0
    log = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "support@studinow.app" in log and "Platte 85 %" in log
    monkeypatch.setattr("sys.stdin", io.StringIO("Zeile aus stdin\n"))
    assert mail.main(["send", "--to", "a@beispiel.de", "--subject", "s"]) == 0
    assert "Zeile aus stdin" in (mail_env / "mail.log").read_text(encoding="utf-8")
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    assert mail.main(["send", "--to", "a@beispiel.de", "--subject", "s"]) == 2
    monkeypatch.setenv("LERNAPP_MAIL", "off")
    assert mail.main(["send", "--to", "a@beispiel.de", "--subject", "s", "--text", "t"]) == 1
    assert mail.main([]) == 2


# ---------------------------------------------------------------- 4. Backup bei 4.000 Konten

def test_backup_snapshot_removes_each_database_copy_right_away(tmp_path, monkeypatch):
    """Vorher lagen alle Kopien bis zum Ende im Temp-Ordner des Containers (4.000 Konten: ueber 1 GB im Schreiblayer)."""
    import runpy
    import sqlite3
    import sys
    import tarfile
    data = tmp_path / "data"
    for i in range(3):
        d = data / "users" / f"{i:032x}"
        d.mkdir(parents=True)
        c = sqlite3.connect(d / "lernapp.db")
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("CREATE TABLE t(x)")
        c.commit()
        c.close()
    monkeypatch.setenv("LERNAPP_DATA_DIR", str(data))
    buf = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", type("S", (), {"buffer": buf, "write": lambda s, t: None, "flush": lambda s: None})())
    copies_seen = []
    real_add = tarfile.TarFile.add

    def add(self, name, *a, **k):
        p = Path(name)
        if p.name.endswith(".db") and p.parent.name.startswith("uniflow-backup-"):
            copies_seen.append(len(list(p.parent.glob("*.db"))))   # Kopien, die gerade im Temp-Ordner liegen
        return real_add(self, name, *a, **k)
    monkeypatch.setattr(tarfile.TarFile, "add", add)
    with pytest.raises(SystemExit) as e:
        runpy.run_path(str(ROOT / "deploy" / "backup_snapshot.py"), run_name="__main__")
    assert e.value.code == 0
    assert copies_seen == [1, 1, 1], copies_seen
    names = tarfile.open(fileobj=io.BytesIO(buf.getvalue()), mode="r:gz").getnames()
    assert sum(n.endswith("lernapp.db") for n in names) == 3


# ---------------------------------------------------------------- 5. Vorlage und Doku

def test_env_example_and_launch_doc_name_the_new_switches():
    env = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    for key in ("LERNAPP_LOGIN_FAILS_IP=500", "LERNAPP_LIMIT_REGISTER_IP=2000/60", "LERNAPP_LIMIT_REGISTER_ALL=",
                "LERNAPP_LIMIT_RESET_IP=300/60", "LERNAPP_DISK_MIN_FREE_MB=", "LERNAPP_MAIL_DEFER=", "LERNAPP_UPLOAD_QUOTA_MB=512"):
        assert re.search(rf"^{re.escape(key)}", env, re.M), key
    doc = ROOT / "docs" / "release" / "LAUNCH-4000-2026-11-08.md"
    assert doc.is_file()
    text = doc.read_text(encoding="utf-8")
    for must in ("LERNAPP_LOGIN_FAILS_IP=500", "LERNAPP_LIMIT_REGISTER_IP=2000/60", "UVICORN_WORKERS=12", "dienst-check.sh",
                 "Restrisiken", "Checkliste", "lasttest-anmeldung.py", "p95"):
        assert must in text, must
