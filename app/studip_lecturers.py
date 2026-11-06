"""Lehrende und Kontakte (LUH, Stud.IP), 06.11.2026 - Auftrag des Inhabers: "baue noch eine funktion e-mails der lehrer
zu finden die kann man ueber studip sehen bei luh; fuer lsf und hsh machen wir das in einer spaeteren version".
docs/LEHRENDE-KONTAKTE-2026-11-06.md, gleiche Regeln im Swift-Kern (StudIPLecturers.swift), Fixture
tools/gen-studip-lecturers-fixture.py.

Gelesen wird nur, was die eigene Stud.IP-Sitzung ohnehin sieht, und nur lesend:
 - `courses/{id}/memberships?filter[permission]=dozent|tutor&include=user`: Lehrende und Tutor/innen eines Kurses mit
   Name, Benutzername und E-Mail-Adresse (Attribut `email` des Nutzers, Stud.IP-JSON:API-Doku "users"). Nur diese zwei
   Rollen: Eintraege mit anderer Rolle (Studierende) werden verworfen, nie gespeichert.
 - `users/{id}` nur, wenn `include=user` fehlt (hoechstens MAX_USER_LOOKUPS je Lauf).
 - `users/{id}/institute-memberships?include=institute`: Sprechzeiten (`office-hours`), Raum (`location`), Einrichtung;
   nur fuer Dozent/innen.
Alle drei live bestaetigt am 06.11.2026 (Anmeldung des Inhabers, nur GET, anonymisiert): `include=user` liefert `email`,
`formatted-name`, `name-prefix`, `name-suffix`; beide Filter wirken; `office-hours` und `location` sind oft null.
Fehlt die E-Mail-Adresse (Stud.IP zeigt sie nicht), zeigt die Oberflaeche "Nachricht ueber Stud.IP".

Wann: nach Stufe (a) des Abgleichs (aktuelles Semester samt Stundenplan, Dateien und Ankuendigungen; app/sync_order.py),
nie davor; je Kurs hoechstens alle REFRESH_DAYS Tage. Nur an der LUH (HsH und Hildesheim: spaeter). Datenschutz: nur
lokal (am PC im Einzelplatz-Betrieb), im gehosteten Dienst nie gelesen oder gespeichert.
"""
from __future__ import annotations

import re
import urllib.parse
from datetime import date, timedelta

from . import announcements

ROLES = ("dozent", "tutor")
ROLE_LABELS = {"dozent": "Dozent/in", "tutor": "Tutor/in"}
REFRESH_DAYS = 7
MAX_COURSES = 30
MAX_USER_LOOKUPS = 20
MAX_PROFILES = 40
MAX_NAME = 120
MAX_OFFICE = 400
MAX_LOCATION = 120
MAX_LABEL = 80
NO_EMAIL = "Nachricht über Stud.IP"
UNKNOWN_NAME = "Stud.IP-Nutzer/in"
HINT_NOT_LOADED = "Die Lehrenden kommen mit dem nächsten Stud.IP-Abgleich (nach dem aktuellen Semester)."
HINT_NONE = "In Stud.IP sind für diese Kurse keine Lehrenden sichtbar."
HINT_NO_MATCH = "Keine Lehrenden gefunden."
MISSING_NAME = "course-memberships"
PROFILE_MISSING_NAME = "institute-memberships"
EMAIL_RE = re.compile(r"^[^@\s<>\"',;:()\[\]]+@[^@\s<>\"',;:()\[\]]+\.[A-Za-z]{2,}$")
_WS_RE = re.compile(r"\s+")
_DAY_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")

TABLE = """CREATE TABLE IF NOT EXISTS studip_lecturers (
    course_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    role TEXT NOT NULL,                -- dozent | tutor (nie Studierende)
    position INTEGER,
    label TEXT,                        -- "Funktion" aus Stud.IP
    name TEXT,
    username TEXT,
    email TEXT,                        -- leer, wenn Stud.IP sie nicht zeigt
    office_hours TEXT,
    location TEXT,
    institute TEXT,
    fetched_at TEXT,
    PRIMARY KEY (course_id, user_id)
)"""
COURSES_TABLE = """CREATE TABLE IF NOT EXISTS studip_lecturer_courses (
    course_id TEXT PRIMARY KEY,
    fetched_at TEXT NOT NULL
)"""


def _id(x) -> str | None:
    v = x.get("id") if isinstance(x, dict) else None
    if isinstance(v, bool) or not isinstance(v, (str, int)) or v == "":
        return None
    return str(v)


def _attrs(x) -> dict:
    a = x.get("attributes") if isinstance(x, dict) else None
    return a if isinstance(a, dict) else {}


def _str(v) -> str:
    return v if isinstance(v, str) else ""


def _rel(x, name: str):
    r = (x.get("relationships") or {}) if isinstance(x, dict) else {}
    r = r.get(name) if isinstance(r, dict) else None
    d = r.get("data") if isinstance(r, dict) else None
    return d if isinstance(d, dict) else None


def _int(v, default: int) -> int:
    if isinstance(v, bool):
        return default
    if isinstance(v, int):
        return v
    if isinstance(v, str) and re.fullmatch(r"-?[0-9]{1,9}", v.strip()):
        return int(v.strip())
    return default


def _clip(s: str, n: int) -> str:
    return _WS_RE.sub(" ", s).strip()[:n].strip()


# ----------------------------------------------------------------------------
# Lesen (reine Funktionen, gleich im Swift-Kern)
# ----------------------------------------------------------------------------

def display_name(a) -> str:
    """Name eines Nutzers: `formatted-name`, sonst Titel, Vorname, Nachname, Titel."""
    a = a if isinstance(a, dict) else {}
    n = _clip(_str(a.get("formatted-name")), MAX_NAME)
    if n:
        return n
    parts = [_str(a.get(k)) for k in ("name-prefix", "given-name", "family-name", "name-suffix")]
    return _clip(" ".join(p for p in parts if p.strip()), MAX_NAME)


def clean_email(v) -> str:
    """Nur eine einzelne, plausible Adresse; sonst leer (dann "Nachricht ueber Stud.IP")."""
    s = _str(v).strip()
    return s if len(s) <= 254 and EMAIL_RE.match(s) else ""


def _users(included) -> dict:
    return {_id(u): _attrs(u) for u in (included if isinstance(included, list) else [])
            if isinstance(u, dict) and u.get("type") == "users" and _id(u)}


def parse_members(body) -> list[dict]:
    """Antwort von courses/{id}/memberships -> [{user_id, role, position, label, name, username, email}]. Nur Eintraege
    vom Typ course-memberships mit Rolle dozent oder tutor (Attribut `permission`); alle anderen (Studierende) fallen
    weg. Name, Benutzername und E-Mail aus `included` (include=user); ohne include bleiben sie leer."""
    body = body if isinstance(body, dict) else {}
    data = body.get("data") if isinstance(body.get("data"), list) else []
    users = _users(body.get("included"))
    out, seen = [], set()
    for i, m in enumerate(data):
        if not isinstance(m, dict) or m.get("type") != "course-memberships":
            continue
        a = _attrs(m)
        role = _str(a.get("permission")).strip().lower()
        u = _rel(m, "user")
        uid = _id(u) if u and u.get("type") == "users" else None
        if role not in ROLES or not uid or uid in seen:
            continue
        seen.add(uid)
        ua = users.get(uid, {})
        out.append({"user_id": uid, "role": role, "position": _int(a.get("position"), i), "label": _clip(_str(a.get("label")), MAX_LABEL),
                    "name": display_name(ua), "username": _clip(_str(ua.get("username")), 64), "email": clean_email(ua.get("email"))})
    return out


def merge_user(m: dict, body) -> dict:
    """Mitglied ohne Namen + Antwort von users/{id} -> Mitglied mit Name, Benutzername, E-Mail (nur leere Felder)."""
    d = body.get("data") if isinstance(body, dict) else None
    a = _attrs(d) if isinstance(d, dict) and _id(d) == m["user_id"] else {}
    return dict(m, name=m["name"] or display_name(a), username=m["username"] or _clip(_str(a.get("username")), 64),
                email=m["email"] or clean_email(a.get("email")))


def parse_profile(body) -> dict:
    """Antwort von users/{id}/institute-memberships (include=institute) -> {office_hours, location, institute}.
    Reihenfolge: Standard-Einrichtung (`is-default`), dann `priority`, dann Stud.IP-Reihenfolge; genommen wird die erste
    mit Sprechzeiten oder Raum, sonst die erste fuer den Namen der Einrichtung."""
    body = body if isinstance(body, dict) else {}
    data = body.get("data") if isinstance(body.get("data"), list) else []
    inst = {_id(x): _attrs(x) for x in (body.get("included") if isinstance(body.get("included"), list) else [])
            if isinstance(x, dict) and x.get("type") == "institutes" and _id(x)}
    cands = []
    for i, x in enumerate(data):
        if not isinstance(x, dict) or x.get("type") != "institute-memberships":
            continue
        a = _attrs(x)
        ref = _rel(x, "institute")
        name = _clip(_str(inst.get(_id(ref), {}).get("name")), MAX_NAME) if ref else ""
        office = announcements.html_to_text(_str(a.get("office-hours")))[:MAX_OFFICE].strip()
        cands.append(((0 if a.get("is-default") is True else 1, _int(a.get("priority"), 999), i),
                      {"office_hours": office, "location": _clip(_str(a.get("location")), MAX_LOCATION), "institute": name}))
    cands.sort(key=lambda c: c[0])
    for _, p in cands:
        if p["office_hours"] or p["location"]:
            return p
    return {"office_hours": "", "location": "", "institute": cands[0][1]["institute"] if cands else ""}


def role_label(roles) -> str:
    return ", ".join(ROLE_LABELS[r] for r in ROLES if r in roles)


def message_url(base: str, username: str) -> str:
    """Schreibfenster von Stud.IP mit voreingetragenem Empfaenger (Parameter `rec_uname` der Stud.IP-Oberflaeche)."""
    b = base.rstrip("/")
    u = (username or "").strip()
    return f"{b}/dispatch.php/messages/write" + (f"?rec_uname={urllib.parse.quote(u, safe='-._~')}" if u else "")


def mailto(email: str) -> str | None:
    return f"mailto:{email}" if email else None


# ----------------------------------------------------------------------------
# Speicher
# ----------------------------------------------------------------------------

def ensure(conn) -> None:
    conn.execute(TABLE)
    conn.execute(COURSES_TABLE)


def _has(conn, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def store_course(conn, course_id: str, members: list[dict], fetched_at: str) -> int:
    """Lehrende eines Kurses ersetzen (Sprechzeiten bekannter Personen bleiben bis zum neuen Profil)."""
    ensure(conn)
    old = {r[0]: (r[1], r[2], r[3]) for r in conn.execute(
        "SELECT user_id, office_hours, location, institute FROM studip_lecturers WHERE course_id=?", (course_id,)).fetchall()}
    conn.execute("DELETE FROM studip_lecturers WHERE course_id=?", (course_id,))
    for m in members:
        oh, loc, ins = old.get(m["user_id"], ("", "", ""))
        conn.execute("""INSERT OR REPLACE INTO studip_lecturers(course_id, user_id, role, position, label, name, username, email,
                        office_hours, location, institute, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                     (course_id, m["user_id"], m["role"], m["position"], m["label"], m["name"], m["username"], m["email"],
                      oh or "", loc or "", ins or "", fetched_at))
    conn.execute("INSERT OR REPLACE INTO studip_lecturer_courses(course_id, fetched_at) VALUES (?, ?)", (course_id, fetched_at))
    return len(members)


def store_profiles(conn, profiles: dict) -> None:
    ensure(conn)
    for uid in sorted(profiles):
        p = profiles[uid]
        conn.execute("UPDATE studip_lecturers SET office_hours=?, location=?, institute=? WHERE user_id=?",
                     (p["office_hours"], p["location"], p["institute"], uid))


def due(conn, course_ids: list[str], today: date) -> list[str]:
    """Kurse, deren Lehrende neu zu lesen sind (nie gelesen oder aelter als REFRESH_DAYS), in der Reihenfolge des
    Abgleichs, hoechstens MAX_COURSES."""
    known = {}
    if _has(conn, "studip_lecturer_courses"):
        known = {r[0]: r[1] for r in conn.execute("SELECT course_id, fetched_at FROM studip_lecturer_courses").fetchall()}
    limit = (today - timedelta(days=REFRESH_DAYS)).isoformat()
    out = []
    for c in course_ids:
        seen = known.get(c)
        stamp = seen[:10] if isinstance(seen, str) and _DAY_RE.match(seen) else None
        if c not in out and (stamp is None or stamp <= limit):
            out.append(c)
    return out[:MAX_COURSES]


def overview(conn, university: str, base: str, course_id: str | None = None, module_id: int | None = None,
             q: str | None = None, allowed: bool = True) -> dict:
    """GET /api/lecturers: Lehrende eines Kurses (`course_id`), eines Moduls (`module_id`) oder aller aktiven Kurse,
    optional gefiltert (`q`: Name, E-Mail, Kurs oder Modul). Nur an der LUH (`available`); HsH und Hildesheim: spaeter.
    Person: {id, name, email, has_email, no_email, roles, role_label, label, office_hours, location, institute, username,
    courses: [{course_id, title, module_id, module_name, role, role_label}], message_url, mailto}."""
    available = university == "luh" and allowed
    out = {"available": available, "university": university, "people": [], "count": 0, "total": 0, "loaded": False,
           "updated_at": None, "hint": None, "no_email": NO_EMAIL}
    if not available:
        return out
    where, args = "c.active=1", []
    if course_id:
        where, args = "l.course_id=?", [course_id]
    elif module_id is not None:
        where, args = "c.module_id=?", [module_id]
    rows = []
    if _has(conn, "studip_lecturers"):
        rows = conn.execute(f"""SELECT l.course_id, l.user_id, l.role, l.position, l.label, l.name, l.username, l.email,
                                l.office_hours, l.location, l.institute, c.title, c.module_id, m.name, l.fetched_at
                                FROM studip_lecturers l JOIN courses c ON c.id=l.course_id LEFT JOIN modules m ON m.id=c.module_id
                                WHERE {where} ORDER BY l.course_id, l.position, l.user_id""", args).fetchall()
    loaded_rows = []
    if _has(conn, "studip_lecturer_courses"):
        lw = where.replace("l.course_id", "k.course_id")
        loaded_rows = conn.execute(f"""SELECT k.fetched_at FROM studip_lecturer_courses k JOIN courses c ON c.id=k.course_id
                                       WHERE {lw}""", args).fetchall()
    people: dict[str, dict] = {}
    for r in rows:
        cid, uid, role, pos, label, name, user, email, oh, loc, ins, title, mid, mname, _ = tuple(r)
        p = people.get(uid)
        if p is None:
            p = people[uid] = {"id": uid, "name": "", "email": "", "roles": [], "label": "", "office_hours": "", "location": "",
                               "institute": "", "username": "", "courses": [], "_pos": pos if isinstance(pos, int) else 999}
        for k, v in (("name", name), ("email", email), ("label", label), ("office_hours", oh), ("location", loc),
                     ("institute", ins), ("username", user)):
            if not p[k] and v:
                p[k] = v
        if role not in p["roles"]:
            p["roles"].append(role)
        if isinstance(pos, int) and pos < p["_pos"]:
            p["_pos"] = pos
        p["courses"].append({"course_id": cid, "title": title or "", "module_id": mid, "module_name": mname,
                             "role": role, "role_label": ROLE_LABELS.get(role, role)})
    total = list(people.values())
    needle = (q or "").strip().lower()
    if needle:
        def hit(p):
            texts = [p["name"], p["email"]] + [c["title"] for c in p["courses"]] + [c["module_name"] or "" for c in p["courses"]]
            return any(needle in t.lower() for t in texts)
        chosen = [p for p in total if hit(p)]
    else:
        chosen = total
    scoped = bool(course_id) or module_id is not None
    if scoped:
        chosen.sort(key=lambda p: (0 if "dozent" in p["roles"] else 1, p["_pos"], p["name"].lower(), p["id"]))
    else:
        chosen.sort(key=lambda p: (p["name"].lower() or "￿", p["id"]))
    result = []
    for p in chosen:
        roles = [r for r in ROLES if r in p["roles"]]
        courses = sorted(p["courses"], key=lambda c: (c["title"].lower(), c["course_id"]))
        result.append({"id": p["id"], "name": p["name"] or UNKNOWN_NAME, "email": p["email"], "has_email": bool(p["email"]),
                       "no_email": None if p["email"] else NO_EMAIL, "roles": roles, "role_label": role_label(roles),
                       "label": p["label"], "office_hours": p["office_hours"], "location": p["location"],
                       "institute": p["institute"], "username": p["username"], "courses": courses,
                       "message_url": message_url(base, p["username"]), "mailto": mailto(p["email"])})
    loaded = bool(loaded_rows)
    stamps = [r[0] for r in loaded_rows if isinstance(r[0], str)]
    hint = None
    if not result:
        hint = HINT_NO_MATCH if needle and total else HINT_NONE if loaded else HINT_NOT_LOADED
    out.update(people=result, count=len(result), total=len(total), loaded=loaded, updated_at=max(stamps) if stamps else None, hint=hint)
    return out


def known_person(conn, user_id: str) -> dict | None:
    """Gespeicherte Person (Lehrende/r eines eigenen Kurses) oder None: nur an sie schreibt die App ueber Stud.IP."""
    if not _has(conn, "studip_lecturers"):
        return None
    r = conn.execute("SELECT user_id, name, username FROM studip_lecturers WHERE user_id=? ORDER BY course_id LIMIT 1",
                     (user_id,)).fetchone()
    return {"id": r[0], "name": r[1] or UNKNOWN_NAME, "username": r[2] or ""} if r else None


# ----------------------------------------------------------------------------
# Abruf
# ----------------------------------------------------------------------------

def lecturers_allowed() -> bool:
    """Nur lokal (PC/Windows-App im Einzelplatz-Betrieb), nie im Dienst; nur an der LUH."""
    from . import config
    return not config.is_hosted() and config.university() == "luh"


def sync(get, conn, course_ids: list[str], today: date, fetched_at: str) -> dict:
    """Lehrende der Kurse lesen, die dran sind (`due`). `get(path)` -> (HTTP-Status, JSON oder None), Pfad relativ zu
    jsonapi.php/v1/. Ein Fehler bei einem Kurs laesst die anderen und den Bestand; 404 bei allen Kursen merkt sich
    den Endpunkt (studip_extras, 30 Tage). Liefert {courses, people, profiles, requests}."""
    from . import studip_extras
    missing = studip_extras.load_missing(conn)
    t = today.isoformat()
    res = {"courses": 0, "people": 0, "profiles": 0, "requests": 0}
    if not studip_extras.should_ask(missing, MISSING_NAME, t):
        return res
    todo = due(conn, course_ids, today)
    if not todo:
        return res

    def ask(path: str):
        res["requests"] += 1
        try:
            return get(path)
        except Exception:  # noqa: BLE001 - Netz: Bestand bleibt
            return 0, None

    not_found = 0
    lookups = 0
    stored: list[dict] = []
    for cid in todo:
        members: list[dict] = []
        ok = True
        for role in ROLES:
            base_path = f"courses/{cid}/memberships?filter[permission]={role}&page[limit]=100"
            status, body = ask(base_path + "&include=user")
            if status == 400:
                status, body = ask(base_path)
            if status == 404:
                not_found += 1
            if status == 403:                    # Stud.IP zeigt die Teilnehmenden nicht: als leer merken (7 Tage)
                members, ok = [], True
                break
            if not (200 <= status < 300) or not isinstance(body, dict):
                ok = False
                break
            members += [m for m in parse_members(body) if m["user_id"] not in {x["user_id"] for x in members}]
        if not ok:
            continue
        for i, m in enumerate(members):
            if not m["name"] and lookups < MAX_USER_LOOKUPS:
                lookups += 1
                status, body = ask(f"users/{m['user_id']}")
                if 200 <= status < 300:
                    members[i] = merge_user(m, body)
        store_course(conn, cid, members, fetched_at)
        res["courses"] += 1
        res["people"] += len(members)
        stored += members
    if res["courses"] == 0 and not_found == len(todo):
        missing = studip_extras.remember(missing, MISSING_NAME, 404, t)      # Stud.IP ohne diese Route
    profiles: dict[str, dict] = {}
    if studip_extras.should_ask(missing, PROFILE_MISSING_NAME, t):
        # nur fuer Dozent/innen (Empfehlung nach dem echten Test 06.11.2026; Tutor/innen haben selten Sprechzeiten)
        for uid in list(dict.fromkeys(m["user_id"] for m in stored if m["role"] == "dozent"))[:MAX_PROFILES]:
            status, body = ask(f"users/{uid}/institute-memberships?include=institute")
            if status == 400:
                status, body = ask(f"users/{uid}/institute-memberships")
            if status == 404 and not profiles:
                missing = studip_extras.remember(missing, PROFILE_MISSING_NAME, 404, t)   # Route fehlt: 30 Tage Ruhe
                break
            if 200 <= status < 300 and isinstance(body, dict):
                profiles[uid] = parse_profile(body)                # 403 (nicht sichtbar): Person ohne Sprechzeiten
        store_profiles(conn, profiles)
    res["profiles"] = len(profiles)
    studip_extras.save_missing(conn, missing)
    return res
