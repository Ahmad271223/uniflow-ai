# Uni Göttingen in StudiNow (Stand 26.11.2026)

Zweig `uni/goettingen` (lokal, nicht gepusht), abgezweigt von `release/1.0.8-alles` (b1682e3a), Arbeitsordner
`~/Studora-Builds/wt-goettingen`. Vorgesehen für **Build 53/54**, nicht für 1.0.8 / Build 50.

Grundlagen (nur auf dem Mac, nicht im Repo):
- `~/Studora-Builds/goettingen/STRUKTUR-ECHT-STUDIP-2026-11-26.md` – echtes Stud.IP Göttingen (drei Blicke) und der
  öffentliche Speiseplan des Studierendenwerks
- `~/Studora-Builds/goettingen/STRUKTUR-ECHT-FLEXNOW-2026-11-26.md` – FlexNow 2 nach der Anmeldung (nur Aufbau)
- `~/Studora-Builds/goettingen/RECHERCHE-GOETTINGEN-2026-11-26.md` – öffentliche Recherche (nicht nachgeprüft)

## 1. Kurz

- Göttingen ist die vierte Hochschule (`UniversityKey.goettingen`) mit eigenem Datenbereich, eigener Anmeldung und dem
  vorhandenen Stud.IP-Abgleich. Im **Store-Build steht sie nicht zur Wahl** (Release `UF_SHIPPED_UNIVERSITIES` bleibt
  `"luh hildesheim"`); in Debug, Simulator und Tests ja.
- Was über Stud.IP geht, ist eingebaut: Kurse, Ordner und Dateien samt Download, Stundenplan, Kalender, Kurstermine,
  Nachrichten, Neuigkeiten/Änderungen, Lehrende, Schwarzes Brett. Dazu der Mensaplan (ohne Preise).
- Was Göttingen nicht in Stud.IP hat (Noten, Bescheinigungen, E-Mail, Mediacast-Videos), ist in der App ausgeblendet
  bzw. durch eine ruhige Karte „gibt es hier noch nicht – hier öffnen“ ersetzt.

**Freigabe später:** In `apps/apple/project.yml` beim Release `UF_SHIPPED_UNIVERSITIES: "luh hildesheim goettingen"`
setzen, `xcodegen generate`, dazu `tests/test_release_texts.py` (prüft heute ausdrücklich „ohne Göttingen“). Eine
Kabel-Fassung fürs iPad des Inhabers geht vorher mit `xcodebuild … UF_SHIPPED_UNIVERSITIES="luh hildesheim goettingen"`.

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

**Nicht** mit dem echten Konto geprüft (nur gegen die Nachbildung):
- Die Anmeldung *in der App* selbst (Anmeldefenster, „Passwort merken“, Fehlermeldung bei falschem Passwort – deren
  Wortlaut ist geraten: `messagebox_error`). Die stille Neuanmeldung nach Ablauf der Sitzung; wie lange die Sitzung hält.
- Ein voller Abgleich der App gegen das echte Stud.IP (Menge, Dauer, große Dateien, Unterordner, gesperrte Ordner).
- Mediacast mit einem Kurs, der Videos hat; ILIAS-Inhalte („Lehrvideos“ über ILIAS).
- Antworten an Lehrende/Abgeben in Stud.IP Göttingen (die Wege sind dieselben wie an der LUH, aber ungeprüft).

**Nächster Schritt mit dem Inhaber (nur mit seinem Okay):** Debug-Fassung mit Göttingen in einem eigenen Simulator oder per
Kabel aufs iPad, er meldet sich im Anmeldefenster selbst an, ein Abgleich, dann Bildschirmfotos.

## 4. Tests (26.11.2026)

- Kern: neu `GoettingenTests` (11) und Mensa-Fälle für Göttingen; **alle 1895 Kern-Tests** liefen, 3 alte Prüfungen
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
| Leistungsübersicht als PDF | FlexNow „Datenblatt erzeugen (prüfbar)“, 11 Arten | gesehen, nicht ausgelöst | Nur auf Tipp erzeugen (jeder Klick legt ein Dokument an), wie bei QIS. |
| Prüfungsanmeldung | FlexNow (Prüfungskorb, „Verbuchen“) | gesehen, nichts angeklickt | Höchstens anzeigen, was angemeldet ist; nie selbst anmelden. Meldezeiträume als Daten (`exam-registration-goettingen.json`). |
| Bescheinigungen, Vorlesungsverzeichnis | eCampus (HISinOne) | nicht angesehen; Academic Cloud mit 2. Faktor | Anmeldung mit 2. Faktor im Fenster (Passkey/Code) klären; dann ähnlich PLuS/HsH (`CertificateClient`). |
| Uni-Mail | Exchange bei der GWDG (`email.gwdg.de`) | nicht angesehen; Webmail über Academic Cloud (2. Faktor) | IMAP/SMTP statt SOGo; klären, ob IMAP mit normalem Passwort geht. Eigene Anbindung. |
| Videos | Mediacast (Reiter „Medien“), teils ILIAS | Einstieg gesehen, kein Kurs mit Video | Mit einem Kurs mit Video ansehen, dann Leser für die Aufzeichnungen. |
| Hintergrund-Anmeldung ohne Webansicht | Stud.IP-Formular | gesperrt (`allowedForms`) | Nach einem echten Test freigeben. |
| Mensa | Studierendenwerk | eingebaut ohne Preise | Beim Studierendenwerk fragen, ob das Abrufen in Ordnung ist und ob es Preise je Gericht gibt; Bistro HAWK und Cafeterien fehlen. |
| Raumfinder | Lageplan (ArcGIS), eCampus-Raumsuche | nur Standorte | Klären, ob die Daten genutzt werden dürfen. |
| Dienst (Server) | `app/universities.py` u. a. | im Zweig, nicht ausgerollt | Mit dem nächsten Deploy (nur mit Okay) – sonst lehnt der Dienst ein Göttinger Konto mit `university_unknown` ab. |
| Store | Texte, Bilder, Datenschutz | nichts geändert | Vor Freigabe: Store-Texte („LUH und Hildesheim“), Datenschutztext (Studierendenwerk Göttingen als Quelle). |
| Medizin (UMG), go@med | – | nicht betrachtet | – |

## 6. Testläufe der Gesamtsuiten

(wird nach den Läufen ergänzt)
