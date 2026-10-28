"""Mailversand (app/mail.py): Modus log schreibt die Mail nach mail.log, Modus smtp spricht smtplib richtig an
(STARTTLS/SSL, Anmeldung, Absender, Empfaenger, UTF-8-Inhalt), Fehler lassen keinen API-Aufruf scheitern, und im
gehosteten Modus haengt der Server den Versand als accounts.reset_sender ein (Reset-Link mit dem richtigen Token)."""
import asyncio
import json
import smtplib

import pytest
from conftest import asgi_call


@pytest.fixture
def mail_env(monkeypatch, tmp_path):
    """Mail in einen eigenen Protokollordner, keine echten Umgebungswerte."""
    from app import config
    for k in ("LERNAPP_MAIL", "LERNAPP_SMTP_HOST", "LERNAPP_SMTP_PORT", "LERNAPP_SMTP_USER", "LERNAPP_SMTP_PASSWORD",
              "LERNAPP_MAIL_FROM", "LERNAPP_PUBLIC_URL"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setattr(config, "LOG_DIR", tmp_path)
    return tmp_path


class FakeSMTP:
    """Zeichnet auf, was der Versand mit smtplib macht; eine Instanz je Klasse (SMTP / SMTP_SSL)."""
    instances: list = []

    def __init__(self, host, port, timeout=None):
        self.host, self.port, self.timeout = host, port, timeout
        self.calls: list = []
        self.messages: list = []
        self.fail_on = None
        FakeSMTP.instances.append(self)

    def ehlo(self):
        self.calls.append("ehlo")

    def has_extn(self, name):
        return name == "starttls"

    def starttls(self):
        self.calls.append("starttls")

    def login(self, user, password):
        self.calls.append(("login", user, password))

    def send_message(self, msg):
        if self.fail_on == "send":
            raise smtplib.SMTPException("Postausgang kaputt")
        self.calls.append("send_message")
        self.messages.append(msg)

    def quit(self):
        self.calls.append("quit")


class FakeSMTPSSL(FakeSMTP):
    pass


def test_mode_defaults(mail_env, monkeypatch):
    from app import config, mail
    assert mail.mode() == "log", "am PC: Protokoll"
    monkeypatch.setattr(config, "MODE", "hosted")
    assert mail.mode() == "log", "gehostet ohne SMTP-Host: Protokoll"
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "mail.example")
    assert mail.mode() == "smtp"
    monkeypatch.setenv("LERNAPP_MAIL", "off")
    assert mail.mode() == "off"
    monkeypatch.setenv("LERNAPP_MAIL", "unsinn")
    assert mail.mode() == "smtp", "unbekannter Wert: Standard der Betriebsart"
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://uniflow.example/")
    assert mail.reset_link("abc") == "https://uniflow.example/login?reset=abc"
    assert mail.sender_address() == "no-reply@uniflow.example"


def test_log_mode_writes_subject_and_link_to_mail_log(mail_env, monkeypatch):
    from app import mail
    monkeypatch.setenv("LERNAPP_MAIL", "log")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://uniflow.example")
    assert mail.send_reset("max@beispiel.de", "tok-123") is None
    text = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "max@beispiel.de" in text and "Passwort" in text
    assert "https://uniflow.example/login?reset=tok-123" in text, "der Link mit dem Reset-Parameter der Anmeldeseite"
    assert "30 Minuten" in text
    mail.send_welcome("max@beispiel.de", "v-123")
    text = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "Willkommen" in text and "https://uniflow.example/login?verify=v-123" in text and "48 Stunden" in text
    mail.send_verify("max@beispiel.de", "v-456")
    text = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "E-Mail-Adresse bestätigen" in text and "https://uniflow.example/login?verify=v-456" in text
    # off: nur ein Vermerk, kein Inhalt
    monkeypatch.setenv("LERNAPP_MAIL", "off")
    assert mail.send("x@beispiel.de", "Betreff", "geheimer-inhalt") is False
    text = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "LERNAPP_MAIL=off" in text and "geheimer-inhalt" not in text


def test_smtp_starttls_login_and_message(mail_env, monkeypatch):
    from app import mail
    FakeSMTP.instances.clear()
    monkeypatch.setattr(smtplib, "SMTP", FakeSMTP)
    monkeypatch.setattr(smtplib, "SMTP_SSL", FakeSMTPSSL)
    monkeypatch.setenv("LERNAPP_MAIL", "smtp")
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")
    monkeypatch.setenv("LERNAPP_SMTP_USER", "postausgang")
    monkeypatch.setenv("LERNAPP_SMTP_PASSWORD", "sehr-geheim")
    monkeypatch.setenv("LERNAPP_MAIL_FROM", "UniFlow <no-reply@uniflow.example>")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://uniflow.example")
    assert mail.send("Ärztin@beispiel.de", "Betreff mit Umlaut ä", "Hallo,\n\nUmlaute äöü und ß.\n") is True
    s = FakeSMTP.instances[-1]
    assert type(s) is FakeSMTP and (s.host, s.port) == ("smtp.example", 587) and s.timeout
    assert s.calls == ["ehlo", "starttls", "ehlo", ("login", "postausgang", "sehr-geheim"), "send_message", "quit"]
    m = s.messages[0]
    assert m["From"] == "UniFlow <no-reply@uniflow.example>" and m["To"] == "Ärztin@beispiel.de"
    assert m["Subject"] == "Betreff mit Umlaut ä" and "äöü und ß" in m.get_content()
    assert m.get_content_charset() == "utf-8" and m.get_content_type() == "text/plain"
    log = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "verschickt an Ärztin@beispiel.de" in log and "sehr-geheim" not in log and "Umlaute äöü" not in log
    # Port 465: SSL von Anfang an, kein STARTTLS; ohne Nutzer keine Anmeldung
    monkeypatch.setenv("LERNAPP_SMTP_PORT", "465")
    monkeypatch.delenv("LERNAPP_SMTP_USER")
    assert mail.send("a@beispiel.de", "b", "c") is True
    s = FakeSMTP.instances[-1]
    assert type(s) is FakeSMTPSSL and s.port == 465 and s.calls == ["ehlo", "send_message", "quit"]


def test_smtp_errors_are_logged_without_secrets_and_never_raise(mail_env, monkeypatch):
    from app import mail
    monkeypatch.setenv("LERNAPP_MAIL", "smtp")
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")

    class Broken(FakeSMTP):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self.fail_on = "send"
    monkeypatch.setattr(smtplib, "SMTP", Broken)
    assert mail.send_reset("max@beispiel.de", "tok-geheim") is None
    log = (mail_env / "mail.log").read_text(encoding="utf-8")
    assert "FEHLER" in log and "Postausgang kaputt" in log and "tok-geheim" not in log
    # Verbindungsfehler (OSError) ebenso
    def boom(*a, **k):
        raise OSError("keine Verbindung")
    monkeypatch.setattr(smtplib, "SMTP", boom)
    assert mail.send("x@beispiel.de", "y", "z") is False
    assert "keine Verbindung" in (mail_env / "mail.log").read_text(encoding="utf-8")


def test_hosted_reset_endpoint_uses_mail_sender_with_the_right_token(app, monkeypatch, mail_env):
    """Lifespan im gehosteten Modus haengt mail.send_reset ein; der Reset-Endpunkt verschickt den Link mit genau dem
    Token, das anschliessend das Passwort setzt. Die Antwort bleibt gleich, ob es das Konto gibt oder nicht; ein
    Versandfehler aendert sie nicht."""
    from app import accounts, config, mail, server
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_MAIL", "log")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://uniflow.example")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "reset_sender", None)
    try:
        async def run_lifespan():
            async with app.router.lifespan_context(app):
                return accounts.reset_sender
        assert asyncio.run(run_lifespan()) is mail.send_reset, "beim Start im Dienst eingehaengt"
        server.wire_hosted_services()
        st, _, body = asgi_call(app, "POST", "/api/account/register",
                                body=json.dumps({"email": "r@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
        assert st == 201
        log = (mail_env / "mail.log").read_text(encoding="utf-8")
        assert "Willkommen" in log and "r@beispiel.de" in log, "Willkommensmail nach der Registrierung"
        st, _, body = asgi_call(app, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "r@beispiel.de"}))
        assert st == 200
        log = (mail_env / "mail.log").read_text(encoding="utf-8")
        import re
        tokens = re.findall(r"https://uniflow\.example/login\?reset=([A-Za-z0-9_-]+)", log)
        assert len(tokens) == 1
        st, _, body2 = asgi_call(app, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "niemand@beispiel.de"}))
        assert (st, body2) == (200, body), "verraet nicht, ob es das Konto gibt"
        assert len(re.findall(r"reset=", (mail_env / "mail.log").read_text(encoding="utf-8"))) == 1, "kein Link fuer unbekannte Adressen"
        st, _, _ = asgi_call(app, "POST", "/api/account/password/reset", body=json.dumps({"token": tokens[0], "new_password": "noch-geheimer-456"}))
        assert st == 200, "das Token aus der Mail setzt das Passwort"
        # Versandfehler: Antwort bleibt 200
        monkeypatch.setenv("LERNAPP_MAIL", "smtp")
        monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.example")
        def boom(*a, **k):
            raise OSError("keine Verbindung")
        monkeypatch.setattr(smtplib, "SMTP", boom)
        st, _, body3 = asgi_call(app, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "r@beispiel.de"}))
        assert (st, body3) == (200, body)
    finally:
        monkeypatch.setattr(accounts, "reset_sender", None)
        accounts.db_path().unlink(missing_ok=True)
