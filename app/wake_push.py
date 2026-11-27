"""Weck-Signal (Auftrag des Inhabers vom 17.11.2026, docs/WECK-SIGNAL-2026-11-17.md).

Die Apple-Apps speichern die Hochschul-Passwoerter nur auf dem Geraet; der Dienst kann die Hochschule nicht abfragen
(app/vault.py, Entscheidung 06.11.2026). Damit eine geschlossene App trotzdem zeitnah abgleicht, schickt der Dienst
zwischen 08:00 und 18:00 Uhr ORTSZEIT DES GERAETS alle 30 Minuten eine stille Push-Nachricht ("Weck-Signal") an ein
gemeldetes Geraet je Konto: seit 26.11.2026 ("Abruf schonen") nur das zuletzt benutzte (`wake_devices`, nach
`last_seen_at`), vorher an jedes. Die App wacht kurz auf und gleicht selbst ab; die anderen Geraete des Kontos gleichen
ab, wenn man sie oeffnet. Der Dienst sieht dabei keine Hochschul-Daten.

Gespeichert wird je Konto und Geraet genau ein Eintrag in `push_tokens` (accounts.db), und nur: Konto, Geraete-Kennung
der Sitzung (wie die Geraete-Regel, app/device_limit.py), APNs-Token, Plattform, App-Version, Zeitzone, Umgebung und
vier Zeitstempel bzw. der letzte Fehlercode von Apple. Ein Token gehoert immer nur zu einem Konto: meldet ein anderes
Konto dasselbe Token, wandert der Eintrag um. Abmelden entfernt die Eintraege des Geraets, "Konto loeschen" alle
(app/accounts.py ruft `forget_device` / `forget_user`).

Zeitplan (`slot_start`, reine Funktion ohne Systemuhr): Fenster WINDOW_START_HOUR (einschliesslich) bis
WINDOW_END_HOUR (ausschliesslich) in der Zeitzone des Tokens, ein Signal je INTERVAL_MINUTES. Gestaffelt: jedes Token
bekommt aus einem Hash einen festen Versatz von 0 bis INTERVAL_MINUTES-1 Minuten, damit nicht alle Geraete zur selben
Minute bei der Hochschule anfragen. Je Token also hoechstens SIGNALS_PER_DAY (20) Signale am Tag. Kein zweites Signal
im selben Abschnitt, auch nach einem Neustart und mit mehreren Prozessen: `claim` setzt `last_sent_at` in der
Datenbank, BEVOR gesendet wird, und nur ein Aufrufer gewinnt.

Versand (`Sender`): APNs ueber HTTP/2 an HOSTS[Umgebung], Anmeldung mit einem JWT (ES256, .p8-Schluessel, Key-ID,
Team-ID), das JWT_REFRESH_S lang wiederverwendet und nie oefter als alle JWT_MIN_INTERVAL_S neu erzeugt wird.
Kopfzeilen `apns-push-type: background`, `apns-priority: 5`, `apns-topic: <Bundle-ID>`, dazu `apns-expiration` (Ende
des Abschnitts: ein Geraet, das erst abends wieder Netz hat, wird nicht nachtraeglich geweckt). Nutzlast ausschliesslich
PAYLOAD. Ungueltige Token (410, oder 400 mit einem Grund aus INVALID_TOKEN_REASONS) werden geloescht. Bei 429/5xx
haelt der Dienst an (Pause, die sich bis BACKOFF_MAX_S verdoppelt), statt weiterzusenden. Im Protokoll steht nie ein
Token, nur ein gekuerzter Hash (`short`).

Einstellungen aus der Umgebung (deploy/.env), Standard AUS:

    STUDINOW_WAKE_PUSH=1     einschalten (alles andere, auch leer: aus)
    APNS_KEY_PATH            Pfad der .p8-Datei des APNs-Schluessels (nie im Repo)
    APNS_KEY_ID              Key-ID dieses Schluessels (10 Zeichen)
    APNS_TEAM_ID             Team-ID (10 Zeichen); fehlt sie, gilt LERNAPP_APPLE_TEAM_ID
    APNS_TOPIC               Bundle-ID der App (Standard DEFAULT_TOPIC, apps/apple/project.yml)

Ausgeschaltet, ohne Schluessel oder ohne das Paket `h2` sendet der Dienst nichts und schreibt das einmal ins Protokoll.
Die Schleife laeuft dort, wo der Zeitplan laeuft (app/jobs.py, `Runner.start`): im gehosteten Dienst im Prozess
`python -m app.jobs` bzw. im API-Prozess bei LERNAPP_JOBS=inproc. Am eigenen PC und in der Windows-App gibt es sie
nicht. Stand ansehen: `python -m app.wake_push --status` (sendet nichts).
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import sys
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo, available_timezones

from . import accounts

log = logging.getLogger("uniflow.wake")

# ---------------------------------------------------------------- Zeitplan: die drei Zahlen stehen nur hier
WINDOW_START_HOUR = 8                     # ab 08:00 Ortszeit des Geraets (einschliesslich)
WINDOW_END_HOUR = 18                      # bis 18:00 Ortszeit des Geraets (ausschliesslich)
INTERVAL_MINUTES = 30                     # ein Signal je Abschnitt dieser Laenge; zugleich die Breite der Staffelung
SIGNALS_PER_DAY = (WINDOW_END_HOUR - WINDOW_START_HOUR) * 60 // INTERVAL_MINUTES      # 20

# ---------------------------------------------------------------- Regeln fuer gemeldete Geraete
PLATFORMS = ("ios", "ipados", "macos")
ENVIRONMENTS = ("production", "sandbox")  # sandbox: Debug-Builds der App (Xcode); alles andere production
DEFAULT_ENVIRONMENT = "production"
TOKEN_RE = re.compile(r"[0-9a-f]{64,200}")
APP_VERSION_MAX = 40
MAX_TOKENS_PER_ACCOUNT = 10               # mehr Geraete meldet kein Konto; das am laengsten nicht gemeldete faellt weg
STALE_DAYS = 60                           # so lange nicht gemeldet: Eintrag weg (app/retention.py); die App meldet bei jedem Start
# Meldungen je Konto: (Anzahl, Minuten), ueberschreibbar mit LERNAPP_LIMIT_PUSH_TOKEN_USER=Anzahl/Minuten. Steht hier
# und nicht in accounts.LIMITS, weil jene Liste Teil des Konto-Vertrags ist (contract.json, `rules.limits`).
LIMIT_NAME, LIMIT = "push_token_user", (60, 60)

# ---------------------------------------------------------------- Versand an Apple
HOSTS = {"production": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}
DEFAULT_TOPIC = "de.uniflow.ai"           # Bundle-ID der App (apps/apple/project.yml, PRODUCT_BUNDLE_IDENTIFIER)
PAYLOAD = b'{"aps":{"content-available":1}}'
PUSH_TYPE, PRIORITY = "background", "5"
JWT_REFRESH_S = 50 * 60                   # Apple nimmt ein JWT hoechstens 60 Minuten; nach 50 gibt es ein neues
JWT_MIN_INTERVAL_S = 20 * 60              # nie oefter (Apple: TooManyProviderTokenUpdates)
# Apple sagt mit diesen Antworten, dass es das Geraet bzw. die App darauf nicht mehr gibt: Eintrag loeschen
INVALID_TOKEN_REASONS = frozenset({"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"})
# Fehler der Einrichtung (Schluessel, Team, Bundle-ID): jedes weitere Signal scheiterte genauso, also lange Pause
CONFIG_REASONS = frozenset({"BadTopic", "TopicDisallowed", "MissingTopic", "InvalidPushType"})
PAUSE_STATUS = frozenset({429, 500, 502, 503, 504})
BACKOFF_START_S = 60                      # erste Pause nach 429/5xx oder ohne Verbindung, danach jeweils doppelt
BACKOFF_MAX_S = 30 * 60
CONFIG_PAUSE_S = 30 * 60
TICK_S = 20                               # Abstand der Durchlaeufe; ein Signal geht damit hoechstens ~20 s nach seiner Minute
TICK_BUDGET_S = 15                        # laenger sendet ein Durchlauf nicht; der Rest kommt im naechsten
TIMEOUT_S = 10

ENV_SWITCH, ENV_KEY_PATH, ENV_KEY_ID, ENV_TEAM_ID, ENV_TOPIC = (
    "STUDINOW_WAKE_PUSH", "APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC")
ENV_TEAM_ID_FALLBACK = "LERNAPP_APPLE_TEAM_ID"      # dieselbe Team-ID wie bei "Mit Apple anmelden" (app/apple_signin.py)

SCHEMA = """
CREATE TABLE IF NOT EXISTS push_tokens (
    token TEXT PRIMARY KEY,                -- APNs-Token des Geraets (Hex, klein); gehoert immer nur zu einem Konto
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT,                        -- Geraete-Kennung der Sitzung (sessions.device_id), falls die App eine meldet
    platform TEXT NOT NULL,                -- ios | ipados | macos
    app_version TEXT,
    timezone TEXT NOT NULL,                -- IANA-Name, z. B. Europe/Berlin
    environment TEXT NOT NULL DEFAULT 'production',     -- production | sandbox
    created_at TEXT NOT NULL,              -- angelegt
    last_seen_at TEXT NOT NULL,            -- zuletzt von der App gemeldet
    last_sent_at TEXT,                     -- zuletzt gesendet (Beginn des Versuchs)
    last_error TEXT                        -- letzter Fehlercode von Apple; leer nach einem Erfolg
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON push_tokens(user_id, device_id);
"""
TABLE = "push_tokens"
PUBLIC_COLUMNS = ("platform", "app_version", "timezone", "environment", "created_at", "last_seen_at")


# ---------------------------------------------------------------- Zeitplan (rein, ohne Systemuhr)

@lru_cache(maxsize=1)
def _zones() -> frozenset[str]:
    return frozenset(available_timezones())


def valid_timezone(name) -> bool:
    """IANA-Name aus der Zeitzonen-Datenbank (genaue Schreibweise, z. B. Europe/Berlin)."""
    return isinstance(name, str) and name in _zones()


@lru_cache(maxsize=512)
def _zone(name: str) -> ZoneInfo:
    if not valid_timezone(name):
        raise ValueError("Unbekannte Zeitzone")
    return ZoneInfo(name)


def offset_minutes(token: str) -> int:
    """Fester Versatz des Tokens in Minuten (0 bis INTERVAL_MINUTES-1): aus einem Hash, also gleichmaessig verteilt
    und bei jedem Start derselbe."""
    digest = hashlib.sha256(b"studinow.wake.v1\x00" + token.lower().encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % INTERVAL_MINUTES


def slot_start(now: datetime, tz_name: str, token: str) -> datetime | None:
    """Beginn (UTC) des Abschnitts, in dem `now` fuer dieses Token liegt; None ausserhalb des Fensters.

    Das Token mit Versatz v bekommt seine Signale um 08:00+v, 08:30+v ... 17:30+v Ortszeit. Vor dem ersten Zeitpunkt
    des Tages und ab 18:00 gibt es nichts. Gerechnet wird mit der Uhr an der Wand des Geraets (zoneinfo), damit
    Sommer- und Winterzeit stimmen. `now` muss eine Zeitzone tragen; unbekannte Zeitzone: ValueError."""
    if now.tzinfo is None:
        raise ValueError("now braucht eine Zeitzone")
    local = now.astimezone(_zone(tz_name))
    minute = local.hour * 60 + local.minute
    first = WINDOW_START_HOUR * 60 + offset_minutes(token)
    if minute < first or minute >= WINDOW_END_HOUR * 60:
        return None
    start = first + (minute - first) // INTERVAL_MINUTES * INTERVAL_MINUTES
    return local.replace(hour=start // 60, minute=start % 60, second=0, microsecond=0).astimezone(timezone.utc)


def is_due(now: datetime, tz_name: str, token: str, last_sent_at: datetime | None) -> bool:
    """Steht fuer dieses Token jetzt ein Signal an? Ja, wenn `now` in einem Abschnitt liegt und in diesem Abschnitt
    noch nichts gesendet wurde."""
    slot = slot_start(now, tz_name, token)
    return slot is not None and (last_sent_at is None or last_sent_at < slot)


def schedule_info(token: str) -> dict:
    """Zeitplan fuer die Antwort an die App (Anzeige, Diagnose)."""
    return {"from": f"{WINDOW_START_HOUR:02d}:00", "to": f"{WINDOW_END_HOUR:02d}:00", "every_minutes": INTERVAL_MINUTES,
            "offset_minutes": offset_minutes(token)}


# ---------------------------------------------------------------- Speicher (accounts.db)

def _iso(dt: datetime) -> str:
    """Zeitstempel wie in accounts.db ueblich (UTC, Sekunden, mit Z): als Text vergleichbar."""
    return accounts.iso(dt.astimezone(timezone.utc).replace(microsecond=0))


def short(token: str) -> str:
    """Gekuerzter Hash eines Tokens fuers Protokoll. Das Token selbst steht dort nie."""
    return hashlib.sha256((token or "").encode("utf-8")).hexdigest()[:10]


@contextmanager
def cursor():
    """Verbindung zu accounts.db mit der Tabelle `push_tokens` (zusaetzlich, wird beim ersten Zugriff angelegt)."""
    from . import db
    with accounts.cursor() as conn:
        db.schema_once(conn, "wake_push", accounts.db_path(), lambda c: c.executescript(SCHEMA))
        yield conn


def _invalid(code: str, message: str) -> accounts.AccountError:
    return accounts.AccountError(code, message, 400)


def normalize_token(token) -> str:
    t = token.strip().lower() if isinstance(token, str) else ""
    if not TOKEN_RE.fullmatch(t) or len(t) % 2:
        raise _invalid("push_token_invalid", "Das Geräte-Token ist ungültig.")
    return t


def _clean(token, platform, app_version, tz_name, environment) -> tuple[str, str, str | None, str, str]:
    token = normalize_token(token)
    platform = platform.strip().lower() if isinstance(platform, str) else ""
    if platform not in PLATFORMS:
        raise _invalid("platform_invalid", "Unbekannte Plattform (ios, ipados, macos).")
    if not valid_timezone(tz_name):
        raise _invalid("timezone_invalid", "Unbekannte Zeitzone. Erwartet wird ein Name wie Europe/Berlin.")
    environment = environment.strip().lower() if isinstance(environment, str) else ""
    environment = environment or DEFAULT_ENVIRONMENT
    if environment not in ENVIRONMENTS:
        raise _invalid("environment_invalid", "Unbekannte Umgebung (production, sandbox).")
    version = app_version.strip() if isinstance(app_version, str) else ""
    if len(version) > APP_VERSION_MAX or not version.isprintable():
        raise _invalid("app_version_invalid", f"Die App-Version darf höchstens {APP_VERSION_MAX} Zeichen haben.")
    return token, platform, version or None, tz_name, environment


def _session_device_id(conn, user_id: str, session_token: str | None) -> str | None:
    """Geraete-Kennung der Sitzung dieser Anfrage, wie die Geraete-Regel sie liest (device_limit._session_device)."""
    if not session_token:
        return None
    s = conn.execute("SELECT device_id FROM sessions WHERE token_hash=? AND user_id=? AND revoked_at IS NULL",
                     (accounts._token_hash(session_token), user_id)).fetchone()
    return s["device_id"] if s else None


def register(user_id: str, session_token: str | None, token, platform, app_version, tz_name, environment=None,
             now: datetime | None = None) -> dict:
    """Geraet melden oder die Meldung auffrischen (beliebig oft mit gleichem Ergebnis). Das Token wandert zu diesem
    Konto, falls es bisher zu einem anderen gehoerte; hatte dieses Geraet ein anderes Token, faellt das alte weg.
    Fehler: AccountError 400 push_token_invalid, platform_invalid, timezone_invalid, environment_invalid,
    app_version_invalid."""
    token, platform, version, tz_name, environment = _clean(token, platform, app_version, tz_name, environment)
    t = _iso(now or accounts.now())
    with cursor() as conn:
        device_id = _session_device_id(conn, user_id, session_token)
        if device_id:
            conn.execute(f"DELETE FROM {TABLE} WHERE user_id=? AND device_id=? AND token<>?", (user_id, device_id, token))
        # Wechselt das Token das Konto, beginnt `created_at` neu; `last_sent_at` bleibt (in diesem Abschnitt wurde das
        # Geraet schon geweckt)
        conn.execute(
            f"INSERT INTO {TABLE}(token, user_id, device_id, platform, app_version, timezone, environment, created_at, last_seen_at) "
            "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(token) DO UPDATE SET "
            f"created_at=CASE WHEN {TABLE}.user_id=excluded.user_id THEN {TABLE}.created_at ELSE excluded.created_at END, "
            "user_id=excluded.user_id, device_id=excluded.device_id, platform=excluded.platform, "
            "app_version=excluded.app_version, timezone=excluded.timezone, environment=excluded.environment, "
            "last_seen_at=excluded.last_seen_at, last_error=NULL",
            (token, user_id, device_id, platform, version, tz_name, environment, t, t))
        extra = conn.execute(f"SELECT token FROM {TABLE} WHERE user_id=? ORDER BY last_seen_at DESC, token LIMIT -1 OFFSET ?",
                             (user_id, MAX_TOKENS_PER_ACCOUNT)).fetchall()
        for r in extra:
            conn.execute(f"DELETE FROM {TABLE} WHERE token=?", (r["token"],))
        row = conn.execute(f"SELECT {', '.join(PUBLIC_COLUMNS)} FROM {TABLE} WHERE token=?", (token,)).fetchone()
    return {"push": dict(row), "schedule": schedule_info(token)}


def unregister(user_id: str, session_token: str | None, token=None) -> int:
    """Meldung zuruecknehmen: mit `token` genau dieses (nur wenn es dem Konto gehoert), ohne die Eintraege des Geraets
    dieser Sitzung. Liefert die Zahl der entfernten Eintraege; nichts zu entfernen ist kein Fehler."""
    token = normalize_token(token) if token not in (None, "") else None
    with cursor() as conn:
        if token:
            return conn.execute(f"DELETE FROM {TABLE} WHERE token=? AND user_id=?", (token, user_id)).rowcount
        return forget_device(conn, user_id, _session_device_id(conn, user_id, session_token))


def forget_device(conn, user_id: str, device_id: str | None, unless_signed_in: bool = False) -> int:
    """Abmelden (app/accounts.py): die Eintraege dieses Geraets weg. Ohne Geraete-Kennung die Eintraege des Kontos, die
    ohne Kennung gemeldet wurden. `unless_signed_in`: nur, wenn das Konto auf diesem Geraet keine weitere gueltige
    Sitzung hat (ein Geraet aus der Liste abmelden). Laeuft in der Transaktion des Aufrufers; gibt es die Tabelle noch
    nicht, passiert nichts."""
    if not accounts._has_table(conn, TABLE):
        return 0
    if unless_signed_in and conn.execute(
            "SELECT 1 FROM sessions WHERE user_id=? AND device_id IS ? AND revoked_at IS NULL AND expires_at>?",
            (user_id, device_id, accounts.iso(accounts.now()))).fetchone():
        return 0
    return conn.execute(f"DELETE FROM {TABLE} WHERE user_id=? AND device_id IS ?", (user_id, device_id)).rowcount


def forget_other_devices(conn, user_id: str, keep_device_id: str | None) -> int:
    """"Andere Geraete abmelden": alle Eintraege des Kontos weg, ausser denen des Geraets, das angemeldet bleibt."""
    if not accounts._has_table(conn, TABLE):
        return 0
    return conn.execute(f"DELETE FROM {TABLE} WHERE user_id=? AND device_id IS NOT ?", (user_id, keep_device_id)).rowcount


def forget_user(conn, user_id: str) -> int:
    """Alle Eintraege des Kontos weg (Konto loeschen, Passwort zurueckgesetzt, ueberall abgemeldet)."""
    if not accounts._has_table(conn, TABLE):
        return 0
    return conn.execute(f"DELETE FROM {TABLE} WHERE user_id=?", (user_id,)).rowcount


def devices(user_id: str) -> list[dict]:
    """Alles, was der Dienst fuer das Weck-Signal zu diesem Konto speichert (Datenexport, app/account_export.py)."""
    with cursor() as conn:
        return [dict(r) for r in conn.execute(
            f"SELECT token, device_id, platform, app_version, timezone, environment, created_at, last_seen_at, last_sent_at, "
            f"last_error FROM {TABLE} WHERE user_id=? ORDER BY created_at, token", (user_id,))]


def wake_devices(rows: list[dict]) -> list[dict]:
    """Je Konto genau EIN Geraet, das geweckt wird (26.11.2026, "Abruf schonen", Freigabe des Inhabers): das zuletzt
    benutzte (`last_seen_at`, die App meldet sich beim Oeffnen; bei Gleichstand das kleinere Token). Sonst gliche ein
    Konto mit iPad, iPhone und Mac dreimal alle 30 Minuten bei der Hochschule ab; die anderen Geraete gleichen ab, wenn
    man sie oeffnet. Zeilen ohne `user_id` bleiben unberuehrt."""
    rest = [r for r in rows if not r.get("user_id")]
    # erst nach Token aufsteigend, dann (stabil) nach last_seen_at absteigend: je Konto steht das gewaehlte vorn
    ordered = sorted((r for r in rows if r.get("user_id")), key=lambda r: r["token"])
    ordered.sort(key=lambda r: r.get("last_seen_at") or "", reverse=True)
    best: dict[str, dict] = {}
    for r in ordered:
        best.setdefault(r["user_id"], r)
    return rest + list(best.values())


def due(now: datetime) -> list[tuple[dict, datetime]]:
    """Eintraege, fuer die jetzt ein Signal ansteht, mit dem Beginn ihres Abschnitts (aeltester Abschnitt zuerst). Je
    Konto nur das Geraet aus `wake_devices`."""
    with cursor() as conn:
        rows = [dict(r) for r in conn.execute(
            f"SELECT token, user_id, timezone, environment, last_seen_at, last_sent_at, last_error FROM {TABLE}")]
    out = []
    for r in wake_devices(rows):
        try:
            slot = slot_start(now, r["timezone"], r["token"])
        except ValueError:                                  # Zeitzone nicht (mehr) bekannt: nie senden statt abbrechen
            continue
        if slot is not None and (not r["last_sent_at"] or r["last_sent_at"] < _iso(slot)):
            out.append((r, slot))
    out.sort(key=lambda x: (x[1], x[0]["token"]))
    return out


def claim(token: str, slot: datetime, now: datetime) -> bool:
    """Abschnitt fuer dieses Token belegen, BEVOR gesendet wird: genau ein Aufrufer bekommt True, auch bei mehreren
    Prozessen und nach einem Neustart (`last_sent_at` steht in der Datenbank)."""
    with cursor() as conn:
        return conn.execute(f"UPDATE {TABLE} SET last_sent_at=? WHERE token=? AND (last_sent_at IS NULL OR last_sent_at < ?)",
                            (_iso(now), token, _iso(slot))).rowcount == 1


def _release(token: str, claimed: datetime, previous: str | None) -> None:
    """Apple hat sicher nicht zugestellt (429, 5xx, Einrichtung): der Abschnitt ist wieder frei und wird nach der
    Pause nachgeholt, solange er noch laeuft."""
    with cursor() as conn:
        conn.execute(f"UPDATE {TABLE} SET last_sent_at=? WHERE token=? AND last_sent_at=?", (previous, token, _iso(claimed)))


def _set_error(token: str, code: str | None) -> None:
    with cursor() as conn:
        conn.execute(f"UPDATE {TABLE} SET last_error=? WHERE token=?", (code, token))


def _remove_invalid(token: str, not_after: datetime | None) -> bool:
    """Von Apple als ungueltig gemeldetes Token loeschen. Nennt Apple den Zeitpunkt, seit dem es ungueltig ist, bleibt
    ein Eintrag, den die App danach neu gemeldet hat."""
    with cursor() as conn:
        if not_after is None:
            return conn.execute(f"DELETE FROM {TABLE} WHERE token=?", (token,)).rowcount > 0
        return conn.execute(f"DELETE FROM {TABLE} WHERE token=? AND last_seen_at<=?", (token, _iso(not_after))).rowcount > 0


def hit_limit(user_id: str) -> None:
    """Meldungen je Konto begrenzen (429 rate_limited mit Wartezeit), gezaehlt in accounts.db wie die Konto-Grenzen."""
    accounts.hit_limit(LIMIT_NAME, user_id, default=LIMIT)


# ---------------------------------------------------------------- Einstellungen

@dataclass(frozen=True)
class Settings:
    enabled: bool
    key_path: str
    key_id: str
    team_id: str
    topic: str


def _env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def settings() -> Settings:
    """Einstellungen frisch aus der Umgebung (deploy/.env). Eingeschaltet ist nur STUDINOW_WAKE_PUSH=1."""
    return Settings(enabled=_env(ENV_SWITCH) == "1", key_path=_env(ENV_KEY_PATH), key_id=_env(ENV_KEY_ID),
                    team_id=_env(ENV_TEAM_ID) or _env(ENV_TEAM_ID_FALLBACK), topic=_env(ENV_TOPIC) or DEFAULT_TOPIC)


NOTHING_SENT = "Es wird nichts an Apple gesendet."


def problem(s: Settings | None = None) -> str | None:
    """Warum der Dienst gerade kein Weck-Signal senden kann, in einem Satz; None, wenn alles eingerichtet ist."""
    s = s or settings()
    if not s.enabled:
        return f"Weck-Signal: ausgeschaltet ({ENV_SWITCH} ist nicht 1). {NOTHING_SENT}"
    missing = [name for name, value in ((ENV_KEY_PATH, s.key_path), (ENV_KEY_ID, s.key_id), (ENV_TEAM_ID, s.team_id)) if not value]
    if missing:
        return f"Weck-Signal: eingeschaltet, aber es fehlt {', '.join(missing)} (APNs-Schlüssel von Apple). {NOTHING_SENT}"
    if not Path(s.key_path).is_file():
        return f"Weck-Signal: eingeschaltet, aber die Schlüsseldatei aus {ENV_KEY_PATH} gibt es nicht. {NOTHING_SENT}"
    return None


# ---------------------------------------------------------------- Versand

def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def provider_jwt(s: Settings, issued_at: int) -> str:
    """Anmeldung bei APNs: JWT mit Kopf {alg: ES256, kid: Key-ID} und Inhalt {iss: Team-ID, iat}, signiert mit dem
    privaten Schluessel aus der .p8-Datei."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    key = serialization.load_pem_private_key(Path(s.key_path).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("Der APNs-Schluessel ist kein EC-Schluessel (.p8)")
    signing = (_b64(json.dumps({"alg": "ES256", "kid": s.key_id}, separators=(",", ":")).encode()) + "."
               + _b64(json.dumps({"iss": s.team_id, "iat": int(issued_at)}, separators=(",", ":")).encode()))
    r, sig_s = decode_dss_signature(key.sign(signing.encode("ascii"), ec.ECDSA(hashes.SHA256())))
    return f"{signing}.{_b64(r.to_bytes(32, 'big') + sig_s.to_bytes(32, 'big'))}"


class _NoDeviceTokenInLog(logging.Filter):
    """Der HTTP-Client schreibt auf Stufe INFO die Adresse jeder Anfrage, die HTTP/2-Pakete auf Stufe DEBUG jede
    Kopfzeile; bei APNs stehen darin das Token (/3/device/<token>) und das JWT (authorization). Solche Zeilen fallen
    weg, damit beides auch bei geschwaetzigem Protokoll nie erscheint."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            text = record.getMessage().lower()
        except Exception:  # noqa: BLE001 - eine nicht formatierbare Zeile ist nicht unsere
            return True
        return "/3/device/" not in text and "authorization" not in text


_log_filter = _NoDeviceTokenInLog()
# Protokolle, in die HTTP-Client und HTTP/2-Pakete Adressen und Kopfzeilen schreiben (ein Filter gilt nur fuer genau
# den Logger, an dem er haengt, nicht fuer dessen Kinder)
_CLIENT_LOGGERS = ("httpx2", "httpx", "httpcore2.http2", "httpcore.http2", "httpcore2.connection", "httpcore.connection",
                   "hpack.hpack", "hpack.table")


def _http_client_module():
    """HTTP-Client mit HTTP/2: httpx (im Repo als `httpx2`, kommt mit dem Anthropic-SDK) plus das Paket `h2`.
    ImportError, wenn eines fehlt."""
    import h2  # noqa: F401 - nur pruefen: ohne das Paket kann der Client kein HTTP/2
    try:
        import httpx2 as httpx
    except ImportError:
        import httpx
    return httpx


class Http2Transport:
    """Der echte Weg zu Apple: POST https://<host>/3/device/<token> ueber HTTP/2; die Verbindung bleibt offen.
    Schnittstelle des Versands (Tests setzen eine Attrappe ein): Aufruf (host, token, headers, body) ->
    (Status, Kopfzeilen, Rumpf)."""

    def __init__(self, verify=True, port: int = 443, timeout: float = TIMEOUT_S):
        self.verify, self.port, self.timeout = verify, port, timeout
        self._client = None
        self._lock = threading.Lock()

    @staticmethod
    def missing() -> str | None:
        """Grund, warum HTTP/2 hier nicht geht (Paket fehlt), sonst None."""
        try:
            _http_client_module()
        except ImportError:
            return f"Weck-Signal: das Paket h2 (HTTP/2, requirements.txt) ist nicht installiert. {NOTHING_SENT}"
        return None

    def _open(self):
        with self._lock:
            if self._client is None:
                httpx = _http_client_module()
                for name in _CLIENT_LOGGERS:
                    logger = logging.getLogger(name)
                    if _log_filter not in logger.filters:
                        logger.addFilter(_log_filter)
                self._client = httpx.Client(http1=False, http2=True, verify=self.verify, timeout=self.timeout, trust_env=False,
                                            limits=httpx.Limits(max_connections=4, max_keepalive_connections=2, keepalive_expiry=600))
            return self._client

    def __call__(self, host: str, token: str, headers: dict, body: bytes) -> tuple[int, dict, bytes]:
        r = self._open().post(f"https://{host}:{self.port}/3/device/{token}", headers=headers, content=body)
        return r.status_code, {k.lower(): v for k, v in r.headers.items()}, r.content

    def close(self) -> None:
        with self._lock:
            client, self._client = self._client, None
        if client is not None:
            client.close()


Transport = Callable[[str, str, dict, bytes], tuple[int, dict, bytes]]


def _reason(body: bytes) -> tuple[str | None, datetime | None]:
    """Grund und (bei 410) Zeitpunkt aus Apples Antwort {"reason": "...", "timestamp": <ms>}."""
    try:
        d = json.loads(body.decode("utf-8")) if body else {}
    except (ValueError, UnicodeDecodeError):
        return None, None
    if not isinstance(d, dict):
        return None, None
    reason = d.get("reason") if isinstance(d.get("reason"), str) else None
    ts = d.get("timestamp")
    try:
        at = datetime.fromtimestamp(ts / 1000, timezone.utc) if isinstance(ts, (int, float)) and not isinstance(ts, bool) else None
    except (OverflowError, OSError, ValueError):
        at = None
    # Apples Gruende sind Woerter wie BadDeviceToken: nur Buchstaben uebernehmen (nichts Fremdes ins Protokoll)
    return (re.sub(r"[^A-Za-z]", "", reason)[:40] or None) if reason else None, at


def _retry_after(headers: dict) -> int:
    try:
        return max(0, int(str(headers.get("retry-after") or "").strip()))
    except ValueError:
        return 0


class Sender:
    """Ein Durchlauf (`tick`) sendet alle anstehenden Signale. Haelt das JWT, die Pause nach 429/5xx und merkt sich,
    was schon einmal ins Protokoll geschrieben wurde. Eine Instanz je Prozess (die Schleife), in Tests je Test."""

    def __init__(self, transport: Transport | None = None):
        self.transport = transport
        self._jwt: str | None = None
        self._jwt_at = 0
        self._pause_until: datetime | None = None
        self._backoff = 0
        self._said: str | None = None

    # -- Protokoll: denselben Zustand nur einmal melden
    def _say_once(self, message: str) -> None:
        if message != self._said:
            self._said = message
            log.warning(message)

    # -- Anmeldung bei Apple
    def _token(self, s: Settings, now: datetime) -> str:
        at = int(now.timestamp())
        if self._jwt is None or at - self._jwt_at >= JWT_REFRESH_S or at < self._jwt_at:
            self._jwt, self._jwt_at = provider_jwt(s, at), at
        return self._jwt

    def _drop_jwt(self, now: datetime) -> None:
        """Apple lehnt das JWT ab: ein neues gibt es fruehestens JWT_MIN_INTERVAL_S nach dem letzten."""
        if int(now.timestamp()) - self._jwt_at >= JWT_MIN_INTERVAL_S:
            self._jwt = None

    # -- Pause
    def _pause(self, now: datetime, seconds: int, why: str) -> None:
        self._pause_until = now + timedelta(seconds=seconds)
        log.warning("Weck-Signal: Pause bis %s (%s). So lange wird nichts gesendet.", _iso(self._pause_until), why)

    def _back_off(self, now: datetime, why: str, at_least: int = 0) -> None:
        self._backoff = min(BACKOFF_MAX_S, self._backoff * 2 if self._backoff else BACKOFF_START_S)
        self._pause(now, min(max(self._backoff, at_least), 2 * BACKOFF_MAX_S), why)

    def paused_until(self) -> datetime | None:
        return self._pause_until

    # -- ein Signal
    def headers(self, s: Settings, now: datetime, slot: datetime) -> dict:
        return {"authorization": f"bearer {self._token(s, now)}", "apns-push-type": PUSH_TYPE, "apns-priority": PRIORITY,
                "apns-topic": s.topic,
                "apns-expiration": str(int((slot + timedelta(minutes=INTERVAL_MINUTES)).timestamp()))}

    def tick(self, now: datetime | None = None) -> dict:
        """Alle anstehenden Signale senden. Wirft nie; liefert Zaehler {sent, removed, errors, state}.
        state: off (ausgeschaltet oder nicht eingerichtet), paused, ok."""
        now = now or accounts.now()
        out = {"sent": 0, "removed": 0, "errors": 0, "state": "ok"}
        s = settings()
        why = problem(s) or (Http2Transport.missing() if self.transport is None else None)
        if why:
            self._say_once(why)
            return {**out, "state": "off"}
        if self._pause_until is not None and now < self._pause_until:
            return {**out, "state": "paused"}
        self._pause_until = None
        if self.transport is None:
            self.transport = Http2Transport()
        deadline = time.monotonic() + TICK_BUDGET_S
        for row, slot in due(now):
            if time.monotonic() > deadline:
                break
            token = row["token"]
            if not claim(token, slot, now):
                continue                                    # ein anderer Prozess war schneller
            try:
                headers = self.headers(s, now, slot)
            except Exception as e:  # noqa: BLE001 - Schluesseldatei unlesbar oder kein EC-Schluessel
                _release(token, now, row["last_sent_at"])
                self._say_once(f"Weck-Signal: der APNs-Schlüssel aus {ENV_KEY_PATH} lässt sich nicht lesen "
                               f"({type(e).__name__}). {NOTHING_SENT}")
                self._pause_until = now + timedelta(seconds=CONFIG_PAUSE_S)
                return {**out, "state": "off"}
            try:
                status, resp_headers, body = self.transport(HOSTS[row["environment"]], token, headers, PAYLOAD)
            except Exception as e:  # noqa: BLE001 - Netz, Zeitlimit: nur die Art des Fehlers, nie Text oder Adresse
                out["errors"] += 1
                _set_error(token, "transport")
                self._back_off(now, f"Apple nicht erreichbar, {type(e).__name__}, Gerät {short(token)}")
                out["state"] = "paused"
                break
            reason, invalid_since = _reason(body)
            if status == 200:
                out["sent"] += 1
                self._backoff = 0
                if row["last_error"]:
                    _set_error(token, None)
            elif status == 410 or (status == 400 and reason in INVALID_TOKEN_REASONS):
                if _remove_invalid(token, invalid_since if status == 410 else None):
                    out["removed"] += 1
                    log.info("Weck-Signal: Gerät %s bei Apple nicht mehr gültig (%s %s), Eintrag gelöscht", short(token), status, reason or "-")
                else:
                    _set_error(token, reason or str(status))
            elif status in PAUSE_STATUS:
                _release(token, now, row["last_sent_at"])
                _set_error(token, reason or str(status))
                self._back_off(now, f"Apple antwortet {status} {reason or ''}".strip() + f", Gerät {short(token)}",
                               at_least=_retry_after(resp_headers))
                out["state"] = "paused"
                break
            elif status == 403 or (status == 400 and reason in CONFIG_REASONS):
                _release(token, now, row["last_sent_at"])
                _set_error(token, reason or str(status))
                if status == 403:
                    self._drop_jwt(now)
                self._say_once(f"Weck-Signal: Apple lehnt die Einrichtung ab ({status} {reason or '-'}). Bitte {ENV_KEY_PATH}, "
                               f"{ENV_KEY_ID}, {ENV_TEAM_ID} und {ENV_TOPIC} prüfen.")
                self._pause(now, CONFIG_PAUSE_S, f"Einrichtung, {status} {reason or '-'}")
                out["state"] = "paused"
                break
            else:
                out["errors"] += 1
                _set_error(token, reason or str(status))
                log.warning("Weck-Signal: Gerät %s, Apple antwortet %s %s", short(token), status, reason or "-")
        if out["sent"] or out["removed"] or out["errors"]:
            log.info("Weck-Signal: %d gesendet, %d ungültige Geräte gelöscht, %d Fehler", out["sent"], out["removed"], out["errors"])
        return out


# ---------------------------------------------------------------- Schleife im Dienst

def run_loop(stop: threading.Event, sender: Sender | None = None, tick_seconds: float = TICK_S) -> None:
    """Bis `stop` gesetzt ist alle `tick_seconds` einen Durchlauf. Ein Fehler beendet die Schleife nie."""
    sender = sender or Sender()
    while not stop.is_set():
        try:
            sender.tick()
        except Exception as e:  # noqa: BLE001 - der Thread darf nie sterben; naechster Durchlauf versucht es wieder
            log.warning("Weck-Signal: Durchlauf abgebrochen (%s)", type(e).__name__)
        stop.wait(tick_seconds)


_said_off = False


def start_background(stop: threading.Event) -> threading.Thread | None:
    """Vom Zeitplan des Dienstes gerufen (app/jobs.py, Runner.start). Ausgeschaltet: keine Schleife, ein Satz im
    Protokoll (einmal je Prozess). Eingeschaltet: eigener Thread, damit ein langsamer Versand weder Abgleich noch
    Loeschfristen aufhaelt; fehlt noch der Schluessel, meldet die Schleife das einmal und sendet nichts."""
    global _said_off
    if not settings().enabled:
        if not _said_off:
            _said_off = True
            log.warning(problem())
        return None
    t = threading.Thread(target=run_loop, args=(stop,), name="uniflow-wake", daemon=True)
    t.start()
    return t


# ---------------------------------------------------------------- Stand ansehen (sendet nichts)

def status() -> dict:
    s = settings()
    why = problem(s) or Http2Transport.missing()
    with cursor() as conn:
        rows = conn.execute(f"SELECT environment, COUNT(*) AS n, MAX(last_sent_at) AS sent FROM {TABLE} GROUP BY environment").fetchall()
    return {"ready": why is None, "note": why, "topic": s.topic,
            "window": f"{WINDOW_START_HOUR:02d}:00-{WINDOW_END_HOUR:02d}:00 Ortszeit des Geräts, alle {INTERVAL_MINUTES} Minuten",
            "devices": {r["environment"]: r["n"] for r in rows}, "last_sent_at": max((r["sent"] for r in rows if r["sent"]), default=None)}


def main(argv: list[str]) -> int:
    """python -m app.wake_push --status: zeigt, ob das Weck-Signal eingerichtet ist und wie viele Geraete gemeldet sind."""
    if argv != ["--status"]:
        print("Aufruf: python -m app.wake_push --status")
        return 2
    st = status()
    print("Weck-Signal: bereit (eingeschaltet, Schlüssel gefunden)." if st["ready"] else st["note"])
    print(f"Zeitplan: {st['window']}")
    print(f"Bundle-ID (apns-topic): {st['topic']}")
    print("Gemeldete Geräte: " + (", ".join(f"{n} ({env})" for env, n in sorted(st["devices"].items())) or "keine"))
    print(f"Zuletzt gesendet: {st['last_sent_at'] or 'noch nie'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
