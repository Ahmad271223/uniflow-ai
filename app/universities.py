"""Uni-Profile: welche Hochschule die App synchronisiert (Einstellung "university").

luh        -> Stud.IP (WebSSO/Shibboleth) + QIS der Leibniz Universitaet Hannover (bisheriger Ablauf)
hildesheim -> Learnweb (Moodle) + LSF der Universitaet Hildesheim, Anmeldung ueber das zentrale CAS
hsh        -> Moodle + Campusmanagement (HISinOne) der Hochschule Hannover, je eigene Anmeldeseite mit dem
              SSO-Account (docs/HSH-2026-11-05.md)
goettingen -> Stud.IP der Georg-August-Universitaet Goettingen (26.11.2026, docs/GOETTINGEN-2026-11-26.md). Der Abgleich
              laeuft nur auf dem Geraet (iPad/iPhone/Mac, Swift-Kern); dieser Dienst kennt die Hochschule fuer Konten
              (`accounts`, `university_unknown`), Mensa und Raeume, gleicht dort aber nichts selbst ab.
"""
from __future__ import annotations

DEFAULT = "luh"

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

# Uni Goettingen: Stud.IP 6.2 mit eigenem Anmeldeformular (dispatch.php/login), JSON:API mit der Sitzung
GOETTINGEN_STUDIP_BASE = "https://studip.uni-goettingen.de"

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
    "goettingen": {
        "key": "goettingen",
        "name": "Georg-August-Universität Göttingen",
        "short": "Uni Göttingen",
        "files_source": "Stud.IP",
        "grades_source": "FlexNow",
        "login": "Stud.IP-Anmeldung (Uni-Konto)",
        "cred_prefix": "GOETTINGEN",
        "user_label": "Benutzername (Uni-Konto)",
        "studip_base": GOETTINGEN_STUDIP_BASE,
        # Nur in den Apps (und dort erst nach Freigabe des Inhabers): Web-App und PC-Server bieten sie nicht zur Wahl an
        # (`offered`), Konten der Apps mit dieser Hochschule nimmt der Dienst aber an (`config.known_universities`).
        "apps_only": True,
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


# Wie `UniversityProfile.goettingen.services` im Swift-Kern (gleiche Schluessel und Adressen)
GOETTINGEN_SERVICES = [
    {"key": "studip", "name": "Stud.IP", "url": f"{GOETTINGEN_STUDIP_BASE}/", "desc": "Kurse, Dateien, Termine, Ankündigungen, Nachrichten", "login": "Uni-Konto", "icon": "book", "connected": True},
    {"key": "flexnow", "name": "FlexNow (Prüfungsverwaltung)", "url": "https://flexnow2.uni-goettingen.de/", "desc": "Prüfungsanmeldung, Noten, Leistungsübersicht", "login": "Uni-Konto", "icon": "exam"},
    {"key": "ecampus", "name": "eCampus", "url": "https://ecampus.uni-goettingen.de/", "desc": "Vorlesungsverzeichnis, Bescheinigungen, Rückmeldung", "login": "Uni-Konto (zweiter Faktor)", "icon": "user"},
    {"key": "mail", "name": "E-Mail (Exchange)", "url": "https://email.stud.uni-goettingen.de/", "desc": "Studentisches Postfach im Browser", "login": "Uni-Konto (zweiter Faktor)", "icon": "bell"},
    {"key": "sub", "name": "SUB Göttingen", "url": "https://www.sub.uni-goettingen.de/", "desc": "Bibliothek: Literatur, Lernplätze, Ausleihe", "login": "Bibliotheksausweis", "icon": "book"},
    {"key": "mensa", "name": "Mensa (Studierendenwerk)", "url": "https://www.studierendenwerk-goettingen.de/campusgastronomie/mensen/speiseplaene-der-mensen", "desc": "Speisepläne der Mensen", "login": "–", "icon": "sun"},
    {"key": "lageplan", "name": "Lageplan", "url": "https://lageplan.uni-goettingen.de/", "desc": "Gebäude und Räume auf der Karte", "login": "–", "icon": "info"},
    {"key": "studit", "name": "studIT (Hilfe)", "url": "https://wiki.student.uni-goettingen.de/", "desc": "Anleitungen: Konto, WLAN, E-Mail, Drucken", "login": "–", "icon": "settings"},
    {"key": "uni", "name": "Universität Göttingen", "url": "https://www.uni-goettingen.de/", "desc": "Webseite der Universität", "login": "–", "icon": "info"},
]


def services(key: str) -> list[dict] | None:
    """Dienste-Liste einer Hochschule ausser der LUH (Hildesheim, HsH, Goettingen); None fuer die LUH (SERVICES in
    app/server.py)"""
    return {"hildesheim": HILDESHEIM_SERVICES, "hsh": HSH_SERVICES, "goettingen": GOETTINGEN_SERVICES}.get(key)


def valid(key: str | None) -> bool:
    return (key or "") in PROFILES


def offered() -> list[str]:
    """Hochschulen, die Web-App und PC-Server zur Wahl stellen (ohne die nur in den Apps angebundenen, `apps_only`)"""
    return [k for k, v in PROFILES.items() if not v.get("apps_only")]


def hidden_regions(own: str | None = None) -> set[str]:
    """Regionen (Mensa), deren Hochschulen alle `apps_only` sind - ausser der Region der eigenen Hochschule"""
    from . import mensa
    unis = mensa.load_data()["universities"]
    own_region = (unis.get(own or "") or {}).get("region")
    by_region: dict[str, list[str]] = {}
    for k, u in unis.items():
        by_region.setdefault(u["region"], []).append(k)
    return {r for r, keys in by_region.items() if r != own_region and all((PROFILES.get(k) or {}).get("apps_only") for k in keys)}


def current_key() -> str:
    """Uni dieser laufenden App-Instanz (beim Start aus UNIVERSITY in der .env festgelegt)."""
    from . import config
    key = config.university()
    return key if key in PROFILES else DEFAULT


def current() -> dict:
    return PROFILES[current_key()]
