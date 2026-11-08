"""Datenexport eines Kontos (gehosteter Dienst, DSGVO Art. 15 Auskunft und Art. 20 Datenuebertragbarkeit, 28.10.2026).

`build(user)` schreibt eine ZIP-Datei in einen Temp-Ordner und liefert den Pfad; `GET /api/account/export` schickt sie
und loescht sie danach. Inhalt:

- `LIESMICH.txt`: was wo liegt
- `konto.json`: Konto, Sitzungen und Geraete, verknuepfte Anmeldewege, Tarife und Kaeufe, Nutzungszaehler, KI-Nutzung,
  Abgleich-Auftraege, gespeicherte Hochschul-Zugangsdaten (Name und Benutzername; Passwoerter, Schluessel und Cookies
  nur als "gespeichert", damit eine verlorene ZIP keine Zugaenge verraet)
- `daten/`: der Nutzerordner je Hochschule: Datenbanken (`lernapp.db`, konsistent ueber die SQLite-Sicherung kopiert)
  mit Kursen, Notizen, Kalender, Lernpaketen, Karteikarten samt Stapeln, Tests, dazu eigene Dateien und Protokolle. Ohne
  Browser-Profile (Sitzungs-Cookies der Hochschule) und ohne Arbeitsordner der KI.
- `community/`: eigene Loesungen (Liste und Pakete), eigene Korrekturvorschlaege, eigene Karteikarten-Stapel, eigene Meldungen und Sperrliste,
  `meine-beitraege.json` (Kommentare, Fragen/Antworten, Likes, Lesezeichen, Mitteilungen, Mitgliedschaften, Claims)
- `testbibliothek.json`: eigene Fragen in der gemeinsamen Testbibliothek
"""
from __future__ import annotations

import json
import sqlite3
import tempfile
import zipfile
from pathlib import Path

from . import accounts, config

SKIP_DIRS = ("browser-profile", "ai-tmp")
SECRET_HINT = "gespeichert (aus Sicherheitsgründen nicht im Export)"


def _rows(conn, sql: str, params=()) -> list[dict]:
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    except sqlite3.OperationalError:            # Tabelle gibt es (noch) nicht
        return []


def _account(user: dict) -> dict:
    from . import vault
    uid = user["id"]
    with accounts.cursor() as conn:
        out = {
            "konto": user,
            "sitzungen": accounts.sessions(uid),
            "anmeldewege": _rows(conn, "SELECT provider, subject, created_at FROM identities WHERE user_id=?", (uid,)),
            "kaeufe": _rows(conn, "SELECT source, plan, original_transaction_id, expires_at, status, will_renew, pending_plan, "
                                  "environment, updated_at FROM entitlements WHERE user_id=?", (uid,)),
            "apple_transaktionen": _rows(conn, "SELECT original_transaction_id, product_id, updated_at FROM apple_transactions WHERE user_id=?", (uid,)),
            "nutzung": _rows(conn, "SELECT period, feature, count FROM usage WHERE user_id=? ORDER BY period, feature", (uid,)),
            "ki_nutzung": _rows(conn, "SELECT period, purpose, provider, model, input_tokens, output_tokens, cost_microeur, state, "
                                      "created_at FROM ai_usage_log WHERE user_id=? ORDER BY created_at", (uid,)),
            "ki_credits": _rows(conn, "SELECT period, allowance, used, reserved, plan FROM credit_months WHERE user_id=? ORDER BY period", (uid,)),
            "ki_credits_anfragen": _rows(conn, "SELECT period, day, purpose, funding, state, model, reserved, charged, cost_microeur, "
                                               "input_tokens, cached_tokens, output_tokens, images, created_at, settled_at "
                                               "FROM credit_ledger WHERE user_id=? ORDER BY created_at", (uid,)),
            "einladungen": _invites(conn, uid),
            "abgleich_auftraege": _rows(conn, "SELECT kind, trigger, status, requested_at, started_at, finished_at, message, new_files "
                                              "FROM sync_jobs WHERE user_id=? ORDER BY id", (uid,)),
            # Audit 08.11.2026, P57-11: Tarifauswahl nach der Probe, Stripe-Kennungen, eigene Seiten-Erklaerungen
            "tarif_auswahl": _rows(conn, "SELECT plan, chosen_at FROM plan_choices WHERE user_id=?", (uid,)),
            "stripe": {"kunde": _rows(conn, "SELECT customer_id, created_at FROM stripe_customers WHERE user_id=?", (uid,)),
                       "abos": _rows(conn, "SELECT subscription_id, event_created FROM stripe_subscription_state WHERE user_id=?", (uid,))},
            "seiten_erklaerungen": _rows(conn, "SELECT record_name, file_key, page, mode, variant, payload, version, created_at "
                                               "FROM page_explain WHERE owner_id=? ORDER BY created_at", (uid,)),
        }
    creds = {}
    for name, value in sorted(vault.env_for(uid).items()):
        creds[name] = value if name.endswith("_USER") else SECRET_HINT
    out["hochschul_zugangsdaten"] = creds
    return out


def _invites(conn, uid: str) -> dict:
    """Eigene Einladungslinks, angekommene Personen (nur Code und Zeitpunkt), eigene Einloesung, Belohnungen (app/invites.py)."""
    from . import invites
    return invites.export_rows(conn, uid)


def _add_db(z: zipfile.ZipFile, src: Path, arc: str) -> None:
    """SQLite-Datei konsistent kopieren (auch mit offenem WAL) und in die ZIP legen."""
    with tempfile.TemporaryDirectory() as tmp:
        dst = Path(tmp) / "kopie.db"
        a = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        b = sqlite3.connect(dst)
        try:
            a.backup(b)
        finally:
            b.close()
            a.close()
        z.write(dst, arc)


def _add_user_dir(z: zipfile.ZipFile, base: Path) -> int:
    n = 0
    if not base.exists():
        return 0
    for p in sorted(base.rglob("*")):
        rel = p.relative_to(base)
        if any(part.startswith(SKIP_DIRS) for part in rel.parts) or not p.is_file():
            continue
        # keine Symlinks (Datei oder Ordner auf dem Weg): nichts ausserhalb des Nutzerordners (Audit P24-10)
        if any((base / Path(*rel.parts[:i + 1])).is_symlink() for i in range(len(rel.parts))):
            continue
        if p.name.endswith(("-wal", "-shm", ".lock")):
            continue
        arc = "daten/" + rel.as_posix()
        if p.suffix == ".db":
            _add_db(z, p, arc)
        else:
            z.write(p, arc)
        n += 1
    return n


def _community(z: zipfile.ZipFile, user: dict) -> int:
    from . import community
    sols = community.mine(user)
    with community.cursor() as conn:
        reports = _rows(conn, "SELECT solution_id, reason, note, created_at FROM reports WHERE reporter_id=?", (user["id"],))
        blocks = _rows(conn, "SELECT pseudonym, created_at FROM blocks WHERE user_id=?", (user["id"],))
    z.writestr("community/meine-loesungen.json", json.dumps(sols, ensure_ascii=False, indent=1))
    z.writestr("community/meine-meldungen.json", json.dumps(reports, ensure_ascii=False, indent=1))
    z.writestr("community/meine-sperrliste.json", json.dumps(blocks, ensure_ascii=False, indent=1))
    from . import community_corrections
    z.writestr("community/meine-korrekturen.json", json.dumps(community_corrections.exported(user), ensure_ascii=False, indent=1))
    from . import community_cards
    z.writestr("community/meine-karteikarten.json", json.dumps(community_cards.exported(user), ensure_ascii=False, indent=1))
    z.writestr("community/meine-beitraege.json", json.dumps(_contributions(user["id"]), ensure_ascii=False, indent=1))
    for s in sols:
        p = community.package_dir() / f"{s['solution_id']}.uniflowsolution"
        if p.exists():
            z.write(p, f"community/pakete/{p.name}")
    return len(sols)


def _contributions(uid: str) -> dict:
    """Alles Weitere, was community.db zum Konto speichert (Audit 08.11.2026, P57-11: fehlte im Export). Nur eigene
    Zeilen und nie fremde Konto-IDs (bei Mitteilungen steht der Ausloeser nur als Pseudonym)."""
    from . import community
    q = (uid,)
    with community.cursor() as conn:
        return {
            "kommentare": _rows(conn, "SELECT id, solution_id, parent_id, page_key, anchor_x, anchor_y, text, pseudonym, created_at, "
                                      "edited_at, status FROM comments WHERE author_id=? ORDER BY created_at", q),
            "likes_loesungen": _rows(conn, "SELECT solution_id, created_at FROM likes WHERE user_id=? ORDER BY created_at", q),
            "kommentar_meldungen": _rows(conn, "SELECT comment_id, reason, created_at FROM comment_reports WHERE reporter_id=?", q),
            "fragen": _rows(conn, "SELECT id, course_key, university, title, body, fingerprint, page, pseudonym, created_at, edited_at, "
                                  "status, accepted_answer FROM questions WHERE author_id=? ORDER BY created_at", q),
            "antworten": _rows(conn, "SELECT id, question_id, body, pseudonym, created_at, edited_at, status FROM answers "
                                     "WHERE author_id=? ORDER BY created_at", q),
            "hilfreich_stimmen": _rows(conn, "SELECT answer_id, created_at FROM answer_votes WHERE user_id=?", q),
            "likes_fragen": _rows(conn, "SELECT question_id, created_at FROM question_likes WHERE user_id=?", q),
            "meldungen_fragen_antworten": _rows(conn, "SELECT kind, target_id, reason, created_at FROM qa_reports WHERE reporter_id=?", q),
            "lesezeichen": _rows(conn, "SELECT kind, target_id, created_at FROM bookmarks WHERE user_id=?", q),
            "mitteilungen": _rows(conn, "SELECT kind, target_kind, target_id, context_id, text, count, created_at, read_at "
                                        "FROM notifications WHERE user_id=? ORDER BY created_at", q),
            "mitgliedschaften": _rows(conn, "SELECT community_key, university, kind, joined_at FROM community_members WHERE user_id=?", q),
            "lerngruppen_angelegt": _rows(conn, "SELECT group_key, university, name, created_at FROM study_groups WHERE created_by=?", q),
            "pdf_fingerabdruecke": _rows(conn, "SELECT fingerprint, university, claimed_at FROM claims WHERE user_id=? ORDER BY claimed_at", q),
            "kurs_schluessel": _rows(conn, "SELECT course_key, university, claimed_at FROM course_claims WHERE user_id=? ORDER BY claimed_at", q),
            "karteikarten_likes": _rows(conn, "SELECT stack_id, created_at FROM card_stack_likes WHERE user_id=?", q),
            "karteikarten_meldungen": _rows(conn, "SELECT stack_id, reason, note, created_at FROM card_stack_reports WHERE reporter_id=?", q),
            "korrektur_meldungen": _rows(conn, "SELECT correction_id, reason, created_at FROM correction_reports WHERE reporter_id=?", q),
        }


def _library(user: dict) -> list[dict]:
    from . import test_library
    owner = test_library.owner_hash(user["id"])
    with test_library.cursor() as conn:
        return _rows(conn, "SELECT id, subject, topic, subtopic, qtype, question, options, answer, explanation, source, review, "
                           "created_at FROM questions WHERE owner_hash=? ORDER BY created_at", (owner,))


README = """StudiNow / UniFlow – Export deiner Daten

Erstellt: {at}
Konto: {email}

konto.json            Konto, angemeldete Geräte, Anmeldewege (Apple/Google), Tarife und Käufe, Nutzungszähler,
                      KI-Nutzung, Abgleich-Aufträge, gespeicherte Hochschul-Zugangsdaten (Passwörter, Schlüssel und
                      Cookies nur als „gespeichert“).
daten/                Deine Daten je Hochschule. lernapp.db ist eine SQLite-Datenbank (öffnen z. B. mit „DB Browser
                      for SQLite“): Kurse, Module, Notizen (Tabelle annotations), Stundenplan, Lernpakete, Aufgaben,
                      Karteikarten mit ihren Stapeln (flashcards, flashcard_stacks), Tests und Noten. Dazu eigene Dateien und Protokolle. Dateien deiner Hochschule
                      speichert der Dienst nicht; sie bleiben in Stud.IP bzw. im Learnweb.
community/            Deine veröffentlichten Lösungen (Liste und Pakete), deine geteilten Karteikarten, deine Korrekturvorschläge, deine Meldungen und deine Sperrliste;
                      in meine-beitraege.json Kommentare, Fragen, Antworten, Likes und Stimmen, Lesezeichen, Mitteilungen,
                      Mitgliedschaften, angelegte Lerngruppen und die gemeldeten Fingerabdrücke und Kurs-Schlüssel.
testbibliothek.json   Deine Fragen in der gemeinsamen Testbibliothek.

Fragen zum Export oder zur Löschung: siehe /datenschutz.
"""


def build(user: dict) -> Path:
    """ZIP mit allen Daten des Kontos; der Aufrufer loescht die Datei nach dem Senden."""
    fd, name = tempfile.mkstemp(prefix="studora-export-", suffix=".zip")
    path = Path(name)
    import os
    os.close(fd)
    at = accounts.iso(accounts.now())
    try:
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as z:
            z.writestr("LIESMICH.txt", README.format(at=at, email=user["email"]))
            z.writestr("konto.json", json.dumps(_account(user), ensure_ascii=False, indent=1))
            _add_user_dir(z, config.BASE_DATA_DIR / "users" / user["id"])
            _community(z, user)
            z.writestr("testbibliothek.json", json.dumps(_library(user), ensure_ascii=False, indent=1))
    except BaseException:
        path.unlink(missing_ok=True)          # keine halbe ZIP im Temp-Ordner des Servers (Audit P24-03)
        raise
    return path
