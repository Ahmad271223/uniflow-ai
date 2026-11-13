"""Uni-Mail und Uni-Kalender (SOGo) der LUH (https://kalender.uni-hannover.de/SOGo/) und der Uni Hildesheim
(https://webmail.uni-hildesheim.de/SOGo/, Wunsch des Inhabers 06.11.2026: dasselbe SOGo), docs/UNI-MAIL-2026-11-05.md.
Rechner je Hochschule in SITES (wie `SOGoSite` im Swift-Kern); alles, was eine Adresse prueft, nimmt den Rechner
(`host`, Vorgabe LUH). Die Hochschule Hannover hat kein SOGo: dort gibt es Uni-Mail nicht.

Wunsch des Inhabers (05.11.2026): E-Mails der Uni empfangen, lesen, beantworten, weiterleiten, neu schreiben und die
Termine des Uni-Kalenders im Lernkalender/Stundenplan sehen. Gleiche Regeln und gleiche JSON-Antworten wie der
Swift-Kern (UniFlowCore/SOGo, `SOGo`, `SOGoClient`, `SOGoCalendar`); gemeinsame Faelle in
packages/shared-contracts/fixtures/sogo (tools/gen-sogo-fixture.py).

Anmeldung nur auf der echten Seite (PC: Anmeldefenster, app/unilogin.py mit `university="sogo"`; iPad: Webansicht des
Containers). Gemerkt wird nur die Sitzung (Cookies, Sitzungsname SOGO_COOKIES), nie ein Passwort. Ist sie abgelaufen
(Anmeldeformular, 401/403, Weiterleitung aus /SOGo/so/ heraus), heisst es "Anmeldung nötig"; eine stille Erneuerung mit
Passwort gibt es nicht. Im Dienst (hosted) gibt es Uni-Mail nicht: Mails liegen nur auf dem Geraet bzw. PC.

Schnittstelle (Aufbau gelesen am 05.11.2026, ~/Studora-Builds/sogo/STRUKTUR-ECHT-2026-11-05.md; Schreiben aus dem
Quelltext von SOGo abgeleitet, github.com/Alinto/sogo, UI/MailerUI/product.plist, UIxMailEditor.m, UIxMailActions.m,
UI/WebServerResources/js/Mailer/Message.service.js, Mailbox.service.js, Account.service.js):
- Konto-Pfad /SOGo/so/<benutzer>/; alle JSON-Anfragen mit Kopfzeile X-XSRF-TOKEN = Wert des Cookies XSRF-TOKEN.
- GET  Mail/0/view                          Ordner {mailboxes:[{path,name,type,children,flags}]}
- POST Mail/0/folderINBOX/view              {"sortingAttributes":{"sort":"arrival","asc":0}} -> uids, headers (<=100), unseenCount
                                             Suche: dazu "filters":[{"searchBy":"subject","searchInput":q},{"searchBy":"from",...}],
                                             sortingAttributes.match "OR" (wie "subject_or_from" der Weboberflaeche)
- POST Mail/0/folderINBOX/headers           {"uids":[...]} -> Tabelle (Zeile 0 Feldnamen), seitenweise je 50
                                             (live bestaetigt 06.11.2026 an der Uni Hildesheim, gleiches SOGo)
- GET  Mail/0/folderINBOX/<uid>/view        Nachricht (parts, from, to, cc, date, isRead); markiert sie als gelesen (wie SOGo)
- GET  .../<uid>/markMessageRead | markMessageUnread, POST .../<uid>/markMessageFlagged | markMessageUnflagged
- POST Mail/0/folderINBOX/batchDelete       {"uids":[...]} verschiebt in den Papierkorb (nie "withoutTrash")
- POST Mail/0/folderTrash/moveMessages      {"uids":[...],"folder":"/0/folderINBOX"} (Wiederherstellen)
- GET  Mail/0/compose | <uid>/reply | <uid>/replyall | <uid>/forward -> 201 {accountId, mailboxPath, draftId}
- GET  Mail/0/<Entwurfsordner>/<draftId>/edit -> {from, to, cc, bcc, subject, text, isHTML, attachmentAttrs}
- POST .../<draftId>/save   JSON (Felder) oder multipart (Feld "attachments") -> {uid, lastAttachmentAttrs}
- POST .../<draftId>/send   JSON (Felder) -> {"status":"success"} bzw. 405 {"status":"failure","message":...}
- POST Mail/unseenCount     {"mailboxes":["0/folderINBOX"]} -> {"0/folderINBOX": n}
- GET  Calendar/calendarslist, GET Calendar/eventslist?asc=1&day=YYYYMMDD&filterpopup=view_next7|view_next31&sort=start
Nicht benutzt: Mail/0/mailboxes (404), CalDAV/ics unter /SOGo/dav/ (Basic-Auth mit Passwort).

Senden geschieht nur auf ausdruecklichen Knopfdruck ("Senden") und genau einmal; nie automatisch, nie wiederholt.
"""
from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from typing import Callable
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo("Europe/Berlin")
HOST = "kalender.uni-hannover.de"                   # LUH (Vorgabe der reinen Funktionen)
BASE = f"https://{HOST}/SOGo"
# SOGo je Hochschule (Schluessel wie universities.PROFILES); fehlt eine, gibt es dort keine Uni-Mail (HsH)
SITES: dict[str, dict] = {
    "luh": {"key": "luh", "host": HOST, "name": "Uni-Mail (LUH)", "university": "Leibniz Universität Hannover",
            "short": "LUH", "room_links": True},
    "hildesheim": {"key": "hildesheim", "host": "webmail.uni-hildesheim.de", "name": "Uni-Mail (Uni Hildesheim)",
                   "university": "Universität Hildesheim", "short": "Uni Hildesheim", "room_links": False},
}
HOSTS = frozenset(s["host"] for s in SITES.values())
SESSION = "SOGO_COOKIES"
PAGE_SIZE = 50
MAX_ATTACHMENT = 20 * 1024 * 1024
SOURCE = "uni-kalender"
COLOR = "#0e7490"
NOT_AVAILABLE = "Uni-Mail gibt es nur in der App auf dem iPad und am PC (Windows-App); E-Mails gehen nie über den StudiNow-Dienst."
NOT_AT_UNI = "Uni-Mail gibt es für Studierende der Leibniz Universität Hannover und der Universität Hildesheim."


def site(key: str | None = None) -> dict | None:
    """SOGo einer Hochschule (ohne Schluessel: die dieser App-Instanz); None, wo es keins gibt (HsH)"""
    if key is None:
        from . import universities
        key = universities.current_key()
    return SITES.get(key)


def base_of(host: str) -> str:
    return f"https://{host}/SOGo"

# Reihenfolge der festen Ordner und ihre Namen in der App
FOLDER_ORDER = ("inbox", "draft", "sent", "trash", "junk", "templates")
FOLDER_NAMES = {"inbox": "Posteingang", "draft": "Entwürfe", "sent": "Gesendet", "trash": "Papierkorb", "junk": "Spam",
                "templates": "Vorlagen"}


class SOGoError(Exception):
    """code: login (Anmeldung noetig), offline, http, bad (unerwartete Antwort), refused (SOGo lehnt ab, Text in detail),
    input (Eingabe pruefen)"""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------------------------------------------- Adressen & Pfade

_CSS = (("_", "_U_"), (".", "_D_"), ("#", "_H_"), ("@", "_A_"), ("*", "_S_"), (":", "_C_"), (",", "_CO_"), (" ", "_SP_"),
        ("'", "_SQ_"), ("&", "_AM_"), ("+", "_P_"))


def css_identifier(s: str) -> str:
    """`String.prototype.asCSSIdentifier` der SOGo-Weboberflaeche (Ordnernamen in Adressen): Zeichen ersetzen,
    Nicht-ASCII weglassen, fuehrende Ziffer mit "_" """
    out = str(s or "")
    for a, b in _CSS:
        out = out.replace(a, b)
    out = "".join(ch for ch in out if ord(ch) < 128)
    if out[:1].isdigit():
        out = "_" + out
    return out


def folder_path(path: str) -> str:
    """IMAP-Pfad "INBOX/Archiv" -> "folderINBOX/folderArchiv" (wie Message.$absolutePath)"""
    return "/".join("folder" + css_identifier(p) for p in str(path or "INBOX").split("/"))


def mailbox_id(path: str) -> str:
    """Kennung fuer unseenCount: "0/folderINBOX" """
    return "0/" + folder_path(path)


def move_target(path: str) -> str:
    """Ziel fuer moveMessages: "/0/folderINBOX" """
    return "/0/" + folder_path(path)


def user_from_url(url: str | None, host: str = HOST) -> str | None:
    """Konto aus einer angemeldeten Adresse https://<host>/SOGo/so/<benutzer>/... (nur HTTPS, nur der Rechner der
    Hochschule); sonst None. Der Benutzername bleibt, wie er in der Adresse steht (LUH: E-Mail-Adresse)."""
    if not url:
        return None
    p = urllib.parse.urlsplit(str(url))
    try:
        port = p.port
    except ValueError:
        return None
    if p.scheme.lower() != "https" or (p.hostname or "").lower() != host or port not in (None, 443):
        return None
    parts = p.path.split("/")
    # ["", "SOGo", "so", "<benutzer>", ...]
    if len(parts) < 5 or parts[1] != "SOGo" or parts[2] != "so":
        return None
    user = urllib.parse.unquote(parts[3])
    if not user or user in (".", "..") or "/" in user or any(ord(c) < 32 for c in user) or len(user) > 128:
        return None
    return user


def user_base(user: str, host: str = HOST) -> str:
    return f"{base_of(host)}/so/{urllib.parse.quote(user, safe='@')}"


def looks_like_login(text: str | None) -> bool:
    """Anmeldeseite von SOGo (Formular loginForm, Feld passwordField)"""
    t = str(text or "")
    return 'name="loginForm"' in t or "app.creds.username" in t or 'id="passwordField"' in t


def looks_like_html(content: bytes) -> bool:
    """HTML statt JSON (13.11.2026, wie SOGo.looksLikeHTML): fast immer eine abgelaufene oder umgeleitete Anmeldung."""
    head = content[:600].decode("utf-8", "replace").strip().lower()
    return head.startswith("<!doctype html") or head.startswith("<html") or "<html" in head


def expired(status: int, final_url: str | None, body: str | None, host: str = HOST) -> bool:
    """Sitzung abgelaufen? 401/403, Weiterleitung aus /SOGo/so/ heraus (Anmeldeseite) oder Anmeldeformular im Inhalt"""
    if status in (401, 403):
        return True
    if final_url and user_from_url(final_url, host) is None:
        return True
    return looks_like_login(body)


def truthy(v) -> bool:
    """Wahrheitswert aus SOGo-JSON (true/false, 0/1, "1")"""
    if v is True:
        return True
    if v is False or v is None:
        return False
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes")
    return False


def _text(v) -> str:
    if v is None or isinstance(v, (dict, list)):
        return ""
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def address(v) -> dict | None:
    """{"name","email"} aus einem Adress-Eintrag von SOGo"""
    if not isinstance(v, dict):
        return None
    name, email = _text(v.get("name")).strip(), _text(v.get("email")).strip()
    if not name and not email:
        return None
    return {"name": name, "email": email}


def addresses(v) -> list[dict]:
    if not isinstance(v, list):
        return []
    return [a for a in (address(x) for x in v) if a]


def address_text(a: dict | None) -> str:
    """Anzeige: Name, sonst Adresse"""
    if not a:
        return ""
    return a.get("name") or a.get("email") or ""


def address_line(a: dict) -> str:
    """Empfaenger fuer das Schreiben: "Name <adresse>" bzw. nur die Adresse"""
    name, email = a.get("name") or "", a.get("email") or ""
    if name and email and name != email:
        return f"{name} <{email}>"
    return email or name


_EMAIL = re.compile(r"^[^@ \t\r\n<>\"(),;:]+@[^@ \t\r\n<>\"(),;:]+\.[^@ \t\r\n<>\"(),;:]+$")


def email_of(entry: str) -> str | None:
    """Adresse aus "Name <a@b.de>" oder "a@b.de"; None, wenn keine gueltige"""
    s = str(entry or "").strip()
    lt, gt = s.rfind("<"), s.rfind(">")
    if lt >= 0 and gt > lt:
        s = s[lt + 1:gt].strip()
    return s if _EMAIL.match(s) else None


def split_recipients(text: str) -> dict:
    """Empfaengerfeld (Komma, Semikolon, Zeilenumbruch; nicht in Anfuehrungszeichen oder <>) -> {"valid": [...],
    "invalid": [...]}"""
    out, cur, quote, angle = [], "", False, False
    for ch in str(text or ""):
        if ch == '"' and not angle:
            quote = not quote
        elif ch == "<" and not quote:
            angle = True
        elif ch == ">" and not quote:
            angle = False
        if ch in ",;\n" and not quote and not angle:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    valid, invalid = [], []
    for x in out:
        x = " ".join(x.split())
        if not x:
            continue
        (valid if email_of(x) else invalid).append(x)
    return {"valid": valid, "invalid": invalid}


def recipient_list(v) -> list[str]:
    """Empfaenger aus der Antwort von edit (Liste von Texten oder Adress-Eintraegen)"""
    if isinstance(v, str):
        r = split_recipients(v)
        return r["valid"] + r["invalid"]
    if not isinstance(v, list):
        return []
    out = []
    for x in v:
        if isinstance(x, dict):
            a = address(x)
            if a:
                out.append(address_line(a))
        elif _text(x).strip():
            out.append(" ".join(_text(x).split()))
    return out


# ---------------------------------------------------------------------------------------------------- HTML

_I = re.IGNORECASE
_S = re.IGNORECASE | re.DOTALL
_SP = "[ \t\r\n\f]"
_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
_BLOCKS = re.compile(r"<(script|style|iframe|object|embed|noscript|form|svg|math|template|head|title)\b[^>]*>.*?</\1" + _SP + r"*>", _S)
_SINGLE = re.compile(r"</?(script|style|iframe|object|embed|noscript|form|svg|math|template|head|title|link|meta|base|frame|frameset|input|button|textarea|select|option|html|body)\b[^>]*>", _I)
_EVENT = re.compile(_SP + r"+on[A-Za-z]+" + _SP + r"*=" + _SP + r"*(\"[^\"]*\"|'[^']*'|[^ \t\r\n\f>]+)", _I)
_SCRIPT_URL = re.compile(r"\b(href|src|action|formaction|xlink:href)" + _SP + r"*=" + _SP + r"*([\"']?)" + _SP + r"*(javascript|vbscript|data|livescript):[^\"'> \t\r\n\f]*\2", _I)
_REMOTE = re.compile(r"\b(src|srcset|background|poster)" + _SP + r"*=" + _SP + r"*([\"']?)" + _SP + r"*(https?:)?//", _I)
_CSS_URL = re.compile(r"url" + _SP + r"*\(", _I)
_UNSAFE = re.compile(_SP + r"+unsafe-[A-Za-z-]+" + _SP + r"*=" + _SP + r"*(\"[^\"]*\"|'[^']*'|[^ \t\r\n\f>]+)", _I)


def sanitize_html(html: str | None) -> dict:
    """HTML einer Mail fuer die Anzeige: ohne Skripte, Formulare, Rahmen, Ereignis-Attribute und javascript:-Links;
    entfernte Bilder und Hintergruende werden nicht geladen (Schutz vor Zaehlpixeln). -> {"html", "remote_blocked"}.
    Die Anzeige laedt zusaetzlich ohne JavaScript und mit Content-Security-Policy ohne Netz."""
    s = str(html or "").replace("\r\n", "\n")
    s = _COMMENT.sub("", s)
    s = _BLOCKS.sub("", s)
    s = _SINGLE.sub("", s)
    s = _EVENT.sub("", s)
    s = _UNSAFE.sub("", s)
    s = _SCRIPT_URL.sub(lambda m: f'{m.group(1)}="#"', s)
    blocked = bool(_REMOTE.search(s)) or bool(_CSS_URL.search(s))
    s = _REMOTE.sub(lambda m: f"data-blocked-{m.group(1).lower()}={m.group(2)}{m.group(3) or ''}//", s)
    s = _CSS_URL.sub("blocked(", s)
    return {"html": s.strip(), "remote_blocked": blocked}


_BR = re.compile(r"<br\b[^>]*>", _I)
_QUOTE_OPEN = re.compile(r"<blockquote\b[^>]*>", _I)
_QUOTE_CLOSE = re.compile(r"</blockquote" + _SP + r"*>", _I)
_BLOCK_END = re.compile(r"</(p|div|tr|h[1-6]|table|pre|ul|ol)" + _SP + r"*>", _I)
_LI = re.compile(r"<li\b[^>]*>", _I)
_TAG = re.compile(r"<[^>]+>")
_NUM = re.compile(r"&#([0-9]{1,7});")
_HEX = re.compile(r"&#[xX]([0-9a-fA-F]{1,6});")
_NAMED = (("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&apos;", "'"), ("&#39;", "'"))
_MANY = re.compile(r"\n{3,}")
Q_IN, Q_OUT = "\u0001", "\u0002"


def _char(n: int) -> str | None:
    if n <= 0 or n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
        return None
    return chr(n)


def entities(s: str) -> str:
    """Zeichenreferenzen: Ziffern, die festen Namen, zuletzt &amp; (nur diese, gleich im Swift-Kern)"""
    s = _NUM.sub(lambda m: _char(int(m.group(1))) or m.group(0), s)
    s = _HEX.sub(lambda m: _char(int(m.group(1), 16)) or m.group(0), s)
    for a, b in _NAMED:
        s = s.replace(a, b)
    return s.replace("&amp;", "&")


def _quote_lines(s: str) -> str:
    """Markierungen der Zitate (Q_IN/Q_OUT) in "> " am Zeilenanfang uebersetzen"""
    out, depth = [], 0
    for line in s.split("\n"):
        text, level, marker = "", None, False
        for ch in line:
            if ch == Q_IN:
                depth += 1
                marker = True
            elif ch == Q_OUT:
                depth = max(0, depth - 1)
                marker = True
            else:
                if level is None and ch not in " \t":
                    level = depth
                text += ch
        if level is None:
            if marker:
                continue
            level = depth
        out.append("> " * level + text if level else text)
    return "\n".join(out)


def html_to_text(html: str | None) -> str:
    """Klartext aus HTML (Ersatz fuer Mails ohne Textteil, Antworten auf HTML-Mails): Zeilenumbrueche, Listen, Zitate
    mit "> ", Zeichenreferenzen; hoechstens eine Leerzeile am Stueck"""
    s = str(html or "").replace("\r\n", "\n").replace("\r", "\n")
    s = _COMMENT.sub("", s)
    s = _BLOCKS.sub("", s)
    s = _BR.sub("\n", s)
    s = _QUOTE_OPEN.sub("\n" + Q_IN, s)
    s = _QUOTE_CLOSE.sub(Q_OUT + "\n", s)
    s = _LI.sub("\n• ", s)
    s = _BLOCK_END.sub("\n", s)
    s = _TAG.sub("", s)
    s = entities(s)
    s = _quote_lines(s)
    s = "\n".join(line.rstrip(" \t") for line in s.split("\n"))
    s = _MANY.sub("\n\n", s)
    return s.strip(" \t\n")


# ---------------------------------------------------------------------------------------------------- Mail: Antworten lesen

def parse_mailboxes(data) -> list[dict]:
    """Ordnerliste aus Mail/0/view: feste Ordner zuerst (Posteingang, Entwuerfe, Gesendet, Papierkorb, Spam, Vorlagen),
    dann die eigenen in Baumreihenfolge. Nicht waehlbare Ordner (\\Noselect) fehlen."""
    found: list[dict] = []

    def walk(items, level):
        for m in items if isinstance(items, list) else []:
            if not isinstance(m, dict):
                continue
            path = _text(m.get("path"))
            flags = [(_text(f)).lower() for f in (m.get("flags") or []) if isinstance(f, str)]
            if path and not any(f.lstrip("\\") == "noselect" for f in flags):
                typ = _text(m.get("type")) or "folder"
                if typ not in FOLDER_NAMES:
                    typ = "folder"
                name = FOLDER_NAMES.get(typ) if typ != "folder" else (_text(m.get("name")) or path.split("/")[-1])
                found.append({"path": path, "name": name, "type": typ, "id": mailbox_id(path), "level": level})
            walk(m.get("children"), level + 1)

    walk((data or {}).get("mailboxes") if isinstance(data, dict) else None, 0)
    special = []
    for t in FOLDER_ORDER:
        hit = next((f for f in found if f["type"] == t), None)
        if hit:
            special.append({**hit, "level": 0})
    taken = {s["path"] for s in special}
    return special + [f for f in found if f["path"] not in taken]


def folder_of_type(boxes: list[dict], typ: str, fallback: str) -> str:
    return next((b["path"] for b in boxes if b["type"] == typ), fallback)


def _flatten(v, out: list[int]) -> list[int]:
    if isinstance(v, list):
        for x in v:
            _flatten(x, out)
    elif isinstance(v, bool):
        pass
    elif isinstance(v, (int, float)) or (isinstance(v, str) and v.strip().isdigit()):
        n = int(float(v)) if not isinstance(v, str) else int(v.strip())
        if n > 0 and n not in out:
            out.append(n)
    return out


def flatten_uids(v) -> list[int]:
    return _flatten(v, [])


def parse_headers(table) -> list[dict]:
    """Kopfzeilen-Tabelle (Zeile 0 Feldnamen) -> Nachrichten der Liste"""
    if not isinstance(table, list) or not table or not isinstance(table[0], list):
        return []
    names = [_text(n) for n in table[0]]
    out = []
    for row in table[1:]:
        if not isinstance(row, list):
            continue
        d = dict(zip(names, row))
        uid = flatten_uids([d.get("uid")])
        if not uid:
            continue
        frm = addresses(d.get("From"))
        to = addresses(d.get("To"))
        labels = [_text(x) for x in d.get("Flags") or [] if isinstance(x, str)] if isinstance(d.get("Flags"), list) else []
        out.append({"uid": uid[0], "subject": _text(d.get("Subject")).strip(), "from": frm, "to": to,
                    "sender": address_text(frm[0] if frm else None), "date": _text(d.get("RelativeDate")).strip(),
                    "size": _text(d.get("Size")).strip(), "read": truthy(d.get("isRead")), "flagged": truthy(d.get("isFlagged")),
                    "answered": truthy(d.get("isAnswered")), "forwarded": truthy(d.get("isForwarded")),
                    "attachment": truthy(d.get("hasAttachment")), "labels": labels})
    return out


def ordered(messages: list[dict], uids: list[int]) -> list[dict]:
    """Nachrichten in der Reihenfolge der UIDs (fehlende fallen weg)"""
    by = {m["uid"]: m for m in messages}
    return [by[u] for u in uids if u in by]


def page_uids(uids: list[int], page: int, size: int = PAGE_SIZE) -> list[int]:
    page = max(0, int(page or 0))
    return uids[page * size:(page + 1) * size]


def parse_folder(data, folder: str, size: int = PAGE_SIZE) -> dict:
    """Antwort von .../view: alle UIDs (neueste zuerst), erste Seite, ungelesene"""
    data = data if isinstance(data, dict) else {}
    uids = flatten_uids(data.get("uids"))
    first = page_uids(uids, 0, size)
    unseen = data.get("unseenCount")
    return {"folder": folder, "uids": uids, "total": len(uids), "page": 0, "pages": (len(uids) + size - 1) // size,
            "messages": ordered(parse_headers(data.get("headers")), first),
            "unseen": int(unseen) if isinstance(unseen, (int, float)) and not isinstance(unseen, bool) else None,
            "sync_token": _text(data.get("syncToken")) or None}


def folder_request(query: str = "") -> dict:
    """Koerper fuer .../view: neueste zuerst; mit Suchtext in Betreff ODER Absender"""
    body: dict = {"sortingAttributes": {"sort": "arrival", "asc": 0}}
    q = " ".join(str(query or "").split())[:200]
    if q:
        body["sortingAttributes"]["match"] = "OR"
        body["filters"] = [{"searchBy": "subject", "searchInput": q}, {"searchBy": "from", "searchInput": q}]
    return body


_BODY_TYPES = ("UIxMailPartHTMLViewer", "UIxMailPartTextViewer")


def attachment_path(url, host: str = HOST) -> str | None:
    """Pfad eines Anhangs (downloadURL) unter /SOGo/so/ dieses Rechners; sonst None"""
    u = _text(url).strip()
    if not u:
        return None
    if u.startswith("/"):
        u = f"https://{host}" + u
    if user_from_url(u, host) is None:
        return None
    p = urllib.parse.urlsplit(u)
    return p.path + (f"?{p.query}" if p.query else "")


def quote_path(path: str) -> str:
    """Pfad fuer die Anfrage: Leerzeichen und andere unsichere Zeichen prozentkodiert, schon kodierte bleiben"""
    return urllib.parse.quote(str(path or ""), safe="/@%?=&:+,;()!*'~$")


def _walk_parts(node, bodies: list[str], files: list[dict], host: str = HOST) -> None:
    if isinstance(node, list):
        for x in node:
            _walk_parts(x, bodies, files, host)
        return
    if not isinstance(node, dict):
        return
    typ = _text(node.get("type"))
    content = node.get("content")
    if typ == "UIxMailPartAlternativeViewer" and isinstance(content, list):
        want = _text(node.get("preferredPart")).lower()
        pick = next((c for c in content if isinstance(c, dict) and _text(c.get("contentType")).lower() == want), None)
        _walk_parts(pick if pick is not None else (content[0] if content else None), bodies, files, host)
        return
    if typ in _BODY_TYPES and isinstance(content, str):
        bodies.append(content)
        if not _text(node.get("filename")).strip():
            return
    elif isinstance(content, (list, dict)) and typ not in ("UIxMailPartImageViewer", "UIxMailPartLinkViewer"):
        _walk_parts(content, bodies, files, host)
        return
    path = attachment_path(node.get("downloadURL"), host)
    if path:
        files.append({"index": len(files), "name": _text(node.get("filename")).strip() or "Anhang",
                      "size": _text(node.get("size")).strip(), "type": _text(node.get("contentType")).strip().lower(),
                      "path": path})


def parse_message(data, folder: str, uid: int, host: str = HOST) -> dict:
    """Antwort von .../<uid>/view -> Nachricht zum Lesen (HTML bereinigt, Klartext, Anhaenge)"""
    data = data if isinstance(data, dict) else {}
    bodies: list[str] = []
    files: list[dict] = []
    _walk_parts(data.get("parts"), bodies, files, host)
    raw = "\n".join(bodies)
    clean = sanitize_html(raw)
    return {"folder": folder, "uid": int(uid), "subject": _text(data.get("subject")).strip(), "date": _text(data.get("date")).strip(),
            "from": addresses(data.get("from")), "to": addresses(data.get("to")), "cc": addresses(data.get("cc")),
            "reply_to": addresses(data.get("reply-to")), "read": truthy(data.get("isRead")), "draft": truthy(data.get("isDraft")),
            "html": clean["html"], "remote_blocked": clean["remote_blocked"], "text": html_to_text(raw), "attachments": files}


def parse_created(data) -> dict:
    """Antwort von compose/reply/replyall/forward: {accountId, mailboxPath, draftId}"""
    data = data if isinstance(data, dict) else {}
    box, draft = _text(data.get("mailboxPath")).strip(), _text(data.get("draftId")).strip()
    if not box or not draft or "/" in draft or ".." in draft:
        raise SOGoError("bad", "Entwurf nicht angelegt")
    return {"account": _text(data.get("accountId")) or "0", "mailbox_path": box, "draft_id": draft}


def draft(created: dict, edit, action: str = "compose", source: dict | None = None) -> dict:
    """Entwurf zum Bearbeiten (aus edit): Text immer als Klartext (HTML-Antworten werden mit "> " zitiert)"""
    edit = edit if isinstance(edit, dict) else {}
    is_html = truthy(edit.get("isHTML"))
    text = _text(edit.get("text"))
    atts = []
    for a in edit.get("attachmentAttrs") or [] if isinstance(edit.get("attachmentAttrs"), list) else []:
        if isinstance(a, dict) and _text(a.get("filename")).strip():
            atts.append({"name": _text(a.get("filename")).strip(), "size": _text(a.get("size")).strip()})
    return {**created, "action": action, "source": source, "from": _text(edit.get("from")).strip(),
            "reply_to": _text(edit.get("replyTo")).strip(),
            "to": recipient_list(edit.get("to")), "cc": recipient_list(edit.get("cc")), "bcc": recipient_list(edit.get("bcc")),
            "subject": _text(edit.get("subject")), "text": html_to_text(text) if is_html else text.replace("\r\n", "\n"),
            "was_html": is_html, "attachments": atts}


def payload(d: dict, to, cc, bcc, subject: str, text: str) -> dict:
    """Koerper fuer save/send (wie Message.$omit der Weboberflaeche, Klartext)"""
    def lst(v):
        if isinstance(v, str):
            r = split_recipients(v)
            return r["valid"] + r["invalid"]
        return [" ".join(_text(x).split()) for x in (v or []) if _text(x).strip()]
    body = {"from": d.get("from") or "", "to": lst(to), "cc": lst(cc), "bcc": lst(bcc), "subject": str(subject or ""),
            "text": str(text or "").replace("\r\n", "\n"), "isHTML": False}
    if d.get("reply_to"):
        body["replyTo"] = d["reply_to"]
    return body


def check_send(body: dict) -> str | None:
    """Vor dem Senden: Fehlertext oder None"""
    rec = list(body.get("to") or []) + list(body.get("cc") or []) + list(body.get("bcc") or [])
    if not rec:
        return "Bitte mindestens einen Empfänger angeben."
    bad = [r for r in rec if not email_of(r)]
    if bad:
        return "Diese Empfänger sind keine gültige E-Mail-Adresse: " + ", ".join(bad[:3])
    if not body.get("from"):
        return "Absender fehlt (Entwurf neu öffnen)."
    return None


def send_result(status: int, data) -> dict:
    """Antwort von send: {"ok": bool, "message": str}"""
    if status == 200 and isinstance(data, dict) and data.get("status") == "success":
        return {"ok": True, "message": "Gesendet."}
    msg = _text(data.get("message")).strip() if isinstance(data, dict) else ""
    return {"ok": False, "message": msg or f"SOGo hat das Senden abgelehnt (HTTP {status})."}


def parse_unseen(data, folder: str = "INBOX") -> int | None:
    if not isinstance(data, dict):
        return None
    v = data.get(mailbox_id(folder))
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def new_since(uids: list[int], last: int | None) -> list[int]:
    """UIDs, die neuer sind als die zuletzt gesehene (Benachrichtigung "neue Uni-Mail"); beim ersten Mal keine"""
    if last is None:
        return []
    return [u for u in uids if u > last]


# ---------------------------------------------------------------------------------------------------- Kalender

def _local(epoch) -> datetime | None:
    try:
        n = int(float(epoch))
    except (TypeError, ValueError):
        return None
    if n < 946_684_800 or n > 4_102_444_800:
        return None
    return datetime.fromtimestamp(n, timezone.utc).astimezone(BERLIN)


def event_key(uid: str) -> str:
    return "sogo-" + hashlib.sha256(uid.encode("utf-8")).hexdigest()[:16]


def parse_events(data) -> list[dict]:
    """eventslist -> Termine (Ortszeit Berlin, "YYYY-MM-DDTHH:MM"); ganztaegige mit all_day und Endtag einschliesslich"""
    if not isinstance(data, dict) or not isinstance(data.get("fields"), list) or not isinstance(data.get("events"), list):
        return []
    names = [_text(f) for f in data["fields"]]
    out, seen = [], set()
    for row in data["events"]:
        if not isinstance(row, list):
            continue
        d = dict(zip(names, row))
        st, en = _local(d.get("c_startdate")), _local(d.get("c_enddate"))
        if st is None:
            continue
        all_day = truthy(d.get("c_isallday"))
        if en is None or en < st:
            en = st
        if all_day:
            last = _local(int(float(d.get("c_enddate") or 0)) - 1) if en > st else st
            en = last if last and last >= st else st
        name, folder = _text(d.get("c_name")).strip(), _text(d.get("c_folder")).strip()
        rid = _text(d.get("c_recurrence_id")).strip()
        uid = f"{folder}/{name}" + (f"@{rid}" if rid else (f"@{int(st.timestamp())}" if truthy(d.get("c_iscycle")) else ""))
        if not name or uid in seen:
            continue
        seen.add(uid)
        status = d.get("c_status")
        out.append({"uid": uid, "id": event_key(uid), "calendar": _text(d.get("calendarName")).strip(),
                    "title": " ".join(_text(d.get("c_title")).split()) or "Termin",
                    "location": " ".join(_text(d.get("c_location")).split()),
                    "start": st.strftime("%Y-%m-%dT%H:%M"), "end": en.strftime("%Y-%m-%dT%H:%M"), "all_day": all_day,
                    "cancelled": isinstance(status, (int, float)) and not isinstance(status, bool) and int(status) == 0})
    out.sort(key=lambda e: (e["start"], e["title"], e["uid"]))
    return out


def parse_calendars(data) -> list[dict]:
    items = data.get("calendars") if isinstance(data, dict) else data
    out = []
    for c in items if isinstance(items, list) else []:
        if isinstance(c, dict) and _text(c.get("id")).strip():
            out.append({"id": _text(c.get("id")).strip(), "name": _text(c.get("name")).strip() or _text(c.get("id")).strip(),
                        "color": _text(c.get("color")).strip(), "active": truthy(c.get("active", 1))})
    return out


def events_query(day: date, days: int) -> dict:
    """Abfrage fuer eventslist: ab `day` die naechsten 7 bzw. 31 Tage (SOGo kennt view_next7, view_next14, view_next31)"""
    popup = "view_next7" if days <= 7 else ("view_next14" if days <= 14 else "view_next31")
    return {"asc": "1", "day": day.strftime("%Y%m%d"), "filterpopup": popup, "search": "title_Category_Location",
            "sort": "start", "value": ""}


EVENTS_TABLE = """CREATE TABLE IF NOT EXISTS sogo_events (
    uid TEXT PRIMARY KEY,               -- Ordner/Name[@Wiederholung] im Uni-Kalender (SOGo)
    id TEXT NOT NULL,                   -- "sogo-" + sha256(uid)[:16] (Kennung im Stundenplan)
    calendar TEXT, title TEXT, location TEXT,
    start TEXT NOT NULL, end TEXT NOT NULL,   -- Ortszeit Berlin "YYYY-MM-DDTHH:MM"
    all_day INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, fetched_at TEXT)"""


def _has(conn, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def store_events(conn, events: list[dict], first: date, last: date, fetched_at: str) -> int:
    """Termine des Zeitraums ersetzen (frueher gelesene ausserhalb bleiben). Rueckgabe: Zahl gespeicherter."""
    conn.execute(EVENTS_TABLE)
    conn.execute("DELETE FROM sogo_events WHERE start >= ? AND start < ?", (first.isoformat(), (last + timedelta(days=1)).isoformat()))
    n = 0
    for e in events:
        conn.execute("""INSERT OR REPLACE INTO sogo_events(uid, id, calendar, title, location, start, end, all_day, cancelled, fetched_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?)""",
                     (e["uid"], e["id"], e["calendar"], e["title"], e["location"], e["start"], e["end"], 1 if e["all_day"] else 0,
                      1 if e["cancelled"] else 0, fetched_at))
        n += 1
    return n


def stored_events(conn, first: date, last: date) -> list[dict]:
    if not _has(conn, "sogo_events"):
        return []
    rows = conn.execute("""SELECT uid, id, calendar, title, location, start, end, all_day, cancelled FROM sogo_events
                           WHERE start < ? AND end >= ? ORDER BY start, title, uid""",
                        ((last + timedelta(days=1)).isoformat(), first.isoformat())).fetchall()
    return [{"uid": r[0], "id": r[1], "calendar": r[2] or "", "title": r[3] or "Termin", "location": r[4] or "", "start": r[5],
             "end": r[6], "all_day": bool(r[7]), "cancelled": bool(r[8])} for r in rows]


def forget_events(conn) -> int:
    if not _has(conn, "sogo_events"):
        return 0
    return conn.execute("DELETE FROM sogo_events").rowcount


def calendar_occurrences(conn, start: date, end: date) -> list[dict]:
    """Termine mit Uhrzeit aus dem Uni-Kalender als Vorkommen ohne Serie (nur lesend, Quelle "uni-kalender").
    Ganztaegige fehlen hier (sie wuerden den ganzen Tag als belegt zaehlen); sie stehen auf der Seite Uni-Mail."""
    if not _has(conn, "sogo_events"):
        return []
    out = []
    for r in conn.execute("""SELECT id, calendar, title, location, start, end, cancelled FROM sogo_events
                             WHERE all_day=0 AND start >= ? AND start < ? ORDER BY start, title, uid""",
                          (start.isoformat(), (end + timedelta(days=1)).isoformat())).fetchall():
        eid, cal, title, loc, st, en, cancelled = tuple(r)
        out.append({"event_id": None, "studip_id": eid, "date": st[:10], "start": st[11:16],
                    "end": en[11:16] if en[:10] == st[:10] else "23:59", "title": title or "Termin", "kind": "sonstiges",
                    "module_id": None, "module_name": None, "color": COLOR, "room": loc or "", "lecturer": None, "course_id": None,
                    "status": "ausfall" if cancelled else "teilnahme", "permanent_skip": False,
                    "exception": "cancelled" if cancelled else None, "source": SOURCE, "calendar": cal or ""})
    return out


def _same_key(o: dict) -> tuple:
    return (o.get("date"), o.get("start"), " ".join(str(o.get("title") or "").split()).lower())


def with_calendar(conn, occ: list[dict], start: date, end: date) -> list[dict]:
    """Vorkommen des Planers mit den Terminen des Uni-Kalenders, nach Tag und Beginn (ohne Termine unveraendert);
    ein Termin mit gleichem Tag, Beginn und Titel wie ein vorhandener kommt nicht doppelt"""
    extra = calendar_occurrences(conn, start, end)
    if not extra:
        return occ
    have = {_same_key(o) for o in occ}
    extra = [e for e in extra if _same_key(e) not in have]
    if not extra:
        return occ
    return sorted(occ + extra, key=lambda o: (o["date"], o["start"] or ""))


# ---------------------------------------------------------------------------------------------------- Zwischenspeicher

CACHE_TABLE = """CREATE TABLE IF NOT EXISTS sogo_mail_cache (
    folder TEXT PRIMARY KEY, data TEXT NOT NULL, fetched_at TEXT)"""


def store_cache(conn, listing: dict, fetched_at: str) -> None:
    """Erste Seite eines Ordners (nur Kopfzeilen, keine Inhalte) fuer die Anzeige ohne Netz"""
    conn.execute(CACHE_TABLE)
    keep = {k: listing.get(k) for k in ("folder", "total", "pages", "messages", "unseen")}
    conn.execute("INSERT OR REPLACE INTO sogo_mail_cache(folder, data, fetched_at) VALUES (?,?,?)",
                 (listing.get("folder") or "INBOX", json.dumps(keep, ensure_ascii=False, sort_keys=True), fetched_at))


def cached(conn, folder: str) -> dict | None:
    if not _has(conn, "sogo_mail_cache"):
        return None
    r = conn.execute("SELECT data, fetched_at FROM sogo_mail_cache WHERE folder=?", (folder,)).fetchone()
    if not r:
        return None
    try:
        d = json.loads(r[0])
    except ValueError:
        return None
    return {**d, "fetched_at": r[1], "stale": True} if isinstance(d, dict) else None


def forget_cache(conn) -> None:
    if _has(conn, "sogo_mail_cache"):
        conn.execute("DELETE FROM sogo_mail_cache")


# ---------------------------------------------------------------------------------------------------- Abruf (PC)

Http = Callable[[str, str, bytes | None, dict], tuple[int, bytes, str, dict]]


def _urllib(method: str, url: str, data: bytes | None, headers: dict) -> tuple[int, bytes, str, dict]:
    if urllib.parse.urlsplit(url).hostname not in HOSTS or not url.startswith("https://"):
        raise SOGoError("bad", "Anfrage außerhalb von SOGo abgelehnt")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 - feste Rechner der Hochschulen (SITES)
            return r.status, r.read(MAX_ATTACHMENT + 1), r.geturl(), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, e.read(200_000), e.geturl() or url, {k.lower(): v for k, v in (e.headers or {}).items()}


def cookie_header(cookies: list[dict], host: str = HOST) -> str:
    from . import unilogin
    return unilogin._cookie_header(cookies, base_of(host) + "/")


def xsrf_of(cookies: list[dict], host: str = HOST) -> str:
    for c in cookies or []:
        if isinstance(c, dict) and c.get("name") == "XSRF-TOKEN":
            dom = str(c.get("domain") or host).lstrip(".").lower()
            if host == dom or host.endswith("." + dom):
                return urllib.parse.unquote(str(c.get("value") or ""))
    return ""


class SOGoWeb:
    """SOGo mit der gemerkten Sitzung. Jede Methode genau eine Anfrage (kein Wiederholen bei schreibenden). Anfragen
    nur an `host` (Rechner der Hochschule)."""

    def __init__(self, user: str, cookies: list[dict], http: Http | None = None, host: str = HOST):
        self.user = user
        self.host = host
        self.cookies = cookies or []
        self.http = http or _urllib
        self.base = user_base(user, host)
        self.sent: list[tuple[str, str]] = []           # (Methode, Pfad) – Protokoll fuer Tests, ohne Inhalte

    def _req(self, method: str, path: str, body=None, raw: bytes | None = None, ctype: str | None = None,
             accept: str = "application/json") -> tuple[int, bytes, dict]:
        cookie = cookie_header(self.cookies, self.host)
        if not cookie:
            raise SOGoError("login")
        url = path if path.startswith("https://") else (f"https://{self.host}{path}" if path.startswith("/") else f"{self.base}/{path}")
        if urllib.parse.urlsplit(url).hostname != self.host:
            raise SOGoError("bad", "Anfrage außerhalb von SOGo abgelehnt")
        headers = {"Cookie": cookie, "Accept": accept, "User-Agent": "StudiNow"}
        token = xsrf_of(self.cookies, self.host)
        if token:
            headers["X-XSRF-TOKEN"] = token
        data = raw
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json;charset=utf-8"
        elif ctype:
            headers["Content-Type"] = ctype
        self.sent.append((method, urllib.parse.urlsplit(url).path))
        try:
            status, content, final, rh = self.http(method, url, data, headers)
        except SOGoError:
            raise
        except (urllib.error.URLError, OSError, TimeoutError):
            raise SOGoError("offline") from None
        text = content[:4000].decode("utf-8", "replace") if "json" not in (rh.get("content-type") or "") else ""
        if expired(status, final, text, self.host):
            raise SOGoError("login")
        return status, content, rh

    def _json(self, method: str, path: str, body=None, ok=(200, 201, 204)):
        # 204 (No Content) und leerer Koerper sind kein Fehler, sondern None (leere Ordner wie Spam/Vorlagen -> "0 Mails")
        status, content, _ = self._req(method, path, body)
        if status not in ok:
            raise SOGoError("http", str(status))
        if status == 204 or not content:
            return None
        try:
            return json.loads(content.decode("utf-8"))
        except ValueError:
            if looks_like_html(content):
                raise SOGoError("login") from None
            raise SOGoError("bad", "keine JSON-Antwort") from None

    # Mail lesen
    def mailboxes(self) -> list[dict]:
        return parse_mailboxes(self._json("GET", "Mail/0/view"))

    def folder(self, path: str = "INBOX", query: str = "") -> dict:
        return parse_folder(self._json("POST", f"Mail/0/{folder_path(path)}/view", folder_request(query)), path)

    def headers(self, path: str, uids: list[int]) -> list[dict]:
        if not uids:
            return []
        return ordered(parse_headers(self._json("POST", f"Mail/0/{folder_path(path)}/headers", {"uids": uids})), uids)

    def message(self, path: str, uid: int) -> dict:
        return parse_message(self._json("GET", f"Mail/0/{folder_path(path)}/{int(uid)}/view"), path, uid, self.host)

    def unseen(self, path: str = "INBOX") -> int | None:
        return parse_unseen(self._json("POST", "Mail/unseenCount", {"mailboxes": [mailbox_id(path)]}), path)

    def attachment(self, att_path: str) -> tuple[bytes, str]:
        if not attachment_path(att_path, self.host):
            raise SOGoError("bad", "Anhang nicht von SOGo")
        status, content, rh = self._req("GET", quote_path(att_path), accept="*/*")
        if status != 200:
            raise SOGoError("http", str(status))
        if len(content) > MAX_ATTACHMENT:
            raise SOGoError("bad", "Anhang zu groß")
        return content, rh.get("content-type") or "application/octet-stream"

    # Markieren, Papierkorb
    def mark_read(self, path: str, uid: int, read: bool) -> None:
        self._json("GET", f"Mail/0/{folder_path(path)}/{int(uid)}/{'markMessageRead' if read else 'markMessageUnread'}")

    def flag(self, path: str, uid: int, flagged: bool) -> None:
        self._json("POST", f"Mail/0/{folder_path(path)}/{int(uid)}/{'markMessageFlagged' if flagged else 'markMessageUnflagged'}", {})

    def trash(self, path: str, uids: list[int]) -> None:
        """In den Papierkorb (SOGo verschiebt; nie endgueltig loeschen)"""
        self._json("POST", f"Mail/0/{folder_path(path)}/batchDelete", {"uids": [int(u) for u in uids]})

    def move(self, path: str, uids: list[int], target: str) -> None:
        self._json("POST", f"Mail/0/{folder_path(path)}/moveMessages", {"uids": [int(u) for u in uids], "folder": move_target(target)})

    # Schreiben
    def new_draft(self, action: str = "compose", path: str = "INBOX", uid: int | None = None) -> dict:
        if action == "compose":
            created = parse_created(self._json("GET", "Mail/0/compose"))
            source = None
        elif action in ("reply", "replyall", "forward") and uid:
            created = parse_created(self._json("GET", f"Mail/0/{folder_path(path)}/{int(uid)}/{action}"))
            source = {"folder": path, "uid": int(uid)}
        else:
            raise SOGoError("input", "Unbekannte Aktion")
        edit = self._json("GET", f"Mail/0/{folder_path(created['mailbox_path'])}/{created['draft_id']}/edit")
        return draft(created, edit, action, source)

    def _draft_path(self, d: dict) -> str:
        did = str(d.get("draft_id") or "")
        if not did or "/" in did or ".." in did:
            raise SOGoError("input", "Entwurf fehlt")
        return f"Mail/0/{folder_path(d.get('mailbox_path') or 'Drafts')}/{did}"

    def save(self, d: dict, body: dict) -> dict:
        r = self._json("POST", self._draft_path(d) + "/save", body)
        return {"uid": flatten_uids([r.get("uid")])[0] if isinstance(r, dict) and flatten_uids([r.get("uid")]) else None}

    def attach(self, d: dict, name: str, data: bytes, mime: str) -> dict:
        if len(data) > MAX_ATTACHMENT:
            raise SOGoError("input", "Der Anhang ist größer als 20 MB.")
        raw, ctype = multipart(name, data, mime)
        status, content, _ = self._req("POST", self._draft_path(d) + "/save", raw=raw, ctype=ctype)
        if status != 200:
            raise SOGoError("http", str(status))
        try:
            r = json.loads(content.decode("utf-8") or "{}")
        except ValueError:
            r = {}
        last = (r.get("lastAttachmentAttrs") or [{}]) if isinstance(r, dict) else [{}]
        first = last[0] if last and isinstance(last[0], dict) else {}
        return {"name": _text(first.get("filename")).strip() or clean_filename(name), "size": _text(first.get("size")).strip()}

    def send(self, d: dict, body: dict) -> dict:
        """Genau eine Anfrage .../send; nur nach "Senden" aufrufen"""
        err = check_send(body)
        if err:
            raise SOGoError("input", err)
        status, content, _ = self._req("POST", self._draft_path(d) + "/send", body)
        try:
            data = json.loads(content.decode("utf-8") or "{}")
        except ValueError:
            data = {}
        return send_result(status, data)

    # Kalender
    def events(self, day: date, days: int = 7) -> list[dict]:
        q = urllib.parse.urlencode(events_query(day, days))
        return parse_events(self._json("GET", f"Calendar/eventslist?{q}"))

    def calendars(self) -> list[dict]:
        return parse_calendars(self._json("GET", "Calendar/calendarslist"))


def clean_filename(name: str) -> str:
    n = " ".join(str(name or "").replace("/", "_").replace("\\", "_").replace('"', "'").split())[:120]
    return n or "Anhang"


def multipart(name: str, data: bytes, mime: str, boundary: str = "----StudiNowSOGo7d1f") -> tuple[bytes, str]:
    """multipart/form-data mit dem Feld "attachments" (wie das Hochladen der Weboberflaeche)"""
    fn = clean_filename(name)
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"{fn}\"\r\n"
            f"Content-Type: {mime or 'application/octet-stream'}\r\n\r\n").encode("utf-8")
    return head + data + f"\r\n--{boundary}--\r\n".encode("utf-8"), f"multipart/form-data; boundary={boundary}"


# ---------------------------------------------------------------------------------------------------- Sitzung (PC)

def saved_user() -> str | None:
    from . import db
    with db.cursor() as conn:
        r = conn.execute("SELECT value FROM settings WHERE key='sogo_user'").fetchone()
    return (r[0] or None) if r else None


def remember_user(user: str | None) -> None:
    from . import db
    with db.cursor() as conn:
        if user:
            db.set_setting(conn, "sogo_user", user)
        else:
            conn.execute("DELETE FROM settings WHERE key='sogo_user'")


def current_host() -> str | None:
    """Rechner von SOGo dieser App-Instanz; None an einer Hochschule ohne SOGo"""
    s = site()
    return s["host"] if s else None


def discover_user(cookies: list[dict], http: Http | None = None, host: str | None = None) -> str | None:
    """Mit den Cookies /SOGo/so/ aufrufen: angemeldet leitet SOGo auf /SOGo/so/<benutzer>/... weiter"""
    host = host or current_host()
    if not host:
        return None
    header = cookie_header(cookies, host)
    if not header:
        return None
    try:
        status, content, final, _ = (http or _urllib)("GET", f"{base_of(host)}/so/", None, {"Cookie": header, "Accept": "text/html", "User-Agent": "StudiNow"})
    except (SOGoError, urllib.error.URLError, OSError, TimeoutError):
        return None
    if status != 200 or looks_like_login(content[:20000].decode("utf-8", "replace")):
        return None
    return user_from_url(final, host)


def live(http: Http | None = None) -> SOGoWeb:
    """Sitzung des PCs; ohne Anmeldung SOGoError("login")"""
    from . import config, unilogin
    if config.is_hosted():
        raise SOGoError("refused", NOT_AVAILABLE)
    host = current_host()
    if not host:
        raise SOGoError("refused", NOT_AT_UNI)
    cookies = unilogin.saved_cookies(SESSION)
    user = saved_user()
    if not cookies or not cookie_header(cookies, host):
        raise SOGoError("login")
    if not user:
        user = discover_user(cookies, http, host)
        if not user:
            raise SOGoError("login")
        remember_user(user)
    return SOGoWeb(user, cookies, http, host)
