"""Absturzmeldungen der Apple-Apps (app/crash_reports.py, docs/ABSTURZMELDUNG-2026-11-25.md): Annahme ohne Konto,
was gespeichert wird und was nie, Grenzen je Geraet und Tag, Aufbewahrung, Auswertung.

Der Durchlauf "Geraet -> Dienst -> Auswertung" haengt an `packages/shared-contracts/fixtures/crash-report/`:
die Swift-Tests (CrashReportTests) pruefen, dass die App aus Apples Daten genau `upload.json` baut; hier nimmt der
Dienst genau diese Datei an und die Auswertung zaehlt daraus. Alle Daten sind erfunden.
"""
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "packages" / "shared-contracts" / "fixtures" / "crash-report"
NOW = datetime(2026, 11, 25, 12, 0, tzinfo=timezone.utc)
INSTALL = "0123456789abcdef0123456789abcdef"
PATH = "/api/diagnose/crashes"


def upload() -> dict:
    return json.loads((FIXTURES / "upload.json").read_text(encoding="utf-8"))


def report(n: int, **over) -> dict:
    """Eine erfundene Absturzmeldung mit der Kennung `n`."""
    base = {"id": f"{n:032x}", "kind": "crash", "at": "2026-11-25T09:00:00Z", "app_version": "1.0.7", "app_build": "49",
            "device_class": "iphone", "device_model": "iPhone17,1", "os_version": "iPhone OS 27.1 (24B83)", "channel": "store",
            "signal": 11, "frames": [{"b": "UniFlow", "o": 4096, "u": "70B89F27-1634-3580-A695-57CDB41D7743"}]}
    base.update(over)
    return base


def body(*reports, install=INSTALL) -> dict:
    return {"v": 1, "install": install, "reports": list(reports)}


def post(app, payload, client=("203.0.113.9", 5000)):
    st, headers, raw = asgi_call(app, "POST", PATH, body=json.dumps(payload), client=client)
    return st, (json.loads(raw) if raw else None), {k.decode().lower(): v.decode() for k, v in headers}


def rows() -> list[dict]:
    from app import crash_reports
    with crash_reports.cursor() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM crash_reports ORDER BY id")]


@pytest.fixture
def hosted(app, monkeypatch):
    """Gehosteter Modus mit leerer Kontodatenbank; die Uhr des Dienstes steht auf NOW (Fixture-Daten sind vom Vortag)."""
    from app import accounts, config, vault
    monkeypatch.setattr(config, "MODE", "hosted")

    from app import crash_reports

    def wipe():
        for p in (accounts.db_path(), crash_reports.db_path()):          # seit 27.11.2026 eigene Datei crash_reports.db
            for suffix in ("", "-wal", "-shm"):
                p.with_name(p.name + suffix).unlink(missing_ok=True)
    wipe()
    vault.reset_master()
    monkeypatch.setattr(accounts, "now", lambda: NOW)
    yield app
    wipe()
    vault.reset_master()


# ---------------------------------------------------------------- Durchlauf: Meldung der App -> Dienst -> Auswertung

def test_upload_of_the_app_reaches_the_summary(hosted):
    from app import crash_reports
    st, data, headers = post(hosted, upload())
    assert (st, data) == (200, {"ok": True, "stored": 5, "duplicates": 0, "dropped": 0})
    assert headers.get("cache-control") == "no-store"

    s = crash_reports.summary(days=14, now=NOW)
    assert (s["crashes"], s["hangs"]) == (2, 1)
    assert [(r["day"], r["version"], r["device"], r["source"], r["crashes"], r["hangs"], r["devices"]) for r in s["rows"]] == [
        ("2026-11-24", "1.0.6 (45)", "ipad", "store", 1, 1, 1),
        ("2026-11-24", "1.0.5 (44)", "ipad", "test", 1, 0, 1),
    ]
    assert s["rows"][0]["models"] == ["iPad14,3"]
    assert {(e["day"], e["version"], e["reason"]): e["count"] for e in s["exits"]} == {
        ("2026-11-24", "1.0.6 (45)", "memory_limit"): 2, ("2026-11-24", "1.0.6 (45)", "bad_access"): 1}
    assert {p["place"]: p["count"] for p in s["top"]} == {
        "UniFlow+0x285b8 (SIGSEGV)": 1, "UniFlow+0x32000 (NSInvalidArgumentException)": 1, "UniFlow+0x1000 (Hänger)": 1}

    only_store = crash_reports.summary(days=14, now=NOW, channel="store")
    assert (only_store["crashes"], only_store["hangs"]) == (1, 1)

    text = crash_reports.text(s)
    assert "Zusammen: 2 Abstürze, 1 Hänger." in text
    assert "2026-11-24  1.0.6 (45)  iPad" in text and "App Store" in text and "Speicher voll" in text
    assert "€" not in text and "Cent" not in text


def test_summary_tool_prints_the_numbers(hosted, monkeypatch, capsys):
    """Das Werkzeug (tools/absturz-auswertung.py ruft crash_reports.main) zeigt dieselben Zahlen, auch als JSON."""
    from app import crash_reports
    assert post(hosted, upload())[0] == 200
    assert crash_reports.main(["--tage", "14"]) == 0
    out = capsys.readouterr().out
    assert "Abstürze von 2026-11-12 bis 2026-11-25 (14 Tage)" in out and "Zusammen: 2 Abstürze, 1 Hänger." in out
    assert crash_reports.main(["--tage", "14", "--quelle", "store", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["crashes"] == 1
    tool = (ROOT / "tools" / "absturz-auswertung.py").read_text(encoding="utf-8")
    assert "from app.crash_reports import main" in tool


def test_summary_without_reports_says_so(hosted):
    from app import crash_reports
    text = crash_reports.text(crash_reports.summary(days=7, now=NOW))
    assert "Keine Meldungen in diesem Zeitraum." in text


# ---------------------------------------------------------------- was gespeichert wird - und was nie

def test_nothing_personal_is_stored(hosted):
    """Kein Konto, keine IP, keine Installations-Kennung; unbekannte Felder und der Text einer Ausnahme fallen weg."""
    r = report(1, email="max@beispiel.de", user_id="abc", exception_message="Datei „Klausur Mathe Müller.pdf“ nicht gefunden",
               termination="Namespace SIGNAL, Code 11 <Müller.pdf> \"x\"", exception_name="NSException mit Text und Leerzeichen",
               device_model="iPhone17,1; drop table", os_version="iPhone OS 27.1 (24B83)\n<script>",
               frames=[{"b": "UniFlow", "o": 4096, "u": "kein-uuid", "symbol": "geheim()", "file": "/Users/max/Mathe.pdf"},
                       {"b": "Uni<Flow>", "o": 12}, {"b": "ohne-abstand"}, "kein-objekt"])
    st, data, _ = post(hosted, body(r), client=("198.51.100.77", 4000))
    assert (st, data["stored"]) == (200, 1)
    (row,) = rows()
    assert set(row) == {"id", "received_at", "received_day", "device_day", "kind", "happened_at", "day", "app_version", "app_build",
                        "device_class", "device_model", "os_version", "channel", "signal", "exception_type", "exception_code",
                        "termination", "exception_name", "hang_seconds", "reason", "count", "frames"}
    assert row["termination"] == "Namespace SIGNAL, Code 11 Mller.pdf x"        # nur harmlose Zeichen
    assert row["exception_name"] is None and row["device_model"] is None
    assert row["os_version"] == "iPhone OS 27.1 (24B83)script"
    assert json.loads(row["frames"]) == [{"b": "UniFlow", "o": 4096}, {"b": "UniFlow", "o": 12}]
    assert row["device_day"] != INSTALL and len(row["device_day"]) == 32
    blob = json.dumps(row, ensure_ascii=False)
    for secret in (INSTALL, "198.51.100.77", "max@beispiel.de", "Müller", "geheim", "/Users/max", "abc\""):
        assert secret not in blob, secret
    # auch sonst steht die Kennung der Installation nirgends in accounts.db (nur ihr Tages-HMAC)
    from app import accounts
    conn = sqlite3.connect(accounts.db_path())
    try:
        for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
            dump = json.dumps(conn.execute(f"SELECT * FROM {table}").fetchall(), default=str)
            assert INSTALL not in dump, table
            if table != "rate_limits":                      # die IP steht nur im Zaehler je Adresse (hoechstens 2 Tage)
                assert "198.51.100.77" not in dump, table
    finally:
        conn.close()


def test_device_day_key_changes_every_day(hosted):
    """Die Tages-Marke verkettet keine Tage: gleiches Geraet, anderer Tag -> anderer Wert; anderes Geraet -> anderer Wert."""
    from app import crash_reports
    a = crash_reports.device_day_key(INSTALL, "2026-11-24")
    assert a == crash_reports.device_day_key(INSTALL, "2026-11-24")
    assert a != crash_reports.device_day_key(INSTALL, "2026-11-25")
    assert a != crash_reports.device_day_key("f" * 32, "2026-11-24")


def test_devices_are_counted_per_day(hosted):
    """Zwei Geraete mit je einem Absturz am selben Tag: 2 Abstuerze auf 2 Geraeten; drei von einem: 3 auf 1."""
    from app import crash_reports
    assert post(hosted, body(report(1), report(2), report(3)))[0] == 200
    assert post(hosted, body(report(4), install="a" * 32))[0] == 200
    (row,) = crash_reports.summary(days=3, now=NOW)["rows"]
    assert (row["crashes"], row["devices"], row["device"], row["version"]) == (4, 2, "iphone", "1.0.7 (49)")


# ---------------------------------------------------------------- doppelt, ungueltig, zu alt

def test_same_report_twice_is_stored_once(hosted):
    assert post(hosted, body(report(1), report(2)))[1]["stored"] == 2
    st, data, _ = post(hosted, body(report(1), report(2), report(3)))
    assert (st, data["stored"], data["duplicates"]) == (200, 1, 2)
    assert len(rows()) == 3


@pytest.mark.parametrize("bad", [
    {"id": "kurz"}, {"kind": "panic"}, {"at": "gestern"}, {"at": "2026-11-25T09:00:00"}, {"app_version": "x' OR 1=1"},
    {"device_class": "toaster"}, {"at": "2026-09-01T09:00:00Z"}, {"at": "2026-12-24T09:00:00Z"},
    {"kind": "exit"}, {"kind": "exit", "reason": "erfunden", "count": 3}, {"kind": "exit", "reason": "memory_limit", "count": 0},
])
def test_invalid_reports_are_dropped_not_stored(hosted, bad):
    st, data, _ = post(hosted, body(report(1, **bad), report(2)))
    assert (st, data["stored"], data["dropped"]) == (200, 1, 1), data
    assert [r["id"] for r in rows()] == [f"{2:032x}"]


@pytest.mark.parametrize("payload", [
    {}, {"v": 2, "install": INSTALL, "reports": [report(1)]}, {"v": 1, "install": "nicht-hex", "reports": [report(1)]},
    {"v": 1, "install": INSTALL, "reports": []}, {"v": 1, "install": INSTALL, "reports": "viele"},
    {"v": 1, "install": INSTALL, "reports": [report(i) for i in range(1, 22)]},
])
def test_malformed_request_is_refused(hosted, payload):
    st, data, _ = post(hosted, payload)
    assert (st, data["code"]) == (400, "invalid_input"), data
    assert rows() == []


def test_request_body_is_limited(hosted):
    """Der oeffentliche Pfad nimmt hoechstens 64 KB an (PUBLIC_BODY_LIMITS)."""
    big = body(report(1, termination="x" * 70_000))
    st, _, raw = asgi_call(hosted, "POST", PATH, body=json.dumps(big))
    assert st == 413 and b"too_large" in raw
    assert rows() == []


# ---------------------------------------------------------------- Grenzen

def test_limit_per_device_and_day(hosted, monkeypatch):
    from app import crash_reports
    monkeypatch.setattr(crash_reports, "DEVICE_DAY_LIMIT", 5)
    st, data, _ = post(hosted, body(*(report(i) for i in range(1, 5))))
    assert (st, data["stored"], data["dropped"]) == (200, 4, 0)
    st, data, _ = post(hosted, body(*(report(i) for i in range(5, 9))))
    assert (st, data["stored"], data["dropped"]) == (200, 1, 3)             # nur noch eine bis zur Grenze
    assert post(hosted, body(report(20)))[1] == {"ok": True, "stored": 0, "duplicates": 0, "dropped": 1}
    # ein anderes Geraet ist nicht betroffen, und am naechsten Tag geht es wieder
    assert post(hosted, body(report(30), install="b" * 32))[1]["stored"] == 1
    from app import accounts
    monkeypatch.setattr(accounts, "now", lambda: NOW + timedelta(days=1))
    assert post(hosted, body(report(40, at="2026-11-26T09:00:00Z")))[1]["stored"] == 1


def test_limit_for_all_devices_per_day(hosted, monkeypatch):
    from app import crash_reports
    monkeypatch.setattr(crash_reports, "DAY_TOTAL", 3)
    assert post(hosted, body(report(1), report(2)))[1]["stored"] == 2
    # 27.11.2026 (Sicherheitspruefung): passt ein Paket nicht mehr in den Tag, heisst es "spaeter" (503 + Retry-After) statt
    # still verwerfen - die App behaelt dann alle Meldungen und sendet spaeter (CrashReportClient: nur 200/400/413/422 sind endgueltig)
    st, data, headers = post(hosted, body(report(3), report(4), install="c" * 32))
    assert (st, data["code"]) == (503, "busy") and int(headers["retry-after"]) > 0
    assert len(rows()) == 2, "nichts halb gespeichert"
    assert post(hosted, body(report(3), install="c" * 32))[1]["stored"] == 1, "was noch passt, geht"


def test_reports_live_in_their_own_file_and_move_over_once(hosted):
    """27.11.2026: eigene Datei crash_reports.db (eine Flut haelt nie die Schreibsperre von accounts.db); Meldungen aus
    der frueheren Tabelle in accounts.db kommen einmal herueber."""
    import sqlite3
    from app import accounts, crash_reports
    with accounts.cursor() as conn:
        crash_reports.ensure_schema(conn)
        conn.execute("INSERT INTO crash_reports(id, received_at, received_day, device_day, kind, happened_at, day, app_version, device_class) "
                     "VALUES ('alt-1', '2026-11-25T10:00:00+00:00', '2026-11-25', 'x', 'hang', '2026-11-25T09:00:00+00:00', '2026-11-25', '1.0.8', 'ipad')")
    assert post(hosted, body(report(1)))[1]["stored"] == 1
    assert crash_reports.db_path().exists() and crash_reports.db_path() != accounts.db_path()
    ids = {r["id"] for r in rows()}
    assert "alt-1" in ids and len(ids) == 2, ids
    with sqlite3.connect(accounts.db_path()) as c:
        assert c.execute("SELECT COUNT(*) FROM crash_reports").fetchone()[0] == 0, "in accounts.db nichts doppelt"


def test_limit_per_ip(hosted, monkeypatch):
    monkeypatch.setenv("LERNAPP_LIMIT_CRASH_IP", "2/60")
    assert post(hosted, body(report(1)))[0] == 200
    assert post(hosted, body(report(2)))[0] == 200
    st, data, headers = post(hosted, body(report(3)))
    assert (st, data["code"]) == (429, "rate_limited") and int(headers["retry-after"]) > 0
    assert post(hosted, body(report(4)), client=("203.0.113.10", 5000))[0] == 200    # andere Adresse geht
    assert len(rows()) == 3


# ---------------------------------------------------------------- ohne Konto, nur im Dienst, Aufbewahrung

def test_works_without_session_and_only_this_path_is_public(hosted):
    from app import crash_reports
    assert crash_reports.PUBLIC == {PATH}
    assert post(hosted, body(report(1)))[0] == 200                           # ohne Anmeldung
    assert asgi_call(hosted, "GET", PATH)[0] in (404, 405)                    # nur POST: nichts zum Lesen
    assert asgi_call(hosted, "GET", "/api/diagnose/crashes/stats")[0] == 401  # nichts zum Lesen ueber das Netz


def test_not_available_outside_the_hosted_service(app):
    """Am PC (LERNAPP_MODE local) gibt es keinen Sammelpunkt: 501 not_hosted, nichts wird angelegt."""
    st, _, raw = asgi_call(app, "POST", PATH, body=json.dumps(body(report(1))))
    assert st == 501 and b"not_hosted" in raw


def test_old_reports_are_purged_by_retention(hosted, monkeypatch):
    from app import accounts, crash_reports, retention
    assert post(hosted, body(report(1)))[1]["stored"] == 1
    later = NOW + timedelta(days=crash_reports.KEEP_DAYS - 1)
    assert retention.purge_account_db(later, dry_run=True)["crash_reports"] == 0
    much_later = NOW + timedelta(days=crash_reports.KEEP_DAYS + 1)
    assert retention.purge_account_db(much_later, dry_run=True)["crash_reports"] == 1
    assert len(rows()) == 1                                                   # Probelauf loescht nichts
    assert retention.purge_account_db(much_later)["crash_reports"] == 1
    assert rows() == []
    monkeypatch.setattr(accounts, "now", lambda: much_later)


def test_columns_are_added_to_an_older_table(hosted):
    """Eine Tabelle aus einem frueheren Stand (nur die Grundspalten) bekommt die fehlenden Spalten nachgetragen."""
    from app import accounts, crash_reports
    with accounts.cursor() as conn:
        conn.executescript(crash_reports.SCHEMA)
        before = {r[1] for r in conn.execute("PRAGMA table_info(crash_reports)")}
        assert "frames" not in before and "signal" not in before
        crash_reports.ensure_schema(conn)
        crash_reports.ensure_schema(conn)                                     # wiederholbar
        after = {r[1] for r in conn.execute("PRAGMA table_info(crash_reports)")}
    assert after == before | {c for c, _ in crash_reports.COLUMNS}


# ---------------------------------------------------------------- Aufrufkette lesen

def test_call_chain_is_read_with_the_crash_site_first():
    from app import crash_reports
    inner_first = [{"b": "libsystem_kernel.dylib", "o": 1}, {"b": "UniFlow", "o": 0x2000}, {"b": "UniFlow", "o": 0x1000},
                   {"b": "(...)", "o": 40}, {"b": "dyld", "o": 9}]
    row = {"kind": "crash", "signal": 6, "frames": json.dumps(inner_first)}
    assert crash_reports.signature(row) == "UniFlow+0x2000 (SIGABRT)"
    # andersherum geliefert (Programmstart vorn): beim Lesen gedreht, dieselbe Stelle
    row["frames"] = json.dumps(list(reversed(inner_first)))
    assert crash_reports.signature(row) == "UniFlow+0x2000 (SIGABRT)"
    assert crash_reports.signature({"kind": "crash", "signal": 99, "frames": None}) == "ohne Aufrufkette (Signal 99)"
    assert crash_reports.signature({"kind": "crash", "frames": json.dumps([{"b": "SwiftUI", "o": 255}])}) == "SwiftUI+0xff"


def test_module_runs_as_a_script(hosted):
    """`python -m app.crash_reports --help` (so ruft der Betrieb es im Container auf) startet ohne Fehler."""
    out = subprocess.run([sys.executable, "-m", "app.crash_reports", "--help"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0 and "--tage" in out.stdout
