# Stud.IP Lern-App

Holt zweimal täglich (8:00 und 15:00 Uhr) alle neuen Dateien aus deinen Stud.IP-Kursen, analysiert sie
mit Claude nach Schwierigkeit und Lernaufwand, baut daraus einen Wochenplan und erstellt pro Fach einen
Wochentest (60 oder 90 Minuten). Die Dateien kannst du in der App lesen, zoomen, markieren und mit Notizen versehen.

## 1. Einrichten (einmalig)

1. `.env.example` nach `.env` kopieren und **LUH-ID und WebSSO-Passwort eintragen**.
   Die Datei bleibt nur auf deinem PC.
2. Login einmal sichtbar testen:
   ```bash
   .venv\Scripts\python.exe sync.py --show --no-ai
   ```
   Es öffnet sich ein Browserfenster, loggt sich ein und lädt alle Dateien nach `data/files/`.
   Bei Problemen liegt ein Screenshot unter `logs/login-fehler.png`.
3. Automatik einrichten (Aufgabenplanung 8:00 + 15:00 Uhr; mit `-Autostart` startet auch der Server bei der Anmeldung):
   ```bash
   powershell -ExecutionPolicy Bypass -File scripts\install_schedule.ps1
   ```

## 2. Benutzen (UniFlow AI 3.0)

Navigation: **Übersicht, Lernkalender, Stundenplan, Meine Module, Dokumente & Notizen, Tests & Wiederholung,
Uni & Noten, Community (vorbereitet), Einstellungen**. Rechts oben: Sync, Hell/Dunkel, Zeitmesser (Stoppuhr, Countdown, Pomodoro).

- **Übersicht**: Lerntag auf einen Blick: geplante Minuten, erledigte Aufgaben, Nachholen, heutige Lernpakete mit
  Uhrzeit und Weiterlernen-Button, Uni-Termine des Tages, nächste Termine, Wochenstreifen, Neues aus Stud.IP.
- **Stundenplan**: Wochenraster mit Uni-Terminen (aus Stud.IP importiert, per ICS, PDF, Screenshot/Text mit KI
  oder manuell), freien Zeitfenstern, Sperrzeiten und Lernslots. Klick auf einen Termin: teilnehmen / heute nicht /
  dauerhaft nicht / fällt aus, Termin bearbeiten (nur dieser, ab hier, Serie), passende Unterlagen öffnen.
  Freigewordene Zeit wird erkannt und kann genutzt werden (Übung, Vorlesung nacharbeiten, automatisch, Nachholen).
  Persönliche Verfügbarkeit: Lernzeiten, Fahrtzeit, Mindestslot, Sperrzeiten.
- **Lernkalender**: Lernpakete pro Modul und Lehrwoche (Vorlesung → alle Übungen → ein gemeinsamer Wochentest),
  mit Uhrzeiten in den freien Fenstern des Stundenplans. Tag (Zeitleiste), Woche, Monat, Aufgabenliste.
- **Dokumente & Notizen**: Bibliothek mit Modulordnern (Vorlesungen, Übungen, Lösungen …), eigenen Ordnern,
  Vorschaubildern, Favoriten, Zuletzt, Papierkorb. „Neu“: Notizbuch (Vorlagen), Whiteboard, Ordner, PDF/Bild importieren.
- **Editor 2.0**: Dokument-Tabs, blaue Hauptleiste (Lasso, Stift, Radierer, Text, Formen, Bild, Haftnotiz, PDF-Text
  markieren, Hand), kontextabhängige zweite Leiste (Stiftarten, Stärken, Farben; Radierer ganz/teilweise/Objekte;
  Schrift, Größe, Farbe, Fett/Kursiv/Unterstrichen, Ausrichtung, Zeilenabstand, Hintergrund; Formen mit Füllung,
  Polygon). Seitenleiste: Seitenminiaturen (Drag zum Sortieren, Seitenmenü), Gliederung & Lesezeichen, Aufnahmen.
  Seite hinzufügen (vor/nach/Ende; Leer, Liniert, Kariert, Gepunktet, Millimeter, Cornell; Bild; PDF-Seiten).
  Mehr-Menü: Favorit, kopieren, drehen, Gliederung, Vorlage wechseln, Gehe zu, leeren, Papierkorb, Scrollrichtung,
  Seitenleiste links/rechts, Stift-/Handballenerkennung, Einzelseite/fortlaufend, Werkzeugleiste anpassen.
  Export: diese Seite / ausgewählte / alle, ohne Notizen, Drucken. Zubehör: Aufnehmen, Zoom-Ansicht, Lineal, Zeitmesser.
- **Tests & Wiederholung**: Testkarten pro Modul und Lehrwoche. Regel: höchstens ein automatischer Wochentest pro
  Modul und Lehrwoche (Unique-Index), nur bei neuen Inhalten; Materialien aus Vorlesung und allen Übungen.
- **Uni & Noten**: alle Uni-Dienste (Stud.IP, ILIAS, QIS, IDM, Webmail, Matrix, LUHKI, GitLab, TIB, Mensa,
  ServiceCenter, LUIS) als Kacheln mit Link und Login-Art. **Notenspiegel**: „Noten abrufen“ liest mit deiner
  LUH-ID den Notenspiegel aus dem QIS-Portal (Prüfungsverwaltung → Notenspiegel) und zeigt Noten, LP, Status,
  Versuch und Durchschnitt; Bescheinigungen werden als PDF abgelegt. Falls QIS ein eigenes Passwort hat:
  „Zugang“ (landet als `QIS_USER`/`QIS_PASSWORD` in der `.env`). Bei Fehlern: `logs/qis-fehler.png`, `logs/qis.log`.
  Ablauf im LUH-QIS: Meine Funktionen → Mein Studium → Notenspiegel → Abschluss aufklappen (bis Tiefe 3). Dokumente werden
  aus „Meine Bescheinigungen“ und den Notenspiegel-Seiten geholt (Klick mit Download, Popup oder direkte PDF-Antwort):
  Immatrikulations-/Studienzeitbescheinigung, Studienverlauf, Notenspiegel-PDF/Transcript sobald Leistungen vorliegen.
  Gleiche Titel werden bei jedem Abruf überschrieben, alte Dateien in `data/qis/` aufgeräumt.
- **Stundenplan automatisch**: Bei jedem Sync werden alle eindeutigen Stud.IP-Termine (Vorlesungen, einzelne
  Übungstermine) und dein persönlicher Stud.IP-Stundenplan (`users/{id}/schedule`) übernommen. Nur parallele
  Übungsgruppen bleiben offen, bis du sie im Stud.IP-Stundenplan oder unter Stundenplan → Importieren auswählst.
- **Design nach Vorlage (2.3)**: Lernkalender als Wochen-Zeitraster mit Tageskarten (Ring = Fortschritt), pastellfarbenen
  Terminkarten, Lernpaketen mit „Geplant“-Haken und rechter Spalte (Mein Fortschritt, Nicht erledigt, Schnell hinzufügen,
  Monatskalender); Tagesansicht als Zeitleiste mit großen Karten, Tagesübersicht, Heutige Aufgaben, Freie Zeit → „Lernzeit
  planen“. Dokumente & Notizen mit Modulordner-Karten, Typ-Chips und Schnellzugriff. Meine Module als Karten mit Thema,
  Fortschritt, nächstem Termin und Dateien/Aufgaben/Wochentest-Zählern (Karten/Liste). Standard ist das helle Design.
- **iPad-Stabilität 2.8**: Pixelrate auf iOS 1,5 statt 2 (Konva und PDF-Canvas), Live-/Vorhersage-Canvas nur während
  eines Strichs belegt, Hilfsebene ohne Hit-Canvas, nur Seiten nahe dem Sichtbereich im Speicher. Zoom hält den Punkt
  unter den Fingern fest (auch an den Rändern, breite Seiten scrollen bis zum Rand). Die Hauptleiste wechselt ihre
  Höhe nicht mehr (fester Status-Chip), damit die Seite nach einem Strich nicht springt. Marker/Bleistift werden in der
  Vorschau als ein Pfad gezeichnet (keine Punktketten).
- **Schreibgefühl 2.7**: Hit-Test-Canvas ist beim Schreiben aus (nur beim Lasso an), Striche haben ein Breitenprofil
  nach Druck, Tempo und Neigung (Kugelschreiber dünner bei Tempo, Füller druckabhängig, Bleistift breiter bei Neigung),
  vorausberechnete Punkte (getPredictedEvents) verkürzen die sichtbare Latenz, der Live-Canvas ist desynchronisiert,
  Finger-Scrollen hat Schwung, ein Stift-Cursor zeigt die Strichbreite beim Schweben.
- **Schreiben auf dem iPad (2.6)**: Striche laufen über native Pointer-Events mit allen Zwischenpunkten (Coalesced Events)
  und Pointer Capture auf eine Live-Zeichenfläche, erst beim Loslassen wird das Objekt angelegt. Punkte und ganz kurze
  Striche gehen nicht mehr verloren. Knopf „Stift/Finger" in der Hauptleiste: bei „Stift" schreibt nur der Apple Pencil,
  ein Finger scrollt, zwei Finger zoomen und verschieben; Handballen wird ignoriert, solange der Stift aufliegt.
- **Editor-Leisten 2.4**: Hauptleiste mit Farbverlauf und Werkzeuggruppe als Pille, zweite Leiste weiß mit Gruppen-Pillen, runde Farbfelder mit Ring, Strichstärken-Pille.
- **3.0 Tablet-Design und Plattform-Vorbereitung**: PDF-Ansicht als Schreibmodus (Kopfzeile, Suche und Sync weg,
  Navigation als Symbolleiste, eine schmale Zeile für Tabs und Aktionen, Textmarker in der Hauptleiste, schwebende
  Seitenanzeige, Vollbild mit einem Klick verlassen, geteilte Ansicht mit nur einer Werkzeugleiste und Skript auf der
  Seite der freien Hand). Lernkalender mit 3-Tage-Ansicht, Spuren gegen Überlagerung, freier Zeit, einklappbarer
  Seitenspalte. Tests mit Statuszeile und höchstens zwei Spalten auf dem Tablet. Einstellungen mit Kategorien,
  Diagnose unter „Erweitert“, Schreibhand. Dateien wie `.py`/`.zip` öffnen nicht mehr im PDF-Editor.
  Native iPad-App (Etappe 1, ungetestet): `apps/apple`. Gemeinsames Notizformat und API: `packages/shared-contracts`.
  Blocker-Liste: `docs/BESTANDSAUFNAHME.md`. Tests: `.venv\Scripts\python.exe -m pytest -q tests`.
- **Apple-Pencil-Reparatur 2.9** (Ursachen und Änderungen):
  - Handballen, der vor dem Stift aufliegt, startete eine Finger-Scrollbewegung, die beim Schreiben und nach dem
    Abheben weiterlief (inkl. Schwung). Jetzt gilt jede Berührung, die mit dem Stift zusammenfällt oder bis 0,5 s danach
    beginnt, als Handballen; Finger-Scrollen startet erst nach 8 px Bewegung; Stiftkontakt stoppt Schwung, Pan, Pinch
    und angefangene Sprünge zur letzten Seite. Beim ersten Pencil-Kontakt schaltet die App automatisch auf „Nur Stift“.
  - Status „Speichert…/Gespeichert“ in der Dokumentleiste änderte bei jedem Strich die Leistenhöhe (Umbruch) und
    verschob die Seite. Leisten haben jetzt feste Höhen, kein Umbruch; die ganze Seite scrollt in der Dokumentansicht
    nicht mehr mit (`body.doc-open`, 100dvh), keine Scroll-Verankerung.
  - Safari markierte Seitentext: `user-select`/`touch-callout` auf der Schreibfläche aus, `touchstart`/`touchmove`
    dort nicht-passiv mit `preventDefault`, `selectstart` während eines Strichs blockiert, Safari-Seitenzoom
    (`gesturestart`) im Editor unterdrückt, `maximum-scale=1` gegen Auto-Zoom bei Eingabefeldern.
  - Abstürze: Pro Seite lagen bis zu 7 große Canvas im Speicher und wurden beim Pinch 60× pro Sekunde neu angelegt.
    Jetzt Pixel-Budget pro Canvas (iOS 4,5 MPixel), Hit-Canvas verkleinert, Zwischen-Canvas sofort freigegeben,
    beim Zoomen nur CSS-Skalierung und Neuzeichnen 220 ms nach der Geste.
  - Doppelte Striche: Die Stift-Listener wurden bei jedem Neu-Einblenden einer Seite erneut angehängt (seit 2.6).
    Jetzt genau einmal pro Seite.
  - Strich-Ende zeichnet nur den neuen Strich auf die Ebene (kein Neuzeichnen der ganzen Seite), Undo speichert nur
    den neuen Strich statt der ganzen Seite, Speichern/Entwurf erst in Schreibpausen (spätestens nach 20 s).
  - Zoom am Rand: unsichtbarer Spielraum um die Seiten, der Punkt unter den Fingern bleibt stehen; nach der Geste
    führt die Ansicht sanft in den Rahmen zurück (Seite schmaler als Bildschirm → zentriert).
  - Plan für die native iPad-App (SwiftUI, PDFKit, PencilKit): `docs/NATIVE-IPAD-PLAN.md`.
- **iPad** (Einstellungen → Zugang → „Auf dem iPad benutzen“): `Start-iPad.cmd` doppelklicken (oder `serve.py --lan`) (einmalig Firewall-Regel
  für Port 8765), auf dem iPad `http://<PC-IP>:8765` öffnen, PIN eingeben (steht in den Einstellungen; gilt nur für fremde
  Geräte, der PC selbst braucht keine), dann Safari → Teilen → „Zum Home-Bildschirm“. Im eduroam sehen sich Geräte nicht:
  Mobilen Hotspot am PC einschalten (Adresse meist 192.168.137.1).
- **Ordner aus Stud.IP**: Der Sync liest die Ordnerstruktur jedes Kurses (JSON-API `courses/{id}/folders`) und speichert
  den Pfad je Datei (`files.studip_folder`). Dokumenttyp und Unterart (Gruppenübung, Hörsaalübung/Zentralübung, Tutorium,
  Altklausur, Lösung, Mitschrift …) kommen aus Ordner + Dateiname und schlagen die KI-Einschätzung. Wochennummer aus
  „Blatt 3“, „ueb2“, „GU01“, „02A“, „VL03“ → Lehrwoche; Klausuren bilden den eigenen Block „Klausuren & Altklausuren“.
- **QIS automatisch**: Mit eigenem QIS-Zugang holt der Sync Noten und Bescheinigungen höchstens alle 20 Stunden mit
  (`sync.py --qis` erzwingt es). Englische Bescheinigungen („Certificate of enrolment“) werden ebenfalls erkannt.
- **Server weg?** Die Oberfläche zeigt „Server nicht erreichbar“ und versucht es alle 3 Sekunden erneut.
- **Zugänge pro Dienst** (Uni & Noten → Zugänge): jeder Dienst (QIS, IDM, ILIAS, E-Mail, Matrix, LUHKI, GitLab) kann eigene
  Zugangsdaten haben oder auf einen anderen verweisen („gleiches Passwort wie QIS“). In der `.env` stehen dafür
  `<DIENST>_USER`/`<DIENST>_PASSWORD` oder `<DIENST>_SAME_AS=QIS`. Genutzt werden Stud.IP (Sync) und QIS (Noten).
- **Wenn ein Dokument leer bleibt**: Der Editor zeigt jetzt eine Meldung mit Ursache und bietet „Im Browser-Viewer anzeigen“
  an. Unter Einstellungen → Diagnose gibt es einen PDF-Anzeige-Test und die Fehler der Sitzung zum Kopieren.
- **Einstellungen → Module & Wochentests**: Modulebene statt Kurstabelle, Wochentest ein/aus, Standard-Testdauer
  (15/30/60/eigene), Kurszuordnung per Klick aufs Modul, automatische Zuordnung prüfen.

### Oberfläche 2.0

Die Oberfläche hat eine Sidebar mit **Dashboard, Meine Module, Lernplan, Aufgaben, Prüfungen, Dokumente,
Community (vorbereitet) und Einstellungen**. Oben: globale Suche (Strg+K), Sync-Status, Hell/Dunkel.

- **Dashboard**: Begrüßung, „Heute lernen“ (die Lernpakete des Tages), Modulkarten mit Fortschritt und neuen
  Dateien, neue Inhalte (max. 5, nach Modul gruppiert), nächste Termine, Wochenübersicht, „Meine Woche retten“.
- **Module**: ein Modul fasst Vorlesung + Übung eines Fachs zusammen. Detailseite mit Tabs (Übersicht nach
  Semesterwoche und Thema, Vorlesungen, Übungen, Lösungen, Skripte, Klausuren, Meine Notizen, Zuordnung).
  Die Kurs-Zuordnung ist manuell korrigierbar, Klausurtermin und Priorität pro Modul einstellbar.
- **Lernplan (interaktiver Lernkalender)**: Tages-, Wochen-, Monats- und Listenansicht. Lernpakete = Modul an
  einem Tag mit Aufgaben (Vorlesung → passende Übung → Wissenstest). Lernkombination wählbar (1–3 Fächer pro
  Tag, Vorlesung/Übung/Tests, Lernzeit, Lerntage) mit Machbarkeitsprüfung. Pakete per Drag & Drop oder Dialog
  verschieben, Aufgaben abhaken, überspringen, neu einplanen. Vergangene offene Aufgaben werden rot als
  „Nachholen“ markiert; „Neu einplanen“ und „Meine Woche retten“ zeigen erst einen Vorschlag, der bestätigt wird.
  Dokumente und Tests lassen sich direkt aus dem Paket öffnen, die letzte PDF-Seite wird gemerkt.
- **Dokumente**: Filter nach Modul, Typ, Status, Favoriten, zuletzt geöffnet; Sortierung; Seitenweise Anzeige.
- **Prüfungen**: Testübersicht mit Ergebnis, fokussierter Testmodus mit Fragen-Navigation und Timer, Karteikarten.

### Alte Oberfläche (bis 1.x)

Server starten (falls nicht per Autostart):
```bash
.venv\Scripts\python.exe serve.py
```
Dann im Browser: <http://localhost:8765>

- **Übersicht**: neue Dateien seit dem letzten Besuch, heutige Lernblöcke, Sync-Status.
- **Dateien**: Links die Unterlagen nach Fach → Semesterwoche → Vorlesung, dann Übung. Rechts der **PDF-Editor**:
  - Stifte: Kugelschreiber, Füller (druckempfindlich), Bleistift, Textmarker; Farbe, Strichstärke, Deckkraft; Radierer.
  - Textfelder überall auf der Seite mit Schriftart, Größe, Farbe, fett/kursiv/unterstrichen, Ausrichtung,
    Hintergrund, Transparenz; verschieben, skalieren, drehen, duplizieren (Doppelklick = bearbeiten).
  - Lasso und Rechteckauswahl (verschieben, skalieren, kopieren, löschen), Formen (Linie, Pfeil, Rechteck, Kreis,
    Dreieck), Bilder und Screenshots (Strg+V), Haftnotizen, leere Notizseiten, Lesezeichen, Seitenübersicht, Suche.
  - Zoom per Strg+Mausrad, Pinch, Buttons; Vollbild; Rückgängig/Wiederholen (Strg+Z/Y).
  - Automatisches Speichern mit Versionen (letzte 30), lokalem Entwurf (IndexedDB) für Offline-Arbeit und
    Konflikterkennung. Export als PDF mit allen Notizen („⬇ PDF“). Das Original bleibt unverändert.
  - Geteilte Ansicht: Vorlesung links, Übungsblatt rechts, unabhängig scrollbar.
  - KI-Seitenleiste („✨ KI“): markierten Text erklären (Werkzeug ¶), Seite zusammenfassen, Aufgabe schrittweise
    lösen, nur Hinweise, eigene Lösung prüfen, ähnliche Aufgabe, Fachbegriffe, Karteikarten erstellen.
  - Tastatur: V Auswahl, P Stift, H Marker, E Radierer, L Lasso, T Text, Entf löschen, Strg+D duplizieren.
- **Karteikarten**: aus dem Editor erzeugt, Wiederholung nach Leitner (richtig = seltener, falsch = morgen).
- **Wochenplan**: von der KI erstellt, nach Schwierigkeit geordnet. Blöcke per Drag & Drop verschieben,
  anklicken zum Bearbeiten, eigene Blöcke hinzufügen, abhaken.
- **Tests**: pro Fach ein Wochentest mit Timer. Nach dem Abgeben bewertet die KI und gibt Feedback.
- **Einstellungen**: Lernzeit pro Tag, freie Tage, Testdauer pro Kurs (60/90), Fach-Zuordnung von
  Vorlesung + Übung, Kurse deaktivieren.

## 3. Befehle

```bash
.venv\Scripts\python.exe sync.py            # Sync + Analyse + Plan + Tests (das macht die Automatik)
.venv\Scripts\python.exe sync.py --no-ai    # nur Dateien holen
.venv\Scripts\python.exe sync.py --plan     # Wochenplan neu erzeugen
.venv\Scripts\python.exe sync.py --tests    # fehlende Wochentests erzeugen
```

## 4. Hinweise

- Der Login geht direkt über den WebSSO-Link der Uni Hannover (`Shibboleth.sso/Login?...entityID=sso.idm.uni-hannover.de`).
  Bei Login-Problemen liegt ein Screenshot unter `logs/login-fehler.png`.
- Einzelne Dateien liefern beim Download `403`. Das sind Dateien, bei denen Stud.IP vorher eine Zustimmung zu
  Nutzungsbedingungen verlangt. Einmal in Stud.IP selbst öffnen und zustimmen, danach lädt der nächste Sync sie.
- Gleichnamige Dateien in einem Kurs (z. B. `01A.pdf` in zwei Ordnern) bekommen lokal ein Suffix mit der Datei-ID.
- Die Zugangsdaten lassen sich auch in der App unter **Einstellungen → Stud.IP-Zugang** eintragen.

## 5. Aufbau

| Pfad | Zweck |
| --- | --- |
| `app/studip_sync.py` | Login über WebSSO (Playwright), Kurse per JSON-API, Dateilisten, Downloads |
| `app/extract.py` | Text aus PDFs ziehen |
| `app/ai.py` | Aufrufe von `claude -p` (Analyse, Plan, Test, Bewertung) |
| `app/planner.py` | Ablauf: analysieren, Plan bauen, Tests anlegen, bewerten |
| `app/qis.py` | QIS-Notenspiegel und Bescheinigungen (Playwright) |
| `app/timetable.py` | Stundenplan, freie Fenster, Import, Auto-Import nach dem Sync |
| `app/server.py` | FastAPI-Backend (API unter `/api/...`) |
| `app/static/` | Web-Oberfläche |
| `data/` | Datenbank `lernapp.db`, heruntergeladene Dateien, Browserprofil |
| `logs/` | `sync.log`, `ai.log`, Fehler-Screenshots |

Die KI läuft über die installierte Claude Code CLI (`claude -p`), also über dein Claude-Abo. Das Modell
stellst du in der `.env` ein (`CLAUDE_MODEL=sonnet`).
