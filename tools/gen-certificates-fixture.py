"""Erzeugt packages/shared-contracts/fixtures/certificates/cases.json: Bescheinigungen (06.11.2026,
docs/BESCHEINIGUNGEN-2026-11-06.md) mit der Python-Referenz (app/certificates.py) auf NACHGEBAUTEN Seiten (keine echte
Seite, keine Person, erfundene Sitzungen). Der Swift-Kern (CertificatesTests) liest dieselben Seiten und vergleicht exakt.

Aufbau der Seiten:
- LUH-QIS "Meine Bescheinigungen" nach docs/QIS-STUDIP-STRUKTUR.md (Links mit state=verpublish: "Studienzeit- /
  Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG", englische Fassung, Hinweis state=verify); Leistungen
  mit "PDF-Notenspiegel zum Drucken" (verpublish). Bestaetigt am echten Konto: Menue und Linktexte.
- QIS-Seite mit Tabellenzeilen und Linktext "PDF" je Semester (HIS-Standard, nicht bestaetigt).
- LSF Hildesheim "Meine Funktionen" ohne Bescheinigungen (wie die Strukturnotizen 05.11.2026).
- HISinOne "Bescheide und Bescheinigungen" der HsH: leer, mit Berichtsknoepfen (jobConfigurationButtons, Poll) wie am
  06.11.2026 gesehen (~/Studora-Builds/bescheinigungen/STRUKTUR-ECHT-2026-11-06.md), und eine Variante mit Tabellenzeilen
  und Semesterauswahl (HISinOne-Standard, nicht bestaetigt; PLuS Hildesheim ungesehen).

Inhalt: kinds, semester, clean_title (Einzelfaelle), qis (Seite -> Angebote), hisinone (Seite -> Angebote und
Semesterauswahl), summary (gespeicherter Stand -> GET /api/certificates ohne Datei und ohne documents).

Aufruf im Projektordner: python tools/gen-certificates-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys

from schema_source import ROOT, write_or_check

sys.path.insert(0, str(ROOT))
from app import certificates as C  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "certificates" / "cases.json"
LUH = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
LUH_SERVLET = "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet"
LSF = "https://lsf.uni-hildesheim.de/qisserver/rds"
ICMS = "https://icms.hs-hannover.de/qisserver/rds"

KIND_TITLES = [
    "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG",
    "Certificate of study period and enrolment",
    "Studienbescheinigung WiSe 2026/27",
    "BAföG-Bescheinigung nach § 9",
    "Datenkontrollblatt",
    "Notenspiegel",
    "PDF-Übersicht: Leistungen",
    "Transcript of Records",
    "Rückmeldebescheinigung SoSe 2026",
    "Beitragsbescheid Wintersemester 2026/27",
    "Exmatrikulationsantrag",
    "",
]

SEMESTER_TEXTS = [
    "Studienbescheinigung WiSe 2026/27", "Wintersemester 2025/2026", "WS 26/27", "SoSe 2026", "Sommersemester 25",
    "SS 2024 und WiSe 2024/25", "Zahlungsnachweis (ab WS 2021/22)", "Bescheinigung für das WiSe2026/27", "Pass 2026", "Semester 20262", "",
]

CLEAN_TITLES = [
    "PDF-Notenspiegel zum Drucken", "  Studienbescheinigung   anzeigen ", "PDF", "Bescheinigung – ", "Datenkontrollblatt drucken PDF",
    "x" * 120,
]


def luh_reports() -> str:
    """Menue "Meine Bescheinigungen" wie live gesehen (06.11.2026): ein Eintrag, relativer Link auf das Servlet"""
    return f"""<html><head><title>Meine Bescheinigungen</title></head><body><h1>Meine Bescheinigungen</h1>
<a href="{LUH}?state=user&amp;type=4&amp;category=auth.logout&amp;asi=FixSitzung1">Abmelden</a>
<ul class="liste">
<li><a class="auflistung" href="de.his.servlet.RequestDispatcherServlet?state=verpublish&amp;publishContainer=bafoegbescheinigung&amp;menuid=bafoeg&amp;asi=FixSitzung1">Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG</a></li>
</ul>
<p>Die Bescheinigungen sind <a href="{LUH}?state=verify&amp;asi=FixSitzung1">verifizierbar</a>.</p>
<a href="{LUH}?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;asi=FixSitzung1">Mein Studium</a>
</body></html>"""


def luh_list() -> str:
    return f"""<html><body><h1>Notenspiegel</h1><a href="{LUH}?state=user&amp;type=4&amp;category=auth.logout&amp;asi=FixSitzung1">Abmelden</a>
<p><a href="{LUH}?state=verpublish&amp;status=transform&amp;moduleCall=Notenspiegel&amp;publishConfFile=reports&amp;asi=FixSitzung1">PDF-Notenspiegel zum Drucken</a>
<a href="{LUH}?state=verpublish&amp;status=transform&amp;moduleCall=Leistungen&amp;publishConfFile=leistungen&amp;asi=FixSitzung1"><img src="pdf.gif" alt="PDF-Übersicht: Leistungen"></a></p>
<table><tr><th>Prüfungsnr</th><th>Prüfungstext</th><th>Note</th></tr><tr><td>1001</td><td>Mathematik I</td><td>2,0</td></tr></table>
</body></html>"""


def qis_table() -> str:
    return f"""<html><body><h1>Studienbescheinigungen</h1><a href="rds?state=user&amp;type=4&amp;category=auth.logout">Abmelden</a>
<table summary="Bescheinigungen">
<tr><th>Bescheinigung</th><th>Semester</th><th></th></tr>
<tr><td>Studienbescheinigung</td><td>WiSe 2026/27</td><td><a href="rds?state=verpublish&amp;publishConfFile=studbesch&amp;semester=20262&amp;asi=AbC.12">PDF</a></td></tr>
<tr><td>Studienbescheinigung</td><td>SoSe 2026</td><td><a href="rds?state=verpublish&amp;publishConfFile=studbesch&amp;semester=20261&amp;asi=AbC.12">PDF</a></td></tr>
<tr><td>Datenkontrollblatt</td><td></td><td><a href="/qisserver/pdf/datenkontrollblatt.pdf;jsessionid=XYZ?asi=AbC.12" title="Datenkontrollblatt drucken">Drucken</a></td></tr>
<tr><td>Rückmeldebescheinigung</td><td>WiSe 2026/27</td><td><a href="https://anderer-rechner.example/bescheinigung.pdf">PDF</a></td></tr>
</table></body></html>"""


def lsf_start() -> str:
    return f"""<html><body><h1>Meine Funktionen</h1><a href="{LSF}?state=user&amp;type=4&amp;re=last&amp;category=auth.logout">Abmelden</a>
<a href="{LSF}?state=change&amp;type=1&amp;moduleParameter=studySOSMenu&amp;asi=LsfSitzung">Veranstaltungsmanagement</a>
<a href="{LSF}?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;asi=LsfSitzung">POS-Management</a>
<a href="{LSF}?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;createInfos=Y&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82&amp;asi=LsfSitzung">Studien-/Prüfungsleistungen (Notenspiegel)</a>
</body></html>"""


def hisinone_empty() -> str:
    return (ROOT / "packages/shared-contracts/fixtures/hsh/hisinone-studienservice-bescheide.html").read_text(encoding="utf-8")


def hisinone_rows() -> str:
    return """<!DOCTYPE html>
<!-- NACHGEBAUT (keine echte Seite, erfundene Daten): HISinOne-Standard "Bescheide und Bescheinigungen", an der HsH NICHT bestaetigt -->
<html lang="de"><body><a href="/qisserver/rds?state=user&amp;type=3&amp;category=auth.logout">Abmelden</a>
<form id="studyServiceForm" action="/qisserver/pages/cm/stu/studyService/start.xhtml" method="post">
<input type="hidden" name="studyServiceForm_SUBMIT" value="1"/><input type="hidden" name="javax.faces.ViewState" value="e1s2-ERFUNDEN"/>
<button type="submit" name="studyServiceForm:tab3" value="Bescheide und Bescheinigungen" class="active">Bescheide und Bescheinigungen</button>
<h2>Bescheinigungen</h2>
<label for="studyServiceForm:termSelect">Semester</label>
<select name="studyServiceForm:termSelect" id="studyServiceForm:termSelect">
<option value="2026_2" selected="selected">Wintersemester 2026/27</option><option value="2026_1">Sommersemester 2026</option><option value="">Bitte wählen</option></select>
<table class="tableOverflowFix"><thead><tr><th>Bezeichnung</th><th>Aktion</th></tr></thead><tbody>
<tr><td>Immatrikulationsbescheinigung</td><td><button type="submit" name="studyServiceForm:table:0:print" value="PDF erzeugen" title="Bescheinigung als PDF erzeugen">PDF erzeugen</button></td></tr>
<tr><td>BAföG-Bescheinigung nach § 9</td><td><button type="submit" name="studyServiceForm:table:1:print" value="PDF erzeugen">PDF erzeugen</button></td></tr>
<tr><td>Datenkontrollblatt</td><td><input type="image" name="studyServiceForm:table:2:print" src="pdf.png" alt="Drucken"/></td></tr>
<tr><td>Beitragsbescheid Wintersemester 2026/27</td><td><a href="/qisserver/pages/cm/stu/documentDownload.faces?doc=ERFUNDEN1">herunterladen</a></td></tr>
<tr><td>Hinweise zur Rückmeldung</td><td>Text ohne Aktion</td></tr>
</tbody></table>
</form></body></html>"""


def hisinone_jobs() -> str:
    """Reiter "Bescheide und Bescheinigungen" wie an der HsH gesehen (06.11.2026): Berichte als JSF-Knoepfe, daneben der
    Poll des Hintergrundauftrags. Texte wie im Testkonto, Werte erfunden."""
    pre = "studyserviceForm:report:reports:reportButtons:jobConfigurationButtons"
    titles = ["Zahlungsbeleg mit Zahlungshistorie", "Payment receipt and payment history", "Bescheinigung über angemeldete Prüfungen",
              "Notenspiegel (alle Leistungen) deutsch", "Notenspiegel (alle Leistungen) englisch",
              "Notenspiegel (bestandene Leistungen) deutsch", "Notenspiegel (bestandene Leistungen) englisch"]
    buttons = "".join(f'<button type="submit" id="{pre}:{i // 2}:jobConfigurationButtons:{i % 2}:job{i}" name="{pre}:{i // 2}:jobConfigurationButtons:{i % 2}:job{i}" class="submit_job">{t}</button>'
                      for i, t in enumerate(titles))
    return f"""<!DOCTYPE html>
<!-- NACHGEBAUT (keine echte Seite, erfundene Werte): Aufbau wie die HsH-Seite vom 06.11.2026 (Strukturnotizen) -->
<html lang="de"><body><a href="/qisserver/rds?state=user&amp;type=3&amp;category=auth.logout">Abmelden</a>
<div id="sessionTimeout" style="display:none">Ihre Sitzung ist aus Sicherheitsgründen abgelaufen. <a href="/qisserver/rds?state=user&amp;type=1&amp;category=auth.login">Anmelden</a></div>
<form id="studyserviceForm" name="studyserviceForm" action="/qisserver/pages/cm/stu/studyService/start.xhtml" method="post">
<input type="hidden" name="studyserviceForm_SUBMIT" value="1"/><input type="hidden" name="javax.faces.ViewState" value="e2s1-ERFUNDEN"/>
<button type="submit" name="studyserviceForm:stgStudent_TabBtn" value="Meine Studiengänge">Meine Studiengänge</button>
<button type="submit" name="studyserviceForm:report_TabBtn" value="Bescheide und Bescheinigungen">Bescheide und Bescheinigungen</button>
<h2>Bescheide</h2><p>Leistungsbescheide (0)</p><p>Allgemein (0)</p>
<h2>Bescheinigungen</h2><div class="reportButtons">{buttons}</div>
<span id="studyserviceForm:report:reports:reportButtons:jobDownloadPoll:pollOnStop"></span>
<button type="button" name="studyserviceForm:report:info">Informationen</button>
</form></body></html>"""


def plus_jobs() -> str:
    """PLuS Hildesheim "Bescheide / Bescheinigungen" wie live gesehen (06.11.2026): gleicher Baustein wie die HsH"""
    pre = "studyserviceForm:report:reports:reportButtons:jobConfigurationButtons"
    titles = ["Bescheinigung nach §9 BAföG", "Bescheinigung über vorlesungsfreie Zeiten", "Immatrikulationsbescheinigung",
              "Studienverlaufsbescheinigung", "Unbedenklichkeitsbescheinigung", "Zahlungsnachweis (ab WS 2021/22)",
              "Enrolment Certificate", "Proof of payment (from winter term 2021/22)"]
    buttons = "".join(f'<button type="submit" id="{pre}:0:jobConfigurationButtons:{i}:job{i}" name="{pre}:0:jobConfigurationButtons:{i}:job{i}">{t}</button>'
                      for i, t in enumerate(titles))
    return f"""<!DOCTYPE html>
<!-- NACHGEBAUT (keine echte Seite, erfundene Werte): Aufbau wie PLuS vom 06.11.2026 -->
<html lang="de"><body><a href="/qisserver/rds?state=user&amp;type=3&amp;category=auth.logout">Abmelden</a>
<form id="studyserviceForm" action="/qisserver/pages/cm/exa/enrollment/info/start.xhtml" method="post">
<input type="hidden" name="javax.faces.ViewState" value="e1s1-PLUS-ERFUNDEN"/>
<button type="submit" name="studyserviceForm:report_TabBtn" value="Bescheide / Bescheinigungen">Bescheide / Bescheinigungen</button>
<h2>Bescheinigungen</h2>{buttons}<span id="studyserviceForm:report:reports:reportButtons:jobDownloadPoll:pollOnStop"></span>
</form></body></html>"""


def offer_view(o: dict) -> dict:
    return {k: o[k] for k in ("id", "title", "kind", "kinds", "semester", "semesters", "source", "portal", "address", "confirmed")}


def main() -> int:
    check = "--check" in sys.argv
    qis_pages = [
        {"name": "luh-meine-bescheinigungen", "url": f"{LUH_SERVLET}?state=change&type=1&moduleParameter=studentReportsMenu&asi=FixSitzung1",
         "html": luh_reports(), "source": "bescheinigungen", "university": "luh", "confirmed": True},
        {"name": "luh-notenspiegel-liste", "url": f"{LUH}?state=notenspiegelStudent&next=list.vm&asi=FixSitzung1",
         "html": luh_list(), "source": "notenspiegel", "university": "luh", "confirmed": False},
        {"name": "qis-tabelle-pdf-je-semester", "url": f"{ICMS}?state=change&type=1&moduleParameter=studySOSMenu&asi=AbC.12",
         "html": qis_table(), "source": "bescheinigungen", "university": "hsh", "confirmed": False},
        {"name": "lsf-hildesheim-ohne-bescheinigungen", "url": f"{LSF}?state=user&type=0",
         "html": lsf_start(), "source": "bescheinigungen", "university": "hildesheim", "confirmed": False},
    ]
    for p in qis_pages:
        p["offers"] = [offer_view(o) for o in C.qis_offers(p["html"], p["url"], p["source"], p["university"], p["confirmed"])]
    his = []
    for name, page in (("hsh-bescheide-leer", hisinone_empty()), ("hisinone-standard-mit-zeilen", hisinone_rows()),
                       ("hsh-berichte-knoepfe", hisinone_jobs()), ("plus-hildesheim-berichte", plus_jobs())):
        sel = C.hisinone_semesters(page)
        uni = "hildesheim" if name.startswith("plus") else "hsh"
        his.append({"name": name, "university": uni, "html": page, "offers": [offer_view(o) for o in C.hisinone_offers(page, uni)],
                    "rows": [{"title": r["title"], "semester": r["semester"],
                              "href": r["action"].get("href"), "button": r["action"].get("button")} for r in C.hisinone_rows(page)],
                    "select": {"name": sel[0], "options": sel[1]} if sel else None,
                    "jobs": C.hisinone_job_buttons(page), "poll": C.hisinone_poll(page), "report_tab": C.is_report_tab(page)})
    luh_offers = C.qis_offers(luh_reports(), qis_pages[0]["url"], "bescheinigungen", "luh", True) + \
        C.qis_offers(luh_list(), qis_pages[1]["url"], "notenspiegel", "luh", False)
    summaries = []
    for uni, offers in (("luh", luh_offers), ("hsh", C.hisinone_offers(hisinone_jobs(), "hsh")), ("hildesheim", C.hisinone_offers(plus_jobs(), "hildesheim"))):
        state = {"university": uni, "checked_at": "2026-11-06T10:00:00", "status": "ok", "message": "x", "offers": offers, "files": {}}
        summaries.append({"university": uni, "state": state, "summary": {k: v for k, v in C.summary_of(state, uni, [], has_file=lambda _p: False).items() if k != "documents"}})
    out = {
        "generator": "tools/gen-certificates-fixture.py",
        "kinds": [{"title": t, "kinds": C.kinds_of(t)} for t in KIND_TITLES],
        "kind_labels": C.KIND_LABELS,
        "semester": [{"text": t, "semester": C.semester_of(t)} for t in SEMESTER_TEXTS],
        "clean_title": [{"raw": t, "title": C.clean_title(t)} for t in CLEAN_TITLES],
        "offer_id": [{"university": "luh", "locator": "https://h/x?state=verpublish&a=%C3%BC", "id": C.offer_id("luh", "https://h/x?state=verpublish&a=%C3%BC")},
                     {"university": "hsh", "locator": "hisinone|Datenkontrollblatt|", "id": C.offer_id("hsh", "hisinone|Datenkontrollblatt|")}],
        "qis": qis_pages,
        "hisinone": his,
        "summary": summaries,
    }
    content = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=False) + "\n"
    return 0 if write_or_check(OUT, content, check) or not check else 1


if __name__ == "__main__":
    sys.exit(main())
