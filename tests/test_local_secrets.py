"""Verschluesselte Geheimnisse in der .env der Windows-App (app/local_secrets.py, 08.11.2026): Passwoerter, Cookies und
Schluessel nie im Klartext, Lesen entschluesselt, Altbestand wird beim Start umgestellt, Oberflaeche sieht die Ablageart.
DPAPI selbst laeuft nur auf echtem Windows (Windows-Workflow), hier der Dateischluessel-Weg."""
import json
import sys

import pytest
from conftest import asgi_call

from app import config, local_secrets as ls


@pytest.fixture
def env(monkeypatch, tmp_path):
    """Eigene .env und eigener Schluessel je Test; Schreiben verschluesselt wie in der Windows-App."""
    monkeypatch.setenv("LERNAPP_ENV_FILE", str(tmp_path / ".env"))
    monkeypatch.setenv(ls.ENV_FLAG, "1")
    monkeypatch.setattr(ls, "key_path", lambda: tmp_path / "local-secrets.key")
    monkeypatch.setattr(config, "MODE", "local")
    ls.reset_cache()
    yield tmp_path
    ls.reset_cache()


def test_roundtrip_prefix_and_garbage(env):
    assert ls.backend() == ("dpapi" if sys.platform == "win32" else "local")
    p = ls.protect("geheim-ä€")
    assert p.startswith(ls.PREFIXES) and "geheim" not in p and ls.is_protected(p)
    assert ls.unprotect(p) == "geheim-ä€"
    assert ls.protect(p) == p, "idempotent"
    assert ls.protect("") == "" and ls.unprotect("klartext") == "klartext"
    assert ls.unprotect(ls.LOCAL_PREFIX + "AAAA") == "", "nicht entschluesselbar -> leer, kein Absturz"
    assert (env / "local-secrets.key").exists()
    assert ls.is_secret_key("QIS_PASSWORD") and ls.is_secret_key("STUDIP_COOKIES") and ls.is_secret_key("LEARNWEB_TOKEN")
    assert not ls.is_secret_key("UNIVERSITY") and not ls.is_secret_key("QIS_USER")


def test_set_env_writes_no_plaintext_and_reads_it_back(env):
    config.set_env({"QIS_USER": "ab12", "QIS_PASSWORD": "qis-geheim-1", "UNIVERSITY": "luh"})
    config.save_credentials("luh-id", "sso-geheim-2")
    raw = (env / ".env").read_text(encoding="utf-8")
    assert "qis-geheim-1" not in raw and "sso-geheim-2" not in raw
    assert 'QIS_USER="ab12"' in raw and 'UNIVERSITY="luh"' in raw, "Nicht-Geheimnisse bleiben lesbar"
    assert config.service_credentials("QIS") == ("ab12", "qis-geheim-1")
    assert config.credentials() == ("luh-id", "sso-geheim-2")
    assert config.service_status("QIS")["own"] is True
    # Loeschen entfernt die Zeile
    config.set_env({"QIS_PASSWORD": None})
    assert "QIS_PASSWORD" not in (env / ".env").read_text(encoding="utf-8")


def test_plain_mode_in_development(env, monkeypatch):
    monkeypatch.setenv(ls.ENV_FLAG, "0")
    config.set_env({"QIS_PASSWORD": "offen"})
    assert 'QIS_PASSWORD="offen"' in (env / ".env").read_text(encoding="utf-8")
    assert ls.storage_label() == "plain" and ls.migrate_env_file(env / ".env") == 0
    monkeypatch.delenv(ls.ENV_FLAG)
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    assert ls.encrypt_on_write(), "Windows-App verschluesselt immer"


def test_migration_encrypts_old_plaintext_once(env):
    (env / ".env").write_text("# Kommentar\nUNIVERSITY=luh\nSTUDIP_USER=luh-id\nSTUDIP_PASSWORD=alt-geheim\nQIS_USER=ab\nQIS_PASSWORD=\"qis geheim\"\nLEARNWEB_TOKEN=abcdef\n", encoding="utf-8")
    assert ls.migrate_env_file(env / ".env") == 3
    raw = (env / ".env").read_text(encoding="utf-8")
    assert "alt-geheim" not in raw and "qis geheim" not in raw and "abcdef" not in raw
    assert raw.startswith("# Kommentar\nUNIVERSITY=luh\nSTUDIP_USER=luh-id\n") and "QIS_USER=ab\n" in raw, "andere Zeilen unveraendert"
    assert config.credentials() == ("luh-id", "alt-geheim") and config.service_credentials("QIS") == ("ab", "qis geheim")
    assert config.secret("LEARNWEB_TOKEN") == "abcdef"
    assert ls.migrate_env_file(env / ".env") == 0, "zweiter Lauf: nichts mehr zu tun"


def test_credentials_endpoint_reports_the_storage(app, env):
    st, _, body = asgi_call(app, "GET", "/api/credentials")
    d = json.loads(body)
    assert st == 200 and d["storage"] == ls.backend() and d["password_set"] is False
    st, _, body = asgi_call(app, "PUT", "/api/credentials", body=json.dumps({"user": "luh-id", "password": "pw-geheim"}))
    assert st == 200
    assert "pw-geheim" not in (env / ".env").read_text(encoding="utf-8")
    st, _, body = asgi_call(app, "GET", "/api/credentials")
    d = json.loads(body)
    assert d == {"user": "luh-id", "password_set": True, "storage": ls.backend()}


@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI gibt es nur unter Windows (laeuft im Windows-Workflow)")
def test_dpapi_roundtrip_on_windows(env):
    p = ls.protect("windows-geheim")
    assert p.startswith(ls.DPAPI_PREFIX) and ls.unprotect(p) == "windows-geheim"
