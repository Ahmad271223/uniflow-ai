"""Tests laufen auf einem eigenen Temp-Datenordner, nie auf data/lernapp.db."""
import asyncio
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="lernapp-test-")
os.environ["LERNAPP_DATA_DIR"] = str(Path(_TMP) / "data")
os.environ["LERNAPP_LOG_DIR"] = str(Path(_TMP) / "logs")
os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"        # Host-Kopfzeile der Test-Aufrufe
os.environ["LERNAPP_NO_SCHEDULER"] = "1"           # keine Hintergrund-Zeitplaene (app/weekly.py) in Tests
os.environ.setdefault("LERNAPP_OCR", "off")         # keine echte Texterkennung (tesseract) in Tests, nur Fake-Motoren (tests/test_pageocr.py)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

LASTTESTS = Path(__file__).with_name("lasttests.txt")


def lasttests() -> set[str]:
    """Eintraege aus tests/lasttests.txt als `datei.py::testname` (Kommentare und Leerzeilen weg)."""
    out = set()
    for line in LASTTESTS.read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            out.add(entry)
    return out


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(config, items):
    """Marker `last` fuer die Lasttests aus tests/lasttests.txt (eine Liste an einer Stelle statt Dekoratoren in vielen
    Dateien). tryfirst: der Marker muss stehen, bevor pytest `-m "not last"` auswertet. Ohne `-m` aendert das nichts:
    der Aufruf ohne Optionen laesst weiter alles laufen (docs/TESTLAEUFE.md)."""
    names = lasttests()
    for item in items:
        path = getattr(item, "path", None)
        if path is None or path.parent != LASTTESTS.parent:
            continue
        test = item.nodeid.split("::", 1)[-1].split("[", 1)[0]
        if f"{path.name}::{test}" in names:
            item.add_marker(pytest.mark.last)


def legacy_vault(user_id, values):
    """Altbestand im Tresor anlegen, wie ihn der Dienst bis 06.11.2026 schrieb (vault.set_values nimmt seitdem keine
    Werte mehr an). Nur fuer Tests von Aufraeumen, Export und Kontoloeschung."""
    from datetime import datetime, timezone

    from app import vault
    cm, conn = vault._conn()
    try:
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        for name, value in values.items():
            conn.execute("INSERT OR REPLACE INTO vault(user_id, name, value_enc, updated_at) VALUES (?,?,?,?)",
                         (user_id, name, vault.encrypt(user_id, str(value)), now))
    finally:
        cm.__exit__(None, None, None)
    vault._cache.pop(user_id, None)


def asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, cookies=None, headers=None, host="test",
              content_type="application/json", raw_path=False):
    """Minimaler ASGI-Aufruf ohne httpx; liefert (status, headers, body_bytes).
    Der Pfad wird wie bei uvicorn prozent-dekodiert (%5C -> Backslash), raw_path bleibt kodiert."""
    from urllib.parse import unquote
    p, _, q = path.partition("?")
    hdrs = [(b"host", host.encode()), (b"content-type", content_type.encode())]
    if cookies:
        hdrs.append((b"cookie", cookies.encode()))
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    raw = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else b"")
    hdrs.append((b"content-length", str(len(raw)).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": unquote(p), "raw_path": p.encode(), "query_string": q.encode(), "headers": hdrs,
             "client": client, "server": ("test", 80)}
    out = {"status": None, "headers": [], "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]; out["headers"] = m["headers"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")

    asyncio.run(app(scope, receive, send))
    return out["status"], out["headers"], out["body"]


@pytest.fixture(scope="session")
def app():
    from app import config
    assert str(config.DATA_DIR).startswith(_TMP), "Tests duerfen nie den echten Datenordner nutzen"
    from app.server import app as fastapi_app
    return fastapi_app


@pytest.fixture(autouse=True)
def _community_legacy_publish(monkeypatch):
    """Tests der Regeln rund um eine Loesung veroeffentlichen ohne Community; die Pflicht prueft test_community_groups.py."""
    from app import community
    monkeypatch.setattr(community, "LEGACY_PUBLISH", True)


@pytest.fixture(autouse=True)
def _ai_consent_off(monkeypatch):
    """Einwilligung vor der StudiNow-KI (app/ai_consent.py) gilt in den uebrigen Tests als erteilt; die Pflicht selbst
    prueft tests/test_ai_consent.py."""
    from app import ai_consent
    monkeypatch.setattr(ai_consent, "ENFORCE", False)


@pytest.fixture(autouse=True)
def _ai_prices(monkeypatch):
    """Im Dienst sperrt ai_backend.complete ohne Token-Preise (fail closed); die Tests setzen winzige Preise (Kosten
    runden auf 0), einzelne Tests ueberschreiben sie."""
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "0.001")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "0.001")


@pytest.fixture(autouse=True)
def _credit_kurs_bis_24_11(request, monkeypatch):
    """Die Rechen-Tests der Credits (Reservieren, Abrechnen, Erstatten, Pakete) rechnen mit festen Beispielzahlen des
    Kurses bis 24.11.2026: 1 Credit = 0,65 Cent, starke Modelle x1,3, Pro AI 100 Credits, Pakete 100/200. Seit 24.11.2026 gilt
    1 Credit = 1 Cent, kein Aufschlag, Pro AI 80, Pakete 80/160 (Entscheidung des Inhabers) - das pruefen tests/test_credit_kurs.py."""
    # Vertrag und Tarif-Antwort zeigen die echten Werte
    if any(k in request.node.nodeid for k in ("test_credit_kurs", "test_old_apps_see_the_same_fields_with_the_same_meaning",
                                               "test_credit_packs_fixture_is_current",
                                               "test_trial_is_plus_in_contract_fixture_and_credits", "test_plans_fixture_is_current",
                                               "test_allowance_per_plan_and_env", "test_tarife_credits_2026_11_26")):
        return
    from app import ai_prices
    monkeypatch.setattr(ai_prices, "MICROEUR_PER_CREDIT", 6_500)
    monkeypatch.setattr(ai_prices, "STRONG_CREDIT_FACTOR", 1.3)
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "100")
    from app import plans
    monkeypatch.setitem(plans.CREDITS, "pro_ai", 100)
    monkeypatch.setenv("LERNAPP_CREDIT_PACKS", "de.uniflow.credits.klein=100,de.uniflow.credits.gross=200")


@pytest.fixture(autouse=True)
def _no_leaked_job_runner():
    """Kein Job-Runner (app/jobs.py) darf einen Test ueberleben: ein vergessener Arbeiter-Thread holte unter Last die
    Jobs der folgenden Tests (test_qis_isolation: claim_next fand nichts, test_hosted_sync, test_retention). Uebrig
    gebliebene Runner werden angehalten, der verursachende Test meldet einen Fehler beim Abbau."""
    yield
    import threading
    leaked = [t for t in threading.enumerate() if t.name.startswith("uniflow-job-") or t.name == "uniflow-schedule"]
    if not leaked:
        return
    for t in leaked:
        runner = getattr(getattr(t, "_target", None), "__self__", None)
        if runner is not None and hasattr(runner, "_stop"):
            runner._stop.set()
    for t in leaked:
        t.join(30)
    pytest.fail(f"Job-Runner nach dem Test noch aktiv (angehalten): {sorted(t.name for t in leaked)}")


@pytest.fixture(autouse=True)
def _token_store_in_memory():
    """Sitzungs-Token des StudiNow-Kontos (app/token_store.py) je Test nur im Speicher: nie in einer Datei des
    Testordners, die der naechste Test faende, und nie in einer echten Anmeldeinformationsverwaltung."""
    from app import token_store
    token_store.use(token_store.MemoryStore())
    yield
    token_store.use(token_store.MemoryStore())
