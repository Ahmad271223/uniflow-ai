"""Externer statischer Audit vom 08.11.2026, Pakete 19-21, Teil app/accounts.py (docs/audit/AUDIT-2026-11-08-PAKET-19-21.md).

P19-06..P19-11 (accounts), P20-01..P20-10, P21-01..P21-05 (accounts-Tabellen), P21-11. Je Befund ein Test: bestaetigte
Fehler wurden hier zuerst rot nachgestellt und dann minimal behoben; widerlegte oder nicht erreichbare Behauptungen
nagelt der Test im heutigen Verhalten fest. Alles auf leeren Datenbanken im Temp-Datenordner der Testsuite.
"""
from __future__ import annotations

import asyncio
import json
import logging
import shutil
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import timedelta
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
PW = "sehr-geheim-123"
KURS = "1" * 64


# ---------------------------------------------------------------- Hilfen

@pytest.fixture
def hosted(app, monkeypatch):
    """Dienstmodus mit frischer accounts.db und community.db; Versandwege und Pruefer leer; Sammler geleert."""
    from app import accounts, community, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_MAIL", "off")

    def wipe():
        for p in (accounts.db_path(), community.db_path()):
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
        shutil.rmtree(community.package_dir(), ignore_errors=True)
    wipe()
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    monkeypatch.setattr(accounts, "verify_sender", None)
    with accounts._seen_lock:
        accounts._seen_pending.clear()
    yield app
    with accounts._seen_lock:
        accounts._seen_pending.clear()
    wipe()


def _j(resp):
    st, _, b = resp
    return st, (json.loads(b) if b else None)


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _threads(n, fn):
    out: list = []
    lock = threading.Lock()
    start = threading.Barrier(n)

    def run(i):
        start.wait()
        try:
            r = fn(i)
        except Exception as e:  # noqa: BLE001 - Ergebnis des Fadens
            r = e
        with lock:
            out.append(r)
    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join(60) for t in ts]
    return out


class _Gate:
    """Verbindung, die nach der ersten Anweisung mit `marker` an einer Schranke wartet: macht ein Rennen zwischen
    Lesen und Schreiben reproduzierbar (beide Faeden haben gelesen, bevor einer schreibt)."""

    def __init__(self, conn, marker, barrier):
        self._c, self._marker, self._barrier, self._done = conn, marker, barrier, False

    def execute(self, sql, *args):
        cur = self._c.execute(sql, *args)
        if not self._done and self._marker in sql:
            self._done = True
            try:
                self._barrier.wait(timeout=2)
            except threading.BrokenBarrierError:
                pass                                 # der andere Faden wartet auf die Schreibsperre: weiter
        return cur

    def __getattr__(self, name):
        return getattr(self._c, name)


def _gated_cursor(monkeypatch, marker, parties=2):
    from app import accounts
    real = accounts.cursor
    barrier = threading.Barrier(parties)

    @contextmanager
    def gated():
        with real() as c:
            yield _Gate(c, marker, barrier)
    monkeypatch.setattr(accounts, "cursor", gated)


def _register_api(app, email, uni="luh", ip="10.0.0.1"):
    st, d = _j(asgi_call(app, "POST", "/api/account/register", client=(ip, 1),
                         body=json.dumps({"email": email, "password": PW, "university": uni})))
    assert st == 201, d
    return d


# ================================================================ PAKET 19 (accounts.py)

def test_p19_06_parallel_registrations_behind_one_campus_address_all_succeed(hosted, monkeypatch):
    """P19-06: `_hit` schreibt und committet bei jedem Versuch, Registrierungen serialisieren sich auf accounts.db.
    Gemessen (in einem Prozess, 40 Faeden, eine Campus-Adresse, Grenze wie deploy/.env.example): alle 201, kein
    `database is locked`; die Schreibsperre haelt nur INSERT + Probe (scrypt laeuft vorher, ausserhalb der Sperre).
    Ein Lasttest mit 12 Prozessen bleibt Betriebsaufgabe (tools/lasttest-anmeldung.py)."""
    from app import accounts
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "2000/60")
    times: list[float] = []

    def reg(i):
        t = time.perf_counter()
        st, d = _j(asgi_call(hosted, "POST", "/api/account/register", client=("10.9.0.1", 1),
                             body=json.dumps({"email": f"last{i}@beispiel.de", "password": PW, "university": "luh"})))
        times.append(time.perf_counter() - t)
        return st
    out = _threads(40, reg)
    assert out.count(201) == 40, out
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 40
        assert conn.execute("SELECT count FROM rate_limits WHERE key='register_ip:10.9.0.1'").fetchone()[0] == 40
    times.sort()
    p95 = times[int(len(times) * 0.95) - 1]
    print(f"P19-06: 40 Registrierungen parallel, p50 {times[19] * 1000:.0f} ms, p95 {p95 * 1000:.0f} ms")
    assert p95 < 15, "deutlich unter busy_timeout (15 s)"


def test_p19_06_scrypt_runs_before_the_write_lock_in_register():
    """P19-06: der Hash wird als Argument des INSERT berechnet, also bevor die Anweisung die Schreibsperre nimmt;
    die Transaktion beginnt (Python-sqlite3, implizites BEGIN) erst mit dem INSERT."""
    import inspect

    from app import accounts
    src = inspect.getsource(accounts.register)
    assert "hash_password(password)" in src.split("INSERT INTO users")[1].split("_grant_trial_in")[0]


def test_p19_07_scrypt_parameters_see_audit_b04():
    """P19-07 = Audit Paket 1-2 B04 (nicht erreichbar, Empfehlung offen): `pw_hash` schreibt nur `hash_password`."""
    from app import accounts
    assert accounts.hash_password("x" * 12).startswith("scrypt$16384$8$1$")
    src = (ROOT / "tests" / "test_audit_paket_1_2.py").read_text(encoding="utf-8")
    assert "def test_30_B04_unbounded_scrypt_parameters_are_not_reachable_and_oversized_ones_fail_fast" in src


def test_p19_08_account_and_trial_atomic_see_audit_b02_02():
    """P19-08 = Audit Paket 1-2 B02-02 (behoben: `_grant_trial_in` in derselben Transaktion)."""
    src = (ROOT / "tests" / "test_audit_paket_1_2.py").read_text(encoding="utf-8")
    assert "def test_39_B02_02_register_leaves_no_account_when_the_trial_cannot_be_granted" in src


@pytest.mark.parametrize("bad", ["kaputt", "", "2026-13-45T99:00:00Z"])
def test_p19_09_corrupt_timestamps_do_not_break_login_or_limits(hosted, bad):
    """P19-09: `datetime.fromisoformat` auf Datenbankwerte ohne Fehlerbehandlung. Nur der Dienst schreibt diese Spalten
    (immer `iso(now())`), ein kaputter Wert kommt nur durch Reparatur/Korruption. Vorher: jeder Login dieser Adresse
    (bzw. jede Registrierung dieser IP) endete mit 500, dauerhaft. Jetzt: kaputter Zeitstempel = abgelaufen."""
    from app import accounts
    accounts.register("zeit@beispiel.de", PW, "luh")
    with accounts.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO login_attempts(key, fails, last_fail_at) VALUES ('email:zeit@beispiel.de', 99, ?)", (bad,))
        conn.execute("INSERT OR REPLACE INTO rate_limits(key, count, window_start) VALUES ('register_ip:10.7.0.1', 99999, ?)", (bad,))
    user, token = accounts.login("zeit@beispiel.de", PW)
    assert user["email"] == "zeit@beispiel.de" and token
    with accounts.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO login_attempts(key, fails, last_fail_at) VALUES ('email:zeit@beispiel.de', 99, ?)", (bad,))
    with pytest.raises(accounts.AccountError) as x:
        accounts.login("zeit@beispiel.de", "falsch-falsch-1")
    assert x.value.code == "credentials_invalid"
    with accounts.cursor() as conn:
        assert conn.execute("SELECT fails FROM login_attempts WHERE key='email:zeit@beispiel.de'").fetchone()[0] == 1, "Zaehler neu"
    accounts.register("neu@beispiel.de", PW, "luh", client_ip="10.7.0.1")
    with accounts.cursor() as conn:
        assert conn.execute("SELECT count FROM rate_limits WHERE key='register_ip:10.7.0.1'").fetchone()[0] == 1, "neues Fenster"


@pytest.mark.parametrize("raw", ["abc", "0/60", "10", "-1/5", "5/0"])
def test_p19_10_invalid_limit_is_logged_and_falls_back(monkeypatch, caplog, raw):
    """P19-10: ungueltige LERNAPP_LIMIT_* fielen still auf den Standard zurueck. Jetzt: Standard plus Warnung im
    Protokoll (Name und Rohwert, keine Geheimnisse), je Name und Wert einmal."""
    from app import accounts
    monkeypatch.setattr(accounts, "_warned_env", set())
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", raw)
    with caplog.at_level(logging.WARNING, logger="uniflow.accounts"):
        assert accounts._limit("register_ip") == accounts.LIMITS["register_ip"]
        assert accounts._limit("register_ip") == accounts.LIMITS["register_ip"]
    msgs = [r.getMessage() for r in caplog.records if "LERNAPP_LIMIT_REGISTER_IP" in r.getMessage()]
    assert len(msgs) == 1 and repr(raw) in msgs[0], msgs
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "300/60")
    assert accounts._limit("register_ip") == (300, 60)


@pytest.mark.parametrize("raw", ["viele", "0", "-3"])
def test_p19_10_invalid_ip_fail_limit_is_logged(monkeypatch, caplog, raw):
    from app import accounts
    monkeypatch.setattr(accounts, "_warned_env", set())
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", raw)
    with caplog.at_level(logging.WARNING, logger="uniflow.accounts"):
        assert accounts.max_fails_ip() == accounts.MAX_FAILS_IP
    assert any("LERNAPP_LOGIN_FAILS_IP" in r.getMessage() for r in caplog.records)
    monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "")
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger="uniflow.accounts"):
        assert accounts.max_fails_ip() == accounts.MAX_FAILS_IP
    assert not caplog.records, "nicht gesetzt ist kein Fehler"


def test_p19_11_account_lock_is_targetable_but_reset_ends_it(hosted):
    """P19-11 (Produktentscheidung, Bewertung im Bericht): 8 falsche Passwoerter von beliebigen Adressen sperren eine
    bekannte Adresse 10 Minuten, auch fuer das richtige Passwort - so gewollt (Schutz gegen Durchprobieren).
    Behoben ist der Teil, der die Person ohne Ausweg liess: nach einem Passwort-Reset (Nachweis ueber das Postfach)
    galt die Sperre weiter (429 mit dem NEUEN Passwort). Jetzt loescht der Reset den Zaehler der Adresse."""
    from app import accounts
    accounts.register("opfer@beispiel.de", PW, "luh")
    for i in range(accounts.MAX_FAILS):
        with pytest.raises(accounts.AccountError):
            accounts.login("opfer@beispiel.de", "falsch-falsch-1", client_ip=f"203.0.113.{i}")
    with pytest.raises(accounts.AccountError) as x:
        accounts.login("opfer@beispiel.de", PW, client_ip="198.51.100.1")
    assert (x.value.code, x.value.status) == ("locked", 429), "gezielte Sperre: gewolltes Verhalten"
    token = accounts.request_password_reset("opfer@beispiel.de")
    accounts.reset_password(token, "ganz-neu-geheim-1")
    user, _ = accounts.login("opfer@beispiel.de", "ganz-neu-geheim-1", client_ip="198.51.100.1")
    assert user["email"] == "opfer@beispiel.de"


def test_p19_11_other_login_ways_are_not_locked(hosted):
    """P19-11: die Sperre gilt nur dem Passwort-Login; eine verknuepfte Apple/Google-Anmeldung meldet weiter an."""
    from app import accounts
    u = accounts.register("opfer2@beispiel.de", PW, "luh")
    accounts.mark_email_verified(u["id"])
    accounts.link_provider(u["id"], "apple", "apple-opfer")
    for _ in range(accounts.MAX_FAILS):
        with pytest.raises(accounts.AccountError):
            accounts.login("opfer2@beispiel.de", "falsch-falsch-1")
    user, token, created = accounts.login_with_provider("apple", "apple-opfer")
    assert user["id"] == u["id"] and token and created is False


# ================================================================ PAKET 20

def test_p20_01_purge_retries_after_a_failure_behind_rmtree(hosted, monkeypatch):
    """P20-01: Ordner weg, danach scheitert `_purge_user` -> Rollback, Ordner trotzdem weg. Folge: kein Verlust (der
    Ordner gehoert einem seit 30 Tagen geloeschten Konto und soll weg), der naechste Lauf findet die Zeile wieder und
    loescht sie (keine Ordner mehr -> `_purge_user`). Bewusste Reihenfolge seit Audit Paket 3 Nr. 66."""
    from app import accounts, config
    u = accounts.register("purge@beispiel.de", PW, "luh")
    d = config.user_data_dir(u["id"], "luh")
    d.mkdir(parents=True, exist_ok=True)
    (d / "lernapp.db").write_bytes(b"x")
    accounts.delete_account(u["id"], PW)
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    real = accounts._purge_user

    def boom(conn, uid):
        raise sqlite3.OperationalError("disk I/O error")
    monkeypatch.setattr(accounts, "_purge_user", boom)
    assert accounts.purge_deleted() == 0
    assert accounts.get_user(u["id"]) is not None and not config.retired_user_data_dirs(u["id"])
    monkeypatch.setattr(accounts, "_purge_user", real)
    assert accounts.purge_deleted() == 1
    assert accounts.get_user(u["id"]) is None


def test_p20_02_p21_03_university_switch_keeps_data_apart(hosted):
    """P20-02/P21-03: `set_university` aendert nur `users.university`. Getrennt bleiben trotzdem: der Datenordner
    (`config.user_data_dir(id, uni)`, LUH im Konto-Ordner, jede andere Hochschule in `unis/<uni>`), Datei- und
    Kurs-Claims (Spalte `university`, Kontext der Sitzung). Mitgliedschaften folgen dem Konto (Produktentscheidung,
    Bericht): die Hochschule ist eine Angabe der Person, keine Mandantengrenze mit Nachweis."""
    from app import accounts, community, config
    reg = _register_api(hosted, "wechsel@beispiel.de")
    uid = reg["user"]["id"]
    accounts.mark_email_verified(uid)
    accounts.set_plan(uid, "plus")
    assert config.user_data_dir(uid, "luh") != config.user_data_dir(uid, "hildesheim")
    user = accounts.get_user(uid)
    community.claim_files(user, "luh", ["a" * 64], course_keys=[KURS])
    community.join(user, "luh", KURS, "course")
    st, d = _j(asgi_call(hosted, "POST", "/api/account/university", body=json.dumps({"university": "hildesheim"}),
                         headers=_auth(reg["token"])))
    assert st == 200 and d["user"]["university"] == "hildesheim"
    user = accounts.get_user(uid)
    with pytest.raises(community.CommunityError) as x:
        community.join(user, "hildesheim", "2" * 64, "course")
    assert x.value.code == "course_not_owned", "Claims der alten Hochschule zaehlen nicht fuer die neue"
    listed = {c["community_key"]: c for c in community.communities(user, "hildesheim")}
    assert listed[KURS]["joined"] is True, "Mitgliedschaft bleibt (Entscheidung, Bericht)"
    st, d = _j(asgi_call(hosted, "POST", "/api/account/university", body=json.dumps({"university": "mars"}),
                         headers=_auth(reg["token"])))
    assert (st, d["code"]) == (400, "university_unknown")


def test_p20_03_idle_flush_touches_no_database(hosted, monkeypatch):
    """P20-03: der Sammler wacht einmal je Sekunde auf; ohne ausstehende Arbeit oeffnet `flush_seen` keine
    Verbindung (ein Lock, ein leeres dict). Ein Faden je Prozess, Daemon."""
    from app import accounts
    calls = []
    monkeypatch.setattr(accounts, "cursor", lambda: calls.append(1))
    assert accounts.flush_seen() == 0 and calls == []


def test_p20_03_p20_04_shutdown_flushes_pending_session_extensions(hosted, monkeypatch):
    """P20-03/P20-04: vorher gingen beim Herunterfahren eines Prozesses (Neustart, Deploy) die gesammelten
    Verlaengerungen der letzten Sekunde verloren. Jetzt schreibt das Ende der Lebensdauer (lifespan) sie noch."""
    from app import accounts, doc_index, jobs, server, vault
    _, token = (accounts.register("seen@beispiel.de", PW, "luh"), None)
    _, token = accounts.login("seen@beispiel.de", PW)
    with accounts.cursor() as conn:
        conn.execute("UPDATE sessions SET last_seen_at='2000-01-01T00:00:00Z'")
    assert accounts.authenticate(token) and accounts.pending_seen() == 1
    for mod, name in ((server, "wire_hosted_services"), (vault, "purge_at_startup"), (jobs, "start_background"),
                      (doc_index, "start_background")):
        monkeypatch.setattr(mod, name, lambda: None)

    async def life():
        async with server._lifespan(None):
            pass
    asyncio.run(life())
    assert accounts.pending_seen() == 0
    with accounts.cursor() as conn:
        assert conn.execute("SELECT last_seen_at FROM sessions").fetchone()[0] != "2000-01-01T00:00:00Z"


def test_p20_04_pending_extension_survives_failed_flush_and_newer_wins(hosted, monkeypatch):
    """P20-04: scheitert das Schreiben, bleiben die Werte gesammelt; ein neuerer Wert derselben Sitzung gewinnt.
    Absturz vor dem Schreiben: die Sitzung verliert hoechstens SEEN_EVERY_S + SEEN_FLUSH_S (~61 s) ihrer 30 Tage."""
    from app import accounts
    accounts._seen_later(7, accounts.now())
    real = accounts.cursor

    @contextmanager
    def locked():
        raise sqlite3.OperationalError("database is locked")
        yield
    monkeypatch.setattr(accounts, "cursor", locked)
    with pytest.raises(sqlite3.OperationalError):
        accounts.flush_seen()
    assert accounts.pending_seen() == 1
    newer = accounts.now() + timedelta(minutes=5)
    with accounts._seen_lock:
        accounts._seen_pending[7] = (accounts.iso(newer), "x")
    with pytest.raises(sqlite3.OperationalError):
        accounts.flush_seen()
    with accounts._seen_lock:
        assert accounts._seen_pending[7][0] == accounts.iso(newer)
    monkeypatch.setattr(accounts, "cursor", real)
    assert accounts.SEEN_EVERY_S + accounts.SEEN_FLUSH_S <= 61


def test_p20_05_flush_seen_keeps_the_batch_on_any_error(hosted, monkeypatch):
    """P20-05: nur `sqlite3.Error` stellte den entnommenen Stapel wieder her; jede andere Ausnahme (z. B. OSError beim
    Anlegen des Ordners, RuntimeError) verlor ihn. Jetzt: jede Ausnahme -> zurueck in den Sammler, weiterwerfen."""
    from app import accounts
    accounts._seen_later(11, accounts.now())

    @contextmanager
    def broken():
        raise RuntimeError("unerwartet")
        yield
    monkeypatch.setattr(accounts, "cursor", broken)
    with pytest.raises(RuntimeError):
        accounts.flush_seen()
    assert accounts.pending_seen() == 1


def test_p20_06_verification_link_is_redeemed_once_under_concurrency(hosted, monkeypatch):
    """P20-06: `used_at` wurde gelesen und danach ohne `AND used_at IS NULL` gesetzt - zwei gleichzeitige Einloesungen
    waren beide erfolgreich (reproduziert mit einer Schranke nach dem Lesen). Folge heute gering (Bestaetigen ist
    idempotent), aber Vertragsbruch "nur einmal". Jetzt: bedingtes UPDATE zuerst, `rowcount != 1` -> verify_invalid."""
    from app import accounts
    u = accounts.register("doppelt@beispiel.de", PW, "luh")
    token = accounts.request_email_verification(u["id"], send=False, count=False)
    _gated_cursor(monkeypatch, "SELECT * FROM users WHERE id=? AND status='active'")
    out = _threads(2, lambda i: accounts.verify_email(token))
    ok = [r for r in out if isinstance(r, dict)]
    bad = [r for r in out if isinstance(r, accounts.AccountError)]
    assert len(ok) == 1 and len(bad) == 1 and bad[0].code == "verify_invalid", out
    monkeypatch.undo()


def test_p20_06_verify_email_single_cases(hosted):
    from app import accounts
    u = accounts.register("einmal@beispiel.de", PW, "luh")
    token = accounts.request_email_verification(u["id"], send=False, count=False)
    assert accounts.verify_email(token)["email_verified"] is True
    with pytest.raises(accounts.AccountError) as x:
        accounts.verify_email(token)
    assert x.value.code == "verify_invalid"
    with pytest.raises(accounts.AccountError):
        accounts.verify_email("")


def test_p20_07_verifier_error_text_see_audit_b02_06():
    """P20-07 = Audit Paket 1-2 B02-06: im Dienst nicht erreichbar (`identity_verifiers` setzt in app/ niemand; der
    Dienst prueft ueber social_login mit selbst formulierten Texten). Festgenagelt per Quelltext-Scan."""
    hits = [p.name for p in (ROOT / "app").glob("*.py")
            if "identity_verifiers[" in p.read_text(encoding="utf-8") or "identity_verifiers.update" in p.read_text(encoding="utf-8")]
    assert hits == [], hits
    src = (ROOT / "tests" / "test_audit_paket_1_2.py").read_text(encoding="utf-8")
    assert "def test_55_B02_06_verify_identity_error_paths" in src


def test_p20_08_p21_01_delete_succeeds_and_catches_up_when_side_effects_fail(hosted, monkeypatch):
    """P20-08/P21-01: nach dem Commit liefen `retire_user_data_dir` und `community.withdraw_all`. Scheiterte einer,
    war das Konto geloescht, die API antwortete 500 (Wiederholung unmoeglich: 401), und der nicht beiseitegelegte
    Ordner blieb fuer immer (purge_deleted kennt nur `users-deleted/<id>-*`), Community-Beitraege bis zum
    endgueltigen Loeschen sichtbar. Jetzt: Fehler werden protokolliert, die Loeschung gilt; der taegliche Lauf
    (`purge_deleted`, retention) holt beide Schritte fuer jedes geloeschte Konto nach (Status `deleted` ist der
    dauerhafte Auftrag, beide Schritte sind idempotent)."""
    from app import accounts, community, config
    reg = _register_api(hosted, "loesch@beispiel.de")
    uid = reg["user"]["id"]
    d = config.user_data_dir(uid, "luh")
    d.mkdir(parents=True, exist_ok=True)
    (d / "lernapp.db").write_bytes(b"x")
    calls = []
    real_retire, real_withdraw = config.retire_user_data_dir, community.withdraw_all

    def bad_retire(user_id):
        raise OSError("Platte voll")

    def bad_withdraw(user_id, reason):
        calls.append(user_id)
        raise sqlite3.OperationalError("database is locked")
    monkeypatch.setattr(config, "retire_user_data_dir", bad_retire)
    monkeypatch.setattr(community, "withdraw_all", bad_withdraw)
    st, out = _j(asgi_call(hosted, "POST", "/api/account/delete", body=json.dumps({"password": PW}), headers=_auth(reg["token"])))
    assert st == 200 and out["deleted"] is True, out
    assert accounts.get_user(uid)["email"].startswith("deleted-") and calls == [uid]
    assert d.exists() and not config.retired_user_data_dirs(uid)
    monkeypatch.setattr(config, "retire_user_data_dir", real_retire)
    seen = []
    monkeypatch.setattr(community, "withdraw_all", lambda user_id, reason: seen.append((user_id, reason)) or real_withdraw(user_id, reason))
    assert accounts.purge_deleted() == 0, "noch nicht faellig"
    assert not d.exists() and config.retired_user_data_dirs(uid), "Ordner nachgeholt"
    assert (uid, "account_deleted") in seen, "Community nachgeholt"
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1 and not config.retired_user_data_dirs(uid)


def test_p20_08_normal_delete_is_unchanged(hosted):
    from app import accounts, config
    u = accounts.register("normal@beispiel.de", PW, "luh")
    d = config.user_data_dir(u["id"], "luh")
    d.mkdir(parents=True, exist_ok=True)
    assert accounts.delete_account(u["id"], PW) == {"deleted": True, "purge_after_days": 30}
    assert not d.exists() and len(config.retired_user_data_dirs(u["id"])) == 1
    accounts.purge_deleted()
    assert len(config.retired_user_data_dirs(u["id"])) == 1, "Nachholen legt nichts doppelt beiseite"


def test_p20_09_failing_reset_sender_does_not_reveal_the_account(hosted, monkeypatch):
    """P20-09: Token ohne zugestellte Mail ist harmlos (30 Minuten, niemand kennt es; neue Anforderung bis 3 je Stunde).
    Der Versand im Dienst (`mail.send_later`) wirft nicht. Haerte: warf der Versandweg doch (z. B. kein neuer Faden
    unter Last), antwortete die API nur fuer BESTEHENDE Adressen 500 - ein Orakel fuer Konten. Jetzt: protokollieren,
    gleiche Antwort."""
    from app import accounts
    accounts.register("da@beispiel.de", PW, "luh")

    def broken(email, token):
        raise RuntimeError("can't start new thread")
    monkeypatch.setattr(accounts, "reset_sender", broken)
    answers = [_j(asgi_call(hosted, "POST", "/api/account/password/reset-request", body=json.dumps({"email": e})))
               for e in ("da@beispiel.de", "nicht-da@beispiel.de")]
    assert answers[0] == answers[1] and answers[0][0] == 200, answers


def test_p20_10_plan_and_role_are_read_fresh_and_billing_takes_the_highest(hosted):
    """P20-10: `set_plan` schreibt nur die manuelle Quelle; der wirksame Tarif kommt immer aus `billing.current_plan`
    (hoechster aktiver Tarif aus users.plan und entitlements). Rollen werden je Anfrage frisch gelesen
    (`authenticate` liest die Zeile), es gibt keinen Cache. `user.plan` in /me ist die manuelle Quelle; den wirksamen
    Tarif liefert /api/entitlements (Hinweis im Bericht)."""
    from app import accounts, billing
    reg = _register_api(hosted, "tarif@beispiel.de")
    uid = reg["user"]["id"]
    accounts.end_trial(uid)
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, uid, "apple", "pro_ai", original_transaction_id="t-1",
                                expires_at=accounts.iso(accounts.now() + timedelta(days=30)))
        conn.commit()
        accounts.set_plan(uid, "plus")
        assert billing.current_plan(conn, uid, legacy={"plan": "plus", "plan_until": None}) == "pro_ai"
    finally:
        conn.close()
    st, d = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=_auth(reg["token"])))
    assert st == 200 and d["plan"] == "pro_ai", d
    accounts.set_role(uid, "admin")
    assert accounts.authenticate(reg["token"])["role"] == "admin"
    accounts.set_role(uid, "user")
    assert accounts.authenticate(reg["token"])["role"] == "user", "sofort wirksam"


# ================================================================ PAKET 21 (accounts)

def test_p21_02_only_the_signed_token_decides_email_verified(hosted, monkeypatch):
    """P21-02 (launchkritisch): Verknuepfen mit einem bestehenden Konto nur, wenn (1) der Anbieter die Adresse im
    SIGNIERTEN Token bestaetigt (`email_verified` aus social_login.verify, nie aus dem Request-Koerper) und (2) das
    Konto seine Adresse selbst bestaetigt hat. Einziger Aufrufer: account_api.login_provider nach `_verified`."""
    from app import accounts, social_login
    reg = _register_api(hosted, "erika@beispiel.de")
    accounts.mark_email_verified(reg["user"]["id"])
    claims = {}
    monkeypatch.setattr(social_login, "configured", lambda p: True)
    monkeypatch.setattr(social_login, "verify", lambda p, t, n=None: dict(claims))

    def attempt(provider, body):
        return _j(asgi_call(hosted, "POST", f"/api/account/login/{provider}", body=json.dumps({"id_token": "x", **body})))
    # (a) Anbieter sagt "nicht bestaetigt", der Client behauptet es im Koerper: kein Verknuepfen, kein Konto
    claims.update(subject="g-angreifer", email="erika@beispiel.de", email_verified=False)
    st, d = attempt("google", {"email_verified": True, "university": "luh"})
    assert (st, d["code"]) == (409, "email_taken")
    # (b) Token ohne Adresse, fremde Adresse als fallback_email: nie Verknuepfen
    claims.clear()
    claims.update(subject="a-angreifer", email=None, email_verified=True)
    st, d = attempt("apple", {"email": "erika@beispiel.de", "email_verified": True, "university": "luh"})
    assert (st, d["code"]) == (409, "email_taken")
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
    # (c) bestaetigt im Token: Verknuepfen mit dem bestaetigten Konto (gewollt)
    claims.clear()
    claims.update(subject="a-erika", email="erika@beispiel.de", email_verified=True)
    st, d = attempt("apple", {})
    assert st == 200 and d["user"]["id"] == reg["user"]["id"] and d["created"] is False


def test_p21_02_apple_string_claims_and_private_relay(hosted, monkeypatch):
    """P21-02: Apple liefert `email_verified`/`is_private_email` als Text. Nur exakt true/"true" gilt; eine
    Relay-Adresse (is_private_email) trifft kein Passwortkonto mit der echten Adresse, es entsteht ein eigenes Konto."""
    from test_social_login import APPLE_ID, Keys, apple_claims

    from app import accounts, social_login
    keys = Keys()
    monkeypatch.setattr(social_login, "fetch_jwks", lambda url: keys.jwks)
    social_login.clear_cache()
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", APPLE_ID)
    for raw, expected in (("true", True), ("TRUE", True), (True, True), ("false", False), ("1", False), (1, False), (None, False)):
        info = social_login.verify("apple", keys.token(apple_claims(email="x@beispiel.de", email_verified=raw), alg="ES256", kid="ec-1"))
        assert info["email_verified"] is expected, raw
    reg = _register_api(hosted, "echt@beispiel.de")
    accounts.mark_email_verified(reg["user"]["id"])
    tok = keys.token(apple_claims(sub="a-relay", email="abc123@privaterelay.appleid.com"), alg="ES256", kid="ec-1")
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/apple", body=json.dumps({"id_token": tok, "university": "luh",
                                                                                      "email": "echt@beispiel.de"})))
    assert st == 201 and d["created"] is True and d["user"]["id"] != reg["user"]["id"]
    assert d["user"]["email"] == "abc123@privaterelay.appleid.com", "Adresse aus dem Token geht vor der Client-Adresse"
    tok = keys.token(apple_claims(sub="a-false", email="echt@beispiel.de", email_verified="false"), alg="ES256", kid="ec-1")
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/apple", body=json.dumps({"id_token": tok, "university": "luh"})))
    assert (st, d["code"]) == (409, "email_taken"), "Apple 'false' als Text verknuepft nicht"
    social_login.clear_cache()


def test_p21_02_login_with_provider_has_a_single_verified_caller():
    """P21-02: `login_with_provider` wird in app/ nur von account_api.login_provider (nach `_verified`) und von
    accounts.login_with_identity (nach `verify_identity`) aufgerufen."""
    import re
    callers = {}
    for p in (ROOT / "app").glob("*.py"):
        n = len(re.findall(r"login_with_provider\(", p.read_text(encoding="utf-8")))
        if n:
            callers[p.name] = n
    assert callers == {"accounts.py": 2, "account_api.py": 1}, callers
    api = (ROOT / "app" / "account_api.py").read_text(encoding="utf-8")
    body = api.split("def login_provider(")[1].split("\n@router")[0]
    assert body.index("_verified(provider, body)") < body.index("login_with_provider("), "erst pruefen, dann anmelden"
    assert 'info.get("email_verified")' in body and 'body.get("email_verified")' not in body


def test_p21_04_parallel_unlinks_keep_one_login_method(hosted, monkeypatch):
    """P21-04: passwortloses Konto mit Apple und Google; zwei gleichzeitige Entfernungen lasen beide COUNT=2 und
    loeschten beide - das Konto hatte keinen Anmeldeweg mehr (reproduziert mit einer Schranke nach dem COUNT).
    Jetzt: nach dem DELETE (Schreibsperre) erneut zaehlen; bliebe ohne Passwort nichts, Rollback und 409."""
    from app import accounts
    user, _, _ = accounts.login_with_provider("apple", "a-1", "solo@beispiel.de", True, "luh")
    accounts.link_provider(user["id"], "google", "g-1")
    _gated_cursor(monkeypatch, "SELECT COUNT(*) FROM identities")
    out = _threads(2, lambda i: accounts.unlink_provider(user["id"], ("apple", "google")[i]))
    monkeypatch.undo()
    assert sorted(type(r).__name__ for r in out) == ["AccountError", "bool"], out
    err = next(r for r in out if isinstance(r, accounts.AccountError))
    assert (err.code, err.status) == ("last_login_method", 409)
    assert len(accounts.identities(user["id"])) == 1


def test_p21_04_unlink_single_cases(hosted):
    from app import accounts
    user, _, _ = accounts.login_with_provider("apple", "a-2", "solo2@beispiel.de", True, "luh")
    with pytest.raises(accounts.AccountError) as x:
        accounts.unlink_provider(user["id"], "apple")
    assert x.value.code == "last_login_method"
    accounts.link_provider(user["id"], "google", "g-2")
    assert accounts.unlink_provider(user["id"], "google") is True
    with pytest.raises(accounts.AccountError) as x:
        accounts.unlink_provider(user["id"], "google")
    assert x.value.code == "last_login_method", "ohne Passwort und mit einem Weg: 409 wie bisher (vor dem DELETE)"
    pw = accounts.register("mitpw@beispiel.de", PW, "luh")
    accounts.mark_email_verified(pw["id"])
    accounts.link_provider(pw["id"], "apple", "a-3")
    assert accounts.unlink_provider(pw["id"], "apple") is True, "mit Passwort darf der letzte Anbieter weg"
    assert accounts.unlink_provider(pw["id"], "apple") is False


def test_p21_05_token_and_limit_tables_are_cleaned_by_retention(hosted):
    """P21-05: schon behoben - `retention.purge_account_db` (taeglich) loescht abgelaufene/benutzte Reset- und
    Bestaetigungs-Tokens, alte Fehlversuche, Zaehler aelter als 2 Tage und abgelaufene/widerrufene Sitzungen;
    vorhandener Test tests/test_retention.py. Hier: alle Tabellen der Konto-DB mit wachsenden Zeilen sind erfasst."""
    import inspect

    from app import retention
    src = inspect.getsource(retention.purge_account_db)
    for table in ("sessions", "reset_tokens", "verify_tokens", "login_attempts", "rate_limits"):
        assert f'"{table}": ("{table}"' in src, table
    assert "INSERT INTO reset_tokens" in (ROOT / "tests" / "test_retention.py").read_text(encoding="utf-8")


def test_p21_11_admin_functions_have_no_http_caller(hosted):
    """P21-11: `set_plan`, `set_role`, `mark_email_verified` pruefen keine Berechtigung; sie werden in app/ nur in
    accounts.py selbst (CLI `main`) aufgerufen, nie von einem Endpunkt. Die Admin-Endpunkte (billing_api) pruefen
    `role == "admin"`; ein normales Konto bekommt 403."""
    import re
    for fn in ("set_plan", "set_role", "mark_email_verified"):
        callers = [p.name for p in (ROOT / "app").glob("*.py")
                   if re.search(rf"accounts\.{fn}\(|(?<![\w.]){fn}\(", p.read_text(encoding="utf-8")) and p.name != "accounts.py"]
        assert callers == [], (fn, callers)
    reg = _register_api(hosted, "normal-admin@beispiel.de")
    api = (ROOT / "app" / "billing_api.py").read_text(encoding="utf-8")
    assert api.count('_user(request).get("role") != "admin"') >= 2
    for path in ("/api/billing/ai-usage", "/api/billing/ai-costs"):
        st, d = _j(asgi_call(hosted, "GET", path, headers=_auth(reg["token"])))
        assert (st, d["code"]) == (403, "admin_required"), (path, st, d)
