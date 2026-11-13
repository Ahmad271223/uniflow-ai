# Was fehlt der Windows-Version gegenüber dem iPad? (Stand 13.11.2026)

Verglichen: iPad-App auf dem Stand von `develop` vom 13.11.2026 (Smart Planner 2.0, Hildesheim, eigene Wochen je
Modul) mit der Windows-App (`apps/windows`: Tauri-Fenster, darin dieselbe Web-Oberfläche `app/static`, darunter der
Python-Dienst auf dem PC). Was hier für Windows steht, gilt auch für die Web-Oberfläche im Browser.

Aufwand grob: **S** = unter 1 Tag, **M** = 1–3 Tage, **L** = mehr als 3 Tage.

## Kurz gesagt

- **Gleich auf beiden Seiten:** QIS-Noten-Regeln (bestandene Prüfungen, Noten, LP-Summe nur aus QIS; dieselbe
  Rechnung, gemeinsam getestet), Dokument-Reiter (im Kern), Lerngruppen mit Code, Erinnerungen ab Plus (solange
  StudiNow offen ist), Apple-Anmeldung über den Browser, Community mit Fragen, Antworten, Melden.
- **Die größte Lücke:** Die **Lernziele (Smart Planner 2.0)** haben am PC keine Ansicht. Der Dienst kann alles schon
  (`/api/goals`, Stoppuhr, Plan), es fehlt nur die Oberfläche.
- **Danach:** Schlösser für Plus/Pro AI in der Oberfläche, Konto löschen am PC, eigene Wochen je Modul bearbeiten.

## Priorisierte Liste

| # | Lücke | iPad heute | Windows/Web heute | Aufwand |
|---|-------|------------|-------------------|---------|
| 1 | **Lernziele (Smart Planner 2.0)** | Ansicht „Lernziele“ im Lernkalender: Ziele je Modul, Prognose, Konflikte, Stoppuhr, Zeit eintragen, Plan erstellen/neu verteilen (`Views/Goals/GoalsPage.swift`) | Keine Ansicht. Der Dienst hat alle Endpunkte (`app/smart_goals.py`, `/api/goals`, `/api/sessions`); die geplanten Blöcke erscheinen als normale Lerneinheiten im Kalender, Ziele setzen geht nicht | **M** (oberes Ende): nur Oberfläche, aber groß (Übersicht, Dialoge, Stoppuhr, „Zeit reicht nicht“-Auswahl) |
| 2 | **Schlösser für Plus/Pro AI** | Schloss „ab Plus“/„ab Pro AI“ an Seitenleiste, Menüs, Editor-Werkzeugen, „KI fragen“, Wochentests, „Plan erstellen“; Antippen öffnet die Tarifauswahl | Nur die Grundsperre „ohne Abo nur ansehen“. Schlösser nur an wenigen Stellen (Karteikarten-Stapel, Erinnerungen, Wochensätze). Sonst merkt man es erst an der Fehlermeldung „Tarif ansehen“ (z. B. Plus-Konto ruft Pro-AI-KI auf) | **M**: gemeinsamer Schloss-Baustein, dann Seitenleiste, Editor, KI-Einstiege |
| 3 | **Konto löschen** | Einstellungen → Konto → „Konto löschen“ | Nur ein Link auf die Seite `/konto-loeschen`. Der Dienst hat `POST /api/account/delete`, aber die Windows-App leitet ihn nicht weiter. `docs/release/KONTO-LOESCHEN.md` beschreibt den iPad-Weg | **S** im Web, **S–M** in Windows (weiterleiten, danach abmelden und lokale Daten löschen) |
| 4 | **Eigene Wochen je Modul bearbeiten** | Abschnitt hinzufügen, umbenennen, verschieben, löschen, Dokumente verschieben, Vorschläge übernehmen, zurücksetzen (`Views/Modules/ModuleLayoutViews.swift`) | **Anzeige gleich** (der Dienst wendet dieselbe Einteilung an), aber nichts änderbar; Vorschläge werden nicht gezeigt. Endpunkte gibt es (`/api/modules/{id}/sections`, `/place`, `/suggestions/accept`, `/layout`) | **M**: nur Oberfläche, gemeinsame Fixture vorhanden |
| 5 | **Erinnerungen bei geschlossener App** | Systemmitteilungen 3 Tage, 1 Tag, 8 Uhr und 2 Stunden vorher, auch wenn die App zu ist | Ab Plus ja, aber nur solange StudiNow offen ist (Zeitgeber für die nächsten 26 Stunden). Ein/Aus gilt je Browser, nicht je Konto | **M**: geplante Windows-Mitteilungen oder Start im Infobereich |
| 6 | **Stud.IP-Studiengruppen** (Import, „Was soll in den Lernkalender?“) | Ja, seit 12.11. (`Views/StudyGroupsViews.swift`) | Fehlt (kein Python-Gegenstück; Fixture `fixtures/studip-studygroups` liegt schon da) | **M**: Python-Leser plus Dialog |
| 7 | **Lerngruppen (Community) über Geräte** | Code und QR-Code, Name der Gruppe | Anlegen und Beitreten per Code geht. Codes liegen nur im Browser: eine am iPad angelegte Gruppe erscheint am PC erst nach erneuter Code-Eingabe. Kein QR-Code. ~~Gruppe hieß nach dem Code~~ **behoben 13.11.** (zeigt jetzt den Namen) | **S** (QR) bis **M** (Codes übers Konto abgleichen) |
| 8 | **Editor/Stift** | PencilKit: Stift, Fineliner, Marker, Radierer, Lasso, Text, Notizzettel, Formen, „Bereich an KI“, Schreiblupe, Werkzeugleiste oben/unten/schwebend, Präsentationsmodus, mehrere Fenster, gesperrte Werkzeugleiste ohne Abo | Konva-Editor: Stift, Marker, Radierer, Lasso, Text, Form, Bild, Notizzettel, Hand, Rückgängig, Lineal, Formerkennung, Audio. Handballen-Erkennung nur als Heuristik (Touch während/kurz nach dem Stift wird ignoriert). Es fehlen Fineliner, „Bereich an KI“, Schreiblupe, Leistenposition, Präsentationsmodus, mehrere Fenster | **L** für alles; jeder Punkt einzeln **S–M** |
| 9 | **Dokument-Reiter** | Bis 10 Reiter je Fenster, ungesicherte bleiben, Stelle (Seite, Zoom) je Gerät gemerkt, Tastenkürzel, Reiter in neues Fenster | Reiter vorhanden (letzte 12, schließen mit ×). Stelle nur als zuletzt geöffnete Seite, kein Schutz vor ungesicherten Änderungen, keine Tastenkürzel | **S** |
| 10 | **Weitere iPad-Funktionen ohne Gegenstück** | Videos & Links (Opencast), Vorlesung aufnehmen mit Mitschrift, Dokument-Index, Katalog-Bibliothek, Abgleich im Hintergrund | Fehlen (Editor nimmt nur Audio auf) | je **M–L** |

**Nicht als Lücke gezählt:**

- **QIS-Noten-Regeln:** gleich (`app/grades_model.py` und `GradesModel.swift`, gemeinsamer Test mit echten
  Notenspiegel-Daten). Der Abruf läuft am iPad bzw. am PC, nicht im Dienst – so gewollt.
- **Eine Apple-Anmeldung:** Windows öffnet die Anmeldung im Systembrowser, dort gibt es „Mit Apple anmelden“. Ein am
  iPad mit Apple angelegtes Konto kann sich am PC anmelden, **sobald im Dienst die Apple-Services-ID eingetragen ist**
  (`LERNAPP_APPLE_WEB_CLIENT_ID`, in `deploy/.env.example` noch leer). Dass Apple dabei dieselbe Kennung liefert, ist
  zu erwarten (gleiches Team), aber noch nicht echt getestet.

## Aus den alten Listen noch offen

Geprüft gegen `docs/WINDOWS-LUECKEN-2026-11-05.md`, `docs/UEBERGABE-WINDOWS-PARITAET-2026-11-04.md` und
`docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md`:

- **Erledigt seitdem:** Windows-Bau wieder grün (Läufe vom 11./12.11.), KI mit eigenen Notizen, Tesseract.
- **Weiter offen:** Installer ohne Update-Funktion und ohne Code-Signatur, Store-Paket (MSIX) noch nicht
  einreichbar, nie auf einem echten, frischen Windows-Rechner getestet, „Angemeldet bleiben“ bei der Uni nur
  teilweise (Benutzername nicht vorausgefüllt), `Retry-After` wird vom PC nicht an die Oberfläche weitergereicht,
  Einladungs-Belohnungen (Entscheidung des Inhabers).
- `WEB-IPAD-PARITAET.md` ist die umgekehrte, veraltete Liste (was dem iPad am 25.10. fehlte) und keine Windows-Liste.

## Was ich direkt geschlossen habe

- **Lerngruppe per Code beitreten zeigt jetzt den Namen der Gruppe** statt des Codes
  (`app/static/community-spaces.js`, fragt dafür die schon vorhandene Gruppen-Vorschau des Dienstes).
- Alles andere ist größer als „klein und sicher“ und wartet auf deine Entscheidung. Vorschlag für die Reihenfolge:
  1 (Lernziele), 3 (Konto löschen), 2 (Schlösser), 4 (Wochen bearbeiten).
