"""Erzeugt packages/shared-contracts/fixtures/learnweb/launch.json: Hochschul-Anmeldung auf dem Geraet (Android/iPad)
aus der Python-Referenz - Anmeldeprofile je Hochschule (Startseite, Pruef-Adresse, Sitzungscookie, erlaubte Hosts),
Moodle-App-Anmeldung (launch.php: Startadresse, Token aus der Rueckleitung mit Signaturpruefung) und die Form des
Downloads mit Schluessel (Schluessel im POST-Koerper, nie in der Adresse).
Aufruf im Projektordner: python tools/gen-learnweb-fixture.py [--check]
"""
from __future__ import annotations

import base64
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "learnweb" / "launch.json"


def _token_redirect(scheme: str, base: str, passport: str, token: str, private: str | None = None, bad_sig: bool = False) -> str:
    sig = hashlib.md5((("x" if bad_sig else "") + base.rstrip("/") + passport).encode()).hexdigest()  # noqa: S324 - Moodle-Format
    text = sig + ":::" + token + (":::" + private if private else "")
    return f"{scheme}://token=" + base64.b64encode(text.encode()).decode()


def build() -> dict:
    sys.path.insert(0, str(ROOT))
    from app import learnweb, studip_sync, universities
    luh_base = studip_sync.STUDIP_BASE
    lw_base = universities.LEARNWEB_BASE
    profiles = {
        "luh": {"name": "Leibniz Universität Hannover", "login_url": studip_sync.LOGIN_URL,
                "logged_in_check_url": f"{luh_base}/jsonapi.php/v1/users/me", "session_cookie": "Seminar_Session",
                "hosts": ["studip.uni-hannover.de", "sso.idm.uni-hannover.de", "login.uni-hannover.de"],
                "file_host": "studip.uni-hannover.de", "learnweb_base": None, "cas_base": None},
        "hildesheim": {"name": "Universität Hildesheim", "login_url": f"{lw_base}/login/index.php?authCAS=CAS",
                       "logged_in_check_url": f"{lw_base}/my/", "session_cookie": "MoodleSession",
                       "hosts": ["www.uni-hildesheim.de", "lsf.uni-hildesheim.de"], "file_host": "www.uni-hildesheim.de",
                       "learnweb_base": lw_base, "cas_base": universities.HILDESHEIM_CAS},
    }
    base, passport = lw_base, "a1b2c3d4-passport"
    launch = {"base": base, "passport": passport, "scheme": "uniflow", "url": learnweb.launch_url(base, passport, "uniflow"),
              "url_default_scheme": learnweb.launch_url(base, passport)}
    cases = [
        ("gueltig mit privatem Schluessel", _token_redirect("uniflow", base, passport, "tok-123", "priv-456")),
        ("gueltig ohne privaten Schluessel", _token_redirect("uniflow", base, passport, "tok-789")),
        ("Schluessel mit URL-sicherem Base64", _token_redirect("uniflow", base, passport, "tok+/=x", "p").replace("+", "-").replace("/", "_").rstrip("=")),
        ("falsche Signatur (anderer Passport)", _token_redirect("uniflow", base, "anderer", "tok-123")),
        ("falsche Signatur (andere Adresse)", _token_redirect("uniflow", "https://fremd.example/moodle", passport, "tok-123")),
        ("leerer Schluessel", _token_redirect("uniflow", base, passport, "")),
        ("kein Token in der Adresse", "uniflow://ohne"),
        ("kein Base64", "uniflow://token=%%%"),
    ]
    token_cases = [{"name": n, "redirect": r, "expect": learnweb.parse_launch_token(r, base, passport)} for n, r in cases]
    download = {"url": f"{lw_base}/pluginfile.php/21/mod_resource/content/1/Blatt%201.pdf", "token": "tok-123",
                "request": learnweb.token_request(f"{lw_base}/pluginfile.php/21/mod_resource/content/1/Blatt%201.pdf", "tok-123")}
    cookies = {
        "description": "Cookie-Kopfzeile fuer den Download: nur Cookies, deren Domain zum Host passt (Suffix, fuehrender Punkt egal) und die nicht abgelaufen sind (expires -1 oder fehlend = Sitzung); Reihenfolge wie gespeichert.",
        "now": 1761600000,
        "cookies": [{"name": "Seminar_Session", "value": "abc", "domain": "studip.uni-hannover.de", "path": "/", "expires": -1},
                    {"name": "shib", "value": "s1", "domain": ".uni-hannover.de", "path": "/", "expires": 1761700000},
                    {"name": "alt", "value": "x", "domain": "studip.uni-hannover.de", "path": "/", "expires": 1761500000},
                    {"name": "MoodleSession", "value": "m1", "domain": "www.uni-hildesheim.de", "path": "/"}],
        "cases": [{"url": f"{luh_base}/sendfile.php?file_id=1", "header": "Seminar_Session=abc; shib=s1"},
                  {"url": f"{lw_base}/pluginfile.php/1/x.pdf", "header": "MoodleSession=m1"},
                  {"url": "https://example.org/", "header": ""}],
    }
    html = {"description": "Antwort ist eine Anmeldeseite statt der Datei, wenn der Content-Type text/html ist oder der Inhalt (nach Leerraum) mit <!doctype oder <html beginnt (Gross-/Kleinschreibung egal). Dann: Sitzung abgelaufen.",
            "cases": [{"content_type": "text/html; charset=utf-8", "body_start": "%PDF-1.7", "html": True},
                      {"content_type": "application/pdf", "body_start": "  <!DOCTYPE html><html>", "html": True},
                      {"content_type": "application/octet-stream", "body_start": "<HTML>", "html": True},
                      {"content_type": "application/pdf", "body_start": "%PDF-1.4", "html": False}]}
    return {"_hinweis": "Erzeugt mit tools/gen-learnweb-fixture.py aus app/learnweb.py, app/studip_sync.py, app/universities.py; nicht von Hand aendern.",
            "profiles": profiles, "launch": launch, "token_cases": token_cases, "download_with_token": download,
            "cookie_header": cookies, "html_instead_of_file": html}


def main(check: bool) -> bool:
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
