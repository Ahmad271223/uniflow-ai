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

**Ausgangslage.** Apple fragt im Fragebogen nach „Unrestricted Web Access“ und meint damit, dass Nutzer in der App
beliebige Webseiten öffnen bzw. frei surfen können (eingebettete Browser-Funktion). Eine Apple-Quelle, die eine feste
Liste ausdrücklich ausnimmt, haben wir nicht. Die Antwort „nein“ stützt sich deshalb auf das, was die App technisch
zulässt – und das ist mit Tests belegt:

| Merkmal eines Browsers | StudiNow |
|---|---|
| Adresszeile, beliebige Adresse eintippen | gibt es nicht |
| Suche im ganzen Netz | gibt es nicht (keine Suchmaschine in der Liste) |
| Links zu anderen Seiten folgen | nein: jede Navigation außerhalb der Hosts der gewählten Seite öffnet außerhalb der App (Safari); eingebettete fremde Rahmen werden nicht geladen (`LearningSitePolicy`, Tests) |
| neue Fenster, Downloads | nein (außerhalb der App bzw. gar nicht) |
| YouTube | nur ein einzelnes Video im offiziellen eingebetteten Player; Startseite, Suche, andere Videos öffnen außerhalb (`VideoSidePolicy`, Tests) |
| Liste der Seiten | fest, von uns gepflegt, im Code geprüft (nur `https`, keine Platzhalter, keine Suchmaschinen/KI-Dienste – Test bricht sonst) |

**Vorschlag Prüfhinweis (App Review Notes, Englisch):**

> StudiNow does not contain a general-purpose web browser. Next to a document, students can open (1) a single YouTube
> video they paste a link to, played in YouTube's official embedded player (privacy-enhanced mode), and (2) one page
> from a fixed, curated list of learning sites (their university's website and library, Wikipedia, Duden, LEO
> dictionary, GeoGebra calculator, Serlo). There is no address bar and no web search. Navigation is restricted to the
> hosts of the chosen site; any link to another site, the YouTube logo or "Watch on YouTube" opens outside the app in
> Safari. University sign-in pages are shown only for logging in. We therefore answer "Unrestricted Web Access" with No.

**Vorschlag für `docs/release/APP-STORE.md`, Zeile „Uneingeschränkter Webzugang“ (nein), Begründung:**

> Webansichten nur für die Anmeldeseiten der Hochschulen, für einzelne YouTube-Videos im offiziellen eingebetteten
> Player und für eine feste Liste von Lernseiten (Hochschule, Bibliothek, Wikipedia, Duden, LEO, GeoGebra, Serlo),
> jeweils auf deren eigene Adressen begrenzt, ohne Adresszeile und ohne Suche im Netz; alle anderen Links öffnen
> außerhalb der App.

**Wikipedia – Einschätzung.** In der Spalte bleiben Wikipedia-Suche und Links zwischen Artikeln erlaubt (dieselben
Hosts `de.wikipedia.org`/`de.m.wikipedia.org`); Einzelnachweise, Weblinks, Wikimedia Commons, Spendenseiten und alles
andere öffnen außerhalb der App (Test: andere Hosts → außerhalb, Unterrahmen → nicht geladen). Das ist **kein freies
Surfen**: Man kommt nie auf eine andere Seite als Wikipedia, und es gibt keine Suche über das Netz.

Eine Begrenzung auf „einen gesuchten Artikel lesen“ empfehle ich **nicht**: Die Wikipedia-Suche erreicht ohnehin
jeden Artikel, die Begrenzung änderte also nicht, welche Inhalte erreichbar sind, nähme aber das Nachschlagen
verwandter Begriffe (Links im Artikel) weg. Der eigentliche Punkt für die Freigabe ist nicht das Surfen, sondern der
**Inhalt**: Wikipedia hat Artikel zu allen Themen, auch zu Sexualität, Drogen oder Gewalt (sachlich, als Lexikon). Wenn
Apple das als Inhalt der App wertet, beträfe es die Fragen zu Inhalten, nicht „Webzugang“. Unsere Zielgruppe sind
Studierende (Datenschutzerklärung: nicht unter 16), eine höhere Stufe wäre unkritisch. Entscheidung des Inhabers:
Wikipedia von Anfang an dabei.

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

## 6. Tarif (entschieden: Plus)

Vorschlag: **Plus**, wie „Übung und Skript nebeneinander“ (`UFFeature.splitView`) – es ist dieselbe geteilte Ansicht.
In Free steht der Eintrag mit Schloss („ab Plus“). Alternative: Video in Free, Lernseiten in Plus (mehr Anreiz zum
Ausprobieren, aber zwei Regeln für dieselbe Ansicht).

## 7. Geräte

- **iPad** zuerst.
- **Mac** („Designed for iPad“) läuft mit: dieselben Spalten; Blätter nur über `ufSheet`/`ufPopover`.
- **iPhone** (ohne Editor): Vorschlag für später – Video über dem Leser (oben das Video, darunter das Dokument),
  Lernseiten als eigenes Blatt. Nicht im ersten Schritt.

## 8. Entscheidungen des Inhabers (14.11.2026, Plan freigegeben: „Ja, so bauen“)

1. Liste der Lernseiten: wie vorgeschlagen.
2. Tarif: Plus für Video und Lernseiten (wie „Übung und Skript nebeneinander“); Free sieht den Eintrag mit Schloss
   „(ab Plus)“, Antippen öffnet die Tarifwahl.
3. Wikipedia: von Anfang an dabei.
4. „Zeit merken“: zweiter Schritt, jetzt nicht gebaut; das gespeicherte Format trägt die Zeitmarken schon
   (`DocumentVideoRecord.marks`, Version 1).
5. Video-Link: nur auf dem Gerät, kein Abgleich.

## 9. Gebaut (Stand 14.11.2026)

- **Einstieg:** „Mehr“ › „Video oder Lernseite daneben …“ (Free: mit Schloss, öffnet die Tarifwahl) und „Geteilt“ ›
  „Daneben öffnen“. Mit dem Menüeintrag stehen Video und Lernseiten oben.
- **Auswahl:** Video (YouTube-Link einfügen, „Zuletzt hier“, Aufzeichnungen des Moduls aus Opencast) und Lernseiten in
  Gruppen „Deine Hochschule“, „Nachschlagen“, „Rechnen und Üben“.
- **Spalten:** YouTube-Video (offizieller Player, Hinweis, „Auf YouTube öffnen“), Aufzeichnung (vorhandener Player
  ohne Browser, Kopf der Spalte mit X), Lernseite (Zurück, Startseite, „In Safari öffnen“, X; keine Adresszeile).
- **iPhone:** nicht gebaut; Vorschlag: Video über dem Leser (oben das Video, darunter das Dokument), Lernseiten als
  eigenes Blatt.

## 10. Erste Grundlage (vor der Freigabe)


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

## 11. Tests (Stand Oberfläche, 14.11.2026)

- Nur einzelne Testklassen auf eigenem Simulator-Klon (auf dem Rechner lief der volle Lauf für Build 42):
  `VideoLearningSitesAppTests` 13/13 (u. a. Wikipedia bleibt Wikipedia, Format für Zeitmarken, Schloss für Free),
  zusammen mit `ViewTypeDepthAppTests`, `SheetGateAppTests`, `LockVisibilityAppTests`, `SplitSidesAppTests`,
  `NotesExportAppTests`: 44/44.
- `UniFlowUITests/WebSideUITests` 2/2 mit echten Berührungen (Lernseite und Video über „Daneben öffnen“; Einstieg über
  „Mehr“ › „Video oder Lernseite daneben …“).
- Volle Suite: steht aus (fährt die Hauptsitzung auf dem Kandidaten).
- Bilder: `~/Studora-Builds/video/bilder/` – 4 Auswahl Video/Lernseiten, 5 Video-Spalte, 2 Wikipedia daneben.

## 12. 17.11.2026: YouTube direkt öffnen

Auftrag des Inhabers (17.11.2026, wörtlich): „kannst du statt YouTube-Link dazu YouTube öffnen selber, dann können die
selber YouTube öffnen“. Ergänzung am selben Tag: „ganzen Änderungen auf iPhone-App auch umsetzen und macOS“.
Zweig `editor/youtube-oeffnen` (von develop `13f11669`). Nicht in develop, nichts gepusht, nichts zu Apple.

**Das ändert die Entscheidung vom 14.11.** („keine YouTube-Startseite, keine Suche, keine Vorschläge in der App“,
Abschnitt 2 „Gesperrt“ und die Zeile „YouTube“ in der Tabelle von Abschnitt 4): In der Spalte „YouTube“ gibt es jetzt
Startseite, Suche, Vorschläge, Kurzvideos und Kanäle von YouTube. Es bleibt dabei: kein allgemeiner Browser, keine
Adresszeile, nur YouTube.

### Was sich ändert

- **Haupteinstieg:** Knopf „YouTube öffnen“ im Abschnitt „Video“ (unter „Daneben öffnen“ bzw. „Video oder Lernseite
  daneben …“). Er lädt die mobile YouTube-Seite `https://m.youtube.com/` in der Spalte neben dem Dokument.
- **Kopf der Spalte:** Zurück, Vor, Neu laden, Startseite von YouTube, „…“ (Auf YouTube öffnen (außerhalb der App),
  YouTube-Daten löschen), X. Keine Adresszeile, keine freie Eingabe von Adressen.
- **Nur YouTube** (`YouTubeSidePolicy` in `WebSideRules.swift`, reine Funktionen mit Tests):

  | Navigation | Was geschieht |
  |---|---|
  | `m.youtube.com`, `www.youtube.com`, `youtube.com`, `youtu.be` (Start, Suche, Video, Kurzvideo, Kanal, Playlist), nur `https` | bleibt in der Spalte |
  | `consent.youtube.com` (Einwilligung von YouTube) | bleibt in der Spalte |
  | jede andere Seite (Links in Beschreibungen, YouTubes Weiterleitung `/redirect`, Kanal-Links nach außen, Werbung, „App öffnen“, `policies.google.com`, `music.`/`studio.youtube.com`) | wird nicht geladen, öffnet außerhalb der App |
  | Anmelden bei Google (`accounts.google.*`, `accounts.youtube.com`, `myaccount.google.com`, YouTube-Pfad `/signin…`) | wird nie geladen; unten in der Spalte der Hinweis „Anmelden geht hier nicht“ mit „Außerhalb öffnen“. Die App sieht nie ein Passwort |
  | `javascript:`, `data:`, `file:`, `blob:`, App-Adressen (`youtube://`) | verworfen |
  | eingebettete Rahmen | nur von YouTube/Google (Player, Einwilligung, Werbung); fremde Rahmen und versteckte Anmelde-Rahmen werden nicht geladen |
  | Täuschungs-Hosts (`youtube.com.evil.example`, `evil-youtube.com`, `youtube.com@evil.example`) | nie in der Spalte |

  Bilder, Skripte und Videodaten (`ytimg.com`, `googlevideo.com`, `gstatic.com`) lädt die YouTube-Seite als
  Unterressourcen selbst; dazu fragt WebKit die App nicht. Die App blendet nichts aus und setzt kein eigenes Skript in
  die Seite – Werbung, Einwilligung und Bedienelemente von YouTube bleiben, wie sie sind.
- **Hinweis vor dem ersten Öffnen** (einmal je Nutzer-Datenbereich, gemerkt nur auf dem Gerät): „YouTube ist ein Dienst
  von Google. Wenn du YouTube öffnest, werden Daten an Google übertragen, zum Beispiel deine IP-Adresse, Angaben zu
  deinem Gerät und was du suchst und ansiehst. Über Cookies und Einwilligung entscheidest du auf der Seite von YouTube
  selbst.“ – „Öffnen“ / „Abbrechen“. Solange der Hinweis steht, gibt es keine Web-Ansicht: vorher geht nichts an YouTube.
- **iPhone** (Leseansicht, keine Spalte): neuer Knopf „Video oder Lernseite“ im Kopf der Leseansicht (Plus wie am iPad,
  sonst die Tarifwahl). Die Auswahl ist dieselbe (YouTube öffnen, Zuletzt hier, Aufzeichnungen, Link einfügen,
  Lernseiten); das Video bzw. die Seite steht **über dem Dokument** (quer: links daneben), der Griff dazwischen
  verschiebt die Teilung, X schließt. Damit gibt es Video und Lernseiten jetzt auch am iPhone.
- **Mac** („Designed for iPad“): dieselbe Spalte und derselbe Knopf wie am iPad, kein eigener Code.

### Entscheidung: Was passiert beim Antippen eines Videos?

**Es spielt direkt auf der YouTube-Seite in der Spalte** (nicht Wechsel in den eingebetteten Player). Gründe:

1. YouTube wechselt zwischen Suche und Video, ohne die Seite neu zu laden. Die App erfährt den Wechsel nur nachträglich
   über die Adresse; ein Umschalten in den eingebetteten Player hieße: das Video lädt zweimal, die Spalte springt.
2. Der eingebettete Player zeigt viele Videos gar nicht (Einbetten vom Kanal abgeschaltet, Altersbeschränkung).
3. Für den Nutzer ist es ein Ort: Zurück führt zu den Suchergebnissen, das nächste Video ist einen Tipp entfernt.
4. Die Seite von YouTube bleibt unverändert – das ist gegenüber YouTube die sauberste Lage.

Preis dafür: Vorschläge, Kurzvideos und Kommentare von YouTube stehen in der Spalte (Ablenkung; siehe Altersfreigabe).
Wer nur ein einzelnes Video ohne alles drumherum will, nimmt weiter „Link einfügen“.

**„Zuletzt hier: YouTube-Video“** geht in beiden Fällen: Ein auf der YouTube-Seite geöffnetes Video (`/watch?v=…`)
wird am Dokument gemerkt (nur auf dem Gerät, `DocumentVideoRecord.onYouTube`) und öffnet wieder auf der YouTube-Seite;
ein eingefügter Link öffnet wie bisher im eingebetteten Player mit Startzeit. Kurzvideos, Kanäle und Suchen werden
nicht gemerkt. Die Stelle im Video merkt die App bei YouTube-Seiten nicht (dafür müsste sie in die Seite hineinlesen).

### Entscheidung: Datenspeicher

Die YouTube-Spalte nutzt **denselben eigenen, dauerhaften Speicher wie die Lernseiten** (`WebSideStore`, je
Nutzer-Datenbereich, getrennt von den Hochschul-Anmeldungen und vom Standardspeicher; wird mit dem Datenbereich
gelöscht). Gründe: Die Antwort auf YouTubes Einwilligungsfrage bleibt erhalten – auch ein „Alle ablehnen“ – und muss
nicht bei jedem Start neu gegeben werden. Ein flüchtiger Speicher würde jedes Mal neu fragen. Weil Anmelden in der
Spalte nicht geht, hängen die Cookies an keinem Google-Konto. Im Simulator beobachtet: YouTube zeigt nach dem ersten
Video eine Startseite mit Vorschlägen aus dem bisher Angesehenen – YouTube erkennt das Gerät also über seine Cookies
wieder. Dagegen gibt es in der Spalte unter „…“ **„YouTube-Daten löschen“** (entfernt Cookies und gespeicherte Daten
von YouTube/Google aus diesem Speicher; Lernseiten bleiben). An den StudiNow-Dienst geht weiterhin nichts.

### Abspielen

Inline in der Spalte (kein erzwungenes Vollbild), Bild-in-Bild erlaubt, Vollbild über den Knopf des Players möglich
(`isElementFullscreenEnabled`), mobile Fassung der Seite (`preferredContentMode = .mobile`, sonst fragt das iPad wie
ein Mac und bekäme die breite Seite). Das Video läuft weiter, während man im Dokument schreibt. Ton bei geschlossener
App: nein – die App hat keine Hintergrund-Freigabe für Ton, und YouTube erlaubt Hintergrund-Wiedergabe nur mit Premium.

### Was gleich bleibt

- „YouTube-Link einfügen“ (kleiner, als zweite Möglichkeit) mit eingebettetem Player `youtube-nocookie.com`, Startzeit
  und `VideoSidePolicy` – unverändert. Ebenso „Auf YouTube öffnen (außerhalb der App)“ und die Aufzeichnungen der Kurse.
- Lernseiten: Liste, `LearningSitePolicy`, kein Eintrag „YouTube“ in `learning-sites.json` (der Test verbietet ihn weiter).
- Tarif: Plus wie „Übung und Skript nebeneinander“. Nichts an den Dienst, kein Abgleich zwischen Geräten.

### Was vor einer Einreichung zu klären ist (nicht geändert, nur benannt)

- **Altersfreigabe / Prüfhinweis:** Der Vorschlag für den Prüfhinweis in Abschnitt 4 („a single YouTube video …
  There is no … web search“) stimmt so nicht mehr. Siehe Bericht vom 17.11.2026 zu „Uneingeschränkter Webzugang“,
  „Nutzergenerierte Inhalte“ und „Werbung“.
- **Datenschutzerklärung:** Sie nennt YouTube bisher nicht. Der Textvorschlag in Abschnitt 5 beschreibt nur den
  eingebetteten Player; für „YouTube öffnen“ braucht es zusätzlich: Die App lädt die Seite von YouTube
  (`youtube.com`), nicht nur den Player im erweiterten Datenschutzmodus; YouTube setzt Cookies nach seiner eigenen
  Einwilligungsabfrage; sie bleiben auf dem Gerät in einem eigenen Speicher, bis der Nutzer sie löscht.
- **Nutzungsbedingungen von YouTube** (Seite in einer Web-Ansicht, Funktion hinter Plus): siehe Bericht.

### Tests und Bilder (17.11.2026)

- `VideoLearningSitesAppTests` (Regeln: YouTube erlaubt, fremde Seiten außerhalb, Täuschungs-Hosts, unsichere
  Adressen, Anmeldung, Rahmen und Unterressourcen, Merken, Hinweis, Web-Ansicht, iPhone-Texte) und `IPhoneReaderTests`
  (Knopf, Auswahl, Hinweis über dem Dokument ohne Web-Ansicht, Tarifwahl ohne Plus).
- `UniFlowUITests/WebSideUITests`: `testYouTubeBesideDocument` (iPad) und `testYouTubeAboveReaderOnPhone` (iPhone) mit
  echtem Netz. Sie hängen an den deutschen Beschriftungen der YouTube-Seite.
- Bilder: `~/Studora-Builds/aufraeumen-17-11/youtube/`.
