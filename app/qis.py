"""QIS/LSF-Anbindung (HIS QIS der Leibniz Universitaet Hannover): Notenspiegel und Bescheinigungen.

Ablauf (Playwright, eigenes Browserprofil):
 1. Loginseite oeffnen, Zugangsdaten aus der .env (QIS_USER/QIS_PASSWORD, sonst LUH-ID wie bei Stud.IP).
 2. Menue "Pruefungsverwaltung" -> "Notenspiegel" -> Abschluss/Studiengang aufklappen -> Tabelle(n) lesen.
 3. Optional: Seite "Bescheinigungen"/"Studienbescheinigungen" nach PDF-Links durchsuchen und herunterladen.
Bei Fehlern wird ein Screenshot unter logs/qis-fehler.png abgelegt.
"""
from __future__ import annotations

import re
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

from . import config, db
from .config import DATA_DIR, LOG_DIR

QIS_BASE = "https://qis.verwaltung.uni-hannover.de"
QIS_START = f"{QIS_BASE}/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf"
PROFILE_DIR = DATA_DIR / "browser-profile-qis"

# Gleiche HIS-QIS-Software an mehreren Hochschulen: Basis-URL, Login und Bescheinigungen je Uni.
PROFILES = {
    "luh": {"base": QIS_BASE, "start": QIS_START, "documents": True, "cred_prefix": "QIS", "profile_dir": PROFILE_DIR},
    "hildesheim": {"base": "https://lsf.uni-hildesheim.de", "start": "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0",
                   "documents": False, "cred_prefix": "HILDESHEIM", "profile_dir": DATA_DIR / "browser-profile-hildesheim"},
}
_P = dict(PROFILES["luh"], key="luh")      # aktives Profil waehrend eines Laufs


def use_profile(key: str) -> dict:
    _P.clear(); _P.update(PROFILES.get(key, PROFILES["luh"]), key=key if key in PROFILES else "luh")
    return _P


def credentials_for(key: str) -> tuple[str, str]:
    """LUH: QIS-Zugang (mit Rueckfall auf die LUH-ID). Andere Unis: nur der eigene Uni-Account."""
    if key == "luh":
        return config.service_credentials("QIS")
    return config.own_credentials(PROFILES[key]["cred_prefix"])


def configured(key: str | None = None) -> bool:
    from . import universities
    key = key or universities.current_key()
    if key == "luh":
        return config.service_status("QIS")["own"]
    u, p = credentials_for(key)
    return bool(u and p)
DOC_DIR = DATA_DIR / "qis"


def _doc_dir():
    return config.data_dir() / "qis" if config.current_user_id() else DOC_DIR


def _profile_dir(prof: dict):
    return config.data_dir() / prof["profile_dir"].name if config.current_user_id() else prof["profile_dir"]
GRADE_HEADERS = {"bezeichnung": "text", "leistung": "text", "prüfungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungstext": "text", "text": "text", "semester": "semester", "note": "note",
                 "status": "status", "credits": "credits", "ects": "credits", "bonus": "credits", "versuch": "versuch", "vermerk": "status", "datum": "datum", "prüfungsdatum": "datum"}


def log(msg: str) -> None:
    line = f"[{db.now_iso()}] {msg}"
    from .studip_sync import console_print
    console_print(line)
    with open(config.log_dir() / "qis.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def _click_text(page: Page, texts: list[str], timeout: int = 8000) -> bool:
    for t in texts:
        loc = page.locator(f"a:has-text('{t}')").first
        try:
            if loc.count() and loc.is_visible():
                loc.click(timeout=timeout)
                page.wait_for_load_state("domcontentloaded")
                page.wait_for_timeout(600)
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def login(page: Page, user: str, password: str) -> None:
    if _P.get("key") == "hildesheim":
        from . import lsf
        lsf.login(page, user, password, log)
        log("QIS: Login erfolgreich (CAS)")
        return
    page.goto(_P["start"], wait_until="domcontentloaded")
    page.wait_for_timeout(800)
    if page.locator("a:has-text('Abmelden'), a:has-text('Logout')").count():
        log("QIS: bereits angemeldet")
        return
    # HIS-QIS Standardfelder heissen 'asdf' (Benutzer) und 'fdsa' (Passwort); Fallbacks fuer andere Layouts
    u = page.locator("input[name='asdf'], input#asdf, input[name*='user' i], input[type='text']:visible").first
    p = page.locator("input[name='fdsa'], input#fdsa, input[type='password']:visible").first
    u.wait_for(state="visible", timeout=20000)
    u.fill(user)
    p.fill(password)
    btn = page.locator("input[type='submit'], button[type='submit'], input[value*='Anmeld' i]").first
    btn.click()
    page.wait_for_load_state("domcontentloaded")
    page.wait_for_timeout(1200)
    if not page.locator("a:has-text('Abmelden'), a:has-text('Logout')").count():
        raise RuntimeError("QIS-Login fehlgeschlagen (kein 'Abmelden'-Link nach dem Login). Bitte Zugangsdaten pruefen.")
    log("QIS: Login erfolgreich")


def _header_map(cells: list[str]) -> list[str | None]:
    """Spaltenkoepfe -> Feldnamen. 'Prüfungsnr.' und 'Bezeichnung der Leistung / ...' werden ueber das erste Wort erkannt."""
    out = []
    for h in cells:
        words = re.sub(r"[^\wäöüß]+", " ", (h or "").strip().lower()).split()
        out.append(GRADE_HEADERS.get(words[0]) if words else None)
    return out


def parse_grade_rows(rows: list[list[str]], abschluss: str = "") -> list[dict]:
    """Zeilen einer Notenspiegel-Tabelle (Zellentexte) -> Leistungen. Ohne Browser, daher testbar.
    - Die Kopfzeile darf irgendwo stehen (Hildesheim: davor eine Zeile 'Abschluss: ...'); mehrere Abschnitte je Tabelle.
    - Modul-Ueberschriften und Summen ohne Note und ohne Status werden uebersprungen."""
    out: list[dict] = []
    mapped: list[str | None] | None = None
    ab = abschluss
    for raw_cells in rows:
        cells = [re.sub(r"\s+", " ", c or "").strip() for c in raw_cells]
        joined = " ".join(c for c in cells if c)
        if joined.lower().startswith("abschluss:"):
            m = re.match(r"(Abschluss:.*?PO-Version:\s*\d+)", joined, re.I)
            ab = (m.group(1) if m else joined)[:160]
            mapped = None
            continue
        hm = _header_map(cells)
        if "text" in hm and "note" in hm:
            mapped = hm
            continue
        if not mapped or len(cells) < 3:
            continue
        rec = {"abschluss": ab, "raw": " | ".join(cells)}
        for k, v in zip(mapped, cells):
            if k and k not in rec:
                rec[k] = v
        if (rec.get("status") or "").lower() == "prüfung vorhanden" and not rec.get("note"):
            continue          # Modul-/Kontozeile ("Prüfung vorhanden"), keine eigene Leistung
        if rec.get("text") and (rec.get("note") or rec.get("status")):
            out.append(rec)
    return out


def _parse_tables(page: Page, abschluss: str) -> list[dict]:
    rows_out = []
    tables = page.locator("table")
    for ti in range(tables.count()):
        trs = tables.nth(ti).locator("tr")
        rows = [trs.nth(ri).locator("th, td").all_inner_texts() for ri in range(trs.count())]
        rows_out += parse_grade_rows(rows, abschluss)
    return rows_out


def fetch_grades(page: Page) -> list[dict]:
    # LUH-QIS: Startseite "Meine Funktionen" mit Menue "Mein Studium" (Noten) und "Meine Bescheinigungen"
    page.goto(_P["start"], wait_until="domcontentloaded"); page.wait_for_timeout(400)
    _click_text(page, ["Meine Funktionen"], timeout=4000)
    found = False
    for menu in ("Mein Studium", "Prüfungsverwaltung", "Pruefungsverwaltung", "Studiumsverwaltung"):
        if _click_text(page, [menu], timeout=4000):
            if _click_text(page, ["Notenspiegel", "Leistungsübersicht", "Leistungsspiegel", "Notenübersicht", "Leistungen", "Noten"], timeout=4000):
                found = True
                break
    if not found and _click_text(page, ["Notenspiegel", "Leistungsübersicht", "Leistungsspiegel"], timeout=4000):
        found = True
    if not found:
        menu_txt = ", ".join(t for t, _ in _links(page)[:40] if t)
        raise RuntimeError(f"'Notenspiegel' nicht gefunden. Sichtbare Menuepunkte: {menu_txt[:300]}")
    try:
        page.screenshot(path=str(config.log_dir() / "qis-notenspiegel.png"), full_page=True)
    except Exception:  # noqa: BLE001
        pass
    log(f"QIS: Notenspiegel-Seite '{_page_title(page)}' mit {page.locator('table').count()} Tabellen")
    grades: list[dict] = []
    # Abschluesse/Studiengaenge aufklappen (z. B. "Abschluss 82 Bachelor of Science" -> Studiengang -> Leistungen), bis Tiefe 3
    EXP = "a[title*='Leistungen' i], a:has(img[src*='info' i]), a:has-text('Abschluss'), a:has-text('Bachelor'), a:has-text('Master'), a:has-text('Alle Leistungen'), a:has-text('Leistungen anzeigen'), a:has-text('Studiengang')"
    seen_urls: set[str] = set()

    def expand(depth: int, title: str) -> None:
        nonlocal grades
        if _P.get("documents", True):          # Hildesheim: keine Bescheinigungen/Transcripts speichern
            _click_pdf_links(page, title or "Notenspiegel")
        found = _parse_tables(page, title)
        if found:
            grades += found
        if depth >= 3:
            return
        hrefs = []
        exp = page.locator(EXP)
        for i in range(min(exp.count(), 10)):
            try:
                t = re.sub(r"\s+", " ", exp.nth(i).inner_text()).strip()[:60] or title
                h = exp.nth(i).get_attribute("href")
                if h and "logout" not in h.lower() and h not in seen_urls and "notenspiegel" not in t.lower():
                    hrefs.append((t, h))
            except Exception:  # noqa: BLE001
                pass
        for t, h in hrefs:
            if h in seen_urls:
                continue
            seen_urls.add(h)
            try:
                page.goto(_abs(h), wait_until="domcontentloaded"); page.wait_for_timeout(600)
            except Exception as e:  # noqa: BLE001
                log(f"Notenspiegel-Unterseite uebersprungen ({t}): {e}"); continue
            try:
                page.screenshot(path=str(config.log_dir() / f"qis-notenspiegel-{depth + 1}.png"), full_page=True)
            except Exception:  # noqa: BLE001
                pass
            log(f"QIS: Notenspiegel > {t}: {page.locator('table').count()} Tabellen")
            expand(depth + 1, t)

    expand(0, "")
    # Doppelte (gleiche Zeile) entfernen
    seen, out = set(), []
    for g in grades:
        key = (g.get("pruefungsnr"), g.get("text"), g.get("semester"), g.get("versuch"))
        if key not in seen:
            seen.add(key)
            out.append(g)
    return out


DOC_KEYWORDS = ("bescheinigung", "transcript", "leistungsübersicht", "leistungsuebersicht", "notenspiegel", "datenkontrollblatt",
                "studienverlauf", "immatrikulation", "zeugnis", "record", "leistungsnachweis", "studienbuch", "notenübersicht", "certificate", "enrolment", "enrollment")
GENERIC = ("pdf", "drucken", "download", "herunterladen", "anzeigen", "öffnen", "oeffnen")


DOCS: list[dict] = []      # in diesem Lauf gespeicherte PDFs
HASHES: set[str] = set()   # Duplikate (gleicher Inhalt) vermeiden


def _clean_title(t: str) -> str:
    t = re.sub(r"\s+", " ", t or "").strip()
    t = re.sub(r"^PDF-?\s*", "", t, flags=re.I)
    t = re.sub(r"\s*zum Drucken\s*$", "", t, flags=re.I)
    t = re.sub(r"\s*(anzeigen|drucken)\s*$", "", t, flags=re.I)
    m = re.match(r"^(.+?) – $", t)
    if m:
        t = m.group(1)
    return t[:90] or "Dokument"


def _store_pdf(body: bytes, title: str) -> bool:
    import hashlib
    if not body or not body.startswith(b"%PDF"):
        return False
    h = hashlib.sha1(body).hexdigest()
    if h in HASHES:
        return True
    HASHES.add(h)
    title = _clean_title(title)
    if any(_title_key(d["title"]) == _title_key(title) for d in DOCS):
        return True
    _doc_dir().mkdir(parents=True, exist_ok=True)
    fname = re.sub(r"[^\w\-]+", "_", title)[:60].strip("_") or "Dokument"
    path = _doc_dir() / f"{fname}.pdf"
    path.write_bytes(body)  # gleicher Titel -> Datei wird bei jedem Abruf aktualisiert
    DOCS.append({"title": title, "local_path": str(path)})
    log(f"QIS-Dokument gespeichert: {title}")
    return True


def _save_pdf(page: Page, url: str, title: str) -> bool:
    """PDF per direktem Request laden (fuer Links, die sofort eine PDF liefern)."""
    try:
        resp = page.request.get(url, timeout=30000)
    except Exception as e:  # noqa: BLE001
        log(f"Bescheinigung uebersprungen ({title}): {e}"); return False
    body = resp.body() if resp.ok else b""
    return _store_pdf(body, title)


def _title_key(t: str) -> str:
    t = _clean_title(t).lower()
    parts = [x.strip() for x in t.split(" – ")]
    return parts[0] if len(parts) > 1 and parts[0] in parts[1:] else t


def _click_pdf_links(page: Page, context: str) -> None:
    """PDF-Links auf der aktuellen Seite holen: Klick mit Download, Popup-Fenster oder Weiterleitung im HTML."""
    try:
        loc = page.locator("a:has-text('PDF'), a[href*='pdf' i], a:has(img[src*='pdf' i]), a:has(img[alt*='pdf' i])")
        n = min(loc.count(), 6)
    except Exception:  # noqa: BLE001
        return
    for i in range(n):
        a = loc.nth(i)
        try:
            text = (a.inner_text() or "").strip() or (a.get_attribute("title") or "").strip()
            if not text:
                text = a.evaluate("el => (el.closest('td,li,p,div,span')?.innerText || '').trim()") or ""
            title = _clean_title(text) if text and _clean_title(text).lower() not in ("pdf", "dokument") else _clean_title(context)
            if any(_title_key(d["title"]) == _title_key(title) for d in DOCS):
                continue
            href = a.get_attribute("href") or ""
            url_before = page.url; pages_before = set(page.context.pages)
            captured: list = []
            seen_resp: list = []
            def on_resp(r, _c=captured, _s=seen_resp):
                try:
                    ct = (r.headers.get("content-type") or "").lower()
                    _s.append(f"{r.status} {ct[:30]} {r.url[-70:]}")
                    if "pdf" in ct or "octet-stream" in ct or "download" in (r.headers.get("content-disposition") or "").lower() or "hisreports" in r.url:
                        _c.append(r)
                except Exception:  # noqa: BLE001
                    pass
            page.on("response", on_resp)
            body = b""
            try:
                with page.expect_download(timeout=7000) as dl:
                    a.click()
                body = Path(dl.value.path()).read_bytes()
            except Exception:  # noqa: BLE001
                pass
            finally:
                try:
                    page.remove_listener("response", on_resp)
                except Exception:  # noqa: BLE001
                    pass
            if not body and captured:  # PDF kam als normale Antwort (inline angezeigt)
                for r in reversed(captured):
                    try:
                        body = r.body()
                        if body:
                            break
                    except Exception:  # noqa: BLE001
                        continue
            if not body:
                log(f"QIS: Antworten nach Klick auf '{title}': " + " | ".join(seen_resp[-6:]))
            if _store_pdf(body, title):
                if page.url != url_before:
                    try:
                        page.go_back(wait_until="domcontentloaded"); page.wait_for_timeout(400)
                    except Exception:  # noqa: BLE001
                        pass
                continue
            # Popup-Fenster mit der PDF?
            page.wait_for_timeout(1500)
            for np_ in [x for x in page.context.pages if x not in pages_before]:
                try:
                    np_.wait_for_load_state("domcontentloaded", timeout=8000)
                    resp = np_.request.get(np_.url, timeout=30000)
                    if not _store_pdf(resp.body() if resp.ok else b"", title):
                        html = np_.content()
                        m = re.search(r"""(?:url=|src=|href=)["']?([^"'> ]+\.pdf[^"'> ]*)""", html, flags=re.I)
                        if m:
                            r2 = np_.request.get(_abs(m.group(1)), timeout=30000); _store_pdf(r2.body() if r2.ok else b"", title)
                        else:
                            (config.log_dir() / "qis-pdf-link.html").write_text(html, encoding="utf-8")
                finally:
                    try:
                        np_.close()
                    except Exception:  # noqa: BLE001
                        pass
            if any(_title_key(d["title"]) == _title_key(title) for d in DOCS):
                continue
            # Gleiche Seite navigiert oder HTML mit Weiterleitung zur PDF
            if page.url != url_before:
                try:
                    page.wait_for_load_state("domcontentloaded", timeout=8000)
                    resp = page.request.get(page.url, timeout=30000)
                    if not _store_pdf(resp.body() if resp.ok else b"", title):
                        html = page.content()
                        (config.log_dir() / "qis-pdf-link.html").write_text(html, encoding="utf-8")
                        log(f"QIS: PDF-Link '{title}' fuehrt zu HTML-Seite {page.url[:120]}")
                        for m in re.finditer(r"""(?:src|href|data|content)=["']?([^"'> ]*(?:\.pdf|pdf|download)[^"'> ]*)""", html, flags=re.I):
                            u = m.group(1).replace("&amp;", "&")
                            if u.startswith("url="):
                                u = u[4:]
                            try:
                                r2 = page.request.get(_abs(u), timeout=30000)
                                if _store_pdf(r2.body() if r2.ok else b"", title):
                                    break
                            except Exception:  # noqa: BLE001
                                continue
                except Exception as e:  # noqa: BLE001
                    log(f"QIS: PDF-Link '{title}': {str(e).splitlines()[0][:80]}")
                page.go_back(wait_until="domcontentloaded"); page.wait_for_timeout(400)
            elif href and not href.startswith(("javascript", "#")):
                resp = page.request.get(_abs(href), timeout=30000)
                body = resp.body() if resp.ok else b""
                if not _store_pdf(body, title):
                    html = body.decode("utf-8", "ignore")
                    m = re.search(r"""(?:url=|src=|href=|action=)["']?([^"'> ]+(?:\.pdf|pdf)[^"'> ]*)""", html, flags=re.I)
                    if m and _abs(m.group(1)) != _abs(href):
                        r2 = page.request.get(_abs(m.group(1)), timeout=30000); _store_pdf(r2.body() if r2.ok else b"", title)
                    if not any(_title_key(d["title"]) == _title_key(title) for d in DOCS):
                        (config.log_dir() / "qis-pdf-link.html").write_text(html, encoding="utf-8")
                        log(f"QIS: PDF-Link '{title}' liefert keine PDF (HTML unter logs/qis-pdf-link.html)")
        except Exception as e:  # noqa: BLE001
            log(f"QIS: PDF-Link '{context}' uebersprungen ({str(e).splitlines()[0][:80]})")


def _abs(href: str) -> str:
    base = _P["base"]
    return href if href.startswith("http") else (base + href if href.startswith("/") else base + "/qisserver/" + href)


def _links(page: Page) -> list[tuple[str, str]]:
    out = []
    try:
        anchors = page.locator("a[href]")
        n = min(anchors.count(), 250)
        for i in range(n):
            a = anchors.nth(i)
            try:
                href = a.get_attribute("href") or ""
                text = re.sub(r"\s+", " ", a.inner_text()).strip()
                if not text:
                    text = (a.get_attribute("title") or a.locator("img").first.get_attribute("alt") or "").strip() if a.locator("img").count() else (a.get_attribute("title") or "").strip()
            except Exception:  # noqa: BLE001
                continue
            if not href or href.startswith(("javascript", "#", "mailto")) or "logout" in href.lower() or "logout" in text.lower() or "abmeld" in text.lower():
                continue
            if href.startswith("http") and not href.startswith(_P["base"]):
                continue
            out.append((text, href))
    except Exception:  # noqa: BLE001
        pass
    return out


def _page_title(page: Page) -> str:
    for sel in ("h1", "h2", ".divcontent h1", "title"):
        try:
            t = page.locator(sel).first.inner_text(timeout=800).strip()
            if t:
                return re.sub(r"\s+", " ", t)[:80]
        except Exception:  # noqa: BLE001
            continue
    return "Dokument"


def fetch_documents(page: Page) -> list[dict]:
    """Bescheinigungen, Transcript of Records, Leistungsuebersichten usw. als PDF einsammeln.

    Durchsucht die QIS-Menues (Meine Funktionen, Pruefungsverwaltung, Studiumsverwaltung ...) nach Links, deren Text
    auf ein Dokument hindeutet, folgt ihnen bis Tiefe 2 und laedt alle PDF-Links dort herunter (dedupliziert).
    """
    _doc_dir().mkdir(parents=True, exist_ok=True)
    visited: set[str] = set(); queue: list[tuple[str, str, int]] = []

    def enqueue(links, depth):
        for text, href in links:
            low = (text or "").lower()
            if any(k in low for k in DOC_KEYWORDS) and href not in visited and all(href != q[1] for q in queue):
                queue.append((text, href, depth))

    def save_pdf(url: str, title: str) -> bool:
        return _save_pdf(page, url, title)

    for menu in ("Meine Funktionen", "Mein Studium", "Meine Bescheinigungen", "Prüfungsverwaltung", "Studiumsverwaltung", "Studienservice"):
        try:
            page.goto(_P["start"], wait_until="domcontentloaded"); page.wait_for_timeout(300)
            if _click_text(page, [menu], timeout=4000):
                enqueue(_links(page), 1)
        except Exception:  # noqa: BLE001
            continue
    while queue and len(visited) < 18 and len(DOCS) < 25:
        text, href, depth = queue.pop(0)
        if href in visited:
            continue
        visited.add(href)
        url = _abs(href)
        try:
            # Viele QIS-Links (verpublish/bafoeg...) liefern direkt eine PDF: erst per Request pruefen, sonst Seite oeffnen
            if save_pdf(url, text or "Dokument"):
                continue
            page.goto(url, wait_until="domcontentloaded"); page.wait_for_timeout(500)
        except Exception as e:  # noqa: BLE001
            if "Download" in str(e):
                save_pdf(url, text or "Dokument")
            else:
                log(f"QIS-Seite uebersprungen ({text}): {e}")
            continue
        heading = _page_title(page)
        _click_pdf_links(page, text or heading)
        for ltext, lhref in _links(page):
            low = (ltext or "").lower(); hl = lhref.lower()
            is_pdf = hl.endswith(".pdf") or "pdf" in hl or any(g in low for g in GENERIC[:1]) or "pdf" in low
            if not is_pdf or lhref in visited:
                continue
            visited.add(lhref)
            title = ltext if ltext and not any(low.startswith(g) or low == g for g in GENERIC) else f"{heading} – {text}" if text and text.lower() != heading.lower() else heading
            save_pdf(_abs(lhref), title)
        if depth < 2:
            enqueue(_links(page), depth + 1)
    return list(DOCS)


def store_grades(conn, grades: list[dict]) -> None:
    """Leistungen speichern: dieselbe Leistung (Pruefungsnr., Text, Semester, Versuch) aktualisieren, sonst anlegen.
    Der Vergleich ist NULL-sicher (IS): der Notenspiegel der Uni Hildesheim hat weder Semester noch Versuch, und fuer
    SQLite sind zwei NULL in einer UNIQUE-Spalte verschieden (ON CONFLICT griffe nie, jeder Abruf legte alle Leistungen
    noch einmal an). Gleiche Regel im Swift-Kern: UniStore.storeGrades."""
    now = db.now_iso()
    for g in grades:
        vals = (g.get("note"), g.get("status"), g.get("credits"), g.get("datum"), g.get("abschluss"), g.get("raw"), now)
        key = (g.get("pruefungsnr"), g.get("text"), g.get("semester"), g.get("versuch"))
        cur = conn.execute("UPDATE grades SET note=?, status=?, credits=?, datum=?, abschluss=?, raw=?, fetched_at=? "
                           "WHERE pruefungsnr IS ? AND text=? AND semester IS ? AND versuch IS ?", vals + key)
        if cur.rowcount == 0:
            conn.execute("INSERT INTO grades(note, status, credits, datum, abschluss, raw, fetched_at, pruefungsnr, text, semester, versuch) "
                         "VALUES (?,?,?,?,?,?,?,?,?,?,?)", vals + key)


def run(show_browser: bool = False, with_documents: bool = True, university: str | None = None) -> dict:
    from . import universities
    db.init_db()
    key = university or universities.current_key()
    prof = use_profile(key)
    with_documents = with_documents and prof["documents"]
    started = db.now_iso()
    ok, msg, grades, docs = False, "", [], []
    DOCS.clear(); HASHES.clear()
    user, pw = credentials_for(prof["key"])
    if not user or not pw:
        msg = "Keine Zugangsdaten fuer QIS (Einstellungen > Zugang)." if prof["key"] == "luh" else             "Keine Zugangsdaten fuer das LSF (Einstellungen > Zugang: UNI-Account)."
    else:
        try:
            with sync_playwright() as p:
                ctx = p.chromium.launch_persistent_context(str(_profile_dir(prof)), headless=not show_browser, locale="de-DE")
                page = ctx.new_page()
                try:
                    login(page, user, pw)
                    grades = fetch_grades(page)
                    if with_documents:
                        docs = fetch_documents(page)
                    ok = True
                    msg = f"{len(grades)} Leistungen, {len(docs)} Bescheinigungen" + ("" if grades else " – im Notenspiegel stehen noch keine Leistungen")
                except Exception as e:  # noqa: BLE001
                    try:
                        page.screenshot(path=str(config.log_dir() / "qis-fehler.png"), full_page=True)
                    except Exception:  # noqa: BLE001
                        pass
                    msg = f"FEHLER: {e}"
                finally:
                    ctx.close()
        except Exception as e:  # noqa: BLE001
            msg = f"FEHLER: {e}"
    with db.cursor() as conn:
        store_grades(conn, grades)
        if docs:
            conn.execute("DELETE FROM qis_documents")
            keep = {d["local_path"] for d in docs}
            for f in _doc_dir().glob("*.pdf"):
                if str(f) not in keep:
                    f.unlink(missing_ok=True)
        for d in docs:
            conn.execute("INSERT INTO qis_documents(title, local_path, fetched_at) VALUES (?,?,?)", (d["title"], d["local_path"], db.now_iso()))
        conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,?,?,?,?)",
                     (started, db.now_iso(), int(ok), msg, len(grades), len(docs)))
    log(f"QIS: {msg}")
    return {"ok": ok, "message": msg, "grades": len(grades), "documents": len(docs)}


def summary(conn) -> dict:
    rows = db.rows(conn, "SELECT * FROM grades ORDER BY semester DESC, text")
    graded = []
    for r in rows:
        try:
            n = float(str(r["note"]).replace(",", "."))
            c = float(str(r["credits"] or "0").replace(",", "."))
            if 1.0 <= n <= 5.0 and (r["status"] or "").lower().startswith(("be", "bestanden", "")):
                graded.append((n, c))
        except (TypeError, ValueError):
            pass
    cp = sum(c for _, c in graded)
    avg = round(sum(n * c for n, c in graded) / cp, 2) if cp else (round(sum(n for n, _ in graded) / len(graded), 2) if graded else None)
    last = db.row(conn, "SELECT * FROM qis_runs ORDER BY id DESC LIMIT 1")
    docs = db.rows(conn, "SELECT * FROM qis_documents ORDER BY id DESC")
    return {"grades": rows, "average": avg, "credits": cp, "passed": len([r for r in rows if (r["status"] or "").lower().startswith("be")]), "last_run": last, "documents": docs}


if __name__ == "__main__":
    import sys
    print(run(show_browser="--show" in sys.argv))
