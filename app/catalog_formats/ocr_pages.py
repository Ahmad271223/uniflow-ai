"""OCR fuer Modulhandbuecher ohne Textebene (Format `scanned`, docs/STUDIENGAENGE-LUH-2026-11-04.md).

Nur auf dem Mac des Inhabers, einmal, offline: Seiten mit PDFKit rendern, Apple Vision (VNRecognizeTextRequest,
de-DE, .accurate) erkennt Text. Tesseract wird bevorzugt, wenn installiert (mit deutschen Daten), sonst Vision ueber
ein kleines Swift-Skript (`xcrun swift`, DEVELOPER_DIR auf Xcode). Nichts wird installiert, kein Netz.

Zwischenspeicher je PDF und Seite: ~/Studora-Builds/luh-ocr/<pdf-stem>/p0001.json mit den erkannten Zeilen
{"w": Breite, "h": Hoehe, "obs": [{"t": Text, "c": Sicherheit, "x","y","bw","bh": Rahmen 0..1, Ursprung oben links}]}.
Eine Seite wird nie zweimal erkannt.

Aus den Beobachtungen werden Textzeilen gebaut (`page_lines`): gleiche Hoehe -> eine Zeile, links nach rechts.
Fuer zweispaltige Tabellen (Phil-Vorlage) liefert `page_rows` die Zeile mit Spaltengrenze ("Schluessel | Wert").
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

OCR_DIR = Path.home() / "Studora-Builds" / "luh-ocr"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
RENDER_SCALE = 3.0  # 216 dpi, reicht Vision fuer 9-Punkt-Schrift
# Vor der Erkennung werden lange waagerechte und senkrechte Linien (Tabellenrahmen) weiss gemalt: steht ein Wort
# direkt an einer Rahmenlinie, laesst Vision sonst den ersten Buchstaben weg ("tudiengang" statt "Studiengang").

SWIFT_SOURCE = r'''
import Foundation
import PDFKit
import Vision
import AppKit

// Aufruf: ocr.swift <pdf> <ausgabeordner> <scale> [erste letzte]
let args = CommandLine.arguments
guard args.count >= 4, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: pdf outdir scale [first last]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[2])
let scale = CGFloat(Double(args[3]) ?? 3.0)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let first = args.count >= 6 ? max(1, Int(args[4]) ?? 1) : 1
let last = args.count >= 6 ? min(doc.pageCount, Int(args[5]) ?? doc.pageCount) : doc.pageCount
if first <= last {
for n in first...last {
    let name = String(format: "p%04d.json", n)
    let target = outDir.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: target.path) { continue }
    autoreleasepool {
        guard let page = doc.page(at: n - 1) else { return }
        let box = page.bounds(for: .mediaBox)
        let rot = page.rotation % 180 != 0
        let w = (rot ? box.height : box.width) * scale
        let h = (rot ? box.width : box.height) * scale
        let img = page.thumbnail(of: CGSize(width: w, height: h), for: .mediaBox)
        var rect = CGRect(origin: .zero, size: img.size)
        guard let src = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        // Tabellenlinien entfernen: Vision verliert sonst den ersten Buchstaben direkt neben einer senkrechten Linie
        let W = src.width, H = src.height
        var px = [UInt8](repeating: 255, count: W * H)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: W, height: H))
        let dark: UInt8 = 160
        let vMin = Int(40 * scale), hMin = Int(120 * scale)
        for x in 0..<W {
            var y = 0
            while y < H {
                if px[y * W + x] < dark {
                    var e = y
                    while e < H && px[e * W + x] < dark { e += 1 }
                    if e - y >= vMin { for k in y..<e { px[k * W + x] = 255 } }
                    y = e
                } else { y += 1 }
            }
        }
        for y in 0..<H {
            var x = 0
            while x < W {
                if px[y * W + x] < dark {
                    var e = x
                    while e < W && px[y * W + e] < dark { e += 1 }
                    if e - x >= hMin { for k in x..<e { px[y * W + k] = 255 } }
                    x = e
                } else { x += 1 }
            }
        }
        guard let cg = ctx.makeImage() else { return }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        var obs: [[String: Any]] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first else { continue }
            let b = o.boundingBox
            obs.append(["t": c.string, "c": Double(c.confidence), "x": Double(b.minX), "y": Double(1 - b.maxY),
                        "bw": Double(b.width), "bh": Double(b.height)])
        }
        let payload: [String: Any] = ["w": Double(cg.width), "h": Double(cg.height), "obs": obs]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            let tmp = outDir.appendingPathComponent(name + ".tmp")
            try? data.write(to: tmp)
            try? FileManager.default.moveItem(at: tmp, to: target)
        }
    }
    print("page \(n)/\(doc.pageCount)")
    fflush(stdout)
}
}
'''


def engine() -> str | None:
    """'tesseract' (mit deu), 'vision' (Xcode vorhanden) oder None"""
    if shutil.which("tesseract"):
        try:
            langs = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True, timeout=30).stdout
            if "deu" in langs.split():
                return "tesseract"
        except (OSError, subprocess.SubprocessError):
            pass
    if Path(DEVELOPER_DIR).is_dir() and shutil.which("xcrun"):
        return "vision"
    return None


def cache_dir(pdf: Path) -> Path:
    return OCR_DIR / Path(pdf).stem


def swift_script() -> Path:
    path = OCR_DIR / "ocr.swift"
    OCR_DIR.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != SWIFT_SOURCE:
        path.write_text(SWIFT_SOURCE)
    return path


def page_count(pdf: Path) -> int:
    from pypdf import PdfReader
    return len(PdfReader(str(pdf)).pages)


def run_vision(pdf: Path, first: int | None = None, last: int | None = None, timeout: int = 7200) -> None:
    """Erkennt alle noch fehlenden Seiten einer PDF (Swift-Skript, Vision)."""
    out = cache_dir(pdf)
    out.mkdir(parents=True, exist_ok=True)
    cmd = ["xcrun", "swift", str(swift_script()), str(pdf), str(out), str(RENDER_SCALE)]
    if first and last:
        cmd += [str(first), str(last)]
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    subprocess.run(cmd, env=env, check=True, timeout=timeout, stdout=subprocess.DEVNULL)


def load_page(pdf: Path, n: int) -> dict | None:
    p = cache_dir(pdf) / f"p{n:04d}.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())


def missing_pages(pdf: Path, total: int) -> list[int]:
    d = cache_dir(pdf)
    return [n for n in range(1, total + 1) if not (d / f"p{n:04d}.json").exists()]


# ----------------------------------------------------------------------------
# Zeilen aus Beobachtungen
# ----------------------------------------------------------------------------

# Feldnamen der Vorlagen (LUH-Modulbeschreibung, Phil-Tabelle): kleine Lesefehler am Zeilenanfang werden berichtigt
# ("Prutungsleistungen" -> "Prüfungsleistungen"), damit die Leseprogramme die Felder finden.
LABELS = (
    "Prüfungsleistungen", "Prüfungsleistung", "Studienleistungen", "Studienleistung", "Leistungspunkte",
    "Häufigkeit des Angebots", "Modultitel", "Kennnummer", "Teilnahmevoraussetzungen", "Empfehlungen",
    "Qualifikationsziele", "Inhalte des Moduls", "Lehrformen und Lehrveranstaltungen", "Literatur",
    "Modulverantwortliche/r", "Modulverantwortliche", "Organisationseinheit", "Studentische Arbeitsbelastung",
    "Empfohlenes Fachsemester", "Moduldauer", "Sprache", "Kompetenzbereich", "Modultyp", "Studiengang",
    "Weitere Verwendung des Moduls", "Anbieter", "Semesterlage", "Verwendbarkeit", "Eingangsvoraussetzungen",
    "Notenskala", "Kompetenzziele", "Lehrinhalte", "Lehrinhalt", "Dauer des Moduls", "Voraussetzungen für die Vergabe",
    "Prüfungs- und", "Davon Präsenzzeit", "Davon Selbststudium", "Weitere Angaben",
    "Module Title", "Module Code", "Degree Course", "Module Type", "Credit Points", "Frequency of Occurrence",
    "Language", "Special Skills Area", "Recommended Semester of Study", "Module Duration", "Student Workload",
    "Further Use of Module", "Kennnummer / Prüfcode",
)
# Kopf der LUH-Vorlage: Zeile nur aus Feldnamen, Werte in der Zeile darunter in denselben Spalten
HEAD_LABELS = (
    "Modultitel", "Kennnummer / Prüfcode", "Kennnummer", "Objektkürzel/Objekt-ID", "Objektkürzel/ Objekt-ID",
    "Objektkürzel / Objekt-ID", "Modul-Nummer", "Modulnummer", "Modul-Code", "Modulcode", "Prüfcode",
    "Studiengang", "Modultyp", "Leistungspunkte",
    "Häufigkeit des Angebots", "Sprache", "Kompetenzbereich", "Empfohlenes Fachsemester", "Moduldauer",
    "Module Title", "Module Code", "Degree Course", "Module Type", "Credit Points", "Frequency of Occurrence",
    "Language", "Special Skills Area", "Recommended Semester of Study", "Module Duration",
)
_LABELS_BY_FIRST: dict = {}
for _l in LABELS:
    _LABELS_BY_FIRST.setdefault(_l[0].lower(), []).append(_l)


def _lev(a: str, b: str, limit: int) -> int:
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        best = i
        for j, cb in enumerate(b, 1):
            v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
            cur.append(v)
            best = min(best, v)
        if best > limit:
            return limit + 1
        prev = cur
    return prev[-1]


FIXUPS = ((re.compile(r"(?<=\S) &t (?=\S)"), " & "),      # "&" wird oft als "&t" gelesen
          (re.compile(r"(?<=\s)Il(?=\s|$|\))"), "II"),       # roemische Zwei ("Experimentalphysik Il")
          # Fussnotenzeichen am Feldnamen ("Modultitel9 Modellierung ..." -> "Modultitel Modellierung ...")
          (re.compile(r"^(Modultitel|Module Title|Leistungspunkte|Modultyp)(?:[0-9]{1,2}|['&’*])(?=\s)"), r"\1"))


def fix_label(text: str) -> str:
    """Feldname am Anfang mit hoechstens 1 Fehler je 7 Zeichen -> richtige Schreibweise (Rest bleibt); dazu typische
    Lesefehler im Text (FIXUPS)"""
    t = text.strip()
    for rx, rep in FIXUPS:
        t = rx.sub(rep, t)
    if not t:
        return text
    # kurzes Stueck, das als Ganzes fast ein Feldname ist ("lodultit" -> "Modultitel"): groessere Toleranz
    if 4 <= len(t) <= 24 and not any(ch.isdigit() for ch in t):
        for lab in LABELS:
            n = len(lab)
            if n - 3 <= len(t) <= n + 2 and t[1:4].lower() == lab[1:4].lower() and t.count(" ") == lab.count(" ") \
                    and _lev(t.lower(), lab.lower(), max(1, n // 3)) <= max(1, n // 3):
                return lab
    for lab in _LABELS_BY_FIRST.get(t[0].lower(), ()):
        n = len(lab)
        if t.startswith(lab):
            return t
        limit = max(1, n // 7)
        for cut in (n, n - 1, n + 1):
            head = t[:cut]
            if cut <= len(t) and (cut == len(t) or not t[cut].isalnum()) and _lev(head.lower(), lab.lower(), limit) <= limit:
                return lab + t[cut:]
    return t


HEADER_ZONE = 0.085  # oberer Rand: Logo "Leibniz Universitaet Hannover" rechts oben wird uebersprungen


def _rows(obs: list[dict]) -> list[list[dict]]:
    """Beobachtungen zu Zeilen: ueberlappen sich zwei Rahmen senkrecht um mehr als die halbe Hoehe, gleiche Zeile.
    Das Logo rechts oben faellt weg, Feldnamen werden berichtigt (fix_label)."""
    obs = [dict(o, t=fix_label(o.get("t") or "")) for o in obs
           if (o.get("t") or "").strip() and not (o["y"] + o["bh"] / 2 < HEADER_ZONE and o["x"] > 0.55)]
    items = sorted(obs, key=lambda o: (o["y"] + o["bh"] / 2, o["x"]))
    rows: list[list[dict]] = []
    for o in items:
        cy = o["y"] + o["bh"] / 2
        placed = False
        for r in reversed(rows[-3:]):
            ry = sum(i["y"] + i["bh"] / 2 for i in r) / len(r)
            rh = max(i["bh"] for i in r)
            if abs(cy - ry) < 0.5 * min(rh, o["bh"]) + 0.002:
                r.append(o)
                placed = True
                break
        if not placed:
            rows.append([o])
    for r in rows:
        r.sort(key=lambda o: o["x"])
    return rows


def page_lines(page: dict | None) -> list[str]:
    """Textzeilen einer erkannten Seite, oben nach unten, links nach rechts"""
    if not page:
        return []
    return [" ".join(o["t"].strip() for o in r) for r in _rows(page.get("obs") or [])]


def page_rows(page: dict | None, split: float) -> list[tuple[str, str, float]]:
    """Zeilen als (linke Spalte, rechte Spalte, y) mit Spaltengrenze `split` (0..1, Anteil der Seitenbreite)"""
    if not page:
        return []
    out = []
    for r in _rows(page.get("obs") or []):
        left = " ".join(o["t"].strip() for o in r if o["x"] < split)
        right = " ".join(o["t"].strip() for o in r if o["x"] >= split)
        out.append((left, right, min(o["y"] for o in r)))
    return out


LAYOUT_WIDTH = 120  # Zeichen je Seitenbreite fuer layout_text


def layout_text(page: dict | None) -> str:
    """Erkannte Seite als Text mit Spaltenlage wie pypdf extraction_mode="layout": jedes Stueck beginnt in der Spalte
    x * LAYOUT_WIDTH; zwischen Stuecken mit sichtbarem Abstand stehen mindestens drei Leerzeichen (Tabellenspalten)."""
    if not page:
        return ""
    out = []
    for r in _rows(page.get("obs") or []):
        line = ""
        prev_end = None
        for o in r:
            t = " ".join(o["t"].split())
            col = int(round(o["x"] * LAYOUT_WIDTH))
            if prev_end is None:
                line = " " * col + t
            else:
                gap = o["x"] - prev_end
                sep = "   " if gap > 0.015 else " "
                line = line + max(sep, " " * (col - len(line))) + t
            prev_end = o["x"] + o["bw"]
        out.append(line)
    return "\n".join(out)


def _is_head_label(t: str) -> bool:
    t = " ".join(t.split()).strip(" :|")
    return any(t == lab or (t.startswith(lab) and len(t) - len(lab) <= 3) for lab in HEAD_LABELS)


def paired_lines(page: dict | None) -> list[str]:
    """Wie page_lines, aber eine Kopfzeile nur aus Feldnamen ("Leistungspunkte  Haeufigkeit des Angebots  Sprache")
    wird mit der Wertzeile darunter spaltenweise zu "Feldname: Wert" je Zeile (LUH-Vorlage; ohne diese Paarung
    steht der Wert eines leeren Feldes beim falschen Feldnamen)."""
    if not page:
        return []
    rows = _rows(page.get("obs") or [])
    out: list[str] = []
    i = 0
    while i < len(rows):
        r = rows[i]
        if len(r) >= 1 and all(_is_head_label(o["t"]) for o in r) and i + 1 < len(rows) \
                and not all(_is_head_label(o["t"]) for o in rows[i + 1]):
            nxt = rows[i + 1]
            starts = [o["x"] for o in r]
            vals: list[list[str]] = [[] for _ in r]
            for o in nxt:
                k = max([j for j, x in enumerate(starts) if x <= o["x"] + 0.03] or [0])
                vals[k].append(o["t"].strip())
            for o, v in zip(r, vals):
                out.append(f"{' '.join(o['t'].split()).strip(' :|')}: {' '.join(v)}".rstrip())
            i += 2
            continue
        if len(r) >= 1 and all(_is_head_label(o["t"]) for o in r):
            out.extend(f"{' '.join(o['t'].split()).strip(' :|')}:" for o in r)
            i += 1
            continue
        out.append(" ".join(o["t"].strip() for o in r))
        i += 1
    return out


def page_text(page: dict | None) -> str:
    return "\n".join(page_lines(page))


def paired_text(page: dict | None) -> str:
    return "\n".join(paired_lines(page))


def pdf_texts(pdf: Path, total: int | None = None) -> list[str]:
    """Seitentexte aus dem Zwischenspeicher (fehlende Seiten leer)"""
    total = total or page_count(pdf)
    return [page_text(load_page(pdf, n)) for n in range(1, total + 1)]


def pdf_paired_texts(pdf: Path, total: int | None = None) -> list[str]:
    total = total or page_count(pdf)
    return [paired_text(load_page(pdf, n)) for n in range(1, total + 1)]


def pdf_layout_texts(pdf: Path, total: int | None = None) -> list[str]:
    total = total or page_count(pdf)
    return [layout_text(load_page(pdf, n)) for n in range(1, total + 1)]


def pdf_pages_raw(pdf: Path, total: int | None = None) -> list[dict | None]:
    total = total or page_count(pdf)
    return [load_page(pdf, n) for n in range(1, total + 1)]


def quality(pdf: Path, total: int) -> dict:
    """Mittlere Sicherheit und Anteil unsicherer Zeilen (c < 0.5)"""
    confs = []
    for n in range(1, total + 1):
        p = load_page(pdf, n)
        if p:
            confs.extend(o.get("c", 0) for o in p.get("obs") or [])
    if not confs:
        return {"lines": 0, "mean": None, "low": None}
    return {"lines": len(confs), "mean": round(sum(confs) / len(confs), 3),
            "low": round(sum(1 for c in confs if c < 0.5) / len(confs), 3)}




# ----------------------------------------------------------------------------
# Lauf ueber alle Eintraege der Formate B (phil-kv-tabelle, maphy-katalog, scanned)
# ----------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent.parent
REGISTRY_LUH = ROOT / "packages" / "shared-contracts" / "study-sources-luh.json"
CRAWL_DIR = Path.home() / "Studora-Builds" / "luh-crawl"
SEED_DIR = Path.home() / "Studora-Builds" / "luh-seed" / "b"
FORMATS_B = ("phil-kv-tabelle", "maphy-katalog", "scanned")


def entries(registry: dict | None = None) -> list[dict]:
    """Registereintraege, deren Hauptkatalog eines der Formate B hat"""
    reg = registry or json.loads(REGISTRY_LUH.read_text())
    return [p for p in reg["programs"] if (p.get("catalog") or {}).get("format") in FORMATS_B]


def _crawl_index() -> tuple[dict, dict]:
    idx = json.loads((CRAWL_DIR / "index.json").read_text())
    fetched = {}
    for e in idx.get("log") or []:
        if isinstance(e, dict) and e.get("status") == 200 and e.get("url"):
            fetched[e["url"]] = e.get("t")
    return idx.get("urls") or {}, fetched


def template_of(texts: list[str]) -> str:
    """Vorlage einer erkannten PDF: 'phil' (Tabelle mit Anbieter), 'luh' (Modulbeschreibung) oder 'mixed'"""
    import re
    joined = "\n".join(texts)
    phil = len(re.findall(r"(?m)^\s*Anbieter", joined))
    luh = len(re.findall(r"Modultitel|Module Title|Kennnummer", joined))
    if phil >= 3 and luh >= 3:
        return "mixed"
    if phil >= 3:
        return "phil"
    return "luh"


def merge_catalogs(base: tuple[dict, dict], other: tuple[dict, dict]) -> tuple[dict, dict]:
    """Module eines zweiten Katalogs (Wahlpflicht-PDF, zweite Vorlage) anhaengen; gleicher Titel = schon da"""
    from app.study_catalog import _unique
    cat, texts = base
    ocat, otexts = other
    cat = json.loads(json.dumps(cat))
    texts = dict(texts)
    area_ids = {a["id"] for a in cat["areas"]}
    area_map = {}
    for a in ocat.get("areas") or []:
        same = next((x for x in cat["areas"] if x["name"] == a["name"]), None)
        if same:
            area_map[a["id"]] = same["id"]
            continue
        nid = _unique(a["id"], area_ids)
        area_map[a["id"]] = nid
        cat["areas"].append(dict(a, id=nid))
    mod_ids = {m["id"] for m in cat["modules"]}
    titles = {m["title"].lower() for m in cat["modules"]}
    id_map = {}
    added = []
    for m in ocat.get("modules") or []:
        if m["title"].lower() in titles:
            continue
        nid = _unique(m["id"], mod_ids)
        id_map[m["id"]] = nid
        added.append(dict(m, id=nid, area=area_map.get(m.get("area")) if m.get("area") else None))
        if m["id"] in otexts:
            texts[nid] = otexts[m["id"]]
    for m in added:
        m["prerequisites"] = [id_map[p] for p in m.get("prerequisites") or [] if p in id_map]
    cat["modules"].extend(added)
    return cat, texts


def _parse_doc(fmt: str, pdf: Path, meta: dict, ocr: bool) -> tuple[tuple[dict, dict] | None, str]:
    """Eine PDF lesen -> ((Katalog, Texte) | None, Hinweis)"""
    from app.catalog_formats import maphy_katalog, phil_kv_tabelle
    from app.catalog_formats.phil_kv_tabelle import catalog_term
    if fmt == "scanned" or ocr:
        total = page_count(pdf)
        if missing_pages(pdf, total):
            return None, f"OCR fehlt ({len(missing_pages(pdf, total))} Seiten)"
        plain = pdf_texts(pdf, total)
        layout = pdf_layout_texts(pdf, total)
        tmpl = template_of(plain)
        meta = dict(meta, catalog_term=catalog_term(meta.get("catalog_term"), "\n".join(plain[:2]), meta.get("term_hint"),
                                                    (meta.get("source") or {}).get("fetched_at")))
        if tmpl == "phil":
            return phil_kv_tabelle.parse(layout, meta), "OCR, Phil-Tabelle"
        try:
            from app.catalog_formats.luh_modulbeschreibung import parse as luh_parse
        except ImportError:
            return None, "OCR fertig, LUH-Vorlage: Leseprogramm luh_modulbeschreibung fehlt noch"
        res = luh_parse(pdf_paired_texts(pdf, total), meta)
        if tmpl == "mixed":
            res = merge_catalogs(res, phil_kv_tabelle.parse(layout, meta))
            return res, "OCR, LUH-Vorlage + Phil-Tabelle"
        return res, "OCR, LUH-Vorlage"
    data = pdf.read_bytes()
    pages = phil_kv_tabelle.layout_pages(data)
    if fmt == "phil-kv-tabelle":
        return phil_kv_tabelle.parse(pages, meta), "Textebene"
    if fmt == "maphy-katalog":
        return maphy_katalog.parse(pages, meta), "Textebene"
    if fmt == "luh-modulbeschreibung":
        from app.study_catalog import pdf_pages
        from app.catalog_formats.luh_modulbeschreibung import parse as luh_parse
        plain = pdf_pages(data)
        meta = dict(meta, catalog_term=catalog_term(meta.get("catalog_term"), "\n".join(plain[:2]), meta.get("term_hint"),
                                                    (meta.get("source") or {}).get("fetched_at")))
        return luh_parse(plain, meta), "Textebene, LUH-Vorlage"
    return None, f"Format {fmt} nicht in Formate B"


def run_entry(p: dict, urls: dict, fetched: dict, shared: dict) -> dict:
    """Ein Registereintrag -> {key, ok, modules, errors, note, catalog}"""
    from datetime import datetime, timezone
    from app.study_catalog import TERM_RE, shareable, validate
    docs = [p["catalog"]] + [c for c in p.get("more_catalogs") or [] if c.get("url")]
    result = None
    notes = []
    for c in docs:
        u = c["url"]
        info = urls.get(u) or {}
        if info.get("status") != 200 or not info.get("path"):
            notes.append("PDF nicht im Zwischenspeicher")
            continue
        t = fetched.get(u)
        term = c.get("term") if TERM_RE.match(c.get("term") or "") else None
        meta = {
            "university": "luh", "program": p["program"], "degree": p["degree"], "po": p["po"],
            "code": p["key"].split("|", 1)[1], "catalog_term": term,
            "regular_semesters": p.get("regular_semesters"), "total_lp": p.get("total_lp"),
            "source": {"url": u, "sha256": info.get("sha256"),
                       "fetched_at": datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                       if t else None},
            "program_key": p["key"], "shared_catalog": shared.get(u, 1) > 1,
        }
        if not term:
            meta["catalog_term"] = None
            meta["term_hint"] = c.get("term")
        res, note = _parse_doc(c["format"], Path(info["path"]), meta, False)
        notes.append(note)
        if res is None:
            continue
        result = res if result is None else merge_catalogs(result, res)
    if result is None:
        return {"key": p["key"], "ok": False, "modules": 0, "errors": [], "note": "; ".join(notes), "catalog": None}
    cat, _texts = result
    facts = shareable(cat)
    errs = validate(facts)
    return {"key": p["key"], "ok": not errs and bool(facts["modules"]), "modules": len(facts["modules"]),
            "errors": errs, "note": "; ".join(dict.fromkeys(notes)), "catalog": facts}


def run_all(write: bool = True) -> list[dict]:
    """Alle Eintraege lesen, pruefen und (write) die Fakten nach ~/Studora-Builds/luh-seed/b/<Registerschluessel>.json"""
    urls, fetched = _crawl_index()
    progs = entries()
    shared: dict = {}
    for p in progs:
        for c in [p["catalog"]] + (p.get("more_catalogs") or []):
            if c.get("url"):
                shared[c["url"]] = shared.get(c["url"], 0) + 1
    out = []
    if write:
        SEED_DIR.mkdir(parents=True, exist_ok=True)
    for p in progs:
        r = run_entry(p, urls, fetched, shared)
        r["format"] = p["catalog"]["format"]
        if write and r["catalog"] is not None and not r["errors"]:
            (SEED_DIR / f"{p['key']}.json").write_text(json.dumps(r["catalog"], ensure_ascii=False, indent=1))
        out.append(r)
    return out


def coverage(results: list[dict]) -> dict:
    """Fuellgrad je Feld ueber alle Module einer Ergebnisliste"""
    keys = ("lp", "exam", "coursework", "turnus", "semester", "language", "workload_h", "area", "prerequisites")
    mods = [m for r in results if r.get("catalog") for m in r["catalog"]["modules"]]
    n = len(mods) or 1
    out = {"entries": len(results), "ok": sum(1 for r in results if r["ok"]), "modules": len(mods)}
    for k in keys:
        if k == "turnus":
            out[k] = sum(1 for m in mods if m[k] != "unbekannt") / n
        elif k == "prerequisites":
            out[k] = sum(1 for m in mods if m[k]) / n
        else:
            out[k] = sum(1 for m in mods if m.get(k) is not None) / n
    return out


def _main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "seed"
    if cmd == "ocr":
        # alle PDFs der Eintraege mit Format scanned erkennen (fehlende Seiten), Swift + Vision
        urls, _ = _crawl_index()
        for p in entries():
            for c in [p["catalog"]] + (p.get("more_catalogs") or []):
                info = urls.get(c.get("url") or "") or {}
                if c.get("format") == "scanned" and info.get("path"):
                    pdf = Path(info["path"])
                    if missing_pages(pdf, page_count(pdf)):
                        run_vision(pdf)
        return 0
    if cmd == "seed":
        res = run_all(write=True)
        for r in res:
            print(f"{'ok ' if r['ok'] else 'ERR'} {r['format']:16} {r['modules']:4} {r['key']}  {r['note']}"
                  + (f"  {r['errors'][:3]}" if r["errors"] else ""))
        for fmt in FORMATS_B:
            print(fmt, json.dumps({k: round(v, 2) if isinstance(v, float) else v
                                   for k, v in coverage([r for r in res if r["format"] == fmt]).items()}))
        return 0
    if cmd == "vision":  # eine PDF: python -m app.catalog_formats.ocr_pages vision <pdf> [erste letzte]
        pdf = Path(argv[2])
        run_vision(pdf, *(int(a) for a in argv[3:5]))
        print(json.dumps(quality(pdf, page_count(pdf))))
        return 0
    print("Aufruf: python -m app.catalog_formats.ocr_pages [ocr|seed|vision <pdf>]")
    return 2


if __name__ == "__main__":
    import sys
    raise SystemExit(_main(sys.argv))
