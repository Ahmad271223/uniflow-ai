# Video und Lernseiten neben dem Dokument – Plan (14.11.2026)

Zweig `editor/video-lernseiten` (von develop `1c2fd03a`). Stand: Plan zur Freigabe durch den Inhaber, technische
Grundlage begonnen (siehe unten „Schon gebaut“). Nicht in develop, nichts gepusht, nichts zu Apple.

Wunsch des Inhabers (14.11.): neben dem Dokument ein Video (YouTube, Vorlesungsaufzeichnung) oder eine Lernseite
öffnen und dabei mitschreiben. Entscheidung: **nur Lernseiten, kein freier Browser.**

## 1. Aufbau

Dieselbe geteilte Ansicht wie „Blatt daneben“ und „Lösung daneben“ (`DocumentView.sidePane`, `SplitSides`): links oder
rechts, Breite ziehbar, Kopf mit Titel und X, Seiten tauschen über den Titel. Neu sind zwei Arten der Spalte:

| Spalte | Inhalt | Quelle |
|---|---|---|
| **Video** | ein einzelnes Video im eingebetteten Player | (a) YouTube-Link, eingefügt vom Nutzer; (b) Vorlesungsaufzeichnung aus den eigenen Kursen (Opencast, schon in der App, eigener Player ohne Browser) |
| **Lernseite** | eine Seite aus einer festen Liste | `packages/shared-contracts/learning-sites.json` (Grundstock in der App) |

Einstieg: „Geteilt“ › „Daneben öffnen“ bekommt zwei neue Abschnitte: „Video“ (Feld „Link einfügen“, darunter die
Aufzeichnungen des Moduls) und „Lernseite“ (Kacheln der erlaubten Seiten). Kein Wechsel des Tarifs nötig (siehe 6).

## 2. Video: was genau geht – und was gesperrt ist

- **Erlaubt als Link:** YouTube in allen üblichen Formen (`youtube.com/watch?v=…`, `youtu.be/…`, `/shorts/…`,
  `/live/…`, `/embed/…`, auch mit Startzeit `t=1m30s`). Andere Links: Hinweis „Nur YouTube-Links oder Aufzeichnungen
  deiner Kurse“. Playlists, Kanäle und Suchlinks werden abgelehnt.
- **Abspielen:** offizieller eingebetteter YouTube-Player im datenschutzfreundlichen Modus (`youtube-nocookie.com/embed`),
  in einer kleinen eigenen Seite mit Absender `https://studinow.app` (YouTube verlangt für eingebettete Player einen
  erkennbaren Absender). Werbung, Hinweise und Bedienelemente von YouTube bleiben unverändert; nichts wird
  heruntergeladen.
- **Gesperrt:** keine YouTube-Startseite, keine Suche, keine Vorschläge zum Weiterklicken innerhalb der App. Jeder Weg
  aus dem Video heraus (YouTube-Logo, „Auf YouTube ansehen“, Links in der Beschreibung, neue Fenster) öffnet **außerhalb
  der App** in Safari bzw. der YouTube-App. Technisch: `WKNavigationDelegate` erlaubt im Hauptrahmen nur die eigene
  Player-Seite, im Player-Rahmen nur die Adressen des Players (`VideoSidePolicy`).
- **Aufzeichnungen der Hochschule:** über den vorhandenen Opencast-Weg (`RecordingLibrary`, `AVPlayerViewController`),
  geladen oder gestreamt wie heute im Moduldetail – kein Browser.
- **Gemerkt:** Der Video-Link wird am Dokument gemerkt (nur auf diesem Gerät, im Container; nicht an unseren Dienst).
  Beim nächsten Öffnen bietet „Daneben öffnen“ „Zuletzt hier: <Titel>“ an.
- **Stelle im Video (Stufe 2):** Knopf „Zeit merken“ im Kopf der Video-Spalte setzt auf der gerade angezeigten
  Notizseite ein Textfeld „▶ 12:30“; antippen springt im Video dorthin. Die Zuordnung Seite → Zeit liegt lokal.

## 3. Lernseite: Liste und Sperre

Feste, von uns gepflegte Liste. Grundstock (Vorschlag, je mit Begründung):

| Seite | Hosts | Warum |
|---|---|---|
| Webseite der eigenen Hochschule | LUH `uni-hannover.de`, Hildesheim `uni-hildesheim.de`, HsH `hs-hannover.de` | Modul-, Prüfungs- und Lehrstuhlseiten; nur die gewählte Hochschule wird angezeigt |
| Bibliothek der eigenen Hochschule | LUH: TIB-Portal `tib.eu`; Hildesheim: Universitätsbibliothek (unter `uni-hildesheim.de`); HsH: Bibliothek (unter `hs-hannover.de`) | Literatur zum Skript suchen; Katalog statt Suche im ganzen Netz |
| Wikipedia (Deutsch, Englisch) | `de.wikipedia.org`, `en.wikipedia.org`, `de.m.wikipedia.org`, `en.m.wikipedia.org` | Begriffe nachschlagen |
| Duden | `duden.de` | Rechtschreibung, Bedeutung |
| LEO Wörterbuch | `dict.leo.org` | Übersetzen von Fachbegriffen (Wörterbuch, kein KI-Übersetzer) |
| GeoGebra Rechner | `geogebra.org` | Rechnen, Graphen, Geometrie |
| Serlo | `de.serlo.org` | freie, gemeinnützige Erklärseite, vor allem Mathematik |

Bewusst **nicht** in der Liste: Suchmaschinen (Google, Google Scholar, Bing), KI-Dienste (ChatGPT, DeepSeek, DeepL,
Google Translate, NotebookLM – StudiNow hat eine eigene KI), soziale Netze, Shops, YouTube als Startseite.

**Sperre:**
- keine Adresszeile, kein Eintippen eigener Adressen, keine Suche über das ganze Netz; Kopf: Titel, Zurück,
  „Startseite der Lernseite“, „In Safari öffnen“, X.
- Navigation im Hauptrahmen nur auf Hosts der gewählten Seite (genau der Host oder eine Unterdomain der Liste),
  nur `https`. Alles andere wird nicht geladen, sondern **außerhalb der App** geöffnet (`LearningSitePolicy`).
- Unterrahmen (eingebettete Inhalte) nur von Hosts derselben Seite; neue Fenster (`target=_blank`) außerhalb.
- Downloads werden nicht in der App angezeigt.
- Die eigene Suche einer Seite (z. B. in Wikipedia, im Bibliothekskatalog) bleibt erlaubt – die Ergebnisse bleiben
  auf derselben Seite.

**Pflege ohne App-Update:** Die Liste liegt in `packages/shared-contracts/learning-sites.json` und ist in die App
eingebaut (Grundstock). Stufe 2: der StudiNow-Dienst liefert dieselbe Datei aus (`GET /api/learning-sites`), die App
übernimmt sie nur, wenn sie gültig ist (nur `https`, keine leeren Hosts, keine Platzhalter wie `*`), sonst bleibt der
Grundstock. Das braucht ein Dienst-Update (Freigabe des Inhabers).

## 4. Altersfreigabe

„Uneingeschränkter Webzugang“ bleibt **nein**: Es gibt keinen freien Browser, keine Adresszeile und keine Suche über
das Netz; jede Lernseite ist auf ihre eigenen Hosts begrenzt, YouTube nur als einzelnes eingebettetes Video. Vorschlag
für die Begründung in `docs/release/APP-STORE.md` (Tabelle Altersfreigabe):

> Webansichten nur für die Anmeldeseiten der Hochschulen, für einzelne YouTube-Videos im offiziellen eingebetteten
> Player und für eine feste Liste von Lernseiten (Hochschule, Bibliothek, Wikipedia, Wörterbücher, Rechner), jeweils
> auf deren eigene Adressen begrenzt, ohne Adresszeile und ohne Suche im Netz; alle anderen Links öffnen außerhalb der
> App.

Offene Frage: Wikipedia enthält Artikel zu allen Themen. Mit begrenzten Hosts ist das kein freier Webzugang; wer ganz
sicher gehen will, lässt Wikipedia beim ersten Schritt weg (Entscheidung 3).

## 5. Datenschutz

- Kein Verlauf, keine Adressen und keine Video-Links an den StudiNow-Dienst. Video-Link je Dokument nur auf dem Gerät.
- Eigener Datenspeicher für Lernseiten und Videos (`WKWebsiteDataStore(forIdentifier:)` je Container), **getrennt** von
  den Anmeldungen der Hochschule; keine Übernahme von Uni-Zugangsdaten oder -Cookies, kein Autologin, kein Skript, das
  in Formulare schreibt. Ein Knopf „Daten der Lernseiten löschen“ in den Einstellungen (Stufe 2).
- YouTube (Google Ireland Limited) wird Drittanbieter: beim Abspielen erhält YouTube IP-Adresse, Geräteangaben und
  das Video; der datenschutzfreundliche Modus setzt Cookies erst beim Abspielen. Lernseiten erhalten beim Aufruf
  dieselben Angaben wie bei jedem Seitenaufruf.

**Vorschlag für die Datenschutzerklärung** (neuer Absatz, z. B. in Abschnitt 12 „Empfänger“ – nicht von mir geändert):

> **Videos und Lernseiten neben dem Dokument (iPad).** Wenn du neben einem Dokument ein YouTube-Video öffnest, lädt die
> App den eingebetteten Player von YouTube (Google Ireland Limited, Gordon House, Barrow Street, Dublin 4, Irland) im
> erweiterten Datenschutzmodus. Dabei erhält YouTube deine IP-Adresse, Angaben zu deinem Gerät und das gewählte Video;
> Cookies setzt YouTube erst, wenn du das Video abspielst. Für die Verarbeitung durch YouTube gilt die
> Datenschutzerklärung von Google. Öffnest du eine Lernseite aus unserer Liste (z. B. Wikipedia, Duden, die Webseite
> deiner Hochschule), ruft die App diese Seite direkt ab; der Betreiber erhält die bei jedem Seitenaufruf üblichen
> Angaben. Video-Links, besuchte Seiten und Cookies dieser Ansichten bleiben auf deinem Gerät, in einem eigenen
> Speicher getrennt von deinen Hochschul-Anmeldungen; wir erhalten davon nichts.

**App-Datenschutz (Nutrition Labels):** keine Änderung – wir erfassen nichts Neues; YouTube und die Lernseiten sind
Seiten, die der Nutzer selbst aufruft (wie ein Link). Vorsichtshalber im Abschnitt „Drittanbieter“ erwähnen.

## 6. Tarif (Vorschlag, Entscheidung beim Inhaber)

Vorschlag: **Plus**, wie „Übung und Skript nebeneinander“ (`UFFeature.splitView`) – es ist dieselbe geteilte Ansicht.
In Free steht der Eintrag mit Schloss („ab Plus“). Alternative: Video in Free, Lernseiten in Plus (mehr Anreiz zum
Ausprobieren, aber zwei Regeln für dieselbe Ansicht).

## 7. Geräte

- **iPad** zuerst.
- **Mac** („Designed for iPad“) läuft mit: dieselben Spalten; Blätter nur über `ufSheet`/`ufPopover`.
- **iPhone** (ohne Editor): Vorschlag für später – Video über dem Leser (oben das Video, darunter das Dokument),
  Lernseiten als eigenes Blatt. Nicht im ersten Schritt.

## 8. Offene Entscheidungen für den Inhaber

1. Liste der Lernseiten wie oben? (streichen, ergänzen)
2. Tarif: Plus für beides (Vorschlag) oder Video in Free?
3. Wikipedia im ersten Schritt dabei?
4. „Zeit merken“ (Stelle im Video zur Notizseite) gleich mit, oder erst Stufe 2?
5. Video-Link nur auf dem Gerät (Vorschlag) oder über den Geräteabgleich auf alle Geräte?

## 9. Schon gebaut (technische Grundlage, ohne fertige Oberfläche)

- `VideoLink`: YouTube-Links erkennen (alle Formen, Startzeit), alles andere ablehnen.
- `VideoSidePolicy` / `LearningSitePolicy`: Entscheidung je Navigation (in der Spalte laden, außerhalb öffnen,
  verwerfen), reine Funktionen mit Tests.
- `learning-sites.json` (Grundstock) + `LearningSites` (lesen, prüfen, nach Hochschule filtern).
- Spalten `VideoSidePane` und `LearningSitePane` mit eigenem Datenspeicher, Einstieg unter „Daneben öffnen“
  (vorläufig, Gestaltung nach Freigabe).
- Datenspeicher der Spalten wird beim Löschen eines Containers mit entfernt (`ContainerManager.removeWebsiteData`).
- Tests: `VideoLearningSitesAppTests` 9/9 (Link-Erkennung, Sperre Video und Lernseite inkl. Host-Tricks, Liste =
  `shared-contracts`, keine Suchmaschinen/KI-Dienste, Datenspeicher getrennt, Link je Dokument);
  `UniFlowUITests/WebSideUITests` mit echten Berührungen: Wikipedia daneben öffnen und schließen, YouTube-Link einfügen,
  Video daneben, schließen. Dazu grün: `ViewTypeDepthAppTests`, `SplitSidesAppTests`, `SheetGateAppTests`.
  (Volle Suite noch nicht – auf dem Rechner lief der Testlauf für Build 42.)
- Bilder: `~/Studora-Builds/video/bilder/` (1 Auswahl, 2 Wikipedia daneben, 3 YouTube-Video daneben).
