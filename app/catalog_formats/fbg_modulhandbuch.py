"""Leseprogramm `fbg-modulhandbuch`: Modulhandbuecher der Fakultaet fuer Bauingenieurwesen und Geodaesie (Datenbank-
Ausgabe; Bau- und Umweltingenieurwesen B.Sc., Bauingenieurwesen M.Sc., Umweltingenieurwesen M.Sc., Computational
Methods in Engineering M.Sc. auf Englisch).

Aufbau je Modul (jedes Modul beginnt auf einer neuen Seite):
  <Titel deutsch> / <Titel englisch>
  Moegl. Pruefungsleistungen: K/KA/MP/HA/HM/PJ/VbP      | Possible forms of examination: K/MP (50%) + VbP (50%)
  Studienleistungen: - SWS / Art 2V / 2Ue               | Course achievements: - SWH / Art
  Sprache D, LP 5, Semester WS WiSe 2026/27             | Language E, CP 6, Semester WS
  P-Form VbP: - P-Form PZ I: K P-Form PZ II: K          (gewaehlte Form je Pruefungszeitraum)
  Ziel des Moduls, Inhalt des Moduls, Workload 150 h (...), Voraussetzungen, Empf. Vorkenntnisse, Literatur, Medien,
  Besonderheiten, Modulverantwortlich, Dozenten, Betreuer, Verantwortl. Pruefer, Institut
  Studiengangs-spezifische Informationen:
    "Fachsemester Pflicht/Wahl Kompetenzbereich" + "2 P Mathematisch-naturwissenschaftliche Grundlagen"
    oder "P/W/WP und Kompetenzbereich in Abhaengigkeit von Vertiefungsrichtung" + "W FSV W UEI ..." (je Vertiefung)
    oder (englisch) "P (Compulsory) / W (Elective) Area of expertise" + "P Kernstudium"
Pruefungsformen als Kuerzel (Legende vorn: K Klausur, MP Muendliche Pruefung, ...). Bereiche mit LP aus der
Uebersicht "1 Mathematisch-naturwissenschaftliche Grundlagen (MNG) 6 LP".
"""
from __future__ import annotations

import re
from collections import Counter

from .formats_a_common import NUM, build_catalog, language_of, number, page_lines, term_of_catalog, text_join, \
    turnus_of

ANCHOR_RE = re.compile(r"^(?:Mögl\. Prüfungsleistungen|Mögliche Prüfungsleistungen|Possible forms of examination)\s*:")
EXAM_NAMES = {"K": "Klausur", "KA": "Klausur mit Antwortwahlverfahren", "MP": "Mündliche Prüfung", "HA": "Hausarbeit",
              "AA": "Ausarbeitung", "DO": "Dokumentation", "ES": "Essay", "KO": "Kolloquium", "KU": "Kurzarbeit",
              "PB": "Praktikumsbericht", "LÜ": "Laborübung", "PJ": "Projektorientierte Prüfung",
              "VbP": "Veranstaltungsbegleitende Prüfung", "R": "Referat", "SE": "Seminarleistung", "P": "Präsentation"}
AREA_ABBR = {"MNG": "Mathematisch-naturwissenschaftliche Grundlagen", "FSG": "Fachspezifische Grundlagen",
             "FSV": "Fachspezifische Vertiefung", "ÜI": "Übergreifende Inhalte", "SG": "Studium Generale"}
KIND_ABBR = {"P": "pflicht", "W": "wahl", "WP": "wahlpflicht"}
OVERVIEW_RE = re.compile(r"^[0-9]+ (.+?) \(([A-ZÄÖÜ]{2,4})\) (" + NUM + r")(?: ?- ?(" + NUM + r"))? ?LP")
TAIL_RE = re.compile(r"Fakultät|http|Informationen|Information$|Kompetenzbereich|Institut|Prüfer|Betreuer|Dozenten|"
                     r"Lecturer|Supervisor|Examiner|Organizer|Vertiefungsrichtung|^[PW] |^[0-9] [PW] |"
                     r"(?:WiSe|SoSe) [0-9]{4}.*(?:Stand|update)|^Modulhandbuch$|^Module handbook$|\((?:M|B)\b[^)]*$")


def _strip(pages: list[list[str]]):
    def norm(l):
        return re.sub(r"[0-9]+", "#", l)
    cnt: Counter = Counter()
    for lines in pages:
        cnt.update(set(norm(l) for l in lines[:4]))
    limit = max(3, len(pages) // 3)
    heads = {k for k, v in cnt.items() if v >= limit}
    out = []
    for pno, lines in enumerate(pages, 1):
        for i, l in enumerate(lines):
            if i < 5 and norm(l) in heads:
                continue
            out.append((pno, l))
    return out


def _split_title(lines: list[str]) -> str:
    """Titelzeilen (deutsch, dann englisch) -> deutscher Titel; Teilung, bei der beide Haelften aehnlich lang sind"""
    if not lines:
        return ""
    if len(lines) == 1:
        return lines[0]
    best, k_best = None, 1
    for k in range(1, len(lines)):
        a, b = " ".join(lines[:k]), " ".join(lines[k:])
        d = abs(len(a) - len(b))
        if best is None or d < best:
            best, k_best = d, k
    return " ".join(lines[:k_best])


def _decode_exam(v: str) -> str:
    def rep(m):
        name = EXAM_NAMES.get(m.group(0))
        return name if name else m.group(0)
    return re.sub(r"(?<![\wÄÖÜäöü])(VbP|KA|MP|HA|AA|DO|ES|KO|KU|PB|LÜ|PJ|K)(?![\wÄÖÜäöü])", rep, v)


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    plines = page_lines(pages)
    head_text = " ".join(" ".join(p[:12]) for p in plines[:2])
    term = term_of_catalog(meta.get("catalog_term"), head_text)
    lines = _strip(plines)
    texts = [l for _, l in lines]
    page_of = [p for p, _ in lines]
    anchors = [i for i, l in enumerate(texts) if ANCHOR_RE.match(l)]

    # Bereiche aus der Uebersicht
    specs, abbr = {}, dict(AREA_ABBR)
    for l in texts[: anchors[0] if anchors else len(texts)]:
        m = OVERVIEW_RE.match(l)
        if m:
            name = m.group(1).strip()
            abbr[m.group(2)] = name
            specs[name] = {"lp_required": number(m.group(3)), "lp_max": number(m.group(4)) if m.group(4) else None}

    starts = []
    for a in anchors:
        j = a - 1
        tl = []
        while j >= 0 and page_of[j] == page_of[a] and len(tl) < 6 and not TAIL_RE.search(texts[j]) \
                and not ANCHOR_RE.match(texts[j]):
            tl.insert(0, texts[j])
            j -= 1
        starts.append((j + 1, a, _split_title(tl)))
    raw = []
    for n, (s, a, title) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(texts)
        block = texts[a:end]
        flat = re.sub(r"\s+", " ", "\n".join(block))
        head_end = re.search(r"Ziel des Moduls|Learning [Oo]bjectives|Qualifikationsziele", flat)
        head = flat[: head_end.start()] if head_end else flat[:800]
        rec = {"title": title, "page": page_of[s] if s < len(page_of) else None, "code": None, "area": None,
               "kind": None, "lp": None, "semester": None, "turnus": "unbekannt", "exam": None, "coursework": None,
               "prereq": "", "language": None, "workload_h": None}
        possible = ANCHOR_RE.sub("", block[0]).strip()
        cm = re.search(r"(?:Studienleistungen|Course achievements)\s*:\s*(.*?)\s*(?:SWS|SWH)\b", head)
        if cm and cm.group(1).strip() not in ("-", "", "keine", "none", "0"):
            v = cm.group(1).strip()
            if re.fullmatch(r"[0-9]+", v):
                v = f"{v} Studienleistung" + ("en" if v != "1" else "")
            rec["coursework"] = v
        lm = re.search(r"(?:Sprache|Language)\s+(D ?/ ?E|E ?/ ?D|D|E|Deutsch|Englisch|English|German)(?![\w])", head)
        if lm:
            rec["language"] = language_of(lm.group(1).replace(" ", ""))
        pm = re.search(r"(?<![\w])(?:LP|CP)\s+(" + NUM + r")", head)
        if pm:
            rec["lp"] = number(pm.group(1))
        sm = re.search(r"(?<![\w])Semester\s+(.*?)\s*(?:(?:WiSe|SoSe) [0-9]{4}|P-Form|$)", head)
        if sm:
            rec["turnus"] = turnus_of(re.sub(r"\((?:F|P|P\+F)\)", "", sm.group(1)))
        forms = []
        for fm in re.finditer(r"P-Form (?:VbP|PZ I{1,2})\s*:\s*(.*?)\s*(?=P-Form|$)", head):
            v = fm.group(1).strip()
            if v and v != "-" and v not in forms:
                forms.append(v)
        if forms:
            rec["exam"] = "; ".join(_decode_exam(f) for f in forms)
        elif possible and possible != "-":
            rec["exam"] = "möglich: " + possible
        wm = re.search(r"Workload\s+(" + NUM + r")\s*h", flat)
        if wm:
            rec["workload_h"] = number(wm.group(1))
        pr = re.search(r"(?:Voraussetzungen|Prerequisites)\s+(.*?)\s*(?:Literatur|Literature|Medien|Media)\b", flat)
        if pr:
            rec["prereq"] = pr.group(1)
        # Studiengangsspezifische Informationen
        sp = re.search(r"(?:spezifische Informationen|Specific Information)\s+(.*)$", flat)
        if sp:
            t = sp.group(1)
            m1 = re.search(r"Fachsemester Pflicht/Wahl Kompetenzbereich\s+([0-9]{1,2})\s+(P|W|WP)\s+(.+?)(?=\s+[0-9]{1,2}\s+(?:P|W|WP)\s|$)", t)
            m2 = re.search(r"P \(Compulsory\) / W \(Elective\) Area of expertise\s+(P|W|WP)\s+(.+?)$", t)
            m3 = re.search(r"Abhängigkeit von Vertiefungsrichtung\s+(.*)$", t)
            if m1:
                rec["semester"] = int(m1.group(1))
                rec["kind"] = KIND_ABBR.get(m1.group(2))
                rec["area"] = m1.group(3).strip()
            elif m2:
                rec["kind"] = KIND_ABBR.get(m2.group(1))
                rec["area"] = m2.group(2).strip()
            elif m3:
                pairs = re.findall(r"(?<![\w])(WP|P|W) (MNG|FSG|FSV|ÜI|SG|[A-ZÄÖÜ]{2,4})(?![\w])", m3.group(1))
                if pairs:
                    kinds = {KIND_ABBR[k] for k, _ in pairs}
                    rec["kind"] = "pflicht" if kinds == {"pflicht"} else (
                        "wahlpflicht" if kinds & {"pflicht", "wahlpflicht"} else "wahl")
                    top = Counter(x for _, x in pairs).most_common(1)[0][0]
                    rec["area"] = abbr.get(top, top)
        # lokale Texte
        sec, cur = {}, None
        labels = {"Ziel des Moduls": "goals", "Learning Objectives": "goals", "Learning objectives": "goals",
                  "Inhalt des Moduls": "content", "Contents": "content"}
        for l in block:
            if l in labels:
                cur = labels[l]
                sec.setdefault(cur, [])
                continue
            m = re.match(r"^(Literatur|Literature)\s+(.*)$", l)
            if m:
                cur = "literature"
                sec.setdefault(cur, []).append(m.group(2))
                continue
            if re.match(r"^(Workload|Medien|Media|Voraussetzungen|Empf\. Vorkenntnisse|Recommended|Besonderheiten|"
                        r"Particularities|Modulverantwortlich|Organizer)\b", l):
                cur = None
                continue
            if cur:
                sec[cur].append(l)
        rec["goals"] = text_join(sec.get("goals"))
        rec["content"] = text_join(sec.get("content"))
        rec["literature"] = text_join(sec.get("literature"))
        if title:
            raw.append(rec)
    return build_catalog(meta, raw, specs, term)
