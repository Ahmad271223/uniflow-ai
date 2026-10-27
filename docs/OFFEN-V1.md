# Was für V1 noch fehlt (Stand 26.10.2026, 11:20)

Geschrieben von der Mac-Sitzung vor dem Ausschalten des Laptops, damit beide Sitzungen und der Inhaber dieselbe Liste
haben. „Getestet“ heißt: automatische Tests grün und, wo angegeben, mit echten Daten im Simulator geprüft.

## Fertig und auf `develop` (ab diesem Push)

| Teil | Stand |
| --- | --- |
| Tarife Free/Plus, erster Start (Apple, Tarif, Hochschulwahl) | getestet |
| S1/S2 lokale Datenbank und Backend ohne PC | getestet |
| S3 Stud.IP-Dateien in Dokumente, Editor offline, Notizen bleiben | getestet, mit echten Dateien (150) |
| S4 Fach, Art, Lehrwoche, Module | getestet, mit echten Dateien |
| S5 Stundenplan aus Stud.IP, ICS-Import | getestet, nur erfundene Stud.IP-Antworten |
| S6 Lernplan, Lernpakete, Übersicht, Woche retten | getestet, erfundene Daten |
| S7 neue PDF-Fassung mit erhaltenen Notizen, Suche offline | getestet, erfundene Daten |
| S9 „Lösung teilen“ als Datei (nur eigene Notizen, verschlüsselt) | getestet, mit echtem Übungsblatt und zwei Benutzern |
| Opencast-Aufzeichnungen (Modul, Woche, Player, Download auf Wunsch) | getestet, erfundene Seiten |
| Datentrennung je (Apple-Nutzer, Hochschule), Umzug alter Daten | getestet |
| ~~Zugangsdaten je Uni im Schlüsselbund, Anmeldeseiten nur vorausfüllen~~ – **abgelöst 27.10.2026:** Hochschul-Passwörter merkt nur iOS (Passwort-Autofill/Schlüsselbund im Anmeldefenster), nie die App; Schalter „Auf diesem iPad merken“, eigenes Speichern und Vorausfüllen entfernt, früher gemerkte Einträge löscht die App einmal beim Start (Zweig `wip/passwort-ios`) | getestet mit lokalen Seiten und den Nachbildungen; am echten iPad offen: Schlüssel-Symbol über der Tastatur, Sichern-Angebot von iOS |
| Hildesheim: CAS, Learnweb, LSF-Stundenplan, Noten | getestet, erfundene Antworten |
| Dreifache Abnahme: 96 bestätigte Befunde behoben (u. a. Notizbücher öffnen, neue Kurse beim Abgleich, HTTP nur Debug, Privacy Manifest, KI-Reste entfernt, Plus-Karte ehrlich) | getestet |

Noch nicht auf `develop`, aber auf GitHub gesichert: `wip/community-cloudkit` (Community über CloudKit, siehe unten).

## Noch zu bauen (Mac-Sitzung, Reihenfolge)

1. **Community über CloudKit** auf den Abnahme-Stand setzen, prüfen lassen, pushen (gebaut: veröffentlichen
   Modul/Lerngruppe/anonym, Treffer im Dokument, Kurs-Ansicht nach Woche, Zurückziehen, Melden, Blockieren,
   Lerngruppen mit Code/QR; Entscheidungen: Kurs-ID/Kursname reicht als Berechtigung, Inhaber moderiert im
   CloudKit Dashboard, AUFTRAG-APPSTORE-V1 auf „Community über CloudKit“ fortschreiben).
2. **Erster Start neu:** Apple → Tarif → Hochschule → **sofort die Anmeldeseiten der Uni** (LUH: Stud.IP, dann QIS;
   Hildesheim: CAS) → Erstabgleich mit Fortschritt → gefüllter Startbildschirm; kleiner Link „Später anmelden“;
   Uni-Wechsel nur in den Einstellungen. **Gebaut (Zweig `wip/erststart-noten`, 26.10.):** `FirstLoginFlow`, Debug
   `-UFOnboarding login -UFLoginStub <ordner>` mit Nachbildungen in `apps/apple/DebugStub/erststart`; geprüft im
   Simulator mit erfundenen Daten, nicht gegen echte Uni-Seiten.
3. **Noten aus QIS (LUH)** anzeigen; leer ist möglich und kein Fehler („noch keine Noten veröffentlicht“).
   **Gebaut (`wip/erststart-noten`):** `QISClient`/`QISGradesSync` im Kern, `QISConnection` in der App, Uni & Noten an
   der LUH lokal; geprüft mit erfundenem QIS-HTML, nicht gegen das echte QIS.
4. **Hildesheim-Gleichheit:** jede LUH-Funktion auch für Hildesheim prüfen (Learnweb-Folien in Dokumente/Module,
   LSF-Stundenplan, Noten, Lernplan, Editor, Teilen/Community) und Lücken schließen. **Geprüft (`wip/erststart-noten`):**
   Tabelle in `docs/HILDESHEIM-PARITAET.md`, `HildesheimParityAppTests`.
5. **Prüfung mit echten Daten** gegen die Zählwerte der PC-Sitzung (`docs/STAND-MAC-SITZUNG.md`): LUH 19 Kurse /
   155 Dateien / 18 Serien / 0 Noten / 12 Opencast-Videos; Hildesheim 9 / 539 / 24 Serien / 17 Ausfalltage /
   16 Leistungen. Der Inhaber meldet sich dafür selbst im Simulator an.
6. **S8** Abgleich im Hintergrund (frühestens 8/15/20 Uhr, Erinnerungen) – nach Messung der Sitzungsdauer.
7. **Karteikarten** selbst anlegen: **erledigt (`wip/karteikarten`)** – vier Endpunkte lokal wie `app/server.py`,
   Seite „Karteikarten“ mit Anlegen, Liste je Modul, Wiederholen und Löschen, nur mit Plus; „bald“ entfällt.
   Offen: „Als Karteikarte“ aus markiertem Text im Editor (der Editor hat keine Textauswahl, `isInMarkupMode`).
8. Kleinere Abnahme-Reste: Strichbreite der fremden Ebene, Stundenplan-Hinweis, E2E-Lage nach Zoom – siehe
   Commits „Abnahme: …“ und offene Punkte in `docs/IPAD-OHNE-PC.md`.

## Nur der Inhaber / Apple / die Hochschulen

- Developer Program aktiv → Team-ID in `apps/apple/Config/Team.xcconfig`; dann „Mit Apple anmelden“ und CloudKit
  echt testbar (iCloud-Container `iCloud.de.uniflow.ai` anlegen, Schema nach Production).
- App Store Connect: App-Eintrag, Abo „Plus 1,99 €/Monat, 1 Woche gratis“, Datenschutz-Angaben.
- Datenschutzerklärung, Nutzungsbedingungen, Impressum veröffentlichen (Entwürfe macht die PC-Sitzung in
  `docs/release/`), Links auf der Abo-Seite eintragen.
- Anfragen an LUH (LUIS/elsa) und Hildesheim (Regel 5.2.2, Learnweb-Schlüssel) – Entwürfe PC-Sitzung. Passwort-Merken
  durch die App muss nicht mehr erfragt werden (seit 27.10.2026 merkt nur iOS das Passwort).
- Apple-Prüfung: kein Demo-Modus gewünscht (Entscheidung 26.10.); Risiko nach Regel 2.1 ist bekannt – vor der
  Einreichung klären (z. B. Prüf-Konto der Hochschule).
- Apple Pencil, echtes iPad, echte Stud.IP-/QIS-/CAS-Anmeldung: nur der Inhaber.
- Passwörter aus dem Chat vom 25.10. ändern (stehen im Verlauf).

## V2 (später)

Eigener UniFlow-Editor, Android/Windows, Google-/SMS-Anmeldung, Abgleich zwischen Geräten, Supabase als
Community-Dienst für alle Plattformen (hinter `CommunityService`), KI-Funktionen.
