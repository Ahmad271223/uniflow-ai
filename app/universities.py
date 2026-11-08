"""Uni-Profile: welche Hochschule die App synchronisiert (Einstellung "university").

luh        -> Stud.IP (WebSSO/Shibboleth) + QIS der Leibniz Universitaet Hannover (bisheriger Ablauf)
hildesheim -> Learnweb (Moodle) + LSF der Universitaet Hildesheim, Anmeldung ueber das zentrale CAS
hsh        -> Moodle + Campusmanagement (HISinOne) der Hochschule Hannover, je eigene Anmeldeseite mit dem
              SSO-Account (docs/HSH-2026-11-05.md)
"""
from __future__ import annotations

import os

DEFAULT = "luh"

# Ausgelieferte Hochschulen (08.11.2026, wie UFReleaseUniversities auf dem iPad): Version 1.0 bietet nur die LUH an.
# LERNAPP_SHIPPED_UNIVERSITIES = "luh" | "luh,hildesheim" | "all". Ohne Angabe: im gehosteten Dienst und in der
# Windows-App (LERNAPP_DESKTOP=1) nur die LUH, in der Entwicklung (serve.py) und in Tests alle drei.
SHIPPED_ENV = "LERNAPP_SHIPPED_UNIVERSITIES"
STORE_DEFAULT: tuple[str, ...] = ("luh",)
MORE_NOTE = "Weitere Hochschulen folgen mit einem Update."

HILDESHEIM_CAS = "https://www.uni-hildesheim.de/sso"
# Nur fuer Links in der Oberflaeche; der Sync ermittelt die Instanz des Semesters selbst (learnweb.discover_base)
LEARNWEB_BASE = "https://www.uni-hildesheim.de/learnweb2026"
LSF_BASE = "https://lsf.uni-hildesheim.de"
LSF_CURRENT_LECTURES = (f"{LSF_BASE}/qisserver/rds?state=currentLectures&type=0&next=CurrentLectures.vm&nextdir=ressourcenManager"
                        "&navigationPosition=lectures%2CcurrentLectures&breadcrumb=currentLectures&topitem=lectures&subitem=currentLectures")

# Hochschule Hannover (oeffentliche Angaben, docs/HSH-2026-11-05.md): Moodle mit eigener Anmeldeseite, HISinOne
# unter campusmanagement.hs-hannover.de (Startseite leitet auf /qisserver/rds?state=user&type=0)
HSH_MOODLE_BASE = "https://moodle.hs-hannover.de"
HSH_CM_BASE = "https://campusmanagement.hs-hannover.de"
HSH_CM_START = f"{HSH_CM_BASE}/qisserver/pages/cs/sys/portal/hisinoneStartPage.faces"

PROFILES: dict[str, dict] = {
    "luh": {
        "key": "luh",
        "name": "Leibniz Universität Hannover",
        "short": "LUH",
        "files_source": "Stud.IP",
        "grades_source": "QIS",
        "login": "WebSSO (LUH-ID)",
        "cred_prefix": "STUDIP",
        "user_label": "LUH-ID",
    },
    "hildesheim": {
        "key": "hildesheim",
        "name": "Universität Hildesheim",
        "short": "Uni Hildesheim",
        "files_source": "Learnweb",
        "grades_source": "LSF",
        "login": "UNI-Account (CAS)",
        "cred_prefix": "HILDESHEIM",
        "user_label": "Zugangskennung (UNI-Account)",
        "cas_base": HILDESHEIM_CAS,
        "learnweb_base": LEARNWEB_BASE,
        "lsf_base": LSF_BASE,
    },
    "hsh": {
        "key": "hsh",
        "name": "Hochschule Hannover",
        "short": "HsH",
        "files_source": "Moodle",
        "grades_source": "Campusmanagement",
        "login": "SSO-Account (Moodle, Campusmanagement)",
        "cred_prefix": "HSH",
        "user_label": "SSO-Account (abc-123-sso)",
        "moodle_base": HSH_MOODLE_BASE,
        "cm_base": HSH_CM_BASE,
    },
}

HILDESHEIM_SERVICES = [
    {"key": "learnweb", "name": "Learnweb", "url": f"{LEARNWEB_BASE}/my/courses.php", "desc": "Kurse, Folien, Skripte, Aufgaben (Moodle)", "login": "UNI-Account (CAS)", "icon": "book", "connected": True},
    {"key": "lsf", "name": "LSF", "url": f"{LSF_BASE}/qisserver/rds?state=user&type=0", "desc": "Vorlesungsverzeichnis, Stundenplan, Notenspiegel, Prüfungsanmeldung", "login": "UNI-Account (CAS)", "icon": "exam", "connector": True},
    # type=1 liefert eine Fehlerseite des LSF (AsiException, geprueft 26.10.2026); type=0 mit Navigation funktioniert ohne Login
    {"key": "lsf-ausfall", "name": "Heute im LSF (Räume)", "url": LSF_CURRENT_LECTURES, "desc": "Alle heutigen Veranstaltungen mit aktuellem Raum; Ausfälle stehen in der Veranstaltung unter „fällt aus am“", "login": "–", "icon": "alert"},
    {"key": "uni", "name": "Uni Hildesheim", "url": "https://www.uni-hildesheim.de/", "desc": "Webseite der Universität", "login": "–", "icon": "info"},
]

HSH_SERVICES = [
    {"key": "moodle", "name": "Moodle", "url": f"{HSH_MOODLE_BASE}/my/", "desc": "Kurse, Materialien, Abgaben, Kalender", "login": "SSO-Account", "icon": "book", "connected": True},
    {"key": "campusmanagement", "name": "Campusmanagement (HISinOne)", "url": f"{HSH_CM_BASE}/", "desc": "Stundenplan, Prüfungsanmeldung, Leistungen, Bescheinigungen", "login": "SSO-Account", "icon": "exam", "connector": True},
    {"key": "accounts", "name": "Accountmanager", "url": "https://accounts.hs-hannover.de/", "desc": "Masteraccount: SSO-, WLAN- und E-Mail-Konto einrichten, Passwörter", "login": "Masteraccount", "icon": "user"},
    {"key": "mail", "name": "E-Mail (Outlook)", "url": "https://outlook.cloud.microsoft/", "desc": "Postfach vorname.nachname@stud.hs-hannover.de", "login": "Microsoft-Konto der HsH", "icon": "bell"},
    {"key": "it", "name": "Hochschul-IT (service.it)", "url": "https://service.it.hs-hannover.de/de/willkommen/", "desc": "Anleitungen: Accounts, WLAN, VPN, Academic Cloud", "login": "–", "icon": "settings"},
    {"key": "termine", "name": "Termine & Fristen", "url": "https://www.hs-hannover.de/ueber-uns/organisation/akademische-angelegenheiten/studierende/wichtige-termine-fristen", "desc": "Vorlesungszeiten, Rückmeldung, Beurlaubung", "login": "–", "icon": "calendar"},
    {"key": "mensa", "name": "Mensa (Studentenwerk)", "url": "https://www.studentenwerk-hannover.de/essen/mensen-und-cafes", "desc": "Speisepläne der Mensen", "login": "–", "icon": "sun"},
    {"key": "uni", "name": "Hochschule Hannover", "url": "https://www.hs-hannover.de/", "desc": "Webseite der Hochschule", "login": "–", "icon": "info"},
]


def services(key: str) -> list[dict] | None:
    """Dienste-Liste einer Hochschule ohne Stud.IP (Hildesheim, HsH); None fuer die LUH (SERVICES in app/server.py)"""
    return {"hildesheim": HILDESHEIM_SERVICES, "hsh": HSH_SERVICES}.get(key)


def valid(key: str | None) -> bool:
    return (key or "") in PROFILES


def shipped() -> tuple[str, ...]:
    """Hochschulen, die diese Auslieferung zur Wahl stellt (Registrierung, Hochschulwahl in Web und Windows-App).
    Alle Profile bleiben bekannt (bestehende Konten, Abgleich); nur die Auswahl ist eingeschraenkt."""
    from . import config
    raw = (os.environ.get(SHIPPED_ENV) or "").strip().lower()
    if raw == "all":
        return tuple(PROFILES)
    if raw:
        keys = tuple(k for k in (part.strip() for part in raw.split(",")) if k in PROFILES)
        if keys:
            return keys
    if config.is_hosted() or os.environ.get("LERNAPP_DESKTOP") == "1":
        return STORE_DEFAULT
    return tuple(PROFILES)


def is_shipped(key: str | None) -> bool:
    return (key or "") in shipped()


def choices(current: str | None = None) -> list[dict]:
    """Hochschulwahl fuer die Oberflaeche: ausgelieferte Hochschulen, die laufende immer dabei (bestehende Daten)."""
    keys = list(shipped())
    if current in PROFILES and current not in keys:
        keys.insert(0, current)
    return [{"key": k, "name": PROFILES[k]["name"]} for k in keys]


def more_note() -> str | None:
    """Hinweis unter der Hochschulwahl, sobald nicht alle Hochschulen ausgeliefert sind."""
    return MORE_NOTE if len(shipped()) < len(PROFILES) else None


def current_key() -> str:
    """Uni dieser laufenden App-Instanz (beim Start aus UNIVERSITY in der .env festgelegt)."""
    from . import config
    key = config.university()
    return key if key in PROFILES else DEFAULT


def current() -> dict:
    return PROFILES[current_key()]
