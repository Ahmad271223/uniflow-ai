# Bescheinigungen und vollständige Noten (06.11.2026)

Auftrag des Inhabers (wörtlich): „die sollen auch nicht vergessen Immatrikulationsbescheinigung sehen, alle deren Noten,
alles komplett, deren Bescheinigungen die es noch so gibt“.

Befund vorher (Audit 06.11.2026): Auf dem iPad wurden Bescheinigungen nur gezählt (`QISGrades.swift`), an der HsH stand
nur die Zahl der Bescheide mit einem Link; nur der PC (`app/qis.py`) lud PDFs – und zwar bei **jedem** Notenabruf alle,
auch beim automatischen alle 20 Stunden (jeder Abruf erzeugt im QIS ein neues Dokument).

## Was jetzt gilt

Neue Seite **„Bescheinigungen“** unter Uni & Noten (iPad `#/bescheinigungen` = `UFRoute.certificates`, Karte
„Bescheinigungen öffnen“; Web/Windows `#/bescheinigungen`, Karte in Uni & Noten). Sie zeigt alles, was das Portal dem Konto
anbietet, gruppiert nach Art (Immatrikulations-/Studienbescheinigung, BAföG § 9, Datenkontrollblatt, Notenspiegel als PDF,
Rückmeldebescheinigung, Bescheide und Zahlungsnachweise, Weitere), je Dokument:

- **Herunterladen** (noch keine Kopie) bzw. **Öffnen** und **Neu laden**; jede Kopie mit Datum („Stand: 06.11.2026, 14:03“),
- Vorschau in der App (QuickLook) mit **„Teilen oder sichern“** (Teilen-Blatt, „In Dateien sichern“),
- **Semesterwahl**, wo das Portal eine Auswahl anbietet (HISinOne-`select`); im QIS stehen Semester-Fassungen als eigene Zeilen,
- darunter ehrlich: **„Nicht im Portal gefunden“** für übliche Arten, die das Portal dem Konto nicht anbietet,
- **„Anmeldung nötig“** bei abgelaufener Sitzung mit dem vorhandenen Anmeldefenster (QIS: `QISLoginView`, HsH:
  `HsHLoginView(.campus)`, Hildesheim: neues `PLuSLoginView`); nie ein Passwort in der App.
- **Abgelaufene Sitzung (10.11.2026, Meldung des Inhabers „Bescheinigungen holt er auch nicht“):** Das QIS meldet nach
  etwa 30 Minuten ab, die App hielt die Verbindung aber weiter für gültig; die Seite endete dann auf „Anmeldung nötig“
  und blieb dort, auch wenn die Verbindung später wieder angemeldet war. Jetzt (`CertificateCenter.silentLogin`):
  QIS und HsH-Campusmanagement melden einmal still mit dem auf diesem Gerät gemerkten Passwort an
  (`docs/AUTOMATISCH-ANMELDEN-2026-11-06.md`, nur mit Zustimmung, nie in einer Schleife) und versuchen Liste bzw.
  Herunterladen **genau einmal** neu (der Aufruf mit abgelaufener Sitzung traf die Anmeldeseite und erzeugte kein
  Dokument). Ohne gemerktes Passwort bleibt „Anmeldung nötig“. Steht in der gespeicherten Liste noch „Anmeldung
  nötig“ und ist die Verbindung wieder angemeldet, liest die Seite beim Öffnen von selbst neu (PLuS nicht: eigene
  Anmeldung im Fenster). Der Leser selbst hatte gegen die echte Seite keinen Fehler.

Ladereihenfolge (`docs/SYNC-REIHENFOLGE-2026-11-05.md`): nichts davon im Abgleich. Die **Liste** liest die Seite beim
Öffnen, wenn sie nie gelesen wurde oder älter als 7 Tage ist (nur Links/Knöpfe, erzeugt nichts), sonst auf „Liste
aktualisieren“; eine **PDF nur auf Tippen**, genau ein Aufruf ohne Wiederholung. Am PC lädt der automatische
Notenabruf (`sync_order.run_grades_if_due`) keine PDFs mehr (`qis.run(with_documents=False)`); er liest nur die Liste mit.
Der Knopf „Noten & Bescheinigungen abrufen“ am PC lädt wie bisher auf ausdrücklichen Wunsch.

## Je Hochschule

Live gelesen am 06.11.2026 mit Anmeldung des Inhabers, nur lesend (`~/Studora-Builds/bescheinigungen/STRUKTUR-ECHT-2026-11-06.md`).

| | LUH (QIS) | HsH (HISinOne Campusmanagement) | Uni Hildesheim (PLuS = HISinOne) |
|---|---|---|---|
| Einstieg | Startseite → `moduleParameter=studentReportsMenu` („Meine Bescheinigungen“) | Studienservice `cm/stu/studyService/start.xhtml?_flowId=studyservice-flow` → Reiter `studyserviceForm:report_TabBtn` „Bescheide und Bescheinigungen“ | `plus.uni-hildesheim.de/qisserver/pages/cm/exa/enrollment/info/start.xhtml?_flowId=studyservice-flow&initialTab=showTabReport` (Kachel „Meine Bescheinigungen“) |
| Liste | Links `state=verpublish` (ohne Linktext, Name steht daneben): „Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG“ (`publishContainer=bafoegbescheinigung&menuid=bafoeg`), am 10.11.2026 dazu die englische Fassung „Certificate of study period and enrolment / Certificate in accordance with § 9 BAföG“ (`publishContainer=studienbescheinigungEN&menuid=studbeschEN`); daneben „verifizierbar“ (`state=verify`, nie gefolgt) – **live bestätigt**, anonymisierte Kopie `fixtures/certificates/qis-echt-bescheinigungen.html` | Knöpfe `…reportButtons:jobConfigurationButtons:<i>:jobConfigurationButtons:<j>:job<k>`, im Testkonto: Zahlungsbeleg (de/en), Bescheinigung über angemeldete Prüfungen, Notenspiegel alle/bestandene (de/en); **keine** Immatrikulationsbescheinigung bei diesem Konto – Liste wird dynamisch gelesen – **live bestätigt** | gleicher Baustein: § 9 BAföG, vorlesungsfreie Zeiten, Immatrikulations-, Studienverlaufs-, Unbedenklichkeitsbescheinigung, Zahlungsnachweis, Enrolment Certificate, Proof of payment – **live bestätigt** |
| PDF-Notenspiegel | Links „PDF-Notenspiegel zum Drucken“ u. ä. auf den Leistungsseiten (verpublish), gesammelt auf dem Weg Mein Studium → Notenspiegel → Abschluss → Leistungen – **nicht bestätigt** (Konto ohne Leistungen) | als Bericht im Reiter (s. o.) | – (LSF hat keine Bescheinigungen) |
| Herunterladen | `GET` des verpublish-Links mit frischem asi liefert **direkt die PDF** (%PDF, HIS eG/FOP) – **live bestätigt** (beim Lesen einmal im Speicher, nicht gespeichert) | Knopf = JSF-Postback → Hintergrundauftrag → Poll `…jobDownloadPoll:pollOnStop` → PDF-Link. Umgesetzt: Knopf einmal absenden, dann bis 12 JSF-Ajax-Abfragen (`javax.faces.partial.ajax`, 1,5 s Abstand) bis ein Link mit `download`/`.pdf` erscheint, den einmal laden – **nicht ausgelöst, echter Test nötig** | wie HsH – **nicht ausgelöst, echter Test nötig** |
| Anmeldung | QIS-Sitzung von „Stud.IP & QIS“ | Campusmanagement-Sitzung (Moodle & Campusmanagement) | **eigene** PLuS-Anmeldung (`/qisserver/api/identityprovider/redirect/5/login` → CAS; fragt erneut nach dem Passwort), Sitzung 30 Min. Leerlauf |

Anmeldestand HISinOne: nur Abmelden-Link (`category=auth.logout`) auf dem eigenen Rechner. Der versteckte Block „Ihre
Sitzung ist abgelaufen / Anmelden“ steht auch angemeldet auf jeder Seite und zählt nie (Test mit nachgebauter Seite).

## Endpunkte

| Route | PC (`app/server.py`, `app/certificates.py`) | iPad (lokales Backend) |
|---|---|---|
| `GET /api/certificates` | `certificates.summary`: `university`, `portal`, `status` (never/ok/login/error), `message`, `checked_at`, `offers[]` (`id`, `title`, `kind`, `kind_label`, `kinds`, `semester`, `semesters[]`, `source`, `confirmed`, `file` mit `fetched_at`, `size`, `semester`, `url`), `kinds[]` (übliche Arten mit `offered`), `note`, `documents` (ältere PC-Kopien aus `qis_documents`) | `CertificatesEndpoints` → `CertificatesSync.summary` (gleiche Form) |
| `GET /api/certificates/{id}/file` | PDF nur aus `<Datenordner>/qis/` des eigenen Kontos | PDF nur aus dem Container |
| `POST /api/certificates/refresh` | Liste lesen im Hintergrund (Playwright); im Dienst 409 | – (App: `CertificateCenter.refresh`) |
| `POST /api/certificates/{id}/download` (`{"semester"}`) | ein Dokument laden; im Dienst 409 | – (App: `CertificateCenter.download`) |

Speicher: `settings.certificates` (JSON: Liste ohne asi/ViewState, Dateien mit Pfad, Datum, Größe, Semester), PDFs unter
`qis/Bescheinigung-<id>.pdf`. Kennung = md5(Hochschule|Ort)[:12] (Ort = QIS-Adresse ohne Sitzung bzw. `hisinone|Titel|Semester`).

## Noten vollständig

- LUH (QIS) und Uni Hildesheim (LSF): Notenspiegel mit allen Semestern, LP und Schnitt (Kennzahlen oben in Uni & Noten,
  `GradesModel`), unverändert.
- **HsH: Lücke geschlossen.** Auf dem iPad fiel Uni & Noten an der HsH auf die Karte des PC-Servers („QIS-Zugang
  hinterlegen … in der Web-App am PC“). Jetzt `HsHGradesCard` mit „Noten abrufen“/„Campusmanagement verbinden“, dieselbe
  Tabelle (alle Semester, LP, Status, Versuch) und Kopfzeile „Hochschule Hannover“.
- Offen (echter Test): Ob der LSF-Link „Studien-/Prüfungsleistungen“ mit `semester=<JJJJS>` im nodeID alle Semester zeigt
  (bisher angenommen: ja, Reiter je Studiengang werden mitgelesen).

## Echter Test nötig (Liste für den Inhaber)

1. LUH: „Herunterladen“ der Immatrikulationsbescheinigung auf dem iPad (erzeugt ein Dokument), Vorschau, „In Dateien sichern“.
2. LUH mit verbuchten Leistungen: erscheinen die PDF-Notenspiegel-Links und lassen sie sich laden?
3. HsH und PLuS: ein Bericht laden – kommt nach dem Knopf der Poll und dann der PDF-Link, passt die Ajax-Abfrage
   (Felder `javax.faces.partial.*`, Kopf `Faces-Request`)? Falls nicht: Antwort des Polls ansehen und
   `CertificateParser.hisinoneAjaxRequest` / `certificates.py` anpassen.
4. PLuS-Anmeldung im Fenster (SSO Uni Hildesheim) und Ablauf nach 30 Minuten → „Anmeldung nötig“.
5. HsH: Konto mit Immatrikulationsbescheinigung und mit Bescheiden („Leistungsbescheide (n)“): erscheinen sie?
6. Semesterwahl: bietet eines der Portale eine Auswahl an (bisher nicht gesehen)?
7. Am PC: „Liste aktualisieren“/„Herunterladen“ an HsH (gemerkte Sitzung) und Hildesheim (PLuS mit UNI-Account, CAS).

## Dateien und Tests

- Kern: `UniFlowCore/Certificates/Certificates.swift` (Arten, Semester, Leser QIS/HISinOne), `CertificatesClient.swift`
  (Abruf, Herunterladen, Speicher, Anzeige), `LocalBackend/Endpoints/CertificatesEndpoints.swift`.
- App: `Services/CertificateCenter.swift`, `Views/Services/CertificatesPage.swift` (Seite, Vorschau, `PLuSLoginView`),
  `Views/Services/ServicesPage.swift` (Karte, `HsHGradesCard`), Zugriffe in `QISConnection`/`HsHConnection`/`HildesheimConnection`.
- PC/Web: `app/certificates.py`, Routen in `app/server.py`, `app/qis.py` (Liste beim Notenabruf), `app/sync_order.py`,
  `app/static/certificates.js`, `certificates-logic.js`.
- Gemeinsame Fälle: `packages/shared-contracts/fixtures/certificates/cases.json` (`tools/gen-certificates-fixture.py`,
  nachgebaute Seiten nach den Strukturnotizen); Debug-Stub `DebugStub/erststart/qis-bescheinigungen.html`, `qis-bescheinigung.pdf`.
- Tests: `CertificatesTests` (Kern), `CertificatesAppTests` (App mit Debug-Stub), `tests/test_certificates.py`,
  `tests/js/certificates.test.mjs`; Breiten-Audit `bescheinigungen` in `LayoutWidthAuditTests`.
