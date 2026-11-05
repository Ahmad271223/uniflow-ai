"""Allgemeines Moodle am PC (Hochschule Hannover und Learnweb der Uni Hildesheim) mit der gemerkten Sitzung: Nachrichten
lesen und beantworten, Abgabe in einer Aufgabe. Gleiche Regeln wie im Kern der iPad-App
(apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Moodle/MoodleWeb.swift, MoodleMessages.swift, MoodleAssign.swift;
gemeinsame nachgebaute Antworten: packages/shared-contracts/fixtures/moodle; docs/HSH-2026-11-05.md).

- Lesen ueber /lib/ajax/service.php mit dem sesskey der Seite wie das Moodle selbst; markiert nichts als gelesen.
- Schreiben (Antwort, Entwurf hochladen, "Jetzt abgeben") nur auf Knopfdruck des Menschen, je genau ein Versuch, nie im
  Abgleich und nie still wiederholt (eine zweite Anfrage koennte doppelt senden bzw. abgeben).
- Ein Entwurf ist noch keine Abgabe: abgegeben wird erst mit der Bestaetigung (action=submit -> confirmsubmit); verlangt
  die Aufgabe eine Erklaerung, muss der Mensch sie ausdruecklich bestaetigen.
- Keine Personennamen gespeichert: Absender "Moodle" bzw. Name der Gruppen-Unterhaltung; Namen liest nur das
  Antwortfenster live. Dateinamen der Abgabe (Name, Matrikelnummer) werden nie gelesen oder gespeichert.

NICHT MIT EINEM ECHTEN KONTO GEPRUEFT: Feldnamen und Texte stammen aus dem Standard-Moodle (wie auf dem iPad).
"""
from __future__ import annotations

import html as html_mod
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from typing import Callable
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo("Europe/Berlin")

# ---------------------------------------------------------------------------- Fehler

ERRORS = {
    "login": "Die Moodle-Anmeldung ist abgelaufen. Bitte neu anmelden.",
    "refused": "Moodle hat abgelehnt ({detail}).",
    "http": "Moodle antwortet mit HTTP {detail}.",
    "unexpected": "Die Moodle-Seite sieht anders aus als erwartet ({detail}).",
    "offline": "Keine Verbindung zu Moodle.",
}
LOGIN_CODES = {"invalidsesskey", "servicerequireslogin", "requireloginerror", "sessionexpired"}


class MoodleError(RuntimeError):
    """code: login, refused, http, unexpected, offline. Kein Text aus Moodle (koennte Eingaben enthalten)."""

    def __init__(self, code: str, detail: str = ""):
        self.code, self.detail = code, detail
        super().__init__(ERRORS.get(code, "Moodle-Fehler ({detail})").format(detail=detail))

    @property
    def message(self) -> str:
        return str(self)


# ---------------------------------------------------------------------------- Sitzung (MoodleWeb)

# (Methode, Adresse, Rumpf, Kopfzeilen) -> (Status, Rumpf, Adresse nach Weiterleitungen)
Http = Callable[[str, str, bytes | None, dict], tuple[int, bytes, str]]

_USERID_RES = [re.compile(r'data-userid="(\d+)"'), re.compile(r'data-user-id="(\d+)"'),
               re.compile(r'"userid"\s*:\s*"?(\d+)'), re.compile(r"user/profile\.php\?id=(\d+)")]
_SESSKEY_RE = re.compile(r'"sesskey"\s*:\s*"([A-Za-z0-9]{1,64})"')
_BODY_CLASS_RE = re.compile(r'<body\b[^>]*\bclass="([^"]*)"', re.I)


def _urllib(method: str, url: str, data: bytes | None, headers: dict) -> tuple[int, bytes, str]:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b"", url


def user_id_from_page(text: str) -> int | None:
    """Kennung des angemeldeten Nutzers aus einer Moodle-Seite (Nachrichten-Leiste, Profil-Link); None, wenn unklar"""
    for rx in _USERID_RES:
        m = rx.search(text or "")
        if m and int(m.group(1)) > 0:
            return int(m.group(1))
    return None


def is_logged_in(text: str) -> bool:
    """Angemeldete Moodle-Seite: traegt einen sesskey, body ohne Klasse notloggedin (wie Learnweb.isLoggedIn)"""
    if "sesskey" not in (text or ""):
        return False
    m = _BODY_CLASS_RE.search(text)
    return not (m and "notloggedin" in m.group(1).split())


def sesskey_from_page(text: str) -> str | None:
    if not is_logged_in(text):
        return None
    m = _SESSKEY_RE.search(text)
    return m.group(1) if m else None


def is_login_url(url: str) -> bool:
    return "/login/index.php" in (url or "") or "/cas/login" in (url or "")


def _looks_like_page(body: bytes) -> bool:
    return body.lstrip()[:1] == b"<"


class MoodleWeb:
    """Eine Moodle-Instanz mit den Cookies der gemerkten Sitzung (HSH_COOKIES bzw. LEARNWEB_COOKIES)"""

    def __init__(self, base: str, cookie: str, http: Http | None = None):
        self.base = base.rstrip("/")
        self.cookie = cookie
        self.http = http or _urllib
        self.sesskey: str | None = None
        self.user_id: int | None = None

    def _url(self, path: str) -> str:
        return path if path.startswith("http") else self.base + path

    def _send(self, method: str, url: str, data: bytes | None, extra: dict | None = None) -> tuple[int, bytes, str]:
        if not self.cookie:
            raise MoodleError("login")
        headers = {"User-Agent": "StudiNow", "Accept": "*/*", "Cookie": self.cookie, **(extra or {})}
        try:
            return self.http(method, url, data, headers)
        except (urllib.error.URLError, OSError, TimeoutError):
            raise MoodleError("offline") from None

    def page(self, path: str) -> tuple[str, str]:
        """Seite lesen (GET); Anmeldeseite = abgelaufen"""
        status, body, final = self._send("GET", self._url(path), None)
        if is_login_url(final):
            raise MoodleError("login")
        if status != 200:
            raise MoodleError("http", str(status))
        text = body.decode("utf-8", "replace")
        if not is_logged_in(text):
            raise MoodleError("login")
        if self.sesskey is None:
            self.sesskey, self.user_id = sesskey_from_page(text), user_id_from_page(text)
        return text, final

    def current(self) -> tuple[str, int | None]:
        """sesskey und Nutzerkennung (aus der Nachrichten-Seite, die beides traegt)"""
        if self.sesskey and self.user_id is not None:
            return self.sesskey, self.user_id
        text, _ = self.page("/message/index.php")
        key = sesskey_from_page(text)
        if not key:
            raise MoodleError("login")
        self.sesskey, self.user_id = key, user_id_from_page(text) or self.user_id
        return self.sesskey, self.user_id

    def ajax(self, fn: str, args: dict, write: bool = False):
        """AJAX-Aufruf wie das Moodle selbst (immer genau ein Versuch; `write` nur zur Kennzeichnung)"""
        key, _ = self.current()
        url = f"{self.base}/lib/ajax/service.php?sesskey={urllib.parse.quote(key)}&info={fn}"
        payload = json.dumps([{"index": 0, "methodname": fn, "args": args}], ensure_ascii=False).encode()
        status, body, final = self._send("POST", url, payload, {"Content-Type": "application/json"})
        if is_login_url(final):
            raise MoodleError("login")
        if status != 200:
            raise MoodleError("http", str(status))
        try:
            first = json.loads(body.decode("utf-8") or "null")[0]
        except (ValueError, IndexError, TypeError, KeyError):
            if _looks_like_page(body):
                self.sesskey = None
                raise MoodleError("login") from None
            raise MoodleError("unexpected", fn) from None
        if not isinstance(first, dict):
            raise MoodleError("unexpected", fn)
        if first.get("error") is True or first.get("exception"):
            code = (first.get("exception") or {}).get("errorcode") or first.get("errorcode") or "error"
            if code in LOGIN_CODES:
                self.sesskey = None
                raise MoodleError("login")
            raise MoodleError("refused", f"{fn}: {code}")
        return first.get("data")

    def post_form(self, path: str, fields: list[tuple[str, str]]) -> tuple[str, str]:
        """Formular absenden, genau ein Versuch; folgt der Weiterleitung"""
        data = urllib.parse.urlencode(fields).encode()
        status, body, final = self._send("POST", self._url(path), data, {"Content-Type": "application/x-www-form-urlencoded"})
        if is_login_url(final):
            raise MoodleError("login")
        if not 200 <= status < 300:
            raise MoodleError("http", str(status))
        return body.decode("utf-8", "replace"), final

    def post_multipart(self, path: str, fields: list[tuple[str, str]], file: tuple[str, str, str, bytes]) -> dict:
        """Datei hochladen (multipart/form-data), genau ein Versuch; Antwort als JSON"""
        field, name, mime, data = file
        boundary = "----StudiNow" + uuid.uuid4().hex
        parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields]
        safe = name.replace('"', "")
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{safe}"\r\nContent-Type: {mime}\r\n\r\n'.encode())
        body = b"".join(parts) + data + f"\r\n--{boundary}--\r\n".encode()
        status, resp, final = self._send("POST", self._url(path), body, {"Content-Type": f"multipart/form-data; boundary={boundary}"})
        if is_login_url(final):
            raise MoodleError("login")
        if status != 200:
            raise MoodleError("http", str(status))
        try:
            j = json.loads(resp.decode("utf-8"))
        except ValueError:
            raise MoodleError("login" if _looks_like_page(resp) else "unexpected", "Upload") from None
        if isinstance(j, dict) and j.get("error"):
            raise MoodleError("refused", f"Upload: {j.get('errorcode') or 'error'}")
        return j if isinstance(j, dict) else {}


# ---------------------------------------------------------------------------- Nachrichten (MoodleMessages)

ID_PREFIX = "moodle-"
MAX_CONVERSATIONS = 30
MAX_PER_CONVERSATION = 30
MAX_TEXT = 20000
SENDER = "Moodle"
SUBJECT = "Nachricht in Moodle"
NOTICE = "Wird über Moodle unter deinem Namen gesendet. Die Empfänger sehen deinen Namen."


def stored_id(conversation: int, message: int) -> str:
    return f"{ID_PREFIX}{int(conversation)}-{int(message)}"


def conversation_id(stored: str) -> int | None:
    """"moodle-12-345" -> 12; None fuer andere Quellen"""
    if not str(stored or "").startswith(ID_PREFIX):
        return None
    head = stored[len(ID_PREFIX):].split("-")[0]
    return int(head) if head.isdigit() else None


def is_moodle_message(stored: str) -> bool:
    return conversation_id(stored) is not None


def iso(seconds) -> str:
    return datetime.fromtimestamp(int(seconds or 0), BERLIN).isoformat()


def web_url(base: str, conversation: int) -> str:
    return f"{base.rstrip('/')}/message/index.php?convid={int(conversation)}"


def conversations(data) -> list[tuple[int, bool, str]]:
    """core_message_get_conversations -> [(Kennung, Gruppe, Name der Gruppe)]"""
    out = []
    for c in (data or {}).get("conversations") or [] if isinstance(data, dict) else []:
        if isinstance(c, dict) and c.get("id") is not None:
            group = int(c.get("type") or 0) == 2
            out.append((int(c["id"]), group, " ".join(str(c.get("name") or "").split()) if group else ""))
    return out


def items(conversation: int, group: bool, name: str, data, me: int | None) -> list[dict]:
    """Nachrichten einer Unterhaltung (core_message_get_conversation_messages) ohne die eigenen"""
    from . import announcements
    out = []
    for m in (data or {}).get("messages") or [] if isinstance(data, dict) else []:
        if not isinstance(m, dict) or m.get("id") is None or m.get("useridfrom") is None or int(m["useridfrom"]) == me:
            continue
        label = name if group and name else ""
        out.append({"conversation": conversation, "message": int(m["id"]), "sender": label or SENDER, "subject": label or SUBJECT,
                    "text": announcements.html_to_text(str(m.get("text") or "")), "sent_at": iso(m.get("timecreated"))})
    return out


def stored(item: dict, base: str) -> dict:
    """Zeile fuer studip_extras.store_messages (Tabelle der Seite "Nachrichten")"""
    from . import announcements
    posted = announcements._posted_day_or_none(item["sent_at"])
    dates = [{"date": d["date"], "time": d["time"], "kind": d["kind"]}
             for d in announcements.dates_for(item["subject"], item["text"], posted)] if posted else []
    return {"id": stored_id(item["conversation"], item["message"]), "sender": item["sender"], "subject": item["subject"],
            "preview": item["text"][:announcements.MAX_TEXT], "sent_at": item["sent_at"],
            "url": web_url(base, item["conversation"]), "dates": dates}


def reply_payload(conversation: int, text: str) -> dict:
    """Antwort (FORMAT_MOODLE: Zeilenumbrueche bleiben)"""
    return {"conversationid": int(conversation), "messages": [{"text": text, "textformat": 0}]}


def fetch_messages(call: Callable[[str, dict], object], me: int | None, base: str) -> tuple[list[dict], int | None]:
    """Unterhaltungen und ihre Nachrichten lesen (nur lesend). `call(fn, args)`: AJAX der Sitzung (MoodleWeb.ajax oder
    learnweb.SessionClient.ajax im Abgleich). Rueckgabe: Zeilen (neueste zuerst), ungelesen in Moodle"""
    if me is None:
        raise MoodleError("unexpected", "Nutzerkennung")
    rows = []
    listing = call("core_message_get_conversations", {"userid": me, "limitfrom": 0, "limitnum": MAX_CONVERSATIONS, "mergeself": True})
    for cid, group, name in conversations(listing):
        data = call("core_message_get_conversation_messages", {"currentuserid": me, "convid": cid, "limitfrom": 0,
                                                               "limitnum": MAX_PER_CONVERSATION, "newest": True})
        rows += [stored(i, base) for i in items(cid, group, name, data, me)]
    try:
        n = call("core_message_get_unread_conversations_count", {"useridto": me})
        unread = int(n) if n is not None else None
    except Exception:  # noqa: BLE001 - Zaehler ist nur Beiwerk
        unread = None
    rows.sort(key=lambda r: (r["sent_at"], r["id"]), reverse=True)
    return rows, unread


def sync_messages(web: MoodleWeb, conn, fetched_at: str, call: Callable[[str, dict], object] | None = None,
                  me: int | None = None) -> dict:
    """Abgleich: Tabelle ersetzen (in Moodle Geloeschtes verschwindet). {count, unread, needs_login, message}.
    Ohne `call`: mit der Sitzung `web` (sesskey und Kennung aus /message/index.php)."""
    from . import studip_extras
    try:
        if call is None:
            _, me = web.current()
            call = web.ajax
        rows, unread = fetch_messages(call, me, web.base)
    except MoodleError as e:
        if e.code == "login":
            return {"count": None, "unread": None, "needs_login": True, "message": "Moodle-Nachrichten: Anmeldung nötig"}
        return {"count": None, "unread": None, "needs_login": False, "message": f"Moodle-Nachrichten: {e.message}"}
    n = studip_extras.store_messages(conn, rows, fetched_at)
    tail = f" ({unread} ungelesen in Moodle)" if unread else ""
    return {"count": n, "unread": unread, "needs_login": False, "message": f"Nachrichten: {n}{tail}"}


def member_names(web: MoodleWeb, conversation: int) -> list[str]:
    """Namen der anderen Teilnehmenden (nur fuer das Antwortfenster, nie gespeichert)"""
    _, me = web.current()
    data = web.ajax("core_message_get_conversation_messages", {"currentuserid": me, "convid": int(conversation), "limitfrom": 0,
                                                               "limitnum": 1, "newest": True})
    return [" ".join(str(m.get("fullname") or "").split()) for m in (data or {}).get("members") or []
            if isinstance(m, dict) and m.get("id") != me and m.get("fullname")]


def reply(web: MoodleWeb, conversation: int, text: str) -> int | None:
    """Antwort senden (genau ein Versuch). Rueckgabe: Kennung der neuen Nachricht, wenn Moodle sie nennt"""
    t = (text or "").strip()
    if not t:
        raise MoodleError("unexpected", "leerer Text")
    data = web.ajax("core_message_send_messages_to_conversation", reply_payload(conversation, t), write=True)
    first = data[0] if isinstance(data, list) and data else None
    return int(first["id"]) if isinstance(first, dict) and first.get("id") is not None else None


# ---------------------------------------------------------------------------- Abgabe (MoodleAssign)

STATE_NONE, STATE_DRAFT, STATE_SUBMITTED, STATE_UNKNOWN = "keine Abgabe", "Entwurf gespeichert", "Abgegeben", "unbekannt"

_CMID_RE = re.compile(r"/mod/assign/view\.php\?id=(\d+)")
_DRAFT_RE = re.compile(r"(Entwurf \(nicht abgegeben\)|Draft \(not submitted\))", re.I)
_SUBMITTED_RE = re.compile(r"(Zur Bewertung abgegeben|Submitted for grading|Abgegeben zur Bewertung)", re.I)
_NONE_RE = re.compile(r"(Keine Abgabe|Keine Einreichung|Kein Versuch|No attempt|Nothing has been submitted)", re.I)
_ROW_RE = re.compile(r"<tr\b[^>]*>(.*?)</tr>", re.I | re.S)
_CELL_RE = re.compile(r"<t[hd]\b[^>]*>(.*?)</t[hd]>", re.I | re.S)
_FORM_RE = re.compile(r"<form\b[^>]*>(.*?)</form>", re.I | re.S)
_INPUT_RE = re.compile(r"<input\b[^>]*>", re.I)
_ATTR_RE = re.compile(r'([a-zA-Z_:-]+)\s*=\s*"([^"]*)"')
_UPLOAD_REPO_RES = [re.compile(r'"id"\s*:\s*"?(\d+)"?\s*,[^{}]*?"type"\s*:\s*"upload"'),
                    re.compile(r'"type"\s*:\s*"upload"[^{}]*?"id"\s*:\s*"?(\d+)"?')]
_CONTEXT_RES = [re.compile(r'"context"\s*:\s*\{\s*"id"\s*:\s*"?(\d+)'), re.compile(r'"contextid"\s*:\s*"?(\d+)')]
_STATEMENT_RE = re.compile(r'<input\b[^>]*name="submissionstatement"[^>]*>(?:.*?<label[^>]*>)?(.*?)</label>', re.I | re.S)


def _text(fragment: str) -> str:
    return " ".join(html_mod.unescape(re.sub(r"<[^>]+>", " ", fragment or "")).split())


def cmid_from_url(url: str | None) -> int | None:
    m = _CMID_RE.search(url or "")
    return int(m.group(1)) if m else None


def assignments(conn) -> list[dict]:
    """Offene und vergangene Abgaben aus den Fristen der Quelle "learnweb" (Moodle; HsH und Hildesheim)"""
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='deadlines'").fetchone():
        return []
    seen, out = set(), []
    for r in conn.execute("""SELECT d.title, d.due_at, d.url, c.title AS course FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id
                             WHERE d.source='learnweb' AND d.kind='abgabe' ORDER BY d.due_at DESC""").fetchall():
        cmid = cmid_from_url(r["url"])
        if cmid is None or cmid in seen:
            continue
        seen.add(cmid)
        out.append({"cmid": cmid, "title": r["title"] or "Aufgabe", "due_at": r["due_at"] or "", "course": r["course"]})
    return out


def status_rows(text: str) -> dict[str, str]:
    """Zeilen der Statustabelle (Kopfzelle -> Wert), ohne "Dateiabgabe" (Dateinamen mit Personendaten)"""
    out: dict[str, str] = {}
    for row in _ROW_RE.findall(text or ""):
        cells = _CELL_RE.findall(row)
        if len(cells) < 2:
            continue
        key = _text(cells[0])
        if not key or key.lower().startswith(("dateiabgabe", "file submissions")):
            continue
        out.setdefault(key, _text(cells[1]))
    return out


def status(text: str) -> dict:
    """Stand von der Seite der Aufgabe (view.php?id=…)"""
    state = (STATE_SUBMITTED if _SUBMITTED_RE.search(text) else STATE_DRAFT if _DRAFT_RE.search(text)
             else STATE_NONE if _NONE_RE.search(text) else STATE_UNKNOWN)
    rows = status_rows(text)
    return {"state": state, "can_edit": "action=editsubmission" in text,
            "can_submit": 'action=submit"' in text or "action=submit&" in text,
            "grading": rows.get("Bewertungsstatus") or rows.get("Grading status"),
            "attempt": rows.get("Nummer") or rows.get("Attempt number"),
            "has_feedback": re.search(r">Feedback<", text, re.I) is not None}


def hidden_fields(text: str, marker: str) -> dict[str, str] | None:
    """Versteckte Felder des Formulars, das `marker` enthaelt"""
    form = next((f for f in _FORM_RE.findall(text or "") if marker in f), None)
    if form is None:
        return None
    out = {}
    for tag in _INPUT_RE.findall(form):
        a = {k.lower(): html_mod.unescape(v) for k, v in _ATTR_RE.findall(tag)}
        if a.get("name") and a.get("type", "").lower() == "hidden":
            out[a["name"]] = a.get("value", "")
    return out


def _first(res, text: str) -> str | None:
    for rx in res:
        m = rx.search(text)
        if m:
            return m.group(1)
    return None


def edit_form(text: str) -> dict | None:
    """Abgabe-Formular: versteckte Felder, Entwurfsbereich, Upload-Repository und Kontext der Dateiauswahl"""
    f = hidden_fields(text, "_qf__mod_assign_submission_form")
    item = (f or {}).get("files_filemanager")
    repo, ctx = _first(_UPLOAD_REPO_RES, text or ""), _first(_CONTEXT_RES, text or "")
    if not f or not item or not repo or not ctx:
        return None
    return {"fields": f, "draft_item_id": item, "repository_id": repo, "context_id": ctx}


def confirm_form(text: str) -> dict | None:
    """Bestaetigungs-Formular; `statement`: Text der Erklaerung, falls verlangt"""
    f = hidden_fields(text, "_qf__mod_assign_confirm_submission_form")
    if f is None:
        return None
    statement = None
    if 'name="submissionstatement"' in text:
        m = _STATEMENT_RE.search(text)
        statement = (_text(m.group(1)) if m else "") or "Erklärung zur Abgabe"
    return {"fields": f, "statement": statement}


def save_fields(form: dict) -> list[tuple[str, str]]:
    """Felder fuer das Speichern des Entwurfs (wie der Knopf "Änderungen sichern")"""
    f = dict(form["fields"], files_filemanager=form["draft_item_id"], submitbutton="Änderungen sichern")
    return sorted(f.items())


def confirm_fields(form: dict, statement_accepted: bool) -> list[tuple[str, str]]:
    """Felder fuer "Abgabe abschliessen"; die Erklaerung nur, wenn der Mensch sie bestaetigt hat"""
    f = dict(form["fields"], submitbutton="Weiter")
    if form.get("statement") is not None and statement_accepted:
        f["submissionstatement"] = "1"
    return sorted(f.items())


def fetch_status(web: MoodleWeb, cmid: int) -> dict:
    return status(web.page(f"/mod/assign/view.php?id={int(cmid)}")[0])


def save_draft(web: MoodleWeb, cmid: int, pdf: bytes, file_name: str) -> tuple[dict, str]:
    """PDF als Entwurf hochladen und speichern (noch nicht abgegeben). Rueckgabe: Stand danach, Name in Moodle"""
    form = edit_form(web.page(f"/mod/assign/view.php?id={int(cmid)}&action=editsubmission")[0])
    if form is None:
        raise MoodleError("unexpected", "Abgabe-Formular ohne Datei-Upload")
    key, _ = web.current()
    upload = web.post_multipart("/repository/repository_ajax.php?action=upload",
                                [("sesskey", key), ("repo_id", form["repository_id"]), ("itemid", form["draft_item_id"]),
                                 ("author", ""), ("savepath", "/"), ("title", file_name), ("ctx_id", form["context_id"]),
                                 ("env", "filemanager"), ("maxbytes", "-1"), ("areamaxbytes", "-1")],
                                ("repo_upload_file", file_name, "application/pdf", pdf))
    # gleicher Name schon im Entwurf: Moodle legt die Datei unter neuem Namen ab ("fileexists")
    saved = ((upload.get("newfile") or {}).get("filename") if isinstance(upload.get("newfile"), dict) else None) or upload.get("file") or file_name
    result, _ = web.post_form("/mod/assign/view.php", save_fields(form))
    return status(result), str(saved)


def fetch_confirm(web: MoodleWeb, cmid: int) -> dict:
    """Bestaetigungs-Seite lesen (zeigt, ob eine Erklaerung verlangt ist), ohne etwas abzusenden"""
    form = confirm_form(web.page(f"/mod/assign/view.php?id={int(cmid)}&action=submit")[0])
    if form is None:
        raise MoodleError("unexpected", "Bestätigung der Abgabe")
    return form


def submit(web: MoodleWeb, cmid: int, statement_accepted: bool) -> dict:
    """"Jetzt abgeben": Bestaetigung absenden. Nur auf ausdruecklichen Knopfdruck aufrufen."""
    form = fetch_confirm(web, cmid)
    if form["statement"] is not None and not statement_accepted:
        raise MoodleError("refused", "Erklärung nicht bestätigt")
    result, _ = web.post_form("/mod/assign/view.php", confirm_fields(form, statement_accepted))
    return status(result)


# ---------------------------------------------------------------------------- Hochschule (PC)

def instance() -> dict | None:
    """Moodle der aktuellen Hochschule: {key, name, base, session} (HsH: Moodle, Hildesheim: Learnweb); sonst None"""
    from . import config
    uni = config.university()
    if uni == "hsh":
        from . import hsh
        return {"key": "hsh", "name": "Moodle", "base": hsh.moodle_base(), "session": hsh.SESSION}
    if uni == "hildesheim":
        from . import hildesheim
        return {"key": "hildesheim", "name": "Learnweb", "base": hildesheim.learnweb_base(), "session": "LEARNWEB_COOKIES"}
    return None


def live(inst: dict | None = None) -> MoodleWeb:
    """Sitzung mit den gemerkten Cookies; ohne Hochschul-Moodle oder ohne Sitzung: MoodleError("login")"""
    from . import filestream
    inst = inst or instance()
    if not inst:
        raise MoodleError("login")
    return MoodleWeb(inst["base"], filestream.cookie_header(inst["session"], inst["base"]))
