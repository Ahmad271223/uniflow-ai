# Entwicklungsstand nach Phasen (Zweig `develop`, Stand 25.10.2026)

> Aktueller Gesamtstand nach der Stabilisierungsrunde: `RELEASE-READINESS.md` im Projektordner.
> 1:1-Umsetzung der Web-App auf dem iPad: Checkliste je Funktion in `WEB-IPAD-PARITAET.md` (erzeugt mit `tools/gen-parity.py`).

Grundregel dieses Berichts: „getestet“ heißt, der Test lief wirklich und ist grün. Nichts hier wurde auf einem echten
iPad oder Mac ausgeführt; iOS-Tests liefen im iPad-Simulator in GitHub Actions.

**Wichtig:** Seit 00:15 Uhr (25.10.) startet GitHub Actions keine Jobs mehr: „recent account payments have failed or
your spending limit needs to be increased“. Alles, was danach geändert wurde, ist nicht in CI gebaut.

## Testläufe

| Lauf (Commit) | Linux-Kern | macOS-Kern | iPad-App + Tests | Python/Web |
| --- | --- | --- | --- | --- |
| `6b699b4` Phase 2/3 + gemeinsame Fälle | 35 grün | 37 grün | 12 grün | grün |
| `df90001` StoreKit | grün | grün | Kompilierfehler (`Transaction` mehrdeutig) | grün |
| `4ef3377` Phase 4 | grün | grün | Kompilierfehler (`cos` mehrdeutig) | grün |
| `ecfdfab` Korrektur | grün | grün | App kompiliert; neue Testdatei mit Raw-String-Fehler | – |
| `7efe85f` Phase 5/6 | **nicht gestartet (Abrechnung)** | – | – | – |
| lokal (PC) | – | – | – | Python 29 grün, Node 10 grün |
| lokal Docker `swift:6.0-jammy` (25.10., mit Stud.IP-Kern) | 48 grün | – | nicht gebaut | Python 43 grün, Node 10 grün |

## Phase 1 – Audit und Live-Blocker
- **Fertig:** 6 P0/P1-Lücken im Server (Pfad-Traversal lesen/schreiben, fremde Webseiten, DNS-Rebinding, gleichzeitiges
  Speichern, `.env`), Web-Entwurf beim Dauerschreiben, eingeschleustes HTML, PIN in Antworten. Liste:
  `BESTANDSAUFNAHME.md` Abschnitt 2a.
- **Getestet:** je Befund ein Test, der am alten Code fehlschlug.
- **Offen:** P2 Datei mit 403 wird bei jedem Sync erneut versucht; Web-Editor zeigt nach >3 Konflikten nur „Offline“.

## Phase 2 – PencilKit und PDFKit
- **Fertig:** PDFKit scrollt/zoomt, PencilKit schreibt; Stift scrollt nie; kein Zoom-Reset nach dem Einpassen;
  Palette an festem Anker; Overlays werden wiederverwendet; Zeichnung wird nie mitten im Strich ersetzt;
  Rückgängig je Dokument; Hoch- und Querformat.
- **Getestet (Simulator):** Seitenkoordinaten echter PDF-Seiten, Overlay in Seitenpunkten, Overlay-Anforderung durch
  PDFKit, Zoomregeln, Strich-Identität (neu, radiert, verschoben, Pixel-Radierer), 1000 Striche.
- **Unbestätigt bis zum Gerätetest:** Schreibgefühl, Handballen, Pencil-Doppeltippen, Verhalten der Palette.

## Phase 3 – Datenverlust verhindern
- **Fertig:** `UniFlowCore` (Swift-Paket): Journal je Seite mit Revisionen, Schreibfehler sichtbar, ein Upload
  gleichzeitig, Striche aus der Uploadzeit bleiben ungesendet, 409 → objektweise Zusammenführung, Offline-Wiederholung;
  Umrechnung abseits des Hauptthreads.
- **Getestet (Linux + macOS):** 1000/5000 Striche, Schreiben während Upload, paralleles Schreiben und Sync,
  Netzabbruch, Absturz, Speicherfehler, Konflikt, gleiche Seite auf zwei Geräten, Neustart, verlorene Bestätigung.

## Phase 4 – PDF-Editor
- **Fertig:** Seitenaufbau wie im Web (eingefügte Seiten, Drehung, entfernte Seiten), Text/Formen/Bilder aus dem Web
  sichtbar, Lesezeichen, Leerseite mit Vorlage, Drehen, Text hinzufügen, Suche, Seitenübersicht, Export als PDF mit
  Notizen, PDF-Import, Dokument-Tabs, Dokumentinformation, Vollbild, Zoomanzeige.
- **Getestet:** App kompiliert (Lauf `ecfdfab`). Die Phase-4-Tests (Seitenaufbau, Geometrie, Export mit sichtbarer
  Handschrift) sind korrigiert, liefen aber noch nicht.
- **Nicht plattformübergreifend bearbeitbar:** Text, Formen, Bilder des Webs sind auf dem iPad nur sichtbar; auf dem
  iPad angelegte Texte sind im Web bearbeitbar.

## Phase 5 – native Oberfläche
- **Fertig (Code):** Tabs Übersicht, Dokumente, Module, Kalender (Tag/3 Tage/Woche), KI-Tests (bearbeiten, abgeben,
  Ergebnis, Wiederholung), Einstellungen (Profil, Server, Schreibhand, Pencil, Sync, Tarif, Diagnose); Lade-, Fehler-,
  Offline- und Leerzustände; Previews.
- **Nicht gebaut** (Actions gesperrt). Von Hand geprüft und zwei wahrscheinliche Kompilierfehler vorab behoben.

## Phase 6 – Skriptsuche und Split-Screen
- **Fertig:** Web: Hinweis zur Aufgabe, geteilte Ansicht (früher). iPad: zweites Dokument daneben, Breite ziehbar,
  Schreibhand, eine gemeinsame Palette, unabhängiges Scrollen/Zoomen, Vorschlag über `/api/related` höchstens einmal je
  Seite nach 2,5 s Ruhe.
- **Getestet:** Web im Desktop-Browser (Aufgabe 2.3 → Folie 13). iPad: nicht gebaut.

## Phase 7 – Konten und Abos
- **Fertig:** Plan mit offenen Entscheidungen (`KONTEN-ABOS-PLAN.md`), Kontingent-Logik `app/billing.py` (nicht
  eingebunden), StoreKit-2-Code + Testkonfiguration (keine echten Produkte).
- **Getestet:** Kontingente lokal (6 Tests, 20 parallele Anfragen → genau 6). StoreKit-Kaufstest noch nicht gelaufen.
- **Offen, wartet auf Entscheidung:** Hosting, KI-Abrechnung, Stud.IP pro Nutzer, Rechtliches, Developer Program.

## Phase 8 – Windows, Android, gemeinsame Daten
- **Fertig:** Verträge (`packages/shared-contracts`: Schema, API-Schemas v1, Fixtures, Versions-, Migrations- und
  Konfliktregeln); gleiche Zusammenführung in Swift, Web, Kotlin; Tauri-Gerüst; Android-Kern.
- **Getestet:** Swift (CI), Web (Node lokal), API-Verträge und DB-Migration (Python lokal).
- **Nicht gebaut:** Tauri (kein Rust, Actions gesperrt), Android-Kern (kein Gradle, Actions gesperrt).

## Phase 9 – CI
- **Fertig:** Workflows Apple (Linux-Kern → macOS-Kern + Simulator), CI (Python, pip-audit, Geheimnis-Prüfung, Web),
  Android, Windows (manuell). Fehler werden nicht verschluckt (pipefail korrigiert).
- **Fehlgeschlagen:** Kontingent/Abrechnung des Kontos blockiert alle Jobs.

## Phase 10 – Release
- **Fertig:** `RELEASE-VORBEREITUNG.md` (Umgebungen, Kennungen, Datenschutz, TestFlight, Metadaten, Bildschirmfotos),
  `MAC-IPAD-CHECKLISTE.md`.
- **Erledigt (Abnahme 26.10.2026):** Info.plist ohne `NSAllowsArbitraryLoads`, lokales Netz nur im Debug-Build,
  Privacy Manifest `PrivacyInfo.xcprivacy`, Release-Prüfung von Team und „Mit Apple anmelden“.
- **Offen:** Signierung (Team des Inhabers), Rechtstexte, Exportkontrolle; Checkliste in `RELEASE-VORBEREITUNG.md`.

## Nächster Schritt

1. Actions wieder freigeben (Entscheidung beim Kontoinhaber), dann Lauf für `develop` wiederholen und Fehler beheben.
2. Gerätetest nach `MAC-IPAD-CHECKLISTE.md`, sobald MacBook und iPad bereitstehen.
3. Entscheidung zu Konten/Hosting, danach Phase 7 am Server.
