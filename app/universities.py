"""Uni-Profile: welche Hochschule die App synchronisiert (Einstellung "university").

luh        -> Stud.IP (WebSSO/Shibboleth) + QIS der Leibniz Universitaet Hannover (bisheriger Ablauf)
hildesheim -> Learnweb (Moodle) + LSF der Universitaet Hildesheim, Anmeldung ueber das zentrale CAS
"""
from __future__ import annotations

DEFAULT = "luh"

HILDESHEIM_CAS = "https://www.uni-hildesheim.de/sso"
LEARNWEB_BASE = "https://www.uni-hildesheim.de/learnweb2026"
LSF_BASE = "https://lsf.uni-hildesheim.de"

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
}

HILDESHEIM_SERVICES = [
    {"key": "learnweb", "name": "Learnweb", "url": f"{LEARNWEB_BASE}/my/courses.php", "desc": "Kurse, Folien, Skripte, Aufgaben (Moodle)", "login": "UNI-Account (CAS)", "icon": "book", "connected": True},
    {"key": "lsf", "name": "LSF", "url": f"{LSF_BASE}/qisserver/rds?state=user&type=0", "desc": "Vorlesungsverzeichnis, Stundenplan, Notenspiegel, Prüfungsanmeldung", "login": "UNI-Account (CAS)", "icon": "exam", "connector": True},
    {"key": "lsf-ausfall", "name": "Ausfälle & Raumwechsel", "url": f"{LSF_BASE}/qisserver/rds?state=currentLectures&type=1&next=CurrentLectures.vm&nextdir=ressourcenManager", "desc": "Heute ausfallende oder verlegte Veranstaltungen", "login": "–", "icon": "alert"},
    {"key": "uni", "name": "Uni Hildesheim", "url": "https://www.uni-hildesheim.de/", "desc": "Webseite der Universität", "login": "–", "icon": "info"},
]


def valid(key: str | None) -> bool:
    return (key or "") in PROFILES


def current_key(conn=None) -> str:
    """Uni dieser laufenden App-Instanz (beim Start aus UNIVERSITY in der .env festgelegt)."""
    from . import config
    return config.UNIVERSITY if config.UNIVERSITY in PROFILES else DEFAULT


def current(conn=None) -> dict:
    return PROFILES[current_key(conn)]
