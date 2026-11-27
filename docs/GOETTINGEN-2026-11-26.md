# Uni Göttingen in StudiNow (Stand 26.11.2026)

Zweig `uni/goettingen` (lokal, nicht gepusht), abgezweigt von `release/1.0.8-alles` (b1682e3a), am 26.11.2026 abends
mit dem damaligen Stand von `release/1.0.8-alles` (51571948) gemischt. Arbeitsordner `~/Studora-Builds/wt-goettingen`.

**Inhaber 26.11.2026 abends:** „dann bau das für Uni Göttingen fertig, binde ein, das soll übermorgen mit reinkommen, die
anderen Sachen ziehen wir nach“. Darum ist Göttingen jetzt **auch im Release-Build zur Wahl**
(`UF_SHIPPED_UNIVERSITIES: "luh hildesheim goettingen"`). Noten, Bescheinigungen, Mail und Mediacast kommen später.

**Nachtrag 26.11.2026 (Inhaber, in einer anderen Sitzung auf die Frage „Soll Göttingen erst nach Build 50 kommen?“):
„Ja, danach“.** Göttingen gehört also **nicht in Build 50 / 1.0.8**, sondern in einen späteren Build; welcher genau (51
oder 53/54), klärt der Inhaber noch. Die Release-Einstellung oben gilt nur auf diesem Zweig.

**Neue Entscheidung 26.11.2026 ca. 21:10 (Inhaber in der Build-Sitzung, wörtlich): „Noch in 1.0.8“** – Göttingen kommt
mit 1.0.8 (Build 51). Davor: „kann man Göttingen auch schon rausbringen … mit Verweis bei Göttingen, dass aktuell nur
folgende Funktionen vorhanden sind und bei technischer Möglichkeit, welche wir aktuell prüfen, nachgezogen werden, auch
auf der Startseite soll das stehen, also Webseite“. Der Nachtrag „Ja, danach“ oben gilt damit nicht mehr. Umgesetzt:
- **Hinweis in der App** (`UFUniversityScope.newNotice`, Kasten `UFUniversityNewNotice`): bei der Hochschulwahl beim
  ersten Start (sobald Göttingen gewählt ist), im Dialog „Hochschule wechseln“, in der Karte „Hochschule“ der Einstellungen
  und oben auf „Uni & Noten“. Wortlaut: „Universität Göttingen – neu in StudiNow. Schon dabei: Stud.IP mit Kursen,
  Dateien, Stundenplan, Terminen, Nachrichten, Ankündigungen und Lehrenden, dazu das Schwarze Brett und der Speiseplan der
  Mensen (noch ohne Preise). Alle Lernfunktionen von StudiNow – Editor, Notizen, Karteikarten und je nach Tarif die KI –
  gehen wie an jeder anderen Hochschule. Noch nicht dabei: Noten und Prüfungsanmeldung (FlexNow), Bescheinigungen und
  Vorlesungsverzeichnis (eCampus), Uni-Mail und Vorlesungsaufzeichnungen. Wir prüfen gerade, wie wir sie technisch
  anbinden können, und ergänzen sie, sobald das möglich ist.“ Kein Datum (Test `testNewUniversityNotice`).
- **Website** (`docs/release/STARTSEITE.md` → `site/index.html`, nur im Zweig, **nicht hochgeladen**): Zeile „Heute
  angebunden“ mit „Neu: Universität Göttingen mit Stud.IP und Mensa“, Vertrauensleiste, Absatz `#goettingen` im
  Abschnitt „Alles aus der Uni“ mit demselben Hinweis, Mensa-Quellen mit dem Studierendenwerk Göttingen, Frage „Für welche
  Hochschulen ist StudiNow?“. Hochladen erst, wenn 1.0.8 im App Store ist (macht die Build-Sitzung); der Live-Stand liegt
  in `~/Studora-Builds/wt-site-neuheiten` und ist hier nicht angefasst.
- `release/1.0.8-alles` bis 52ff61a3 (Build 50 eingetragen, Rechtstexte) ist eingemischt, ohne Konflikte.

Grundlagen (nur auf dem Mac, nicht im Repo):
- `~/Studora-Builds/goettingen/STRUKTUR-ECHT-STUDIP-2026-11-26.md` – echtes Stud.IP Göttingen (drei Blicke) und der
  öffentliche Speiseplan des Studierendenwerks
- `~/Studora-Builds/goettingen/STRUKTUR-ECHT-FLEXNOW-2026-11-26.md` – FlexNow 2 nach der Anmeldung (nur Aufbau)
- `~/Studora-Builds/goettingen/RECHERCHE-GOETTINGEN-2026-11-26.md` – öffentliche Recherche (nicht nachgeprüft)

## 1. Kurz

- Göttingen ist die vierte Hochschule (`UniversityKey.goettingen`) mit eigenem Datenbereich, eigener Anmeldung und dem
  vorhandenen Stud.IP-Abgleich. Zur Wahl in Debug und (seit 26.11.2026 abends) im Release-Build.
- Was über Stud.IP geht, ist eingebaut: Kurse, Ordner und Dateien samt Download, Stundenplan, Kalender, Kurstermine,
  Nachrichten, Neuigkeiten/Änderungen, Lehrende, Schwarzes Brett. Dazu der Mensaplan (ohne Preise).
- Was Göttingen nicht in Stud.IP hat (Noten, Bescheinigungen, E-Mail, Mediacast-Videos), ist in der App ausgeblendet
  bzw. durch eine ruhige Karte „gibt es hier noch nicht – hier öffnen“ ersetzt.

### Vor dem Einreichen (Pflicht)

1. **Server-Update (nur mit Okay des Inhabers; Entscheidung 26.11.2026: erst direkt vor der Veröffentlichung von 1.0.8):** Der laufende StudiNow-Dienst kennt `goettingen` nicht. Ein neuer
   Göttinger Nutzer bekäme beim Anlegen des StudiNow-Kontos „Unbekannte Hochschule“ (`university_unknown`) – keine KI,
   keine Probe über das Konto. Nötig sind aus diesem Zweig `app/universities.py`, `app/config.py`, `app/account_api.py`,
   `app/server.py`, `app/mensa.py`, `app/mensa_api.py`, `app/holidays.py`, `app/studip_lecturers.py`, `app/rooms.py` und die Daten `packages/shared-contracts/mensa.json`,
   `rooms.json` (Tests: `tests/test_goettingen.py`, `tests/test_mensa.py`, `tests/test_account_contract.py`). Der Rest
   des Dienstes ändert sich nicht; Hannover/Hildesheim sehen in der Web-App weiter nur ihre Hochschulen und Mensen.
2. **Einmal mit echtem Konto in der App:** Der Inhaber meldet sich in der Testfassung selbst bei Stud.IP Göttingen an,
   ein Abgleich läuft durch. Bis dahin ist nur gegen die Nachbildung geprüft (Abschnitt 3).
3. **Datenschutz (Website):** `docs/release/DATENSCHUTZ.md` Abschnitt 4b nennt jetzt das Studierendenwerk Göttingen als
   Quelle des Speiseplans; `site/datenschutz.html` ist in diesem Zweig neu erzeugt (`tools/gen-site.py`). Live ist aber der
   Stand aus `~/Studora-Builds/wt-site-neuheiten` (uncommittet) – dort denselben Satz in Abschnitt 4b nachtragen; hochladen
   nur durch den Inhaber (`tools/site-hochladen.sh`).
4. **Store-Texte (nur Entwurf, nicht in `APP-STORE.md` und nicht bei Apple eingetragen):** Nötig ist nichts – die Texte
   nennen LUH und Hildesheim, das stimmt weiter, und keiner sagt „alle Hochschulen“. Empfohlen, weil die App Göttingen
   zur Wahl stellt:
   - *Neu in dieser Version* (1.0.8), ein Punkt: „• Neu: Universität Göttingen – Kurse, Dateien, Stundenplan, Termine,
     Nachrichten und Lehrende aus Stud.IP, das Schwarze Brett und der Speiseplan der Mensen. Noten (FlexNow), eCampus und
     Uni-Mail folgen, sobald wir sie anbinden können.“
   - *Beschreibung (Pro AI, 3988 von 4000 Zeichen):* den Satz „Angebunden: LUH (Stud.IP, QIS) und Uni Hildesheim
     (Learnweb, LSF), weitere Hochschulen folgen.“ ersetzen durch „Angebunden: LUH (Stud.IP, QIS), Uni Hildesheim
     (Learnweb, LSF), neu Uni Göttingen (Stud.IP).“ – danach 3986 Zeichen. Dabei fällt „weitere Hochschulen folgen“ weg
     (steht sonst nirgends in der Beschreibung); wer es behalten will, muss anderswo 14 Zeichen kürzen.
   - *Schlüsselwörter* (100 von 100): unverändert lassen; „Göttingen“ ginge nur gegen ein anderes Wort.
   - Feste Prüfsätze in `tests/test_release_texts.py` prüfen den alten Satz nicht wörtlich; nach dem Eintragen den Test
     laufen lassen.
5. **Prüfhinweise für Apple (Entwurf):** „Connected today: Leibniz Universität Hannover and Universität Hildesheim.“ →
   „Connected today: Leibniz Universität Hannover, Universität Hildesheim and (new, Stud.IP only) Universität Göttingen.“
   (+43 Zeichen, danach 3980 von 4000). Prüfkonto bleibt LUH bzw. Demo.

## 2. Was gebaut ist

### Hochschule und Schalter
- `UniversityProfile.goettingen` (Kern, `Universities/UniversityProfile.swift`): Name, Stud.IP
  `https://studip.uni-goettingen.de`, Anmeldedienst `studip` (nur `dispatch.php/login`), Schlüsselbund-Präfix
  `goettingen`, `hasBulletinBoard: true`, **`gradeLayout: nil`** (keine Noten in der App). Dienste-Liste: Stud.IP
  (verbunden), FlexNow, eCampus, E-Mail (Exchange), SUB, Mensa, Lageplan, studIT, Uni – alles außer Stud.IP nur Links.
- Python-Gegenstück `app/universities.py` (`PROFILES["goettingen"]`, `GOETTINGEN_SERVICES`) mit `apps_only: True`: der
  Dienst nimmt Konten der Apps mit dieser Hochschule an (`config.known_universities`), Web-App und PC-Server bieten sie
  aber nicht zur Wahl (`universities.offered()`), und Göttinger Mensen erscheinen dort nur für Göttinger Konten.
  `/api/university/profile` kennt das Göttinger Stud.IP (Cookie `Studip_Session`). **Am Server ist nichts geändert oder
  ausgerollt** – das kommt erst mit einem Deploy (nur mit Okay).
- Hochschulwahl beim ersten Start: eigener Text („Stud.IP … Noten (FlexNow) und eCampus öffnest du weiter im Browser“).
  Erster Start: genau ein Schritt „Bei Stud.IP anmelden“ (kein QIS-Schritt).

### Anmeldung (Passwort nur auf dem Gerät)
- Das Anmeldefenster öffnet die echte Seite `studip.uni-goettingen.de/dispatch.php/login` mit den Direkt-Feldern
  „Benutzername“ und „Passwort“ (an der LUH weiter direkt das WebSSO). „CAS Login“ und „Other Institutes Login“ derselben
  Seite fasst die App nie an.
- Neues Formular `UniLoginForms.goettingenStudIP` (Feldnamen am 26.11.2026 an der echten Seite gelesen: `loginname`,
  `password`, Knopf `submit_login`). Darüber laufen „Passwort auf diesem iPad merken“, Uni-Zugang in den Einstellungen
  (ein Zugang, kein „überall gleich“) und die stille Neuanmeldung mit der unsichtbaren Webansicht – alles nur im
  Schlüsselbund des Geräts, nie auf einem Server. Ein abgelehntes Passwort wird nie ein zweites Mal gesendet.
- **Nicht freigegeben:** die Anmeldung im Hintergrund *ohne* Webansicht (`UniFormLogin.allowedForms`), bis sie einmal mit
  echtem Konto geprüft ist. Im Hintergrund bleibt es dann bei „Anmeldung nötig“ bzw. der Webansicht im Vordergrund.
- Erkennung „angemeldet“: Stud.IP-Seite außerhalb des eigenen Anmeldeformulars (`StudIPSync.isPastLogin`) und
  `users/me` nimmt die Cookies an. Anfragen gehen nur an `studip.uni-goettingen.de`, nie an Rechner einer anderen
  Hochschule (`URLSessionUniTransport.studipDomains(host:)`).

### Abgleich (vorhandene Stud.IP-Anbindung, je Hochschule die richtige Adresse)
- `StudIPSync` hat jetzt `base` und `loginEntry` seiner Hochschule (vorher fest LUH). Ansichten, Abgeben, Antworten,
  Aufzeichnungen und Lehrende nehmen die Adresse des offenen Containers.
- Läuft wie an der LUH: Kurse (mit Semester), Ordner und Dateien (Download der **ganzen Datei**, kein `Range`; der
  Transport schickt keinen Teilabruf), Stundenplan aus `schedule`, eigener Kalender `events.ics`, Kurstermine,
  Ankündigungen je Kurs, Posteingang, Änderungen (Activity-Stream), Semester, Lehrende/Kontakte.
- Was dort nicht geht, stört nicht und erzeugt keine Meldung:
  - Sprechstunden (404): gemerkt, 30 Tage nicht wieder gefragt (wie bisher).
  - `studip/news` (**500**, neu gesehen): neuer Merker „heute mit Serverfehler“ (`studip_failing_endpoints`) – höchstens
    ein Versuch je Tag statt jedes Mal mit Wartezeiten.
  - Wiki (404), Courseware-Fristen (`courseware-tasks` 400, `courseware-task-groups` 404): als fehlend gemerkt.
  - Aufzeichnungen: die LUH-Erweiterung `opencastpluginluh` (dort 403) wird an anderen Hochschulen gar nicht mehr gefragt
    (`OpencastParser.hasLUHPlugin`); der Kursüberblick ohne Reiter „Aufzeichnungen“ heißt „keine“ – kein
    „Aufzeichnungen von N Kursen nicht lesbar“.
- Veranstaltungsarten: Göttingen hat eigene Nummern (`sem-types`, 116 Arten; 4 = Seminar, 21 = Übung, 26 = Tutorium,
  16 = Praktikum). Eigene Tabelle `StudIPSchedule.goettingenCourseTypes`, damit ein Seminar nicht als „Labor“ erscheint.
- Räume: drei Standorte in `packages/shared-contracts/rooms.json` (Zentralcampus mit ZHG/MZG, Nordcampus, Waldweg),
  Raumnamen wie im echten Stud.IP („ZHG010 (ZHG)“). Kein Raumfinder wie an der LUH; Links öffnen die Karte.

### Schwarzes Brett
- Dieselbe Erweiterung wie in Hannover; der vorhandene Abruf (`StudIPBulletin`: Themenliste `category/list`, RSS je
  Thema) läuft unverändert, weil das Profil `hasBulletinBoard: true` sagt. Am echten Stud.IP geprüft: Themenliste mit
  `sb-categories` und RSS 2.0 je Thema. Karte „Schwarzes Brett“ unter „Uni & Noten“ wie an der LUH.

### Mensaplan
- Quelle geprüft (Abschnitt „Speiseplan“ in der Strukturnotiz): HTML-Bausteine je Tag und Mensa,
  `…/mensaspeiseplan/cached/de/<Tag>/<mensa>.html`, heute + 5 Tage, **keine Preise**.
- Neue Quelle `stwgoe` in `packages/shared-contracts/mensa.json` (mit `"prices": false`), drei Mensen (Zentralmensa,
  CGiN, Mensa am Turm) mit Adresse und Öffnungszeiten von den Seiten des Studierendenwerks, Kennzeichen aus der Legende
  (Zusatzstoffe 1–11, Allergene a–n, Symbole vegan/vegetarisch/Fleisch/Fisch/Strohschwein/Bauernrind/Niedersachsen-Menü).
- Leser in Python (`app/mensa.py` `parse_stwgoe`) und Swift (`Mensa.parseStwgoe`), gleiche Fälle aus gespeicherten
  echten Bausteinen (`fixtures/mensa/raw/stwgoe-zentralmensa.json`, `tools/gen-mensa-fixture.py`).
- **Ohne Preise keine falsche Preisangabe:** keine Beträge, kein Strich, kein „Preis für“, keine Sortierung nach Preis;
  in „Alle Angaben“ steht „Der Speiseplan nennt keine Preise je Gericht …“.
- Die Fleischart steht dort nicht im Plan: „ohne Schwein“ blendet jedes Fleischgericht aus (`pork_unknown`), mit Hinweis.
- Mensen einer Hochschule, die der Build nicht zur Wahl stellt, erscheinen in Hannover/Hildesheim nicht in der Liste.

### Ausgeblendet bzw. ehrlich ersetzt (Göttingen)
- „Uni & Noten“: keine Kennzahlen (Schnitt, LP), kein „Notenspiegel (QIS)“, kein „QIS-Zugang hinterlegen“; stattdessen
  Karte „Noten (FlexNow)“ mit „FlexNow öffnen“. Keine Karte „Bescheinigungen“. Stundenplan, Stud.IP und Schwarzes Brett
  bleiben.
- Seite „Bescheinigungen“: Karte „Bescheinigungen im eCampus“ mit „eCampus öffnen“, kein Abruf.
- „Studienverlauf“: nicht im Menü, kein Knopf „Im Studienverlauf“ im Modul; Leerkarte ohne „Verbinde QIS“.
- Uni-Mail: es gibt keine (Exchange, kein SOGo) – kein Menüpunkt.
- Prüfungsanmeldung: keine Meldezeiträume, keine Karte.
- Erstabgleich: keine Zeile „Noten aus QIS“; „Videos aus Stud.IP“ statt „Aufzeichnungen (Opencast)“.
- Aufzeichnungen im Modul: Hinweis, dass Mediacast-Videos (Reiter „Medien“) noch in Stud.IP geöffnet werden.
- Texte im Einstieg nennen „Stud.IP“ statt „QIS“, die Einstellungen kein „QIS“.

### Debug-Nachbildung
- `tools/build-goettingen-stub.py` erzeugt `apps/apple/DebugStub/goettingen/` (erfundene Kurse, Personen, Texte im Aufbau
  des echten Stud.IP, samt der Antworten, die dort nicht gehen). Simulator:
  `-UFOnboarding login -UFUniversity goettingen -UFLoginStub <Ordner>`; neu `-UFStubSignedIn YES` (Nachbildung gilt als
  angemeldet, für Bildvergleiche).

## 3. Was mit dem echten Konto geprüft wurde – und was nicht

Mit der Sitzung des Inhabers im Browser-Fenster (er hat sich selbst angemeldet; ich habe nur gelesen, nichts
abgeschickt, keine Inhalte notiert):
- Alle JSON:API-Abfragen, die der Abgleich stellt, einmal gestellt: Status und Feldnamen wie in der Nachbildung (Liste in
  der Strukturnotiz). Download einer Datei: kam ganz (7,3 MB), `Range` wird nicht beachtet.
- Anmeldeformular (ohne Sitzung gelesen), Name des Sitzungs-Cookies, Antworten ohne Sitzung.
- Schwarzes Brett (Themenliste, RSS), Aufzeichnungs-Wege (403/500/leeres V3-JSON), Veranstaltungsarten.
- Speiseplan des Studierendenwerks (öffentlich).

**Echter Kontotest in der App (27.11.2026, Build-Sitzung mit dem Inhaber, „Ja, angemeldet“, Debug-Build auf
release/1.0.8-alles):** Anmeldung und Abgleich in Ordnung – 9 Kurse, 153 Dateien, 15 Stundenplan-Termine, 7 Nachrichten,
9 Ankündigungen, 34 Einträge am Schwarzen Brett; Stundenplan, Nachrichten, Module, Übersicht angesehen. Drei Fehler dort
gefunden und in release behoben: d9bda316 (maskiertes `&lt;div&gt;&lt;/div&gt;` am Ende von Nachrichten), 028ee2a8
(Anführungszeichen im Titel trennten Vorlesung und Übung in zwei Module), 8f3cb718 (kurz „Offline – Stand vor …“ beim
Laden). Die Hintergrund-Anmeldung ohne Fenster hat der Inhaber danach freigegeben („Ja, freigeben“, 27.11.2026) – auf
`uni/goettingen`, für ein Update nach Build 51.

Vor dem Kontotest **nicht** mit dem echten Konto geprüft (nur gegen die Nachbildung):
- Die Anmeldung *in der App* selbst (Anmeldefenster, „Passwort merken“, Fehlermeldung bei falschem Passwort – deren
  Wortlaut ist geraten: `messagebox_error`). Die stille Neuanmeldung nach Ablauf der Sitzung; wie lange die Sitzung hält.
- Ein voller Abgleich der App gegen das echte Stud.IP (Menge, Dauer, große Dateien, Unterordner, gesperrte Ordner).
- Mediacast mit einem Kurs, der Videos hat; ILIAS-Inhalte („Lehrvideos“ über ILIAS).
- Antworten an Lehrende/Abgeben in Stud.IP Göttingen (die Wege sind dieselben wie an der LUH, aber ungeprüft).

**Nächster Schritt mit dem Inhaber (nur mit seinem Okay):** Debug-Fassung mit Göttingen in einem eigenen Simulator oder per
Kabel aufs iPad, er meldet sich im Anmeldefenster selbst an, ein Abgleich, dann Bildschirmfotos.

## 4. Tests (26.11.2026)

- Kern: neu `GoettingenTests` (13, seit dem Durchlauf mit Vorlesungszeiten und Lehrenden) und Mensa-Fälle für Göttingen; **alle 1895 Kern-Tests** liefen, 3 alte Prüfungen
  setzten genau drei Hochschulen voraus und sind angepasst (`ReleaseUniversitiesTests`), danach grün.
- App: neu `GoettingenAppTests` (7: Schalter, Anmelderegeln, Erstabgleich gegen die Nachbildung mit allen Bereichen,
  abgelaufene Sitzung, Ausblenden, Mensa ohne Preise, Nachbildung). Gesamtläufe iPad/iPhone/Mac: siehe Abschnitt 6.
- Python: 4116 grün; `tests/test_release_texts.py` angepasst (Debug nennt Göttingen, Release nicht). 3 Tests in
  `tests/test_audit_p58_87_golive.py` sind rot – **genauso auf dem unveränderten `release/1.0.8-alles`**, also nicht von
  diesem Zweig.
- Eigene Simulatoren: „Goettingen iPad“ (4D143598-1830-46AF-8DEC-F0759B756907), „Goettingen iPhone“
  (BDD5EFAC-9FA4-475B-BE93-5D2E68FCC9EB); Bauordner `~/Studora-Builds/dd-goe`, `~/Studora-Builds/dd-goe-core`.
  Bildschirmfotos: `~/Studora-Builds/goettingen/rundgang-ipad/`, `…/rundgang-iphone/`.

## 5. Was noch zu bauen wäre (offen)

| Bereich | System | Stand | Was nötig wäre |
|---|---|---|---|
| Noten, Credits, angemeldete Prüfungen | FlexNow 2 (`flexnow2.uni-goettingen.de`, ohne 2. Faktor) | Aufbau nach der Anmeldung gesehen (eine Adresse `/FN2SSS/FrontControllerSS`, Seite lädt nach); Zeilen nicht gelesen | Neuer Leser in der Webansicht (wie QIS): „Studierendendaten → Alle Prüfungen“, „Aktuelles → Neueste Ergebnisse“; dann Studienverlauf. Vorher: die Antworten von `FrontControllerSS` und das Notenformat mit dem Inhaber ansehen. Anmeldung kam im Fenster der Claude-App nicht an – am Gerät prüfen. |
| — Nachtrag 27.11.2026 (zweiter Blick in FlexNow, Chrome des Inhabers) | | | Das Testkonto hat **noch keine Noten**: der Notenbaum (`ul.treeview`: Studiengang → PO mit Credits → Fachgruppe mit C → Modul) endet bei leeren Modulen. Das Format einer Notenzeile ist nicht gesehen → Noten-Leser erst mit einem Konto, das Noten hat. Gesehen und baubar: „Aktuelle Prüfungen“ (angemeldete Prüfungen mit An-/Abmeldefrist, `div.prfangBlock.angemeldet`). Einzelheiten maskiert in `~/Studora-Builds/goettingen/STRUKTUR-ECHT-FLEXNOW-2026-11-26.md`. |
| Leistungsübersicht als PDF | FlexNow „Datenblatt erzeugen (prüfbar)“, 11 Arten | gesehen, nicht ausgelöst | Nur auf Tipp erzeugen (jeder Klick legt ein Dokument an), wie bei QIS. |
| Prüfungsanmeldung | FlexNow (Prüfungskorb, „Verbuchen“) | gesehen, nichts angeklickt | Höchstens anzeigen, was angemeldet ist; nie selbst anmelden. Meldezeiträume als Daten (`exam-registration-goettingen.json`). |
| Bescheinigungen, Vorlesungsverzeichnis | eCampus (HISinOne) | nicht angesehen; Academic Cloud mit 2. Faktor | Anmeldung mit 2. Faktor im Fenster (Passkey/Code) klären; dann ähnlich PLuS/HsH (`CertificateClient`). |
| Uni-Mail | Exchange bei der GWDG (`email.gwdg.de`) | nicht angesehen; Webmail über Academic Cloud (2. Faktor) | Laut öffentlicher Anleitung der Uni (27.11.2026 nachgesehen, studit.uni-goettingen.de) geht IMAP: `email.gwdg.de`, Port 993 (SSL/TLS), Benutzer `ug-student\<Kennung>`, SMTP `email.gwdg.de`; Thunderbird-Anleitung nennt `email.stud.uni-goettingen.de`. Eigene IMAP-Anbindung nötig (die App kann bisher nur SOGo); Passwort tippt nur der Nutzer am Gerät. |
| Videos | Mediacast (Reiter „Medien“), teils ILIAS | Einstieg gesehen, kein Kurs mit Video | Mit einem Kurs mit Video ansehen, dann Leser für die Aufzeichnungen. |
| Hintergrund-Anmeldung ohne Webansicht | Stud.IP-Formular | **freigegeben 27.11.2026** (Inhaber: „Ja, freigeben“, nach dem echten Kontotest), `UniFormLogin.allowedForms`, Test `testBackgroundLoginWithoutWebView`; nur auf `uni/goettingen`, nicht in Build 51 | Am Gerät beobachten, ob die stille Erneuerung nach Ablauf der Sitzung ohne Fenster klappt. |
| Mensa | Studierendenwerk | eingebaut ohne Preise | Beim Studierendenwerk fragen, ob das Abrufen in Ordnung ist und ob es Preise je Gericht gibt; Bistro HAWK und Cafeterien fehlen. |
| Raumfinder | Lageplan (ArcGIS), eCampus-Raumsuche | nur Standorte | Klären, ob die Daten genutzt werden dürfen. |
| Dienst (Server) | `app/universities.py` u. a. | im Zweig, nicht ausgerollt | Mit dem nächsten Deploy (nur mit Okay) – sonst lehnt der Dienst ein Göttinger Konto mit `university_unknown` ab. |
| Store | Texte, Bilder, Datenschutz | nichts geändert | Vor Freigabe: Store-Texte („LUH und Hildesheim“), Datenschutztext (Studierendenwerk Göttingen als Quelle). |
| Medizin (UMG), go@med | – | nicht betrachtet | – |

## 6. Kompletter Durchlauf 26.11.2026 abends (Auftrag „teste göttingen komplett durch“)

Rundgang über alle Seiten mit der Nachbildung (angemeldet, nach einem Abgleich), iPad und iPhone, je 24 Seiten plus
Hochschulwahl. Bildschirmfotos: `~/Studora-Builds/goettingen/rundgang-ipad-2/` (vor den Korrekturen) und
`…/rundgang-iphone-2/` (danach).

Gefunden und behoben (Commit c8624807):

| Fehler | Ursache | Behoben |
|---|---|---|
| Stundenplan zeigte „WiSe 2026/27 · 12.10.2026 – 30.01.2027“ (Vorlesungszeit der LUH) | `holidays.SEMESTERS` kannte Göttingen nicht, also blieb die alte LUH-Vorgabe | Göttinger Semestertermine (ohne Medizin, Seite „Semestertermine“ der Uni) in `app/holidays.py` und `Holidays.swift`: WiSe 26.10.2026–12.02.2027 mit Weihnachtspause 28.12.–08.01., SoSe 2027, WiSe 2027/28, SoSe 2028; SoSe 2026 wie im echten Stud.IP. Jetzt „26.10.2026 – 12.02.2027“ |
| „Lehrende“ sagte „gibt es vorerst für die Leibniz Universität Hannover“ | Abfrage und Abgleich fragten fest nach `luh` | Freigegeben für alle Hochschulen mit Stud.IP (`universities.has_studip`, `StudIPLecturers.offered`), auch im Termin. Göttingen zeigt jetzt die Lehrenden mit E-Mail und „Nachricht in Stud.IP“ |
| Raumfinder nannte unten „Standortfinder der Leibniz Universität Hannover“ | Standort-Antwort gab immer die LUH-Quelle mit | Quelle nur noch, wenn die Hochschule einen eigenen Raumfinder hat (LUH, Hildesheim mit LSF); betraf auch die HsH |
| Wochenansicht fast leer | Nachbildung hatte nur 1–2 Einzeltermine je Kurs | Nachbildung legt wie das echte Stud.IP jede Woche der Vorlesungszeit an (ohne Weihnachtspause, ein Termin fällt aus) |

Angesehen und in Ordnung: Start, Stundenplan (Tag und Woche), Module und Modulseite, Dokumente, Nachrichten, Uni & Noten
(FlexNow-Karte, Stud.IP, Schwarzes Brett), Bescheinigungen (eCampus-Karte), Studienverlauf (ruhige Karte), Mensa (echter
Speiseplan, keine Preise, „Seite der Mensa öffnen“), Raumfinder (drei Standorte), Uni-Mail (nicht angeboten), Tests,
Karteikarten, KI, Community, alle Einstellungen, Hochschulwahl mit Göttingen-Text.

Nicht geändert, nur bemerkt: Im Modul steht der Reiter „Aufzeichnungen“ auch in Göttingen (darin der Hinweis auf
Mediacast); „Aktuelle Lehrwoche“ zählt wie überall die letzte Woche mit Dateien.

## 6a. Abgabe für 1.0.8 (fbd40438, 27.11.2026 nachts): release/1.0.8-alles bis d2e5edbb eingemischt + Hinweis

| Lauf | Ergebnis |
|---|---|
| Kern (`swift test`, auf 1e8b635c) | 1949 Tests, 0 Fehler (20 übersprungen) |
| Python ohne Lasttests (auf 79280a15) | 4129 grün; rot: `test_audit_p58_87_golive.py::test_p84_03…backup` (alt) und `test_web_overview.py::test_overview_answers_what_to_do_today` (allein grün, hängt an Uhrzeit/Reihenfolge) |
| Python-Auswahl (auf 1e8b635c) | `test_wake_push`, `test_goettingen`, `test_site`, `test_release_texts`, `test_holidays`, `test_rooms`, `test_studip_lecturers`: 173 grün |
| App iPad + iPhone (auf 75f57230, 76 Klassen zu Göttingen, Hochschulwahl, Uni & Noten, Stundenplan, Mensa, Lehrende, Raumfinder; 544 Tests je Gerät) | rot nur StoreKit (`AbnahmeTarife…`, `AbnahmeV1LUHRelease…`, `StoreScreenshotFinalTests.testTarifPruefung`, `KIAbnahmeLUHAppTests.test3…` – Preise/Kauf laden nur im Gesamtlauf; im ganzen iPad-Lauf alle grün) und am iPhone die zwei, die auf 1.0.8 genauso rot sind (`BackArrow…`, `StudyPlanManual…OnPhone`) |
| App iPad + iPhone (auf 1e8b635c): `GoettingenAppTests`, `ReleaseUniversitiesAppTests`, `MensaAppTests`, `LecturersAppTests`, `TextBlockAppTests`, `AutoSyncAppTests`, `SyncAllPortalsTests`, `WakePushAppTests`, `MacTestIsolationTests` | 84 Tests je Gerät grün bis auf den neuen Hinweis-Test; der ist in fbd40438 berichtigt, danach `GoettingenAppTests` (8) auf iPad und iPhone grün |
| Mac | zuletzt auf c8624807 (28 Tests grün); auf dem Abgabestand nicht wiederholt |
| Bildschirmfoto „Uni & Noten“ mit dem Hinweis | `~/Studora-Builds/goettingen/hinweis/services.png` |

## 6b. Testläufe auf dem Stand c8624807 (26.11.2026 abends)

| Lauf | Ergebnis |
|---|---|
| Kern (`swift test`) | 1936 Tests, 0 Fehler (20 übersprungen) |
| Python (`pytest tests`) | 4133 grün; rot: die 3 alten in `test_audit_p58_87_golive.py` (auf 1.0.8 genauso) und `test_release_build_provenance` (die Build-Sitzung hat `StudiNow-50.commit` neben die Archive gelegt, die Tabelle in diesem Zweig kennt Build 50 noch nicht – kein Bezug zu Göttingen) |
| App iPad, **alle 2320 Tests** (Stand cba3e6b4, vor den Korrekturen) | 3 rot: `StoreScreenshotTests.test01Uebersicht` (auf 1.0.8 genauso), `EditorStrichBleibtTests…Absetzen` (Bildmessung unter Last; einzeln grün), `MacTestIsolationTests` (meine Rundgang-Anmeldung lag noch im Simulator; auf geleertem Simulator grün) |
| App iPad, neuer Stand | 76 Klassen, die die Korrekturen berühren (646 Tests): **alle grün** |
| App iPhone, neuer Stand | dieselben Klassen (661 Tests): 2 rot – `BackArrowAppTests.testHomeHasNoArrowOtherPagesExactlyOne` und `StoreScreenshotTests.test01Uebersicht`, **auf dem unveränderten 1.0.8 im selben Simulator genauso rot** |
| App iPhone, alle Tests (neuer Stand) | siehe unten |
| Mac (`tools/mac-test.sh`, eigener Bauordner `dd-goe-mac`) | `MacTestIsolationTests`, `GoettingenAppTests`, `MensaAppTests`, `ReleaseUniversitiesAppTests`, `LecturersAppTests`: 28 Tests, alle grün |

## 6c. Frühere Testläufe (f2e21505, 26.11.2026 abends)

| Lauf | Ergebnis |
|---|---|
| Kern (`swift test`) | 1934 Tests, 0 Fehler (20 übersprungen) |
| Python (`pytest tests`) | 4132 grün; 3 rot in `test_audit_p58_87_golive.py` – auf dem unveränderten `release/1.0.8-alles` genauso rot |
| App iPad („Goettingen iPad“) | 85 Klassen, die geänderten Code berühren (728 Tests): nach den Anpassungen grün bis auf StoreKit-Preise in `AbnahmeTarifeAppTests`/`AbnahmeV1LUHReleaseAppTests`/`AboNurJahrAppTests` (Preise laden im Testlauf nicht, kein Bezug zu Göttingen) |
| App iPhone („Goettingen iPhone“) | dieselben 85 Klassen: zusätzlich `StudyPlanManualAppTests.testEnterGradeOnPhone` und `UniversityLoginPolicyTests.testQISLoginPaneShowsTheHintAndKeepsNoPassword` rot – **auf dem unveränderten 1.0.8-Stand (51571948) im selben Simulator genauso rot** |
| `GoettingenAppTests`, `MensaAppTests`, `ReleaseUniversitiesAppTests` | iPad und iPhone grün |
| Mac (`tools/mac-test.sh`) | **nicht gelaufen**: zur selben Zeit lief der Mac-Lauf einer anderen Sitzung. Nachholen mit `tools/mac-test.sh -only-testing:UniFlowTests/GoettingenAppTests -only-testing:UniFlowTests/MensaAppTests` |
| Gesamtlauf aller 2200 App-Tests | nicht zu Ende gelaufen (mehrere Sitzungen testeten gleichzeitig, nach 2 Stunden erst ein Zehntel); stattdessen die 85 Klassen oben |

Für den Vergleich liegt eine Kopie von 51571948 unter `~/Studora-Builds/wt-goe-vergleich` (Bauordner
`dd-goe-vergleich`); kann weg, wenn niemand sie mehr braucht.

## 7. Einbinden in den nächsten Build

`uni/goettingen` enthält `release/1.0.8-alles` bis d2e5edbb und lässt sich ohne Konflikte darauf mischen. **Nicht in
Build 50, sondern in 1.0.8 / Build 51** (Inhaber 26.11.2026: „Noch in 1.0.8“). Mischen und bauen macht die Build-Sitzung. Danach Pflicht: Abschnitt „Vor dem Einreichen“ oben (Server-Update nur mit Okay, laut Inhaber erst direkt vor der Veröffentlichung; Test mit echtem Göttinger Konto am gemischten Stand).
