"""Windows-App fertigstellen (12.11.2026, docs/WINDOWS-FERTIG-2026-11-12.md).

Befund: Der gehostete Dienst kennt "apple: true", aber keine Web-Kennung (`apple_web_client_id`). Der Knopf "Mit Apple
anmelden" der Windows-App fuehrte dann auf eine Anmeldeseite ohne Apple-Knopf. Die App fragt jetzt den Dienst, welche
Wege im Browser gehen (`GET /api/app-account/providers`), und zeigt sonst den Hinweis fuer Konten vom iPad.

Der "Dienst" ist dieselbe App im gehosteten Modus (ASGI, wie tests/test_account_mode.py); nichts geht ins Netz."""
import json
import re

from conftest import asgi_call
from test_account_mode import SERVICE, _local, svc  # noqa: F401 - Fixture `svc` (Windows-App + Dienst im selben Prozess)


def test_providers_without_any_provider(svc, monkeypatch):
    for k in ("LERNAPP_APPLE_CLIENT_IDS", "LERNAPP_APPLE_WEB_CLIENT_ID", "LERNAPP_GOOGLE_CLIENT_IDS", "LERNAPP_GOOGLE_WEB_CLIENT_ID"):
        monkeypatch.delenv(k, raising=False)
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert st == 200
    assert d == {"reachable": True, "apple": False, "google": False, "apple_browser": False, "google_browser": False,
                 "service_url": SERVICE}


def test_apple_for_the_ipad_only_is_not_offered_in_the_browser(svc, monkeypatch):
    """Stand des Dienstes am 12.11.2026: Bundle-ID eingetragen (iPad), Services-ID fehlt -> kein Apple-Knopf im Browser."""
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", "de.uniflow.ai")
    monkeypatch.delenv("LERNAPP_APPLE_WEB_CLIENT_ID", raising=False)
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert st == 200 and d["apple"] is True and d["apple_browser"] is False
    # genau das meldet die oeffentliche Seite des Dienstes (die Anmeldeseite blendet den Knopf danach ein oder aus)
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        s3, _, b3 = asgi_call(svc.app, "GET", "/api/account/providers")
    finally:
        config.MODE = old
    assert s3 == 200 and json.loads(b3)["apple"] is True and json.loads(b3)["apple_web_client_id"] is None


def test_apple_in_the_browser_needs_the_services_id(svc, monkeypatch):
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", "de.uniflow.ai")
    monkeypatch.setenv("LERNAPP_APPLE_WEB_CLIENT_ID", "de.uniflow.ai.web")
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert st == 200 and d["apple"] and d["apple_browser"] is True and d["google_browser"] is False


def test_google_needs_the_web_client_id_too(svc, monkeypatch):
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", "android-id")
    monkeypatch.delenv("LERNAPP_GOOGLE_WEB_CLIENT_ID", raising=False)
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert d["google"] is True and d["google_browser"] is False
    monkeypatch.setenv("LERNAPP_GOOGLE_WEB_CLIENT_ID", "web-id")
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert d["google_browser"] is True


def test_providers_when_the_service_is_not_reachable(svc):
    """Ohne Netz kein Raten: die Oberflaeche zeigt dann wie bisher beide Knoepfe (socialState in account-gate.js)."""
    svc.offline = True
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert st == 200 and d["reachable"] is False and d["apple_browser"] is False and d["google_browser"] is False


def test_providers_are_open_while_signed_out(svc):
    """Der Anmeldebildschirm fragt, bevor jemand angemeldet ist (app/account_mode.py ALWAYS_OPEN)."""
    st, d = _local(svc.app, "GET", "/api/app-account/status")
    assert d["state"] == "signed_out"
    st, d = _local(svc.app, "GET", "/api/app-account/providers")
    assert st == 200


def test_providers_do_not_exist_in_the_service(app):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, _, _ = asgi_call(app, "GET", "/api/app-account/providers")
    finally:
        config.MODE = old
    assert st in (401, 404)           # im Dienst: nie die Windows-Seite (ohne Sitzung gilt 401)


# ---------------------------------------------------------------- Tarifanzeige in der Probe

def test_community_card_shows_the_plan_the_pc_really_works_with(svc):
    """Befund 12.11.2026: `GET /api/studora/status` lieferte den gespeicherten Kontotarif "free", die Karte zeigte
    "StudiNow Free" mitten in der Probe (Rechte wie Pro AI). Jetzt kommt der wirksame Tarif dazu."""
    from test_account_mode import _end_trial, _login, _register
    user, _tok = _register(svc.app, "probe@example.org")
    _login(svc.app, "probe@example.org")
    st, d = _local(svc.app, "GET", "/api/studora/status?refresh=false")
    assert st == 200 and d["linked"] and d["user"]["plan"] == "free"
    assert d["effective_plan"] == "pro_ai" and d["trial"] is True
    # nach der Probe ohne Abo: gesperrt, kein wirksamer Tarif (die Karte faellt auf den Kontotarif zurueck)
    _end_trial(user["id"])
    from app import account_mode
    account_mode.refresh()
    st, d = _local(svc.app, "GET", "/api/studora/status?refresh=false")
    assert d["effective_plan"] is None and d["trial"] is False


def test_card_js_uses_the_effective_plan():
    from pathlib import Path
    js = (Path(__file__).resolve().parent.parent / "app" / "static" / "studora-link.js").read_text(encoding="utf-8")
    assert "st.effective_plan || u.plan" in js and '(Probe)' in js


# ---------------------------------------------------------------- Abgleich: Stand des eigenen Abrufs bleibt am Geraet

def test_own_fetch_state_stays_on_the_device():
    from app import sync_client
    for k in ("studip_bulletin_fetched_at", "studip_bulletin_fetched_at_v2", "studip_blubber_fetched_at", "studip_blubber_activity"):
        assert sync_client._setting_local(k), k
    for shared in ("study_plan", "exam_dates_auto", "certificates", "studip_bulletin_fetched_at_v3", "studip_blubber",
                   "x_studip_blubber_activity", "studip_bulletin_activity"):
        assert not sync_client._setting_local(shared), shared


def test_the_list_the_mac_test_reads_is_unchanged():
    """Die Mac-Seite (DeviceSyncLocalSettingsTests.swift) liest `LOCAL_SETTINGS = {...}` aus sync_client.py und erwartet
    genau zehn Schluessel; die Erweiterung steht darum in einer eigenen Menge."""
    import re
    from pathlib import Path
    src = (Path(__file__).resolve().parent.parent / "app" / "sync_client.py").read_text(encoding="utf-8")
    start = src.index("LOCAL_SETTINGS = {")
    body = src[start + len("LOCAL_SETTINGS = {"):src.index("}", start)]
    assert len(re.findall(r'"([^"]+)"', body)) == 10


# ---------------------------------------------------------------- Bild importieren (Pillow)

def _png(w=40, h=30) -> bytes:
    import struct
    import zlib
    raw = b"".join(b"\x00" + b"\x20\x80\xff" * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def test_imported_image_becomes_a_real_pdf_page(app):
    """Befund 12.11.2026: ohne Pillow legte der Import ein Dokument "Name.pdf" an, dessen Datei ein PNG war (Editor und
    Vorschau konnten es nicht oeffnen). Mit Pillow in requirements.txt wird jedes Bild eine PDF-Seite."""
    import io

    from pypdf import PdfReader
    from test_security import _multipart
    body, ctype = _multipart("upload", "foto.png", _png(), {"kind": "image", "title": "Foto"})
    st, _, b = asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype)
    assert st == 200, b[:200]
    f = json.loads(b)
    assert f["page_count"] == 1 and f["mime"] == "application/pdf" and f["local_path"].endswith(".pdf")
    st, _, content = asgi_call(app, "GET", f"/api/files/{f['id']}/content")
    assert st == 200 and content.startswith(b"%PDF"), "die gelieferte Datei ist wirklich eine PDF"
    assert len(PdfReader(io.BytesIO(content)).pages) == 1


def test_pillow_is_pinned_in_the_requirements():
    from pathlib import Path
    req = (Path(__file__).resolve().parent.parent / "requirements.txt").read_text(encoding="utf-8")
    assert re.search(r"^Pillow==\d+\.\d+\.\d+\s*$", req, re.M)
    spec = (Path(__file__).resolve().parent.parent / "apps" / "windows" / "backend" / "uniflow-backend.spec").read_text(encoding="utf-8")
    assert '"PIL.Image"' in spec


# ---------------------------------------------------------------- Domain-Bestaetigung fuer "Mit Apple anmelden" im Browser

def _hosted_get(app, path):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        return asgi_call(app, "GET", path)
    finally:
        config.MODE = old


def test_apple_domain_association_file_is_served_only_when_the_owner_put_it_there(app):
    from app import config
    path = "/.well-known/apple-developer-domain-association.txt"
    target = config.BASE_DATA_DIR / "apple-developer-domain-association.txt"
    target.unlink(missing_ok=True)
    assert _hosted_get(app, path)[0] == 404, "ohne Datei nichts"
    target.write_bytes(b"MEIN-APPLE-NACHWEIS\n")
    try:
        st, h, b = _hosted_get(app, path)                    # oeffentlich: Apple fragt ohne Anmeldung
        assert st == 200 and b == b"MEIN-APPLE-NACHWEIS\n"
        assert dict((k.decode(), v.decode()) for k, v in h)["content-type"].startswith("text/plain")
        assert asgi_call(app, "GET", path)[0] == 404, "am eigenen PC gibt es sie nicht"
        target.write_bytes(b"x" * ((64 << 10) + 1))
        assert _hosted_get(app, path)[0] == 404, "zu gross: nicht ausliefern"
    finally:
        target.unlink(missing_ok=True)
