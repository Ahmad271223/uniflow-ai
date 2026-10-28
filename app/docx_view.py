"""Word-Dateien (DOCX) ansehen, ohne Bearbeiten (Entscheidung des Inhabers vom 28.10.2026: "erst nur anzeigen").

Wandelt `word/document.xml` in schlichtes, sicheres HTML: Ueberschriften, Absaetze, Fett/Kursiv/Unterstrichen/
Durchgestrichen, Hoch-/Tiefstellung, Farben, Listen (mit Ebenen, nummeriert oder mit Punkten), Tabellen, Bilder
(PNG/JPEG/GIF als Daten-URL), Links (nur http/https), Zeilen- und Seitenumbrueche, Formeln als Text. Ohne weitere
Bibliothek (die Windows-App bringt nur die Standardbibliothek mit). Jeder Text wird maskiert, es entstehen nur die
eigenen Elemente und Attribute; ein Word-Dokument kann so kein Skript in die App bringen. Altes Word (.doc) und
Dokumente mit Makros werden nicht gezeigt.
"""
from __future__ import annotations

import base64
import html
import io
import re
import zipfile
import xml.etree.ElementTree as ET

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
M = "http://schemas.openxmlformats.org/officeDocument/2006/math"
V = "urn:schemas-microsoft-com:vml"
PR = "http://schemas.openxmlformats.org/package/2006/relationships"
MAX_BYTES = 60 << 20
MAX_IMAGE = 8 << 20
MAX_XML = 40 << 20
IMG_MIME = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif"}
HEX = re.compile(r"^[0-9A-Fa-f]{6}$")


class DocxError(Exception):
    pass


def w(tag: str) -> str:
    return f"{{{W}}}{tag}"


def _val(el, tag) -> str | None:
    if el is None:
        return None
    x = el.find(w(tag))
    return None if x is None else x.get(w("val"), "true")


def _on(el, tag) -> bool:
    v = _val(el, tag)
    return v is not None and v not in ("0", "false", "none")


class Converter:
    def __init__(self, z: zipfile.ZipFile):
        self.z = z
        self.rels = self._rels("word/_rels/document.xml.rels")
        self.styles = self._styles()
        self.numfmt = self._numbering()
        self.images = 0

    def _read(self, name) -> bytes | None:
        try:
            info = self.z.getinfo(name)
        except KeyError:
            return None
        if info.file_size > MAX_XML:
            raise DocxError("Das Word-Dokument ist zu groß für die Vorschau.")
        return self.z.read(name)

    def _rels(self, name) -> dict:
        data = self._read(name)
        if not data:
            return {}
        out = {}
        for r in ET.fromstring(data).iter(f"{{{PR}}}Relationship"):
            out[r.get("Id")] = (r.get("Target") or "", r.get("TargetMode") or "", r.get("Type") or "")
        return out

    def _styles(self) -> dict:
        """Formatvorlage -> Ueberschriftsebene (1..6) ueber Namen und Gliederungsebene."""
        data = self._read("word/styles.xml")
        out = {}
        if not data:
            return out
        for st in ET.fromstring(data).iter(w("style")):
            sid = st.get(w("styleId")) or ""
            name = (_val(st, "name") or sid).lower()
            lvl = None
            ppr = st.find(w("pPr"))
            ol = _val(ppr, "outlineLvl") if ppr is not None else None
            m = re.search(r"(heading|überschrift|ueberschrift)\s*(\d)", name)
            if m:
                lvl = int(m.group(2))
            elif ol and ol.isdigit():
                lvl = int(ol) + 1
            elif name in ("title", "titel"):
                lvl = 1
            if lvl:
                out[sid] = max(1, min(6, lvl))
        return out

    def _numbering(self) -> dict:
        """numId -> {Ebene: Format} (decimal, bullet, ...)."""
        data = self._read("word/numbering.xml")
        if not data:
            return {}
        root = ET.fromstring(data)
        abstract = {}
        for an in root.iter(w("abstractNum")):
            lv = {}
            for l in an.iter(w("lvl")):
                lv[l.get(w("ilvl"))] = _val(l, "numFmt") or "bullet"
            abstract[an.get(w("abstractNumId"))] = lv
        out = {}
        for n in root.iter(w("num")):
            a = n.find(w("abstractNumId"))
            if a is not None:
                out[n.get(w("numId"))] = abstract.get(a.get(w("val")), {})
        return out

    # ------------------------------------------------ Inhalt
    def body(self) -> str:
        data = self._read("word/document.xml")
        if not data:
            raise DocxError("Kein Word-Dokument (word/document.xml fehlt).")
        root = ET.fromstring(data)
        b = root.find(w("body"))
        return self.blocks(b) if b is not None else ""

    def blocks(self, parent) -> str:
        out, lst = [], []                      # lst: offene Listen [(tag, ebene)]

        def close_lists(to=0):
            while len(lst) > to:
                out.append(f"</{lst.pop()[0]}>")
        for el in parent:
            if el.tag == w("p"):
                ppr = el.find(w("pPr"))
                num = ppr.find(w("numPr")) if ppr is not None else None
                if num is not None and _val(num, "numId") not in (None, "0"):
                    lvl = int(_val(num, "ilvl") or 0)
                    fmt = self.numfmt.get(_val(num, "numId"), {}).get(str(lvl), "bullet")
                    tag = "ul" if fmt in ("bullet", "none") else "ol"
                    while len(lst) > lvl + 1:
                        out.append(f"</{lst.pop()[0]}>")
                    while len(lst) < lvl + 1:
                        lst.append((tag, len(lst)))
                        out.append(f"<{tag}>")
                    out.append(f"<li>{self.inline(el)}</li>")
                    continue
                close_lists()
                out.append(self.paragraph(el, ppr))
            elif el.tag == w("tbl"):
                close_lists()
                out.append(self.table(el))
            elif el.tag == w("sdt"):
                c = el.find(w("sdtContent"))
                if c is not None:
                    close_lists()
                    out.append(self.blocks(c))
        close_lists()
        return "".join(out)

    def paragraph(self, p, ppr) -> str:
        style = _val(ppr, "pStyle") if ppr is not None else None
        lvl = self.styles.get(style or "")
        align = _val(ppr, "jc") if ppr is not None else None
        st = f' style="text-align:{ {"center": "center", "right": "right", "end": "right", "both": "justify"}[align]}"' if align in ("center", "right", "end", "both") else ""
        inner = self.inline(p)
        if lvl:
            return f"<h{lvl}{st}>{inner or '&nbsp;'}</h{lvl}>"
        return f"<p{st}>{inner or '&nbsp;'}</p>"

    def inline(self, p) -> str:
        out = []
        for el in p:
            if el.tag == w("r"):
                out.append(self.run(el))
            elif el.tag == w("hyperlink"):
                rid = el.get(f"{{{R}}}id")
                target = self.rels.get(rid, ("", "", ""))[0] if rid else ""
                inner = "".join(self.run(r) for r in el.iter(w("r")))
                if re.match(r"^https?://", target or "", re.I):
                    out.append(f'<a href="{html.escape(target, quote=True)}" target="_blank" rel="noopener noreferrer">{inner}</a>')
                else:
                    out.append(inner)
            elif el.tag in (w("ins"), w("smartTag"), w("fldSimple")) or el.tag == w("sdt"):
                c = el.find(w("sdtContent")) if el.tag == w("sdt") else el
                out.append(self.inline(c) if c is not None else "")
            elif el.tag in (f"{{{M}}}oMath", f"{{{M}}}oMathPara"):
                txt = "".join(t.text or "" for t in el.iter(f"{{{M}}}t"))
                out.append(f'<span class="dx-math">{html.escape(txt)}</span>')
        return "".join(out)

    def run(self, r) -> str:
        rpr = r.find(w("rPr"))
        parts = []
        for el in r:
            if el.tag == w("t"):
                parts.append(html.escape(el.text or ""))
            elif el.tag == w("tab"):
                parts.append('<span class="dx-tab"></span>')
            elif el.tag in (w("br"), w("cr")):
                parts.append('<hr class="dx-page">' if el.get(w("type")) == "page" else "<br>")
            elif el.tag == w("drawing") or el.tag == w("pict"):
                parts.append(self.image(el))
            elif el.tag == w("sym"):
                parts.append("□")
        text = "".join(parts)
        if not text or rpr is None:
            return text
        if _on(rpr, "b"):
            text = f"<b>{text}</b>"
        if _on(rpr, "i"):
            text = f"<i>{text}</i>"
        if _on(rpr, "u"):
            text = f"<u>{text}</u>"
        if _on(rpr, "strike") or _on(rpr, "dstrike"):
            text = f"<s>{text}</s>"
        va = _val(rpr, "vertAlign")
        if va == "superscript":
            text = f"<sup>{text}</sup>"
        elif va == "subscript":
            text = f"<sub>{text}</sub>"
        color = _val(rpr, "color")
        hl = _val(rpr, "highlight")
        style = []
        if color and HEX.match(color) and color.upper() != "000000":
            style.append(f"color:#{color}")
        if hl and re.match(r"^[a-zA-Z]+$", hl) and hl != "none":
            style.append(f"background:{hl.lower()}")
        if style:
            text = f'<span style="{";".join(style)}">{text}</span>'
        return text

    def image(self, el) -> str:
        blip = next(el.iter(f"{{{A}}}blip"), None)
        rid = blip.get(f"{{{R}}}embed") if blip is not None else None
        if rid is None:
            imd = next(el.iter(f"{{{V}}}imagedata"), None)
            rid = imd.get(f"{{{R}}}id") if imd is not None else None
        target = self.rels.get(rid, ("", "", ""))[0] if rid else ""
        if not target or self.images >= 200:
            return ""
        name = "word/" + target.lstrip("/").replace("../", "") if not target.startswith("word/") else target
        ext = name.rsplit(".", 1)[-1].lower()
        if ext not in IMG_MIME:
            return '<span class="dx-missing">[Bild]</span>'
        try:
            info = self.z.getinfo(name)
        except KeyError:
            return ""
        if info.file_size > MAX_IMAGE:
            return '<span class="dx-missing">[Bild zu groß]</span>'
        self.images += 1
        data = base64.b64encode(self.z.read(name)).decode()
        return f'<img src="data:{IMG_MIME[ext]};base64,{data}" alt="">'

    def table(self, t) -> str:
        rows = []
        for tr in t.findall(w("tr")):
            cells = []
            for tc in tr.findall(w("tc")):
                tcpr = tc.find(w("tcPr"))
                span = _val(tcpr, "gridSpan") if tcpr is not None else None
                vm = tcpr.find(w("vMerge")) if tcpr is not None else None
                if vm is not None and vm.get(w("val")) != "restart":
                    continue                       # fortgesetzte senkrechte Verbindung: Zelle schon oben
                attr = f' colspan="{int(span)}"' if span and span.isdigit() and int(span) > 1 else ""
                cells.append(f"<td{attr}>{self.blocks(tc)}</td>")
            rows.append("<tr>" + "".join(cells) + "</tr>")
        return '<table class="dx-table">' + "".join(rows) + "</table>"


def to_html(data: bytes) -> dict:
    """{html, title, images} oder DocxError mit verstaendlicher Meldung."""
    if len(data) > MAX_BYTES:
        raise DocxError("Das Word-Dokument ist zu groß für die Vorschau.")
    if data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        raise DocxError("Altes Word-Format (.doc) – bitte als .docx speichern oder herunterladen.")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        raise DocxError("Die Datei ist kein Word-Dokument (.docx).")
    with z:
        names = set(z.namelist())
        if "word/vbaProject.bin" in names:
            raise DocxError("Das Dokument enthält Makros und wird aus Sicherheitsgründen nicht angezeigt.")
        c = Converter(z)
        try:
            body = c.body()
        except ET.ParseError:
            raise DocxError("Das Word-Dokument ist beschädigt.")
        title = None
        core = c._read("docProps/core.xml")
        if core:
            try:
                t = ET.fromstring(core).find("{http://purl.org/dc/elements/1.1/}title")
                title = (t.text or "").strip() or None if t is not None else None
            except ET.ParseError:
                pass
        return {"html": body, "title": title, "images": c.images}
