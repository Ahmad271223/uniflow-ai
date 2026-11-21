# Übergabe 20.11.2026 abends – Stand StudiNow und alle offenen Arbeiten

Für die nächste Claude-Code-Sitzung (anderer Account). Dieses Repo ist **öffentlich**: hier stehen keine Schlüssel,
Passwörter, Tester-Adressen oder Inhalte der privaten Wissensbibliothek. Zuerst ganz lesen, dann
`docs/UEBERGABE-2026-11-14.md` (Befehle, Regeln) und `docs/release/BUILD-HERKUNFT.md`.

## 1. Was live ist

- **App Store:** Version **1.0.6** (Build 45, Commit `f5e21794`) seit 19./20.11.2026 für iPad, iPhone, Mac („Designed for
  iPad“). Credit-Pakete `de.uniflow.credits.klein`/`.gross` freigegeben. TestFlight-Gruppe „LUH-Tester“: öffentlicher
  Link aus (20.11.), Testversion läuft noch – erst beenden, wenn die Tester auf die App-Store-Version gewechselt sind.
- **Server** (Hetzner, `app.studinow.app`): läuft mit Stand `release/1.0.7` @ `2a238f0f` (Klausur-Generator-Routen,
  Prüfungsanmeldungen im Geräteabgleich, eigene Noten = 501 im Dienst, Datei-Eingang mit Stream/Parallel-Grenze).
  Deploy-Befehl und Sicherung: `docs/UEBERGABE-2026-11-14.md`. Eigener Eingangs-Server für Kursdateien läuft.
- **Website** `studinow.app`: Stand 1.0.6-Texte. Die 1.0.7-Texte (Datenschutz 4b/7/8d, AGB 5a) sind im Repo erzeugt,
  **noch nicht hochgeladen** (Upload nur durch den Inhaber: `bash tools/site-hochladen.sh`).

## 2. Version 1.0.7 – Zweig `release/1.0.7` (@ `54dae5a6`, auf GitHub)

Enthält (alles getestet, Editor-Teile vom Inhaber am iPad freigegeben):
Klausur-Generator (Pro AI, 15 Credits/Probeklausur), Mensa-Fotos (Studi|Futter), eigene Noten eintragen/abhaken
(nur Gerät, QIS gewinnt), Prüfungsanmeldungen im Geräteabgleich (ohne Noten/Ergebnisse/Prüfer, Hinweis „Stand von
deinem anderen Gerät“), Neu-Anmelden im Hintergrund (QIS, Stud.IP, LSF; ein Versuch), „Lösung daneben“ als echte
PDF-Ansicht (1:1, zoombar), Knopf „Ausblenden“ für eingeblendete Lösungen, Wochenkopf-Fix, Lasso ohne
Bildschirmtastatur, scharfe Handschrift bis 10-fach (Ausschnitt), Schrift haftet beim Zoomen (kein Umbau während des
Pinchens), CloudKit Production auch für Kabel-Fassungen, KI-Hilfe-Fixes, Abo-Downgrade-Hinweis.
Version/Build: `MARKETING_VERSION 1.0.7`, `CURRENT_PROJECT_VERSION 46` (noch nicht gebaut/hochgeladen).
Store-Texte, Prüfhinweis, Datenschutz/AGB für 1.0.7 sind eingetragen und vom Inhaber freigegeben.

## 3. Offene Arbeiten (Reihenfolge)

1. **NEU, dringend: Scrollen mit dem Finger hakt** seit „Schrift haftet beim Zoomen“/scharfer Ausschnitt
   (Befund Inhaber 20.11. abends). Verdacht: `PageInkView` in `apps/apple/UniFlow/Editor/PDFEditorController.swift`
   – `followViewport` (Ausschnitt wandert beim Scrollen und zeichnet Kacheln neu), Pinch-Hilfsfläche
   `showPinchUnderlay`, Deckbilder. Messen (Hauptthread-Pausen beim Scrollen bei 100 % und >400 %), beheben, ohne dass
   die Schrift beim Zoomen wieder verrutscht. Notschalter: `PencilTuning.sharpInkWindow = false` = Verhalten vor der
   Schärfe-Änderung (keine Ausschnitte). Vor Auslieferung dem Inhaber per Kabel am iPad zeigen.
2. **Wissensbank (nur LUH, Pro AI)** – Zweig `server/wissensbank` (@ `bb6666bc`, gepusht), Stand in
   `docs/WISSENSBANK-STAND.md`. Fehlt: 20 KI-Hilfe-Testklassen + volle Python-Suite erneut, Verlauf speichert
   Abzeichen/Frage nicht. Offene Entscheidungen des Inhabers: Urheberrecht prüfen lassen bevor `LERNAPP_WISSENSBANK`
   angeht; Musterlösungen der Lehrenden ausliefern ja/nein; Probe-Konten mit Wissensbank ja/nein. Die Bibliothek
   kommt per `tools/wissensbank-hochladen.sh` (vom Inhaber ausgeführt) nach `/data/wissensbank` auf den Server, nie
   ins Repo. Der Inhaber will die Wissensbank in 1.0.7 → nach Abschluss in `release/1.0.7` mischen.
3. **Speicher-Absicherung für 3-GB-iPads** (Auftrag Inhaber: „iPads dürfen nie wegen Arbeitsspeicher abstürzen“) –
   Zweig `app/speicher` angelegt, noch keine Änderung. Messen (300-Seiten-PDF, A0, 5 Tabs, 600 %, Lösung daneben,
   Mensa-Fotos), Obergrenzen je Gerät, zentraler Speicherwarnungs-Handler, Lecks. Bisher: auf dem iPad des
   Inhabers kein einziger Speicher-Absturz (nur ein behobener Hänger vom 17.11.).
4. **Eigene Wissensbibliothek-Ansicht** (nur für den Inhaber, lokal) – Zweig `app/wissensbibliothek` (@ `680f2795`,
   gepusht), Schalter standardmäßig aus, NICHT in 1.0.7 (Inhaber wählte „Wissensbank für alle“). Fragen dazu in
   `RUECKMELDUNG-MAC.md` im privaten Bibliotheks-Repo.
5. **1.0.7 abschließen:** nach 1.–2. komplette Tests (Python `tests`, Kern `swift test`, App `UniFlowTests` im
   Simulator), Build 46 archivieren und hochladen (Befehl: `docs/UEBERGABE-2026-11-14.md`, Bash-Skript nötig, weil
   zsh Variablen nicht aufteilt), Build in Version 1.0.7 wählen, Inhaber lädt Website hoch, dann einreichen (nur mit
   Okay). App Store Connect per API: `tools/asc.py`, `tools/store_einreichen.py texte|bilder|build|senden 1.0.7`.
6. **Danach:** TestFlight beenden (Okay), `release/1.0.7` nach `develop` mischen und pushen (nie nach `main` ohne Okay).

## 4. Bekannte wackelige Tests (nicht als Fehler werten, einzeln prüfen)

`tests/test_web_overview.py::test_overview_answers_what_to_do_today` (nur im Gesamtlauf),
`CommunityCorrectionWiringAppTests.testInboxBannerOnSpacePageOpensAndIgnores` (Simulator-Zustand; App im Simulator
deinstallieren hilft), `PurchaseTests…AskToBuy`, `StudyPlanLocalAppTests…Dashboard` unter iOS 26.2.

## 5. Regeln des Inhabers (Auszug, vollständig in den Übergaben und im Gedächtnis der alten Sitzung)

Antworten auf Deutsch, einfach. Veröffentlichen, Einreichen, Server-Deploy, Website-Upload, TestFlight-Änderungen
nur mit ausdrücklichem Okay im Chat. Kein Push auf `main`. Sichtbare Editor-Änderungen erst per Kabel am iPad des
Inhabers zeigen. Passwörter nur im Schlüsselbund des Geräts, nie selbst eintippen. Keine personenbezogenen Daten,
Schlüssel oder Bibliotheksinhalte ins (öffentliche) Repo. Noten: QIS ist Hauptquelle, eigene Einträge ergänzen.
Auf Inhaber-Geräten nur technische Zustände lesen. Bankdaten, Zahlungen, Passwörter: nie selbst eingeben.

## 6. Werkzeuge auf dem Mac (nicht im Repo)

Schlüssel/Zugänge liegen in `~/Studora-Builds/private_keys/` (App-Store-API-Schlüssel, Netlify) und `~/.ssh/`
(Server). Arbeits-Worktree mit `release/1.0.7`: `~/Studora-Builds/wt-aufraeumen`. Private Bibliothek:
`~/UniFlow/uniflow-wissensbibliothek`. Tester-Build per Kabel: Release-Build mit `-allowProvisioningUpdates` und
`xcrun devicectl device install app --device <UDID> <App>`; iPad des Inhabers: siehe `xcrun devicectl list devices`.

## 7. Andere Sitzungen und Hintergrundaufgaben (Stand 20.11. abends)

Alle Hintergrund-Helfer dieser Sitzung sind beendet; ihre Arbeit ist committet und gepusht (Zweige oben).
Der letzte laufende Testlauf (20 KI-Hilfe-Testklassen für die Wissensbank) wurde abgebrochen → in Punkt 3.2 neu laufen
lassen. Weitere Sitzungen in der Seitenleiste (Claude Desktop):

| Sitzung | Stand | Was noch zu tun ist |
|---|---|---|
| Klausur-Generator in der App | fertig, in `release/1.0.7` (über `app/klausur-generator` @ `229eb3b7`) | nichts; nach 1.0.7 archivieren |
| Mac-Version prüfen (Zweig `mac/lesbarkeit`, Worktree `claude/quizzical-mclean-f3e77a`) | Mac-Lesbarkeit + Demo hinter „Hilfe“ sind in 1.0.6/1.0.7 | offen nur: Inhaber soll sagen, **wo es am Mac ruckelt**; Mac auf App-Store-1.0.6 aktualisieren |
| Klausur-Generator auf dem Mac prüfen, Altklausur-Lösungen erkennen | alt (18.11.), Ergebnis im Klausur-Generator enthalten | archivieren |
| iPhone-Version, iPhone-Store-Bilder, Uni Hildesheim, Startseite, Smart Planner, Geteilte Ansicht, Verbundenes iPad, Mac-Tests Datenordner | alt (13.–15.11.), Inhalte längst in develop/1.0.6 | archivieren |
| Windows-App für den Microsoft Store (13.11.) | nicht abgeschlossen (Store-Upload) | nur wenn der Inhaber es wieder aufnimmt; Stand in jener Sitzung |

Worktrees mit ungesicherten Änderungen (alt, nicht wichtig, vor dem Löschen kurz ansehen):
`~/Studora-Builds/wt-absturz`, `~/Studora-Builds/wt-site-eingang`, `.claude/worktrees/confident-feynman-ae4f01`,
`.claude/worktrees/agent-a384073a1c5515e76`, `.claude/worktrees/agent-ac4e094ef6068094e`.
