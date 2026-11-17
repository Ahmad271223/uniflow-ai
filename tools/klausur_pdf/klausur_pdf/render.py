"""PDF-Ausgabe mit reportlab: Aufgaben-PDF, Lösungs-PDF, Formelblatt-PDF."""
from __future__ import annotations

import re
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (KeepTogether, Paragraph, SimpleDocTemplate, Spacer, Table,
                                TableStyle)

from .fonts import kann, registriere
from .model import Dokument

ERGEBNIS_FARBE = colors.HexColor("#E8F1FB")
MERKE_FARBE = colors.HexColor("#FFF6DA")
RAHMEN = colors.HexColor("#555555")


def dateiname(text: str) -> str:
    """Titel → sicherer Dateiname (Umlaute bleiben, Sonderzeichen werden zu -)."""
    s = re.sub(r"[\\/:*?\"<>|]+", "-", text).strip()
    s = re.sub(r"\s+", "-", s)
    return s or "Dokument"


def fett(markup: str) -> str:
    """Fettdruck für bereits escapten Text: echte Fettschrift, wenn sie alle Zeichen kann."""
    sch = registriere()
    roh = re.sub(r"<[^>]+>", "", markup)
    for a, b in (("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")):
        roh = roh.replace(a, b)
    if sch.titel != sch.normal and kann(sch.titel, roh):
        return f'<font name="{sch.titel}">{markup}</font>'
    return f"<b>{markup}</b>"


def inline(text: str) -> str:
    """Einfaches Markdown (**fett**, `code`) → reportlab-Markup, Rest escapen."""
    t = escape(text.replace("`", ""))
    t = re.sub(r"\*\*(.+?)\*\*", lambda m: fett(m.group(1)), t)
    return t.replace("\n", "<br/>")


class _Stile:
    def __init__(self) -> None:
        s = registriere()
        n, b = s.normal, s.fett
        self.text = ParagraphStyle("t", fontName=n, fontSize=10.5, leading=14.5)
        self.klein = ParagraphStyle("k", parent=self.text, fontSize=8.5, leading=11, textColor=colors.HexColor("#444444"))
        self.kopf = ParagraphStyle("kopf", parent=self.text, fontSize=9, leading=12)
        self.fach = ParagraphStyle("fach", parent=self.text, fontName=n, fontSize=14, leading=18, alignment=TA_CENTER)
        self.titel = ParagraphStyle("titel", parent=self.text, fontName=n, fontSize=12.5, leading=16, alignment=TA_CENTER)
        self.unter = ParagraphStyle("unter", parent=self.text, alignment=TA_CENTER)
        self.aufgabe = ParagraphStyle("auf", parent=self.text, fontName=n, fontSize=11.5, leading=15, spaceBefore=8, spaceAfter=3)
        self.teil = ParagraphStyle("teil", parent=self.text, leftIndent=9 * mm, firstLineIndent=-7 * mm, spaceBefore=2)
        self.schritt = ParagraphStyle("sch", parent=self.text, leftIndent=12 * mm, firstLineIndent=-6 * mm, spaceBefore=1)
        self.formel = ParagraphStyle("f", parent=self.text, fontSize=12, leading=16, leftIndent=8 * mm, spaceBefore=2)
        self.fett = ParagraphStyle("fe", parent=self.text, fontName=b)
        self.abschnitt = ParagraphStyle("ab", parent=self.aufgabe, fontSize=12.5, spaceBefore=12)


def _kasten(inhalt, farbe, breite) -> Table:
    t = Table([[inhalt]], colWidths=[breite])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), farbe),
        ("BOX", (0, 0), (-1, -1), 0.6, RAHMEN),
        ("LEFTPADDING", (0, 0), (-1, -1), 6), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def _fusszeile(titel: str):
    def zeichne(canvas, doc):
        canvas.saveState()
        canvas.setFont(registriere().normal, 8)
        canvas.setFillColor(colors.HexColor("#666666"))
        canvas.drawString(20 * mm, 12 * mm, titel)
        canvas.drawRightString(A4[0] - 20 * mm, 12 * mm, f"Seite {doc.page}")
        canvas.restoreState()
    return zeichne


def _doc(pfad: Path, titel: str) -> SimpleDocTemplate:
    return SimpleDocTemplate(str(pfad), pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm,
                             topMargin=18 * mm, bottomMargin=20 * mm, title=titel)


def _kopf(d: Dokument, st: _Stile, zusatz: str, breite: float) -> list:
    m = d.meta
    links = inline(_s(m.get("fakultaet")) or _s(m.get("institution")))
    rechts = inline(_s(m.get("semester")))
    kopf = Table([[Paragraph(links, st.kopf), Paragraph(rechts, ParagraphStyle("r", parent=st.kopf, alignment=2))]],
                 colWidths=[breite * 0.6, breite * 0.4])
    kopf.setStyle(TableStyle([("LINEBELOW", (0, 0), (-1, 0), 0.6, RAHMEN), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                              ("RIGHTPADDING", (0, 0), (-1, -1), 0)]))
    teile = [kopf, Spacer(1, 5 * mm), Paragraph(fett(inline(d.fach)), st.fach), Spacer(1, 2 * mm),
             Paragraph(fett(inline(d.titel + (f" – {zusatz}" if zusatz else ""))), st.titel)]
    if d.untertitel:
        teile.append(Paragraph(inline(d.untertitel), st.unter))
    if m.get("datum"):
        teile.append(Paragraph(inline(_s(m["datum"])), st.unter))
    return teile


def _s(x) -> str:
    return "" if x is None else str(x)


def _meta_zeile(d: Dokument, st: _Stile) -> Paragraph:
    m = d.meta
    teile = []
    if m.get("dauer"):
        teile.append(fett("Bearbeitungszeit:") + f" {inline(_s(m['dauer']))}")
    if m.get("punkte") not in (None, ""):
        teile.append(fett("Gesamtpunkte:") + f" {inline(_s(m['punkte']))}")
    if m.get("hilfsmittel"):
        teile.append(fett("Hilfsmittel:") + f" {inline(_s(m['hilfsmittel']))}")
    return Paragraph("   ·   ".join(teile), st.text)


def baue_aufgaben(d: Dokument, out: Path) -> Path:
    st = _Stile()
    breite = A4[0] - 40 * mm
    ziel = out / f"{dateiname(d.titel)}-Aufgaben.pdf"
    story = _kopf(d, st, "", breite)
    story += [Spacer(1, 5 * mm)]
    felder = Table([["Name:", "", "Matrikelnummer:", ""]], colWidths=[16 * mm, 70 * mm, 30 * mm, breite - 116 * mm])
    felder.setStyle(TableStyle([("FONTNAME", (0, 0), (-1, -1), registriere().normal), ("FONTSIZE", (0, 0), (-1, -1), 10),
                                ("LINEBELOW", (1, 0), (1, 0), 0.5, colors.black), ("LINEBELOW", (3, 0), (3, 0), 0.5, colors.black),
                                ("LEFTPADDING", (0, 0), (-1, -1), 0)]))
    story += [felder, Spacer(1, 4 * mm), _meta_zeile(d, st), Spacer(1, 3 * mm)]
    if d.hinweis:
        story.append(_kasten(Paragraph(inline(d.hinweis), st.text), colors.HexColor("#F3F3F3"), breite))
    platz = float(d.meta.get("platz_mm", 0) or 0)
    for a in d.aufgaben:
        block = [Paragraph(fett(f"Aufgabe {inline(a.nr)}" + (f" ({inline(a.punkte)} Punkte)" if a.punkte else "")), st.aufgabe)]
        if a.text:
            block.append(Paragraph(inline(a.text), st.text))
        for t in a.teile:
            label = f"({inline(t.label)})" if t.label else "•"
            block.append(Paragraph(f"{label}&nbsp;&nbsp;{inline(t.text)}", st.teil))
        story.append(KeepTogether(block))
        if platz:
            story.append(Spacer(1, platz * mm))
    # Punktetabelle wie auf dem Deckblatt der Originalklausuren
    if d.typ == "klausur" and d.aufgaben:
        kopfzeile = ["Aufgabe"] + [a.nr for a in d.aufgaben] + ["Σ"]
        maxzeile = ["Punkte"] + [a.punkte for a in d.aufgaben] + [_s(d.meta.get("punkte"))]
        leer = ["erreicht"] + [""] * (len(d.aufgaben) + 1)
        tab = Table([kopfzeile, maxzeile, leer])
        tab.setStyle(TableStyle([("FONTNAME", (0, 0), (-1, -1), registriere().normal), ("FONTSIZE", (0, 0), (-1, -1), 9),
                                 ("GRID", (0, 0), (-1, -1), 0.5, RAHMEN), ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                                 ("ROWHEIGHT", (0, 2), (-1, 2), 9 * mm)]))
        story += [Spacer(1, 8 * mm), tab]
    _doc(ziel, d.titel).build(story, onFirstPage=_fusszeile(d.titel), onLaterPages=_fusszeile(d.titel))
    return ziel


def baue_loesungen(d: Dokument, out: Path) -> Path | None:
    if not d.loesungen:
        return None
    st = _Stile()
    breite = A4[0] - 40 * mm
    ziel = out / f"{dateiname(d.titel)}-Loesungen.pdf"
    story = _kopf(d, st, "Lösungen", breite) + [Spacer(1, 4 * mm)]
    for l in d.loesungen:
        story.append(Paragraph(fett(f"Aufgabe {inline(l.nr)}"), st.aufgabe))
        if l.merke:
            story.append(_kasten(Paragraph(fett("Merke:") + " " + inline(l.merke), st.text), MERKE_FARBE, breite))
        for t in l.teile:
            block = []
            if t.label:
                block.append(Paragraph(fett(f"({inline(t.label)})"), st.fett))
            if t.merke:
                block.append(_kasten(Paragraph(fett("Merke:") + " " + inline(t.merke), st.text), MERKE_FARBE, breite))
            for i, s in enumerate(t.schritte, 1):
                text = inline(s)
                if not re.match(r"(?i)\s*(<b>)?schritt\s*\d", s):
                    text = fett(f"Schritt {i}:") + " " + text
                block.append(Paragraph(text, st.schritt))
            if t.ergebnis:
                block.append(Spacer(1, 1.5 * mm))
                block.append(_kasten(Paragraph("▶ " + fett(inline(t.ergebnis)), st.text), ERGEBNIS_FARBE, breite))
            story.append(KeepTogether(block))
            story.append(Spacer(1, 2 * mm))
        if l.wichtig:
            story.append(Paragraph(fett("Wichtig für die Klausur:") + " " + inline(l.wichtig), st.text))
    _doc(ziel, d.titel + " – Lösungen").build(story, onFirstPage=_fusszeile(d.titel + " – Lösungen"),
                                               onLaterPages=_fusszeile(d.titel + " – Lösungen"))
    return ziel


def baue_formelblatt(d: Dokument, out: Path) -> Path:
    st = _Stile()
    breite = A4[0] - 40 * mm
    ziel = out / f"{dateiname(d.titel)}.pdf"
    story = _kopf(d, st, "", breite) + [Spacer(1, 4 * mm)]
    abschnitt = None
    for f in d.formeln:
        if f.abschnitt and f.abschnitt != abschnitt:
            abschnitt = f.abschnitt
            story.append(Paragraph(fett(inline(abschnitt)), st.abschnitt))
        aufgabe = f.aufgabe.strip()
        if not aufgabe.lower().startswith("aufgabe"):
            aufgabe = f"Aufgabe: „{aufgabe}“"
        block = [Paragraph(fett(inline(aufgabe)), st.text), Paragraph(inline(f.formel), st.formel)]
        if f.hinweis:
            block.append(Paragraph(inline(f.hinweis), ParagraphStyle("h", parent=st.klein, leftIndent=8 * mm)))
        block.append(Spacer(1, 2.5 * mm))
        story.append(KeepTogether(block))
    _doc(ziel, d.titel).build(story, onFirstPage=_fusszeile(d.titel), onLaterPages=_fusszeile(d.titel))
    return ziel


def baue(d: Dokument, out: str | Path) -> list[Path]:
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    if d.typ == "formelblatt":
        return [baue_formelblatt(d, out)]
    pfade = [baue_aufgaben(d, out)]
    lo = baue_loesungen(d, out)
    if lo:
        pfade.append(lo)
    return pfade
