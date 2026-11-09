"""ASGI-Einstieg NUR fuer Lasttests (tools/lasttest-ki.py, tools/lasttest-dauer.py, tools/lasttest-server.sh), 09.11.2026.

Der Dienst nimmt im gehosteten Modus als LERNAPP_OPENAI_BASE_URL nur https://api.openai.com an (Audit P7-03,
app/ai_backend.check_openai_base_url) - richtig fuer den Betrieb, aber der Lasttest fragt die Attrappe
tools/lasttest-ki-anbieter.py auf http://127.0.0.1:<port>/v1. Dieses Modul laesst zusaetzlich GENAU diese
Loopback-Adressen zu (http, Host 127.0.0.1 oder localhost) und startet sonst die unveraenderte App:

    uvicorn lasttest_dienst:app --app-dir tools        (Arbeitsordner = Repo-Wurzel bzw. /srv/uniflow im Container)

Liegt nicht im Image (.dockerignore laesst tools/ aus) und wird im Betrieb nie geladen.
"""
from __future__ import annotations

from urllib.parse import urlparse

from app import ai_backend

LOOPBACK = ("127.0.0.1", "localhost")
_strict = getattr(ai_backend, "check_openai_base_url", None)


def _check_openai_base_url(url: str) -> str:
    u = urlparse(url)
    if u.scheme == "http" and (u.hostname or "").lower() in LOOPBACK:
        return url
    return _strict(url) if _strict else url


if _strict is not None:
    ai_backend.check_openai_base_url = _check_openai_base_url

from app.server import app  # noqa: E402,F401
