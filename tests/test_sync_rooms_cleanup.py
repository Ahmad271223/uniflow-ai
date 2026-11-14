"""Aufraeumen nach der Vermischung zweier Uni-Konten (Befund am echten iPhone, 14.11.2026), mit erfundenen Daten.

Nachgestellt mit dem Abgleich-Client (app/sync_client.py, dieselben Regeln wie `DeviceSync` im Swift-Kern) gegen den
Dienst per ASGI: Adas iPad und iPhone (Uni-Konto "ada") und ein drittes Geraet mit demselben StudiNow-Konto, aber dem
Uni-Konto "bob". Vor den Raeumen hat jedes Geraet alles bekommen; danach hat Adas iPhone 15 Faecher, 8 davon leer und
fremd. Erwartet: die 8 gehen auf Adas Geraeten (ohne Loeschmarke), die 7 eigenen bleiben, auf Bobs Geraet bleiben die 8."""
import json
import sqlite3

import pytest
from conftest import asgi_call

SERVICE = "http://127.0.0.1:9"
ADA = [f"Ada-Fach {i}" for i in range(1, 8)]
BOB = [f"Bob-Fach {i}" for i in range(1, 9)]


@pytest.fixture
def service(app, monkeypatch):
    from app import accounts, community, config, service_link
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)

    def hosted(method, path, body=None, headers=None):
        old = config.MODE
        config.MODE = "hosted"
        try:
            return asgi_call(app, method, path, body=body, headers=headers)
        finally:
            config.MODE = old

    def transport(method, url, headers, body, timeout):
        st, h, b = hosted(method, url[len(SERVICE):], body or b"", {k: v for k, v in headers.items() if k == "Authorization"})
        return st, {k.decode(): v.decode() for k, v in h}, b
    monkeypatch.setattr(service_link, "transport", transport)
    st, _, b = hosted("POST", "/api/account/register",
                      json.dumps({"email": "zwei-unis@example.org", "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 201
    d = json.loads(b)
    accounts.mark_email_verified(d["user"]["id"])
    yield {"token": d["token"], "account": d["user"]["id"], "hosted": hosted}
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


class Device:
    """Ein Geraet mit eigener Datenbank; `uni` wie nach dem Stud.IP-Abgleich (nur der Hash liegt lokal)."""

    def __init__(self, tmp_path, name, service):
        from app import db, sync_client
        self.name, self.service = name, service
        self.conn = sqlite3.connect(tmp_path / f"{name}.db", isolation_level=None, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("BEGIN")
        db._init_db(self.conn)
        self.conn.execute("COMMIT")
        sync_client.ensure_tables(self.conn)
        self.mode = "alt"                                       # alt: kein Hash | hash: nur studip_user (1.0.3) | neu: uni_key
        self.last = None

    def studip(self, subjects, course_prefix):
        """Der eigene Stud.IP-Abgleich: Fach (falls es noch fehlt), Kurs und Datei."""
        for i, name in enumerate(subjects, 1):
            r = self.conn.execute("SELECT id FROM modules WHERE name=?", (name,)).fetchone()
            mid = r[0] if r else self.conn.execute("INSERT INTO modules(name, semester, created_at) VALUES (?, 'WiSe 2026/27', '2026-11-11')", (name,)).lastrowid
            cid = f"{course_prefix}-{i}"
            self.conn.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, module_id) VALUES (?,?,?,?, 'vorlesung', ?)",
                              (cid, name, "WiSe 2026/27", name, mid))
            self.conn.execute("INSERT OR IGNORE INTO files(id, course_id, name, kind, status) VALUES (?,?,?, 'pdf', 'neu')", (f"{cid}-f", cid, "Skript.pdf"))

    def uni(self, user, mode):
        from app import sync_client
        sync_client.remember_studip_user(self.conn, user)
        self.mode = mode

    def sync(self):
        import time
        from app import sync_client
        time.sleep(0.003)       # eine Loeschung direkt davor liegt nicht in der Millisekunde des Abrufs (dessen Marken gehoeren dem Dienst)
        c = sync_client.Client(self.conn, self.name, token=self.service["token"], url=SERVICE)
        if self.mode == "neu":
            c.use_uni_account(self.service["account"], "luh")
        elif self.mode == "hash":
            c.studip_user = self.conn.execute("SELECT value FROM settings WHERE key='studip_user_hash'").fetchone()[0]
        c.pull()
        c.push()
        c.pull()
        assert c.stats["errors"] == [], c.stats
        self.last = c.stats
        return c.stats

    def subjects(self):
        return sorted(r[0] for r in self.conn.execute("SELECT name FROM modules"))

    def count(self, table):
        return self.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def unsent_tombstones(self):
        return self.conn.execute("""SELECT COUNT(*) FROM sync_tombstones t JOIN sync_link_map m ON m.entity=t.entity AND m.local_id=t.entity_id
                                    WHERE t.device IS NULL""").fetchone()[0]


def _mixed(tmp_path, service):
    """Stand vor dem Update: alle drei Geraete gleichen ohne Hash ab und haben am Ende alles."""
    ipad, other, iphone = (Device(tmp_path, n, service) for n in ("ipad-ada", "ipad-bob", "iphone-ada"))
    ipad.studip(ADA, "ada")
    ipad.sync()
    other.studip(BOB, "bob")
    mid = other.conn.execute("SELECT id FROM modules WHERE name=?", (BOB[0],)).fetchone()[0]
    for day in (0, 2):                                           # Bobs Stundenplan
        eid = other.conn.execute("""INSERT INTO course_events(module_id, course_id, title, weekday, start_time, end_time, kind, created_at)
                                    VALUES (?, 'bob-1', 'Bob-Vorlesung', ?, '08:15', '09:45', 'vorlesung', '2026-11-11')""", (mid, day)).lastrowid
        other.conn.execute("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?, '2026-12-24', 'skip', '2026-11-11')", (eid,))
    other.sync()
    iphone.sync()                                                # frisches iPhone: holt alle 15
    iphone.studip(ADA, "ada")                                    # sein Stud.IP-Abgleich haengt Kurse nur an die eigenen 7
    ipad.sync()
    return ipad, other, iphone


def test_mixed_devices_are_separated_again_without_losing_anything(tmp_path, service):
    ipad, other, iphone = _mixed(tmp_path, service)
    # der Fehler: 15 Faecher auf dem iPhone, 8 davon leer und fremd, dazu Bobs Termine
    assert iphone.subjects() == sorted(ADA + BOB) and iphone.count("course_events") == 2 and iphone.count("event_exceptions") == 2
    empty = [r[0] for r in iphone.conn.execute("SELECT name FROM modules m WHERE NOT EXISTS (SELECT 1 FROM courses c WHERE c.module_id=m.id)")]
    assert sorted(empty) == BOB
    assert ipad.subjects() == sorted(ADA + BOB) and other.subjects() == sorted(ADA + BOB)

    # --- Dienst und iPhone-App sind neu; Bobs Geraet hat sich noch nicht gemeldet: nichts ist nachweislich fremd
    iphone.uni("ada", "neu")
    st = iphone.sync()
    assert iphone.subjects() == sorted(ADA + BOB) and st["foreign_removed"] == 0, "im Zweifel bleibt alles"

    # --- Bobs Geraet gleicht ab (aeltere App, schickt nur den Stud.IP-Hash): seine Zeilen gehoeren seinem Raum
    other.uni("bob", "hash")
    other.sync()
    assert other.subjects() == sorted(ADA + BOB), "aeltere App raeumt nicht auf, verliert aber auch nichts"

    # --- das iPhone beim naechsten Abgleich: die 8 fremden, leeren Faecher und Bobs Termine gehen
    st = iphone.sync()
    assert iphone.subjects() == ADA and st["foreign_removed"] == 8 + 2 + 2 and st["other_uni"] is True
    assert iphone.count("course_events") == 0 and iphone.count("event_exceptions") == 0
    assert iphone.count("courses") == 7 + 1 and iphone.count("files") == 7, "eigene Kurse und Dateien unberuehrt (+ Eigene Dokumente)"
    assert iphone.unsent_tombstones() == 0 and st["deleted"] == 0, "keine Loeschmarke, die sich fortpflanzt"

    # --- auf Bobs Geraet bleibt alles: auch nach weiteren Abgleichen aller Geraete
    other.sync()
    iphone.sync()
    assert [n for n in other.subjects() if n in BOB] == BOB
    assert other.count("course_events") == 2 and other.count("event_exceptions") == 2 and other.count("courses") == 8 + 1

    # --- Adas iPad bekommt die neue App: gleiches Aufraeumen; seine 7 Faecher gehoeren nun dem Raum
    ipad.uni("ada", "neu")
    st = ipad.sync()
    assert ipad.subjects() == ADA and st["foreign_removed"] == 8 + 2 + 2 and ipad.count("courses") == 7 + 1
    assert iphone.sync()["foreign_removed"] == 0 and iphone.subjects() == ADA

    # --- Bobs Geraet bekommt die neue App: Adas 7 Faecher (dort leer) gehen, seine 8 bleiben
    other.uni("bob", "neu")
    st = other.sync()
    assert other.subjects() == BOB and st["foreign_removed"] == 7 and st["deleted"] == 0
    assert other.count("course_events") == 2 and other.count("courses") == 8 + 1 and other.unsent_tombstones() == 0

    # --- im Dienst ist nichts geloescht: 7 Faecher in Adas Raum, 8 in Bobs, keine Loeschmarke
    for d in (ipad, iphone, other):
        assert d.sync()["foreign_removed"] == 0
    assert ipad.subjects() == ADA and iphone.subjects() == ADA and other.subjects() == BOB
    fresh_ada, fresh_bob = Device(tmp_path, "mac-ada", service), Device(tmp_path, "mac-bob", service)
    fresh_ada.uni("ada", "neu")
    fresh_bob.uni("bob", "neu")
    fresh_ada.sync()
    fresh_bob.sync()
    assert fresh_ada.subjects() == ADA and fresh_bob.subjects() == BOB and fresh_bob.count("course_events") == 2
    assert fresh_ada.last["deleted"] == 0 and fresh_bob.last["deleted"] == 0

    # --- danach laeuft der Abgleich im Raum weiter: Adas neues Fach kommt aufs iPhone, nicht zu Bob
    ipad.conn.execute("INSERT INTO modules(name, semester, created_at) VALUES ('Ada neu', 'WiSe 2026/27', '2026-11-15')")
    ipad.sync()
    iphone.sync()
    other.sync()
    assert "Ada neu" in iphone.subjects() and "Ada neu" not in other.subjects()
    # und Loeschen bleibt im Raum
    iphone.conn.execute("DELETE FROM modules WHERE name='Ada neu'")
    iphone.sync()
    ipad.sync()
    other.sync()
    assert "Ada neu" not in ipad.subjects() and other.subjects() == BOB


def test_foreign_subject_with_own_content_is_kept_and_becomes_an_own_row(tmp_path, service):
    """Niemals etwas entfernen, das auf dem Geraet eigene Inhalte hat: ein fremdes Fach, zu dem hier ein Lernpaket
    angelegt wurde, und eines, das hier umbenannt wurde, bleiben und gehen als eigene Zeilen in den eigenen Raum."""
    ipad, other, iphone = _mixed(tmp_path, service)
    with_plan = iphone.conn.execute("SELECT id FROM modules WHERE name=?", (BOB[2],)).fetchone()[0]
    iphone.conn.execute("INSERT INTO study_packages(date, module_id, subject, title, created_at) VALUES ('2026-11-20', ?, ?, 'Eigenes Paket', '2026-11-14')",
                        (with_plan, BOB[2]))
    iphone.conn.execute("UPDATE modules SET name='Selbst umbenannt' WHERE name=?", (BOB[3],))
    iphone.conn.execute("INSERT INTO flashcard_stacks(name, subject, created_at) VALUES ('Karten', ?, '2026-11-14')", (BOB[4],))
    iphone.uni("ada", "neu")
    other.uni("bob", "neu")
    other.sync()
    st = iphone.sync()
    kept = {BOB[2], "Selbst umbenannt", BOB[4]}
    assert set(iphone.subjects()) == set(ADA) | kept and st["foreign_removed"] == 5 + 2 + 2
    assert iphone.count("study_packages") == 1 and iphone.count("flashcard_stacks") == 1
    # Bob behaelt seine Zeilen unveraendert (auch den alten Namen), sieht nichts von Adas Kopien
    other.sync()
    assert [n for n in other.subjects() if not n.startswith("Ada")] == BOB and other.count("study_packages") == 0
    # die behaltenen Faecher liegen jetzt als eigene Zeilen in Adas Raum: das iPad bekommt sie samt Lernpaket
    ipad.uni("ada", "neu")
    ipad.sync()
    iphone.sync()
    ipad.sync()
    other.sync()
    assert other.subjects() == BOB and other.count("study_packages") == 0, "Adas Faecher (dort leer) sind bei Bob weg, seine 8 bleiben"
    assert set(ipad.subjects()) == set(ADA) | kept and ipad.count("study_packages") == 1
    row = ipad.conn.execute("SELECT m.name FROM study_packages p JOIN modules m ON m.id=p.module_id").fetchone()
    assert row[0] == BOB[2], "das Lernpaket haengt am eigenen Fach"


def test_uni_key_is_the_same_on_every_platform(tmp_path):
    """Derselbe Schluessel wie `UniAccountKey.key` im Swift-Kern (UniAccountKeyTests): sonst laegen iPad und PC
    desselben Uni-Kontos in zwei Raeumen. Lokal liegt nur der Hash, nie die Kennung."""
    from app import db, sync_client
    h = sync_client.studip_user_hash("ada-123")
    assert h == "60fab9dfa5becd800791b629c996b414601dd13a510e4d7320424b338339900b"
    assert sync_client.uni_key("konto-1", "luh", h) == "08121804954ac42166e68cc347ca2ce43306ca68c56bfee60b2672717fe92586"
    assert sync_client.uni_key("konto-1", "luh", None) is None and sync_client.uni_key(None, "luh", h) is None
    c = sqlite3.connect(tmp_path / "pc.db")
    db._init_db(c)
    sync_client.remember_studip_user(c, "ada-123")
    assert c.execute("SELECT value FROM settings WHERE key='studip_user_hash'").fetchone()[0] == h
    assert "ada-123" not in " ".join(str(r[0]) for r in c.execute("SELECT value FROM settings")), "die Kennung selbst wird nie gespeichert"
    assert sync_client._setting_local("studip_user_hash"), "geht nie in den Abgleich"
    c.close()


def test_delete_before_the_other_devices_are_known_stays_in_the_own_uni_account(tmp_path, service):
    """Das iPhone loescht ein Fach von Adas iPad und eines von Bobs Geraet, bevor der Dienst weiss, wem die beiden
    Geraete gehoeren. Die Loeschung gilt fuer Adas Uni-Konto: auf dem iPad kommt sie an, sobald es sich meldet. Bobs
    Geraet bekommt die Loeschmarke nie; sein Fach bleibt und liegt danach als eigene Zeile in seinem Raum."""
    ipad, other, iphone = _mixed(tmp_path, service)
    iphone.uni("ada", "neu")
    iphone.sync()
    iphone.conn.execute("UPDATE courses SET module_id=NULL WHERE module_id=(SELECT id FROM modules WHERE name=?)", (ADA[6],))
    iphone.conn.execute("DELETE FROM modules WHERE name IN (?, ?)", (ADA[6], BOB[7]))
    iphone.conn.execute("UPDATE modules SET color='#abcdef' WHERE name=?", (ADA[0],))
    st = iphone.sync()
    assert st["pushed"] == 1 and len(iphone.subjects()) == 13, "ein Uni-Konto bekannt: Aendern und Loeschen wie bisher"
    # die beiden anderen Geraete, noch ohne Hash: die Aenderung kommt an, die Loeschmarke der eigenen Zeile nicht
    ipad.sync()
    other.sync()
    assert ADA[6] in ipad.subjects() and BOB[7] in other.subjects()
    assert ipad.conn.execute("SELECT color FROM modules WHERE name=?", (ADA[0],)).fetchone()[0] == "#abcdef"
    # Bobs Geraet meldet sich: sein Fach bleibt (es hat dort einen Kurs) und wird in seinem Raum neu angelegt
    other.uni("bob", "neu")
    st = other.sync()
    assert st["deleted"] == 0 and BOB[7] in other.subjects()
    iphone.sync()
    other.sync()
    assert [n for n in other.subjects() if n.startswith("Bob")] == BOB and iphone.subjects() == ADA[:6]
    # Adas iPad meldet sich im selben Raum: jetzt gilt die Loeschung des iPhones auch dort
    ipad.uni("ada", "neu")
    ipad.sync()
    assert ipad.subjects() == ADA[:6]
    for d in (other, iphone, ipad, other):
        d.sync()
    assert other.subjects() == BOB and iphone.subjects() == ADA[:6] and ipad.subjects() == ADA[:6]
    # ein neues Geraet in Bobs Raum bekommt alle acht Faecher, auch das vom iPhone "geloeschte"
    fresh = Device(tmp_path, "mac-bob", service)
    fresh.uni("bob", "neu")
    fresh.sync()
    assert fresh.subjects() == BOB
