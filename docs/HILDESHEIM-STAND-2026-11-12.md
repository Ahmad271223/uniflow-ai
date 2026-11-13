# Uni Hildesheim: Bestandsaufnahme und eigene Wochen (12.11.2026)

Auftrag des Inhabers (12.11.2026): „Bau jetzt komplett die Uni Hildesheim ein und schau, was noch knifflig ist und was
schon perfekt ist. Vor allem: Wenn keine klaren Vorlesungswochen bestehen, soll der Nutzer selbst welche anlegen
können … Das Gleiche auch für LUH und Hochschule Hannover – aber fang an mit Uni Hildesheim und LUH.“

Zweig `uni/hildesheim-fertig`. Hildesheim bleibt im Store-Build **ausgeblendet** (`apps/apple/project.yml`, Release
`UF_SHIPPED_UNIVERSITIES: "luh"`); freischalten erst nach dem Test mit echtem Konto (Checkliste unten). Grundlage:
`docs/HILDESHEIM-STAND-2026-11-05.md`, die anonymisierten echten Seiten `~/Studora-Builds/hildesheim/STRUKTUR-ECHT-*.md`,
Code und Tests. Keine Anfrage an Uni-Seiten, keine Anmeldung.

## 1. Was schon gut ist (mit erfundenen Daten geprüft)

| Bereich | Stand |
| --- | --- |
| Kurse, Dateien, Lehrwochen aus dem Learnweb | Learnweb (Moodle) über die Sitzung oder den Schlüssel der Moodle-App; Lehrwoche je Datei aus Abschnitt („Woche 3“, Datumsabschnitt), Dateiname („VL 3“, „Blatt 2“), Datum (`LectureWeeks`), einmal berechnet und gemerkt |
| Stundenplan | LSF-Kalender (iCal) mit Wiederholungen und Ausfällen |
| Fristen, Ankündigungen, Nachrichten (lesen und antworten) | Learnweb-Kalender, Ankündigungsforen, Moodle-Unterhaltungen |
| Abgeben | gemeinsames Moodle-Abgabeblatt (Entwurf, dann ausdrücklich „Jetzt abgeben“) |
| Prüfungsanmeldung (Hilfe) | 71 Studiengänge, „Meine POS-Anmeldungen“ nur lesend; nie „An-/Abmeldung“ auslösen |
| Studienverlauf | 105 Kataloge, 2 050 Module; Studiengang aus der LSF-Zeile „Abschluss: …“ |
| Planer → „Zum Modul“ → passende Woche | geht wie an der LUH (Kurs → Modul über die Kursnummer) |
| KI, Karteikarten, Wochentests, Community | hochschulunabhängig |
| **Neu:** eigene Wochen | siehe Abschnitt 4 |

## 2. Was knifflig oder unsicher ist

| Punkt | Warum unsicher | Was hilft |
| --- | --- | --- |
| Alles nur mit nachgebauten Seiten geprüft | Die App lief nie mit einem echten Hildesheim-Konto (die Struktur-Notizen sind gelesen, aber nicht automatisch getestet) | Test mit echtem Konto (Checkliste) |
| Anmeldung (CAS) | Ob die Uni die Moodle-App-Anmeldung (`moodlemobile`) erlaubt, ist offen; LSF-, PLuS- und SOGo-Formular nur nachgebaut (`docs/AUTOMATISCH-ANMELDEN-2026-11-06.md`) | Checkliste Punkte 1–3 |
| LSF-Notenspiegel | **Kein echtes Muster** des Hildesheimer Notenspiegels. Spalten (Prf.Art, Versuch, Semester) sind geraten wie bei der LUH | Seite einmal anonymisiert speichern („Diese Seite auslesen“ gibt es bisher nur fürs QIS der LUH) |
| Versuche | Der LSF-Notenspiegel hat kein Semester/Versuch; die App zählt jetzt gleiche Leistung mit anderem Datum als weiteren Versuch (`QISParser.numberAttempts`) – richtig, wenn das LSF jeden Versuch als eigene Zeile zeigt | Checkliste Punkt 6 |
| Frühere Semester aus älteren Learnweb-Instanzen (learnweb2025, 2024) | Kennungen kollidieren zwischen Instanzen; braucht einen Präfix je Instanz und einen Umzug | eigener Auftrag |
| Kurse ohne Wochenstruktur im Learnweb | Themenformat, ein großer Abschnitt, Dateien ohne Nummer | **jetzt: „Nicht zugeordnet“ + Vorschläge + eigene Wochen** |
| Studienverlauf-Katalog | ohne höchstzulässige Versuche und Modellstudienpläne (`plan_slots`) | Katalog-Werkzeug erweitern |
| Bescheinigungen (PLuS) | nur nachgebaut; jetzt im Sync als Liste gelesen | Checkliste Punkt 7 |
| Abmelden in Hildesheim | löscht das gespeicherte Passwort ganz (auch für die Uni-Mail); an der LUH bleibt es und wird nur für das Portal gesperrt | bewusst so gelassen (sicherer); bei Bedarf angleichen |

## 3. Was heute gefehlt hat und jetzt gebaut ist

| Lücke (gegenüber den LUH-Verbesserungen auf develop) | Vorher | Jetzt |
| --- | --- | --- |
| Uni-Zugang einmal speichern | Learnweb/LSF wurden mit dem gespeicherten Passwort nur **erneuert**, nie zum ersten Mal verbunden | `HildesheimConnection.connectWithStoredLogin`: erst still erneuern, dann jede noch nicht verbundene Quelle über die unsichtbare CAS-Anmeldung verbinden (Passwort genau einmal; abgelehnt = vergessen); im Bericht „verbunden“/„Anmeldung nötig“ |
| Ein Sync für alle Portale | Der Knopf startete nur Learnweb/LSF, ohne Uni-Mail, ohne Ergebnis-Meldung, ohne „Noten jetzt“ | `runHildesheimPortals`: gespeicherten Zugang verbinden → abgelaufene Anmeldung still erneuern und **abwarten** → Uni-Mail und Learnweb/LSF nebeneinander → PLuS-Bescheinigungen (nur Liste) → Meldung „Abgeglichen: Learnweb, LSF und Uni-Mail …“. Gilt auch beim Öffnen der App |
| LSF-Anmeldung im Sync abwarten | Erneuerung lief losgelöst nach dem Sync | wird vor dem Abgleich abgewartet |
| Noten nur aus dem Notenportal | LSF-Noten wurden nur ergänzt (weggefallene Zeilen blieben), nur 6 Seiten, Versuche verschmolzen | vollständig gelesener Notenspiegel **ersetzt** (wie QIS der LUH; leere Antwort löscht nie), bis 60 Seiten, Versuche getrennt |
| Mitteilungen | Schalter für Nachrichten ohne Stud.IP versteckt, Text „Stud.IP“ | Schalter „Learnweb-Nachrichten“, Text „Neue Learnweb-Nachricht“ |
| Studiengruppen-Abfrage | nur Stud.IP | bleibt so (für Hildesheim sicher übersprungen); Learnweb-Gruppen wären eine neue Funktion |

## 4. Eigene Wochen (Hildesheim, LUH; HsH später automatisch mit)

- Die App ordnet weiter selbst. **Unsicheres** steht im Block **„Nicht zugeordnet“** (ganz oben): Learnweb-Dateien
  ohne Abschnitt/Nummer/Datum, Dateien mit Datum außerhalb der Vorlesungszeit, und an der LUH ein **Sammelupload**
  (mindestens 6 Dateien eines Kurses am selben Tag zu Semesterbeginn, ohne Nummer im Namen).
- **Vorschläge** je Datei („→ Woche 3“): aus der ersten Seite (Folientitel „Vorlesung 3“, „Blatt 2“, Datum) oder der
  Nummer am Anfang des Namens. „Vorschläge übernehmen“ legt alle auf einmal ab; „Vorschläge suchen“ liest die ersten
  Seiten der nicht zugeordneten Dateien.
- **Selbst ordnen**: Abschnitt hinzufügen („Woche 7“ legt die Lehrwoche 7 an, jeder andere Name wird ein eigener
  Abschnitt), umbenennen, nach oben/unten, löschen; Dateien per Ziehen (Mac: Maus, iPad: Finger/Pencil) oder
  „Verschieben nach …“ (Rechtsklick bzw. lange drücken; VoiceOver: Aktionen) in einen Abschnitt; „Wieder automatisch
  einordnen“ und „Eigene Ordnung zurücksetzen“.
- **Bleibt beim Abgleich**: Die Ordnung liegt in eigenen Tabellen (`module_sections`, `module_file_places`), in die
  kein Abgleich schreibt. Neue Dateien ordnet die App selbst ein; eine neue Woche 9 erscheint hinter Woche 8, wo auch
  immer der Nutzer Woche 8 hingeschoben hat.
- **Lernkalender, Wochentests, „Zum Modul“**: nutzen die eigene Ordnung (`LocalModules.week`): Datei in Woche 3 gelegt
  → Lernblock in Woche 3; Datei in einem eigenen Abschnitt → die Woche davor; „Zum Modul“ klappt den Abschnitt der
  Datei auf. Dateien in „Nicht zugeordnet“ plant der Lernkalender wie bisher, bis der Nutzer sie ablegt.
- Schnittstelle zu „Smart Planner 2.0“ (`feature/smart-planner-2`): dort nichts geändert. Der Planer bekommt die
  Lehrwoche einer Datei weiter über `LocalModules.week(_:dates:)` und `LocalModules.Dates`; neu ist nur, dass diese
  Funktion die eigene Ordnung beachtet. Wer dort `autoWeek` braucht (ohne Nutzer), findet sie daneben.
- Python (PC/Web) rechnet dieselben Regeln (`app/module_layout.py`, Endpunkte in `app/server.py`); gemeinsame Fälle
  `packages/shared-contracts/fixtures/module-layout/cases.json`. Die Web-Oberfläche zeigt die Felder noch nicht an
  (Folgeauftrag).

## 5. Checkliste für den Inhaber vor dem Freischalten (echtes Hildesheim-Konto, iPad mit Debug-Build)

1. Einstellungen → Uni-Zugang: Benutzername/Passwort der Uni Hildesheim speichern. Danach ohne weitere Eingabe:
   Learnweb **und** LSF verbunden? Uni-Mail verbunden?
2. Oben „Sync“ tippen: Meldung „Abgeglichen: Learnweb, LSF und Uni-Mail“ (ggf. „Bescheinigungen: … verfügbar“)?
3. App 9 Stunden liegen lassen, öffnen, „Sync“: kein Passwort-Fenster, Daten kommen?
4. Module: Stehen die Dateien eines Kurses mit Wochen-Abschnitten in den richtigen Wochen? Gibt es „Nicht
   zugeordnet“? Passen die Vorschläge?
5. Eine Woche anlegen („Woche 15“), einen Abschnitt („Klausurvorbereitung“), eine Datei hineinziehen, Abschnitt
   umbenennen, nach oben schieben. Danach „Sync“: bleibt alles so? Neue Dateien landen automatisch?
6. Noten: Stimmen alle bestandenen Leistungen und die LP-Summe mit dem LSF-Notenspiegel überein? Ein nicht
   bestandener und ein späterer bestandener Versuch: zwei Versuche im Studienverlauf? Notenspiegel-Seite einmal
   anonymisiert sichern (für ein echtes Testmuster).
7. Bescheinigungen (PLuS): Liste sichtbar? (Nur ansehen, nichts erzeugen.)
8. Lernkalender: Fach antippen → richtiges Modul, richtige Woche (auch für eine selbst verschobene Datei)?
9. Mitteilungen: Schalter „Learnweb-Nachrichten“ vorhanden; eine Testnachricht von einem Zweitkonto erzeugt eine
   Mitteilung „Neue Learnweb-Nachricht“?
10. Prüfungsanmeldung, Nachrichten antworten, Abgeben: wie in `docs/HILDESHEIM-STAND-2026-11-05.md`, Testliste 4–8.
11. Erst wenn 1–9 passen: `UF_SHIPPED_UNIVERSITIES` für Release auf `"luh hildesheim"` und `ipad_hildesheim` in
    `docs/release/angaben.json` auf `true`, Store-Texte neu füllen.

## 6. Tests (13.11.2026, nach Zusammenführen mit develop 09b55ff4)

- Kern: alle 1472 Tests grün (`swift test`), darunter `ModuleLayoutTests` (11 Fälle, inkl. gemeinsamer Fälle mit
  Python) und `HildesheimGradesAttemptsTests`.
- Python: 229 Tests der Bereiche Module/Wochen/Planer/Hildesheim grün, dazu `tests/test_module_layout.py`.
- App (geklonter iPad-Simulator): `ModuleLayoutAppTests`, `HildesheimAppTests` (neu: Sync für alle Portale),
  `SyncAllPortalsTests`, `StoredLoginConnectTests`, `ViewTypeDepthAppTests` (neue Ansichten flach: Tiefe ≤ 38) und
  30 weitere Testgruppen (321 Tests) grün. Eine volle Runde aller 1563 App-Tests lief auf dem überlasteten Simulator
  4,7 statt 0,4 Stunden; die dabei roten Editor-/Store-Tests sind einzeln wiederholt alle grün. Vorbestehend rot (auch
  auf develop): `BackgroundSyncAppTests.testDeletingTheContainerDuringABackgroundRunLeavesNothing`
  (`uniflow.studip.studyGroups`).
- Bildschirmfotos: `~/Studora-Builds/hildesheim/bilder-2026-11-12/` (wochen-01 Hildesheim „Nicht zugeordnet“,
  wochen-02 eigene Ordnung, wochen-03 LUH-Sammelupload, wochen-04 Abschnitt anlegen; je hell/dunkel).
- Bekannt, nicht von hier: `tools/gen-local-backend-fixture.py --check` scheitert schon auf develop (6 Pfade in
  `SAMPLES` fehlen); die neuen Pfade der eigenen Wochen müssten dort mit nachgetragen werden.
