"""Mailversand des gehosteten Dienstes: Passwort-Reset-Link und Willkommensmail nach der Registrierung.

Betriebsart ueber LERNAPP_MAIL:
  off   kein Versand (nur ein Protokolleintrag ohne Inhalt)
  log   die ganze Mail wird in `log_path()` = config.BASE_LOG_DIR/mail.log geschrieben (Standard am eigenen PC und im
        Dienst ohne SMTP-Host; so laesst sich der Reset-Link im Betrieb aus der Datei holen)
  smtp  Versand ueber smtplib (Standard im gehosteten Modus, sobald LERNAPP_SMTP_HOST gesetzt ist)

SMTP: LERNAPP_SMTP_HOST, LERNAPP_SMTP_PORT (587 = STARTTLS, Standard; 465 = SSL von Anfang an, z. B. STRATO
smtp.strato.de; alles andere: STARTTLS wenn der Server es anbietet; Zertifikat und Hostname werden immer geprueft), LERNAPP_SMTP_USER / LERNAPP_SMTP_PASSWORD (leer = ohne Anmeldung), LERNAPP_MAIL_FROM
(Absender, Standard der SMTP-Nutzer bzw. no-reply@<Host der oeffentlichen URL>). LERNAPP_PUBLIC_URL ist die Basis
aller Links in Mails (z. B. https://uniflow.example); die Anmeldeseite nimmt den Reset-Token als /login?reset=<token>.

Regeln: `send` wirft nie - ein Fehler beim Versand landet in mail.log und auf der Konsole, der API-Aufruf bleibt 200.
Seit 08.11.2026 verschicken die API-Pfade (Willkommen, Bestaetigung, Reset) ueber `send_later`: im Modus smtp geht die
Mail in eine Warteschlange und ein Hintergrund-Thread je Prozess liefert sie aus - die Anfrage wartet nicht mehr bis zu
SMTP_TIMEOUT (20 s) auf STRATO und belegt keinen Thread des Pools (500 Registrierungen in einer Stunde hinter Campus-NAT).
LERNAPP_MAIL_DEFER=0 schaltet das ab (dann wieder sofort, wie vorher; Tests). Was beim Stopp des Prozesses noch in der
Warteschlange liegt, geht verloren (der Nutzer kann "erneut senden"; docs/release/LAUNCH-4000-2026-11-08.md).
Kommandozeile fuer den Betrieb (deploy/dienst-check.sh): `python -m app.mail send --to ADRESSE --subject BETREFF`
(Text von stdin) und `python -m app.mail status` (Modus und Host, nie Passwoerter).
Token und Passwoerter stehen nie im normalen Serverprotokoll; nur im Modus `log` steht der Reset-Link in mail.log.
mail.log ist EIN zentrales Protokoll im Protokollordner des Dienstes (`config.BASE_LOG_DIR`, im Container /logs), auch
wenn die Mail aus dem Kontext eines Kontos heraus verschickt wird (z. B. Bestaetigung erneut senden, Konto loeschen):
`config.log_dir()` zeigt dort auf `users/<id>/logs/` und wird hier absichtlich NICHT benutzt – der Betreiber soll den
Mailversand an einer Stelle pruefen koennen (docs/START-DIENST-CHECKLISTE.md, Abschnitt 11), und der Nutzerordner
faellt unter die Loeschfristen von app/retention.py.
"""
from __future__ import annotations

import os
import queue
import smtplib
import socket
import ssl
import sys
import threading
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from urllib.parse import urlsplit

from . import config

SMTP_TIMEOUT = 20
APP_NAME = "StudiNow"


# ---------------------------------------------------------------- Konfiguration

def _env(key: str, default: str = "") -> str:
    return (os.environ.get(key) or default).strip()


def mode() -> str:
    """off | log | smtp (siehe Modulkopf). Unbekannte Werte zaehlen wie nicht gesetzt (Standard der Betriebsart)."""
    m = _env("LERNAPP_MAIL").lower()
    if m in ("off", "log", "smtp"):
        return m
    return "smtp" if config.is_hosted() and _env("LERNAPP_SMTP_HOST") else "log"


def public_url() -> str:
    return _env("LERNAPP_PUBLIC_URL").rstrip("/") or f"http://localhost:{config.PORT}"


def reset_link(token: str) -> str:
    """Link, den die Anmeldeseite versteht (app/static/login.js liest den Parameter `reset`)."""
    return f"{public_url()}/login?reset={token}"


def verify_link(token: str) -> str:
    """Bestaetigungslink; die Anmeldeseite (app/static/login.js) liest den Parameter `verify`."""
    return f"{public_url()}/login?verify={token}"


def sender_address() -> str:
    if _env("LERNAPP_MAIL_FROM"):
        return _env("LERNAPP_MAIL_FROM")
    user = _env("LERNAPP_SMTP_USER")
    if "@" in user:
        return user
    host = urlsplit(public_url()).hostname or "localhost"
    return f"no-reply@{host}"


def smtp_settings() -> dict:
    port = _env("LERNAPP_SMTP_PORT") or "587"
    try:
        port_n = int(port)
    except ValueError:
        port_n = 587
    return {"host": _env("LERNAPP_SMTP_HOST"), "port": port_n, "user": _env("LERNAPP_SMTP_USER"),
            "password": os.environ.get("LERNAPP_SMTP_PASSWORD") or "", "from": sender_address()}


# ---------------------------------------------------------------- Protokoll

def log_path():
    """Zentrales Mail-Protokoll des Prozesses, unabhaengig vom Nutzerkontext (siehe Modulkopf)."""
    return config.BASE_LOG_DIR / "mail.log"


def _log(text: str) -> None:
    stamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    try:
        p = log_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(f"[{stamp}] {text}\n")
    except OSError:
        pass


def _console(line: str) -> None:
    try:
        print(f"[mail] {line}", file=sys.stderr, flush=True)
    except (OSError, ValueError, UnicodeEncodeError):
        pass


# ---------------------------------------------------------------- Versand

def build_message(to: str, subject: str, text: str) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = sender_address()
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=False, usegmt=True)
    msg["Message-ID"] = make_msgid(domain=urlsplit(public_url()).hostname or "localhost")
    msg["Auto-Submitted"] = "auto-generated"
    msg.set_content(text, charset="utf-8")
    return msg


def _send_smtp(msg: EmailMessage) -> None:
    s = smtp_settings()
    if not s["host"]:
        raise RuntimeError("LERNAPP_SMTP_HOST ist nicht gesetzt")
    # Zertifikat und Hostname pruefen (smtplib prueft ohne eigenen Kontext NICHT; das Passwort des Postfachs geht hier durch)
    ctx = ssl.create_default_context()
    if s["port"] == 465:
        client = smtplib.SMTP_SSL(s["host"], s["port"], timeout=SMTP_TIMEOUT, context=ctx)
    else:
        client = smtplib.SMTP(s["host"], s["port"], timeout=SMTP_TIMEOUT)
    try:
        client.ehlo()
        if s["port"] != 465 and (s["port"] == 587 or client.has_extn("starttls")):
            client.starttls(context=ctx)
            client.ehlo()
        if s["user"]:
            client.login(s["user"], s["password"])
        client.send_message(msg)
    finally:
        try:
            client.quit()
        except (smtplib.SMTPException, OSError):
            pass


def send(to: str, subject: str, text: str) -> bool:
    """Verschickt eine Textmail (UTF-8) nach LERNAPP_MAIL. Liefert True bei Erfolg, False bei Fehler oder `off`;
    wirft nie, damit kein API-Aufruf am Mailversand scheitert."""
    to = (to or "").strip()
    if not to:
        return False
    m = mode()
    if m == "off":
        _log(f"nicht verschickt (LERNAPP_MAIL=off): an {to}, Betreff: {subject}")
        return False
    if m == "log":
        _log(f"MAIL an {to} | Von: {sender_address()} | Betreff: {subject}\n{text}\n--- Ende der Mail ---")
        return True
    try:
        _send_smtp(build_message(to, subject, text))
    except (smtplib.SMTPException, OSError, socket.timeout, RuntimeError, ValueError) as e:
        # Fehlertext ohne Mailinhalt: der Reset-Link darf hier nicht stehen
        _log(f"FEHLER beim Versand an {to} (Betreff: {subject}): {type(e).__name__}: {e}")
        _console(f"Versand an {to} fehlgeschlagen: {type(e).__name__}: {e}")
        return False
    _log(f"verschickt an {to} | Betreff: {subject}")
    return True


# ---------------------------------------------------------------- Versand im Hintergrund (08.11.2026)

QUEUE_MAX = 2000                 # je Prozess; voll = Mail geht verloren und steht als Fehler in mail.log
_queue: queue.Queue | None = None
_worker: threading.Thread | None = None
_qlock = threading.Lock()


def deferred() -> bool:
    """Mails aus API-Aufrufen im Hintergrund ausliefern: nur im Modus smtp, und nicht mit LERNAPP_MAIL_DEFER=0."""
    return mode() == "smtp" and _env("LERNAPP_MAIL_DEFER", "1") != "0"


def _drain() -> None:
    assert _queue is not None
    while True:
        to, subject, text = _queue.get()
        try:
            send(to, subject, text)
        except Exception as e:  # noqa: BLE001 - send wirft nicht; Sicherheitsnetz, damit der Thread nie stirbt
            _log(f"FEHLER im Hintergrundversand an {to} (Betreff: {subject}): {type(e).__name__}: {e}")
        finally:
            _queue.task_done()


def _ensure_worker() -> queue.Queue:
    global _queue, _worker
    with _qlock:
        if _queue is None:
            _queue = queue.Queue(maxsize=QUEUE_MAX)
        if _worker is None or not _worker.is_alive():
            _worker = threading.Thread(target=_drain, name="uniflow-mail", daemon=True)
            _worker.start()
        return _queue


def send_later(to: str, subject: str, text: str) -> bool:
    """Wie `send`, aber im Modus smtp ohne zu warten: True = angenommen (Warteschlange) bzw. verschickt/protokolliert."""
    if not deferred():
        return send(to, subject, text)
    try:
        _ensure_worker().put_nowait((to, subject, text))
        return True
    except queue.Full:
        _log(f"FEHLER: Warteschlange voll ({QUEUE_MAX}), nicht verschickt: an {to}, Betreff: {subject}")
        _console(f"Mail-Warteschlange voll, Mail an {to} verworfen")
        return False


def pending() -> int:
    """Noch nicht ausgelieferte Mails dieses Prozesses."""
    return _queue.qsize() if _queue is not None else 0


def flush(timeout: float = 10.0) -> bool:
    """Auf die Warteschlange warten (Tests, geordnetes Beenden); True, wenn sie leer wurde."""
    import time
    deadline = time.monotonic() + timeout
    while _queue is not None and _queue.unfinished_tasks > 0 and time.monotonic() < deadline:
        time.sleep(0.01)
    return _queue is None or _queue.unfinished_tasks == 0


# ---------------------------------------------------------------- Vorlagen (Deutsch)

def reset_text(link: str) -> str:
    from . import accounts
    return (f"Hallo,\n\n"
            f"für dein {APP_NAME}-Konto wurde ein neues Passwort angefordert. Mit diesem Link kannst du eines setzen:\n\n"
            f"{link}\n\n"
            f"Der Link gilt {accounts.RESET_MINUTES} Minuten und nur einmal. Nach dem Setzen meldest du dich auf allen Geräten neu an.\n\n"
            f"Wenn du kein neues Passwort angefordert hast, kannst du diese Mail ignorieren; dein Passwort bleibt unverändert.\n\n"
            f"{APP_NAME}")


def welcome_text(email: str, link: str | None = None) -> str:
    confirm = (f"Bitte bestätige deine E-Mail-Adresse mit diesem Link (gilt 48 Stunden):\n\n{link}\n\n"
               f"Bis dahin kannst du alles nutzen, nur noch keine Lösungen in der Community veröffentlichen.\n\n") if link else ""
    return (f"Hallo,\n\n"
            f"dein {APP_NAME}-Konto für {email} ist angelegt. Du kannst dich damit auf allen deinen Geräten anmelden:\n\n"
            f"{public_url()}/login\n\n"
            f"{confirm}"
            f"Die Zugangsdaten deiner Hochschule gibst du erst in der App ein; sie liegen verschlüsselt am Konto und werden "
            f"nur für den Abgleich genutzt.\n\n"
            f"Wenn du dieses Konto nicht angelegt hast, antworte bitte kurz auf diese Mail oder lösche das Konto in der App "
            f"unter Konto → Konto löschen.\n\n"
            f"{APP_NAME}")


def send_reset(email: str, token: str) -> None:
    """Versandweg fuer accounts.reset_sender: (email, token) -> None. Im Hintergrund (send_later)."""
    send_later(email, f"{APP_NAME}: Passwort zurücksetzen", reset_text(reset_link(token)))


def send_welcome(email: str, verify_token: str | None = None) -> None:
    send_later(email, f"{APP_NAME}: Willkommen", welcome_text(email, verify_link(verify_token) if verify_token else None))


def verify_text(link: str) -> str:
    return (f"Hallo,\n\n"
            f"bitte bestätige die E-Mail-Adresse deines {APP_NAME}-Kontos mit diesem Link:\n\n{link}\n\n"
            f"Der Link gilt 48 Stunden und nur einmal. Wenn du das nicht angefordert hast, kannst du diese Mail ignorieren.\n\n"
            f"{APP_NAME}")


def send_verify(email: str, token: str) -> None:
    """Versandweg fuer accounts.verify_sender: (email, token) -> None. Im Hintergrund (send_later)."""
    send_later(email, f"{APP_NAME}: E-Mail-Adresse bestätigen", verify_text(verify_link(token)))


# ---------------------------------------------------------------- Kommandozeile (Betrieb)

def main(argv: list[str] | None = None) -> int:
    """`python -m app.mail status` | `python -m app.mail send --to ADRESSE --subject BETREFF [--text TEXT]` (sonst stdin).
    Fuer deploy/dienst-check.sh: Warnmails ueber das vorhandene SMTP-Setup des Dienstes, ohne Passwoerter im Skript.
    Exit 0 = verschickt bzw. protokolliert, 1 = Fehler, 2 = falscher Aufruf."""
    import argparse
    ap = argparse.ArgumentParser(prog="python -m app.mail", description="Mailversand des StudiNow-Dienstes (Betrieb)")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("status", help="Modus (off/log/smtp), SMTP-Host und Absender anzeigen - nie das Passwort")
    s = sub.add_parser("send", help="eine Textmail sofort verschicken (Text aus --text oder stdin)")
    s.add_argument("--to", required=True)
    s.add_argument("--subject", required=True)
    s.add_argument("--text", default=None)
    a = ap.parse_args(argv)
    if a.cmd == "status":
        st = smtp_settings()
        print(f"mode={mode()} host={st['host'] or '-'} port={st['port']} user={'ja' if st['user'] else 'nein'} "
              f"from={sender_address()} defer={'ja' if deferred() else 'nein'} log={log_path()}")
        return 0
    if a.cmd == "send":
        text = a.text if a.text is not None else sys.stdin.read()
        if not text.strip():
            print("Kein Text (stdin leer).", file=sys.stderr)
            return 2
        ok = send(a.to, a.subject, text)
        print(f"{'verschickt' if ok else 'NICHT verschickt'} an {a.to} (Modus {mode()})")
        return 0 if ok else 1
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
