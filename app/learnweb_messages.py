"""Learnweb-Nachrichten (Moodle) der Uni Hildesheim: lesen und antworten (Auftrag des Inhabers 05.11.2026,
"uni hildesheim einbinden", docs/HILDESHEIM-STAND-2026-11-05.md).

Moodle hat keinen Posteingang mit Betreff wie Stud.IP, sondern Unterhaltungen (Einzel- und Gruppenunterhaltungen).
Die App zeigt je Unterhaltung die neueste Nachricht, die nicht von dir kommt, in derselben Liste wie die
Stud.IP-Nachrichten (Tabelle studip_messages, Kennung "lw-msg-<unterhaltung>-<nachricht>"), damit Seite, Suche, Zaehler
und Erkennung von Tagen fuer beide Hochschulen gleich sind.

Moodle-Dienste (lib/db/services.php, Moodle 4.4, alle mit 'ajax' => true, also auch mit der Sitzung und sesskey nutzbar):
- core_message_get_conversations(userid, limitfrom, limitnum, type, favourites, mergeself): lesen, markiert nichts als
  gelesen. Ein eigenes "als gelesen markieren" ruft die App nie auf.
- core_message_get_conversation(userid, conversationid, includecontactrequests, includeprivacyinfo, memberlimit, ...):
  Mitglieder einer Unterhaltung (Namen nur fuer das Antwortfenster, nie gespeichert).
- core_message_send_messages_to_conversation(conversationid, messages[{text, textformat}]): senden, nur auf Knopfdruck.

Gespeichert werden wie bei Stud.IP keine Personennamen (Regel 02.11.2026): Absender "Learnweb-Kontakt" bzw.
"Learnweb-Gruppe", Betreff "Nachricht im Learnweb" bzw. der Name der Gruppenunterhaltung. Gleiche Regeln im Kern:
apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Hildesheim/LearnwebMessages.swift (gemeinsame Faelle:
packages/shared-contracts/fixtures/learnweb/messages-cases.json, tools/gen-learnweb-fixture.py).
"""
from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
from datetime import date, datetime
from typing import Callable
from zoneinfo import ZoneInfo

LOCAL_PREFIX = "lw-msg-"
BERLIN = ZoneInfo("Europe/Berlin")
CONVERSATIONS = 50                    # Unterhaltungen je Abruf (neueste zuerst)
MEMBER_LIMIT = 21                     # Mitglieder fuer das Antwortfenster
TYPE_INDIVIDUAL, TYPE_GROUP, TYPE_SELF = 1, 2, 3
FORMAT_PLAIN = 2                      # Moodle FORMAT_PLAIN: Zeilenumbrueche bleiben, kein HTML
SENDER_INDIVIDUAL = "Learnweb-Kontakt"
SENDER_GROUP = "Learnweb-Gruppe"
SUBJECT_INDIVIDUAL = "Nachricht im Learnweb"
SUBJECT_GROUP = "Gruppenunterhaltung im Learnweb"
MAX_TEXT = 20000
NOTICE = "Wird über das Learnweb unter deinem Namen gesendet. Die Empfänger sehen deinen Namen."
ERRORS = {
    "not_found": "Die Unterhaltung gibt es im Learnweb nicht mehr. Antworte bitte direkt im Learnweb.",
    "not_allowed": "Das Learnweb lässt hier keine Antwort zu (Person nimmt keine Nachrichten an oder Nachrichten sind gesperrt).",
    "self": "Das ist deine eigene Notiz-Unterhaltung im Learnweb.",
    "login": "Die Learnweb-Anmeldung ist abgelaufen. Bitte neu anmelden.",
    "no_user": "Das Learnweb hat deine Kennung nicht genannt. Antworte bitte direkt im Learnweb.",
    "http": "Das Learnweb hat die Nachricht nicht angenommen ({code}).",
    "offline": "Keine Verbindung zum Learnweb. Dein Text bleibt als Entwurf.",
}
NOT_ALLOWED_CODES = {"usercantbemessaged", "messagingdisabled", "nopermissions", "cannotmessageuser", "blockedbyuser"}
LOGIN_CODES = {"invalidsesskey", "servicerequireslogin", "requireloginerror", "sessionexpired", "invalidtoken"}

_USERID_RES = [re.compile(r'"userId"\s*:\s*(\d+)'), re.compile(r'\bdata-userid\s*=\s*"(\d+)"'),
               re.compile(r"[?&;]userid=(\d+)")]
_SESSKEY_RE = re.compile(r'"sesskey"\s*:\s*"([A-Za-z0-9]+)"')


class MessageError(RuntimeError):
    def __init__(self, code: str, detail: str = ""):
        super().__init__(ERRORS.get(code, code).format(code=detail or code))
        self.code = code
        self.message = str(self)

    @property
    def offers_web_fallback(self) -> bool:
        return self.code not in ("login", "offline", "self")


# ---------------------------------------------------------------------------- rein (gleich im Kern)

def local_id(conversation_id, message_id) -> str:
    return f"{LOCAL_PREFIX}{int(conversation_id)}-{int(message_id)}"


def conversation_of(local: str) -> int | None:
    """"lw-msg-12-345" -> 12; alles andere None"""
    m = re.fullmatch(r"lw-msg-(\d+)-(\d+)", local or "")
    return int(m.group(1)) if m else None


def is_learnweb_message(local: str) -> bool:
    return conversation_of(local) is not None


def user_id_from_page(html_text: str) -> int | None:
    """Eigene Moodle-Kennung aus einer angemeldeten Seite (M.cfg.userId, sonst data-userid des Nachrichten-Menues)"""
    for rx in _USERID_RES:
        m = rx.search(html_text or "")
        if m and int(m.group(1)) > 1:            # 1 = Gast
            return int(m.group(1))
    return None


def sesskey_from_page(html_text: str) -> str | None:
    m = _SESSKEY_RE.search(html_text or "")
    return m.group(1) if m else None


def sent_iso(ts) -> str:
    """Unix-Zeit -> "2026-11-02T08:15:00+01:00" (wie Stud.IP mkdate)"""
    return datetime.fromtimestamp(int(ts), BERLIN).isoformat()


def web_url(base: str, conversation_id) -> str:
    return f"{base.rstrip('/')}/message/index.php?convid={int(conversation_id)}"


def inbox_url(base: str) -> str:
    return f"{base.rstrip('/')}/message/index.php"


def conversations_args(me: int) -> dict:
    return {"userid": int(me), "limitfrom": 0, "limitnum": CONVERSATIONS, "mergeself": False}


def conversation_args(me: int, conversation_id: int) -> dict:
    return {"userid": int(me), "conversationid": int(conversation_id), "includecontactrequests": False,
            "includeprivacyinfo": False, "memberlimit": MEMBER_LIMIT, "memberoffset": 0, "messagelimit": 1, "messageoffset": 0,
            "newestmessagesfirst": True}


def send_args(conversation_id: int, text: str) -> dict:
    return {"conversationid": int(conversation_id), "messages": [{"text": text, "textformat": FORMAT_PLAIN}]}


def flatten(args: dict, prefix: str = "") -> dict[str, str]:
    """Verschachtelte Argumente fuer REST (Formular): messages[0][text]=…; Wahrheitswerte als 1/0"""
    out: dict[str, str] = {}
    items = args.items() if isinstance(args, dict) else enumerate(args)
    for k, v in items:
        key = f"{prefix}[{k}]" if prefix else str(k)
        if isinstance(v, (dict, list)):
            out.update(flatten(v, key))
        elif isinstance(v, bool):
            out[key] = "1" if v else "0"
        elif v is not None:
            out[key] = str(v)
    return out


def parse_conversations(data, me: int, base: str, today: date) -> list[dict]:
    """Antwort von core_message_get_conversations -> Nachrichten zum Speichern (wie studip_extras.parse_messages).
    Je Einzel- oder Gruppenunterhaltung die neueste Nachricht, die nicht von dir kommt; eigene Notizen (Typ 3) und
    Unterhaltungen nur mit eigenen Nachrichten fehlen. `members` (Zahl mit dir) fuer die Anzeige."""
    from . import announcements
    convs = data.get("conversations") if isinstance(data, dict) else None
    out = []
    for c in convs if isinstance(convs, list) else []:
        if not isinstance(c, dict) or c.get("id") is None:
            continue
        kind = int(c.get("type") or 0)
        if kind not in (TYPE_INDIVIDUAL, TYPE_GROUP):
            continue
        msgs = [m for m in (c.get("messages") or []) if isinstance(m, dict) and m.get("id") is not None
                and m.get("useridfrom") is not None and int(m["useridfrom"]) != int(me) and m.get("timecreated")]
        if not msgs:
            continue
        m = max(msgs, key=lambda x: (int(x["timecreated"]), int(x["id"])))
        text = announcements.html_to_text(str(m.get("text") or ""))[:announcements.MAX_TEXT]
        if kind == TYPE_GROUP:
            subject = announcements.html_to_text(str(c.get("name") or ""))[:announcements.MAX_TITLE] or SUBJECT_GROUP
        else:
            subject = SUBJECT_INDIVIDUAL
        sent = sent_iso(m["timecreated"])
        posted = announcements._posted_day_or_none(sent) or today
        dates = [{"date": d["date"], "time": d["time"], "kind": d["kind"]} for d in announcements.dates_for(subject, text, posted)]
        out.append({"id": local_id(c["id"], m["id"]), "sender": SENDER_GROUP if kind == TYPE_GROUP else SENDER_INDIVIDUAL,
                    "subject": subject, "preview": text, "sent_at": sent, "url": web_url(base, c["id"]), "dates": dates,
                    "members": int(c.get("membercount") or 0) or None, "unread": bool(int(c.get("unreadcount") or 0))})
    out.sort(key=lambda x: (x["sent_at"], x["id"]), reverse=True)
    return out


def reply_context(conv, me: int) -> dict:
    """Antwort von core_message_get_conversation -> {conversation_id, group, name, recipients[{id, name}], replyable,
    reason}. Namen nur fuer das Fenster."""
    if not isinstance(conv, dict) or conv.get("id") is None:
        raise MessageError("not_found")
    kind = int(conv.get("type") or 0)
    members = [x for x in (conv.get("members") or []) if isinstance(x, dict) and x.get("id") is not None and int(x["id"]) != int(me)]
    if kind == TYPE_SELF:
        return {"conversation_id": int(conv["id"]), "group": False, "name": "", "recipients": [], "replyable": False, "reason": "self"}
    names = [{"id": int(x["id"]), "name": str(x.get("fullname") or "Learnweb-Nutzer/in")} for x in members]
    blocked = kind == TYPE_INDIVIDUAL and any(x.get("isblocked") or x.get("canmessage") is False for x in members)
    group = kind == TYPE_GROUP
    return {"conversation_id": int(conv["id"]), "group": group,
            "name": str(conv.get("name") or "") if group else (names[0]["name"] if names else ""),
            "member_count": int(conv.get("membercount") or len(members) + 1),
            "recipients": names, "replyable": bool(names) and not blocked, "reason": "not_allowed" if blocked or not names else None}


def send_result(data) -> int | None:
    """Antwort von core_message_send_messages_to_conversation (Liste der neuen Nachrichten) -> Kennung"""
    if isinstance(data, list) and data and isinstance(data[0], dict) and data[0].get("id") is not None:
        return int(data[0]["id"])
    return None


def error_for(errorcode: str | None) -> MessageError:
    code = (errorcode or "").lower()
    if code in LOGIN_CODES:
        return MessageError("login")
    if code in NOT_ALLOWED_CODES:
        return MessageError("not_allowed")
    if code in ("invalidrecord", "conversationdoesntexist", "invalidparameter"):
        return MessageError("not_found")
    return MessageError("http", code or "Fehler")


# ---------------------------------------------------------------------------- Abgleich (PC, hildesheim.run_sync)

def fetch(call: Callable[[str, dict], object], me: int, base: str, today: date | None = None) -> list[dict]:
    """`call(fn, args)`: SessionClient.ajax oder TokenClient (ueber `token_call`)"""
    return parse_conversations(call("core_message_get_conversations", conversations_args(me)), me, base, today or date.today())


def token_call(client) -> Callable[[str, dict], object]:
    return lambda fn, args: client.call(fn, **flatten(args))


def token_user(client) -> int | None:
    uid = (client.call("core_webservice_get_site_info") or {}).get("userid")
    return int(uid) if uid else None


def session_user(page) -> int | None:
    try:
        uid = page.evaluate("() => (window.M && M.cfg && M.cfg.userId) || null")
        if uid:
            return int(uid)
    except Exception:  # noqa: BLE001
        pass
    try:
        return user_id_from_page(page.content())
    except Exception:  # noqa: BLE001
        return None


def store(conn, items: list[dict], fetched_at: str) -> int:
    """In dieselbe Tabelle wie die Stud.IP-Nachrichten (die Uni Hildesheim hat kein Stud.IP; eigener Datenordner)"""
    from . import studip_extras
    return studip_extras.store_messages(conn, items, fetched_at)


# ---------------------------------------------------------------------------- live mit der gemerkten Sitzung (PC)

Http = Callable[[str, bytes | None, dict], tuple[int, bytes, str]]


def _urllib(url: str, data: bytes | None, headers: dict) -> tuple[int, bytes, str]:
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b"", url


class LiveSession:
    """AJAX mit den Cookies der Learnweb-Sitzung (LEARNWEB_COOKIES, wie filestream). Liest sesskey und die eigene
    Kennung aus /my/; eine Anmeldeseite heisst: Sitzung abgelaufen."""

    def __init__(self, base: str, cookie: str, http: Http | None = None):
        self.base = base.rstrip("/")
        self.cookie = cookie
        self.http = http or _urllib
        self.sesskey: str | None = None
        self.me: int | None = None

    def _headers(self, extra: dict | None = None) -> dict:
        h = {"User-Agent": "StudiNow", "Accept": "*/*", "Cookie": self.cookie}
        h.update(extra or {})
        return h

    def _login_page(self, final_url: str) -> bool:
        return "/sso/login" in final_url or "/login/index.php" in final_url

    def open(self) -> None:
        if not self.cookie:
            raise MessageError("login")
        status, body, final = self.http(f"{self.base}/my/", None, self._headers())
        text = body.decode("utf-8", "replace")
        if self._login_page(final) or status != 200:
            raise MessageError("login")
        self.sesskey = sesskey_from_page(text)
        self.me = user_id_from_page(text)
        if not self.sesskey:
            raise MessageError("login")
        if not self.me:
            raise MessageError("no_user")

    def ajax(self, fn: str, args: dict):
        if not self.sesskey:
            self.open()
        url = f"{self.base}/lib/ajax/service.php?sesskey={urllib.parse.quote(self.sesskey or '')}&info={fn}"
        payload = json.dumps([{"index": 0, "methodname": fn, "args": args}]).encode()
        status, body, final = self.http(url, payload, self._headers({"Content-Type": "application/json"}))
        if self._login_page(final):
            raise MessageError("login")
        try:
            first = json.loads(body.decode("utf-8") or "null")[0]
        except (ValueError, IndexError, TypeError, KeyError):
            raise MessageError("login" if body.lstrip()[:1] == b"<" else "http", str(status)) from None
        if first.get("error") or first.get("exception"):
            raise error_for((first.get("exception") or {}).get("errorcode"))
        return first.get("data")


def live_context(session: LiveSession, conversation_id: int) -> dict:
    session.open() if session.me is None else None
    return reply_context(session.ajax("core_message_get_conversation", conversation_args(session.me, conversation_id)), session.me)


def live_send(session: LiveSession, conversation_id: int, text: str) -> int | None:
    """Genau ein Versuch, nur auf Knopfdruck"""
    if session.me is None:
        session.open()
    return send_result(session.ajax("core_message_send_messages_to_conversation", send_args(conversation_id, text)))
