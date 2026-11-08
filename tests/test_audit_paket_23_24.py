"""Audit Paket 23/24 (08.11.2026): Konto-Pflicht am PC (app/account_mode.py) und Datenexport (PC und Dienst).

Bericht: docs/audit/AUDIT-2026-11-08-PAKET-23-24.md. Der "Dienst" laeuft wie in tests/test_account_mode.py im selben
Prozess (ASGI); nichts geht ins Netz."""
import io
import json
import os
import threading
import time
import zipfile
from pathlib import Path

import pytest
from conftest import asgi_call
from test_account_mode import (_end_trial, _hosted, _local, _login, _register, stripe, svc)  # noqa: F401 (Fixtures)


def _set_link(user_id: str, token: str = "tok-b"):
    from app import service_link
    st = service_link.load_state()
    st.update({"token": token, "user": {"id": user_id, "email": f"{user_id}@example.org"}})
    service_link.save_state(st)


def _plus_cache(user_id):
    from app import account_mode
    return account_mode.save_cache({"plan": "plus", "source": "stripe", "paid_plan": "plus"}, {"id": user_id, "role": "user"})


# ================================================================ P23-01 Cache an das Konto binden

def test_p23_01_cache_of_another_account_is_ignored(svc):
    from app import account_mode
    _set_link("konto-a", "tok-a")
    _plus_cache("konto-a")
    assert account_mode.state()["state"] == "active"
    # Kontowechsel ohne Cache-Loeschung (Absturz, Teilfehler): der Stand von A gilt nicht fuer B
    _set_link("konto-b", "tok-b")
    s = account_mode.state()
    assert s["state"] == "unverified" and s["locked"], s


def test_p23_01_cache_without_owner_is_ignored(svc):
    from app import account_mode
    _set_link("konto-a")
    account_mode.save_cache({"plan": "plus", "source": "stripe", "paid_plan": "plus"}, None)
    assert account_mode.state()["state"] == "unverified"


# ================================================================ P23-02 lokaler Cache ist kein Zahlungsnachweis

def test_p23_02_manipulated_cache_does_not_change_the_service(svc):
    from app import account_mode
    app = svc.app
    u, tok = _register(app, "manipuliert@example.org")
    _end_trial(u["id"])
    _login(app, "manipuliert@example.org")
    c = json.loads(account_mode.cache_path().read_text(encoding="utf-8"))
    c["entitlements"].update(plan="pro_ai", paid_plan="pro_ai", source="stripe")
    account_mode.cache_path().write_text(json.dumps(c), encoding="utf-8")
    assert account_mode.state()["state"] == "active", "dokumentierte Grenze: lokale Sperre ist kein Kopierschutz"
    st, e = _hosted(app, "GET", "/api/entitlements", headers={"Authorization": f"Bearer {tok}", "X-StudiNow-Client": "windows"})
    assert st == 200 and e["plan"] == "free" and e["access"]["locked"], "der Dienst entscheidet selbst"
    # der naechste Abruf ueberschreibt die Manipulation
    assert _local(app, "GET", "/api/app-account/status?refresh=1")[1]["state"] == "subscription_required"


# ================================================================ P23-03 eindeutige Temp-Datei

def test_p23_03_save_cache_uses_unique_temp_files(svc, monkeypatch):
    from app import account_mode
    _set_link("konto-a")
    seen = []
    real = os.replace

    def spy(src, dst):
        seen.append(Path(src).name)
        return real(src, dst)
    monkeypatch.setattr(account_mode.os, "replace", spy)
    _plus_cache("konto-a")
    _plus_cache("konto-a")
    assert len(set(seen)) == 2 and "account-cache.json.tmp" not in seen, seen
    monkeypatch.setattr(account_mode.os, "replace", lambda s, d: (_ for _ in ()).throw(OSError("voll")))
    with pytest.raises(OSError):
        _plus_cache("konto-a")
    left = [p.name for p in account_mode.cache_path().parent.iterdir() if p.name.startswith("account-cache") and p.name != "account-cache.json"]
    assert left == [], "keine Temp-Reste nach Fehler"


def test_p23_03_parallel_saves_leave_a_valid_file(svc):
    from app import account_mode
    _set_link("konto-a")
    errors = []

    def w():
        try:
            for _ in range(10):
                _plus_cache("konto-a")
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=w) for _ in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errors, errors
    assert json.loads(account_mode.cache_path().read_text(encoding="utf-8"))["user"]["id"] == "konto-a"
    assert not [p for p in account_mode.cache_path().parent.iterdir() if p.name.startswith("account-cache") and p.name != "account-cache.json"]


# ================================================================ P23-04 / P23-09 refresh gegen Logout und Kontowechsel

def test_p23_04_logout_during_refresh_leaves_no_cache(svc, monkeypatch):
    from app import account_mode, service_link
    app = svc.app
    _register(app, "rennen@example.org")
    _login(app, "rennen@example.org")
    real = service_link.call

    def call(method, path, *a, **k):
        out = real(method, path, *a, **k)
        if path == "/api/account/me":
            account_mode.logout()                  # Abmelden im anderen Fenster, waehrend refresh laeuft
        return out
    monkeypatch.setattr(service_link, "call", call)
    d = account_mode.refresh()
    assert not account_mode.cache_path().exists(), "Cache taucht nach dem Abmelden nicht wieder auf"
    assert d["state"] == "signed_out"


def test_p23_09_account_switch_during_refresh_is_not_mixed(svc, monkeypatch):
    from app import account_mode, service_link
    app = svc.app
    _register(app, "erst@example.org")
    _login(app, "erst@example.org")
    account_mode.clear_cache()
    real = service_link.call

    def call(method, path, *a, **k):
        st, h, b = real(method, path, *a, **k)
        if path == "/api/account/me":
            return st, h, json.dumps({"user": {"id": "jemand-anders", "email": "x@example.org"}}).encode()
        return st, h, b
    monkeypatch.setattr(service_link, "call", call)
    account_mode.refresh()
    c = account_mode.load_cache()
    assert c is None or c["user"]["id"] != "jemand-anders"
    assert (service_link.load_state().get("user") or {}).get("id") != "jemand-anders"


# ================================================================ P23-06 ungueltige Cache-Typen

BAD_CACHES = [
    {"fetched_at": "abc", "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": {"x": 1}, "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": True, "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": "nan", "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": 1e309, "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": None, "user": {"id": "konto-a"}, "entitlements": {"plan": "plus"}},
    {"fetched_at": time.time(), "user": "konto-a", "entitlements": {"plan": "plus"}},
    {"fetched_at": time.time(), "user": {"id": "konto-a"}, "entitlements": {"plan": "plus", "trial": "abc"}},
    {"fetched_at": time.time(), "user": {"id": "konto-a"}, "entitlements": {"plan": ["plus"]}},
    {"fetched_at": time.time(), "user": {"id": "konto-a"}, "entitlements": {"plan": "plus", "subscriptions": "ja", "quotas": 5}},
]


@pytest.mark.parametrize("bad", BAD_CACHES)
def test_p23_06_broken_cache_fails_closed(svc, bad):
    from app import account_mode
    _set_link("konto-a")
    account_mode.cache_path().write_text(json.dumps(bad), encoding="utf-8")
    s = account_mode.state()
    assert s["locked"], (bad, s)
    account_mode.info()
    account_mode.entitlements_status()
    account_mode.cached_purchase()


def test_p23_06_evaluate_itself_does_not_raise():
    from app import account_mode
    for bad in BAD_CACHES:
        assert account_mode.evaluate(True, bad, time.time(), 7)["state"] in ("unverified", "subscription_required", "active", "trial")
    assert account_mode.evaluate(True, BAD_CACHES[0], time.time(), 7)["state"] == "unverified"


# ================================================================ P23-08 Hintergrund-Arbeit dedupliziert

def test_p23_08_run_later_keeps_one_thread(monkeypatch):
    from app import account_mode
    gate = threading.Event()
    runs = []

    def fn():
        runs.append(1)
        gate.wait(5)
    for _ in range(6):
        account_mode.run_later(fn)
    alive = [t for t in threading.enumerate() if t.name == "studora-claims" and t.is_alive()]
    assert len(alive) <= 1, alive
    gate.set()
    for t in alive:
        t.join(5)
    assert 1 <= len(runs) <= 2, "hoechstens ein Nachlauf fuer die gesammelten Anstoesse"


# ================================================================ P23-10 Browser startet nicht

def test_p23_10_checkout_reports_when_the_browser_did_not_open(svc, stripe, monkeypatch):
    from app import account_mode
    app = svc.app
    _register(app, "kein-browser@example.org")
    _login(app, "kein-browser@example.org")
    monkeypatch.setattr(account_mode, "open_url", lambda url: False)
    st, d = _local(app, "POST", "/api/app-account/checkout", {"plan": "plus"})
    assert st == 200 and d["opened"] is False and d["url"].startswith("https://checkout.stripe.com/")
    st, d = _local(app, "POST", "/api/app-account/portal", {})
    assert st == 200 and d["opened"] is False and d["url"]
    st, d = _local(app, "POST", "/api/app-account/browser-login", {"mode": "login"}, host="127.0.0.1:8765")
    assert st == 200 and d["opened"] is False and d["url"]
    src = (Path(account_mode.__file__).parent / "static" / "views-abo.js").read_text(encoding="utf-8")
    assert "opened === false" in src, "Oberflaeche zeigt die Adresse zum Kopieren"


# ================================================================ P24-05 state erst nach Pruefung verbrauchen

def test_p24_05_incomplete_callback_does_not_burn_the_state(svc):
    from app import account_mode
    r = account_mode.start_browser_login("http://127.0.0.1:8765", open_browser=False)
    state = dict(__import__("urllib.parse").parse.parse_qsl(r["url"].split("?", 1)[1]))["state"]
    st, _ = account_mode.complete_browser_login({"state": state})            # ohne Code
    assert st == 400
    assert state in account_mode._flows, "unvollstaendige Rueckmeldung verbraucht den Flow nicht"
    st, _ = account_mode.complete_browser_login({"state": state, "error": "access_denied"})
    assert st == 400 and state not in account_mode._flows, "Abbruch beendet den Flow"


# ================================================================ P24-07 nur Stripe-Ziele

@pytest.mark.parametrize("url", ["https://evil.example/c/cs_1", "https://checkout.stripe.com.evil.example/x",
                                 "https://user@checkout.stripe.com@evil.example/", "https://checkout.stripe.com:8443/x",
                                 "http://checkout.stripe.com/x", "https://evilstripe.com/x", "javascript:alert(1)"])
def test_p24_07_checkout_and_portal_only_open_stripe_hosts(svc, monkeypatch, url):
    from app import account_mode
    _set_link("konto-a")
    monkeypatch.setattr(account_mode, "_service_json", lambda *a, **k: {"url": url})
    opened = []
    monkeypatch.setattr(account_mode, "open_url", lambda u: opened.append(u) or True)
    for fn in (lambda: account_mode.checkout("plus"), lambda: account_mode.portal()):
        with pytest.raises(account_mode.AccountModeError) as e:
            fn()
        assert e.value.code == "stripe_error"
    assert opened == []


def test_p24_07_stripe_hosts_are_allowed(svc, monkeypatch):
    from app import account_mode
    _set_link("konto-a")
    monkeypatch.setattr(account_mode, "open_url", lambda u: True)
    monkeypatch.setattr(account_mode, "_service_json", lambda *a, **k: {"url": "https://checkout.stripe.com/c/cs_1"})
    assert account_mode.checkout("plus")["opened"] is True
    monkeypatch.setattr(account_mode, "_service_json", lambda *a, **k: {"url": "https://billing.stripe.com/p/x"})
    assert account_mode.portal()["opened"] is True


# ================================================================ P24-08 Antwortform

@pytest.mark.parametrize("body", [b"", b"[]", b"{}", b"nicht json", b'{"url": 5}'])
def test_p24_08_bad_service_answers_are_502(svc, monkeypatch, body):
    from app import account_mode, service_link
    _set_link("konto-a")
    monkeypatch.setattr(service_link, "call", lambda *a, **k: (200, {}, body))
    with pytest.raises(account_mode.AccountModeError) as e:
        account_mode.checkout("plus", open_browser=False)
    assert (e.value.code, e.value.status) == ("stripe_error", 502)


# ================================================================ P24-01/09/10/03 Export am PC

def _user_file(file_id, name, local_path):
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id=?", (file_id,))
        conn.execute("""INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at,
                        first_seen, status, seen_by_user, kind, title) VALUES (?,'__user__',?,0,'application/pdf','Ich',0,'',?,?,?,
                        'gelesen',1,'pdf',?)""", (file_id, name, str(local_path), db.now_iso(), db.now_iso(), name))


@pytest.fixture
def export_env(svc, tmp_path, monkeypatch):
    from app import config, db
    monkeypatch.setattr("tempfile.tempdir", str(tmp_path / "tmp"))
    (tmp_path / "tmp").mkdir()
    own = config.data_dir() / "files" / "Eigene Dokumente"
    own.mkdir(parents=True, exist_ok=True)
    made = []
    yield own, tmp_path, made
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id LIKE 'audit24-%'")
    for p in made:
        Path(p).unlink(missing_ok=True)


def test_p24_01_10_export_only_takes_files_inside_the_data_folder(export_env):
    from app import account_mode, config
    own, tmp_path, made = export_env
    secret = tmp_path / "geheim.txt"
    secret.write_text("FREMD", encoding="utf-8")
    ok = own / "audit24-ok.pdf"
    ok.write_bytes(b"%PDF-1.4 eigen")
    link = own / "audit24-link.pdf"
    link.symlink_to(secret)
    made += [ok, link]
    assets = config.data_dir() / "assets"
    assets.mkdir(exist_ok=True)
    alink = assets / "audit24-asset-link.png"
    alink.symlink_to(secret)
    made.append(alink)
    _user_file("audit24-a", "Eigen.pdf", ok)
    _user_file("audit24-b", "Absolut.pdf", secret)                        # Pfad ausserhalb
    _user_file("audit24-c", "Traversal.pdf", own / ".." / ".." / ".." / secret.name)
    _user_file("audit24-d", "Link.pdf", link)                             # Symlink nach draussen
    _user_file("audit24-e", "..", ok)                                     # gefaehrlicher Name
    _user_file("audit24-f", "Eigen.pdf", ok)                              # Namenskollision
    p = account_mode.export_zip()
    try:
        z = zipfile.ZipFile(p)
        names = z.namelist()
        for n in names:
            assert b"FREMD" not in z.read(n), n
        assert "eigene-dateien/Eigen.pdf" in names
        own_names = [n for n in names if n.startswith("eigene-dateien/")]
        assert len(own_names) == len(set(own_names)) == 3, own_names
        for n in names:
            parts = n.split("/")
            assert ".." not in parts and "." not in parts and not n.startswith("/") and all(parts), n
        assert not any("asset-link" in n for n in names)
    finally:
        p.unlink(missing_ok=True)


def test_p24_03_failed_export_leaves_no_zip(export_env, monkeypatch):
    from app import account_mode
    _own, tmp_path, _made = export_env
    monkeypatch.setattr(account_mode, "_add_db", lambda *a, **k: (_ for _ in ()).throw(OSError("Platte voll")))
    with pytest.raises(OSError):
        account_mode.export_zip()
    assert not list((tmp_path / "tmp").glob("studinow-export-*")), "Temp-ZIP wird bei Fehler geloescht"


def test_p24_09_export_size_and_free_space_limits(export_env, monkeypatch):
    from app import account_mode
    _own, tmp_path, _made = export_env
    monkeypatch.setattr(account_mode, "export_max_bytes", lambda: 10)
    with pytest.raises(account_mode.AccountModeError) as e:
        account_mode.export_zip()
    assert (e.value.code, e.value.status) == ("export_too_large", 413)
    monkeypatch.setattr(account_mode, "export_max_bytes", lambda: 1 << 40)
    monkeypatch.setattr(account_mode, "_free_bytes", lambda p: 5)
    with pytest.raises(account_mode.AccountModeError) as e:
        account_mode.export_zip()
    assert (e.value.code, e.value.status) == ("disk_full", 507)
    assert not list((tmp_path / "tmp").glob("studinow-export-*"))
    from app.server import app
    st, _, body = asgi_call(app, "GET", "/api/app-account/export")
    assert st == 507 and json.loads(body)["code"] == "disk_full"
    assert not list((tmp_path / "tmp").glob("studinow-export-*"))


# ================================================================ P24-02 Zugriff auf den Export

def test_p24_02_pc_export_only_local_and_not_from_foreign_sites(svc):
    app = svc.app
    assert _hosted(app, "GET", "/api/app-account/export")[0] in (401, 404), "im Dienst ohne Anmeldung: nichts"
    _u, tok = _register(app, "pc-export-im-dienst@example.org")
    st, _ = _hosted(app, "GET", "/api/app-account/export", headers={"Authorization": f"Bearer {tok}"})
    assert st == 404, "im Dienst gibt es den PC-Export nicht, auch angemeldet"
    st, _, _ = asgi_call(app, "GET", "/api/app-account/export", client=("192.168.1.50", 5000))
    assert st == 401, "WLAN-Geraet ohne PIN"
    st, _, _ = asgi_call(app, "GET", "/api/app-account/export", client=("8.8.8.8", 5000))
    assert st == 403, "oeffentliche Adresse"
    for h in ({"Sec-Fetch-Site": "cross-site"}, {"Referer": "https://evil.example/"}, {"Origin": "https://evil.example"}):
        st, _, _ = asgi_call(app, "GET", "/api/app-account/export", headers=h)
        assert st == 403, h
    st, _, body = asgi_call(app, "GET", "/api/app-account/export", headers={"Sec-Fetch-Site": "same-origin", "Referer": "http://test/"})
    assert st == 200 and "LIESMICH.txt" in zipfile.ZipFile(io.BytesIO(body)).namelist()


def test_p24_02_service_export_is_per_account(svc):
    from app import config
    app = svc.app
    a, ta = _register(app, "export-a@example.org")
    b, tb = _register(app, "export-b@example.org")
    da = config.BASE_DATA_DIR / "users" / a["id"]
    db_ = config.BASE_DATA_DIR / "users" / b["id"]
    for d, txt in ((da, "NUR-A"), (db_, "NUR-B")):
        (d / "files").mkdir(parents=True, exist_ok=True)
        (d / "files" / "notiz.txt").write_text(txt, encoding="utf-8")
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, _, body = asgi_call(app, "GET", "/api/account/export", headers={"Authorization": f"Bearer {ta}"})
    finally:
        config.MODE = old
    assert st == 200
    z = zipfile.ZipFile(io.BytesIO(body))
    blob = b"".join(z.read(n) for n in z.namelist())
    assert b"NUR-A" in blob and b"NUR-B" not in blob
    assert _hosted(app, "GET", "/api/account/export")[0] == 401


# ================================================================ Dienst-Export: Symlinks und Aufraeumen

def test_service_export_skips_symlinks_and_cleans_up(svc, tmp_path, monkeypatch):
    from app import account_export, config
    app = svc.app
    u, _ = _register(app, "export-link@example.org")
    base = config.BASE_DATA_DIR / "users" / u["id"]
    (base / "files").mkdir(parents=True, exist_ok=True)
    secret = tmp_path / "server-geheim.txt"
    secret.write_text("SERVERGEHEIM", encoding="utf-8")
    (base / "files" / "link.txt").symlink_to(secret)
    (base / "files" / "eigen.txt").write_text("EIGEN", encoding="utf-8")
    monkeypatch.setattr("tempfile.tempdir", str(tmp_path))
    from app import accounts
    user = accounts.get_user(u["id"]) if hasattr(accounts, "get_user") else u
    p = account_export.build(user)
    try:
        z = zipfile.ZipFile(p)
        blob = b"".join(z.read(n) for n in z.namelist())
        assert b"EIGEN" in blob and b"SERVERGEHEIM" not in blob
    finally:
        p.unlink(missing_ok=True)
    monkeypatch.setattr(account_export, "_community", lambda *a, **k: (_ for _ in ()).throw(OSError("kaputt")))
    with pytest.raises(OSError):
        account_export.build(user)
    assert not list(tmp_path.glob("studora-export-*"))
