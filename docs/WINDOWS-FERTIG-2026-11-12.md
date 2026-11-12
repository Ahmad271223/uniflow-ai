# Windows-App: Geht das schon? Stand und Fertigstellung (12.11.2026)

Auftrag des Inhabers: Die Windows-App soll wirklich benutzbar sein – schreiben, importieren, Lösungen teilen, in der
Community mit Windows-, iPad-, iPhone- und Mac-Nutzern diskutieren, und wer sich auf dem iPad mit Apple angemeldet hat,
soll dasselbe Konto auf Windows nutzen. Dazu die ehrliche Frage: **Geht das aktuell schon?**

Grundlage: `origin/develop` (`d29765c3`, 11.11.2026), Zweig `feature/windows-fertigstellung`. Windows-App `0.6.0`
(`apps/windows`), iPad-App 1.0.2 im Store, `develop` = 1.0.3 / Build 34.

## 1. Die Antwort in einfachen Worten

**Mit anderen Windows-Nutzern und dem Web: ja, das läuft – ich habe es echt durchgespielt.** Schreiben mit dem Stift,
PDF- und Bild-Import, Anmeldung mit E-Mail und Passwort, derselbe Stand auf zwei Windows-PCs, Lösung veröffentlichen,
liken, kommentieren, antworten, Fragen stellen und beantworten.

**Nachtrag am Abend (Freigabe des Inhabers: „mach alles, dass es klappt und alles 1 zu 1 funktioniert“):** Eigene
Dokumente gleichen jetzt zwischen Windows-PCs und Web ab (Notizbuch, importierte PDF, Notizen, Bilder, Umbenennen,
Papierkorb, endgültig Löschen – echter Lauf 49/49, Abschnitt 4a). Lerngruppen, die auf einem anderen Gerät beigetreten
wurden, erscheinen in Web/Windows mit „Code hier einmal eingeben“; die Community lädt beim Zurückkommen ins Fenster neu.
**Was weiter fehlt, ist Arbeit auf dem Mac (Swift) und Schritte im Konto des Inhabers:** der Mac-Auftrag steht in
`docs/AUFTRAG-MAC-2026-11-12.md`. Damit es draußen läuft, muss der Dienst auf dem Server den Stand dieses Zweigs
bekommen (vom Mac aus, Abschnitt 5).

**Mit iPad, iPhone und Mac: nein, nicht vollständig.** Es gibt drei echte Hindernisse, die ich vom PC aus nicht
beseitigen kann. Alle drei brauchen eine Entscheidung oder eine Handlung des Inhabers (Abschnitt 5):

1. **Mit Apple angelegtes Konto auf Windows:** Der Knopf „Mit Apple anmelden“ führte bisher ins Leere. Der Dienst hat
   keine „Services-ID“ von Apple hinterlegt, ohne sie zeigt die Anmeldeseite im Browser keinen Apple-Knopf. Das ist eine
   Einstellung im Apple-Entwicklerkonto (Inhaber). Bis dahin gibt es einen Umweg (Passwort festlegen), den die App jetzt
   erklärt.
2. **Community:** iPad und Mac benutzen eine andere Community-Datenbank (Apples CloudKit) als Windows und Web (der Dienst
   `app.studinow.app`). **Beide sehen die Beiträge der anderen nicht.** Gemeinsam geht nur der Datei-Weg
   (`.uniflowsolution`). Die Zusammenlegung („Plan A“, ca. 4–6 Tage Swift-Arbeit auf dem Mac) ist noch nicht
   entschieden.
3. **Eigene Dokumente (selbst angelegte Notizbücher, importierte PDFs und Bilder):** ~~Sie gleichen sich nirgends
   ab.~~ **Seit dem Abend: Windows ↔ Web ↔ Windows ja** (ab Pro AI bzw. in der Probe, wie Notizen; gebaut und echt
   durchgespielt). **Mit dem iPad noch nicht:** dafür braucht die iPad-App einen kleinen Abgleich-Teil gegen dieselben
   Dienst-Wege (Mac-Auftrag).

Dazu kommt: **Bezahlen unter Windows geht heute nicht** (Stripe ist im Dienst nicht eingerichtet). Wer keine Apple-Abo
hat, ist nach den 7 Tagen Probe gesperrt (nur lesen und exportieren).

## 2. Wie ich geprüft habe (und was das beweist)

| Beleg | Was es ist | Was es beweist | Was nicht |
| --- | --- | --- | --- |
| **Echter Lauf** `tools/e2e-windows-konto.py` | Dienst und zwei „Windows-PCs“ als eigene Prozesse auf 127.0.0.1 (eigene Temp-Daten, echtes HTTP), dazu ein „iPad“ und ein zweites Konto über die API des Dienstes | Konto, Abgleich, Community laufen zwischen mehreren Geräten wirklich (36 Prüfungen, alle bestanden) | Das „iPad“ ist ein Stellvertreter (Python mit dem iPad-Vertrag), kein echtes Gerät |
| **Oberfläche im Browserfenster** | Die Oberfläche der Windows-App (`app/static`) im Browserfenster dieser Sitzung gegen den Test-Aufbau: Anmeldebildschirm, Editor (Striche gezeichnet), Community beitreten, Lösung veröffentlichen, Bild importieren | So sieht und bedient es sich | Nicht das Tauri-Fenster mit WebView2, kein Stift, kein Touch |
| **Tests** | `pytest tests` und `node --test tests/js` (Abschnitt 7) | Regeln, Verträge, Grenzfälle | Keine Geräte |
| **Öffentliche Abfragen am Live-Dienst** | Nur lesende `GET`-Aufrufe an `https://app.studinow.app` (Anmeldewege, Info, Anmeldeseite) | Dienst läuft, Apple für das iPad an, **Apple im Browser aus**, Windows-Anmeldeseite des Dienstes ist die aus `develop` | Nichts am Dienst verändert, keine Konten angelegt, keine Mails ausgelöst |
| **Quellcode und Doku** | Lesen, mit Dateipfad | Wie es gedacht ist | Doku kann veraltet sein; Widersprüche sind unten genannt |

Die Spalten iPad, iPhone und Mac der Tabelle stammen aus dem **Lesen von Swift-Code und Doku** (mit Dateipfad und
Zeilen, Stand `origin/develop` und Zweig `origin/feature/iphone`), nicht aus eigenen Läufen: Belege wie „Simulator-Tests
grün“ sind Angaben aus `docs/release/BUILD-HERKUNFT.md` und den Paritätsberichten. Nichts wurde auf einem echten iPad,
iPhone, Mac oder Windows-Laptop mit installierter App geprüft. Rust ist auf diesem
PC nicht installiert, die Tauri-Hülle und der Installer wurden deshalb **nicht gebaut**.

## 3. Tabelle: Funktion × Plattform

Zeichen: **✔** funktioniert · **◐** teilweise · **✘** fehlt. „Gerät“ = nur auf einem echten Gerät prüfbar.

| Funktion | Windows (0.6.0) | iPad (1.0.2 Store / Build 34) | iPhone | Mac (iPad-App) | Web |
| --- | --- | --- | --- | --- | --- |
| **Editor: schreiben** (Stift/Maus, Text, Formen) | **✔** echter Lauf: PDF geöffnet, Striche gezeichnet und gespeichert, Notiz erscheint auf PC 2. Stift/Touch auf echtem Gerät offen | ✔ Code und Simulator-Tests (Build 33: 1504 grün); echtes Pencil: Gate G2 offen | ✘ nur im Zweig `feature/iphone`, nie auf echtem iPhone | ◐ Maus schreibt, kein Pencil; von Hand bedient laut Doku, nicht geprüft | ✔ dieselbe Oberfläche wie Windows |
| **Dokument importieren** (PDF, Bild) | **✔ (nach Korrektur heute)**: PDF ✔; Bild war kaputt (Datei „x.pdf“ war ein PNG), jetzt echte PDF-Seite (Pillow). HEIC/Word-Import: nein | ✔ PDF/ZIP per Dateiwahl und Ziehen (`ExternalFileImport`), Simulator-Tests | ✘ nur Zweig | ◐ Dateidialog ja, Ziehen nur per Test | ✔ wie Windows |
| **Hochschuldateien** (Stud.IP/Learnweb) | ✔ eigener Abgleich auf dem PC (Anmeldung im App-Fenster) | ✔ jedes Gerät lädt selbst | ✘ | ✔ wie iPad | ◐ im Dienst keine Passwörter gespeichert (06.11.) |
| **Lösung teilen (Datei)** `.uniflowsolution` | ✔ öffnen und speichern; Paketformat durch gemeinsame Vektoren abgesichert (`vectors.json`, Tests in Python, JS, Swift) | ✔ | ✘ | ✔ | ✔ |
| **Lösung teilen (Community)** | **✔** Windows ↔ Windows/Web: echtes Paket veröffentlicht, von zweitem Konto gelesen und geöffnet (Lauf). **✘ zu iPad/Mac** | ✔ nur CloudKit (Dienst-Weg seit 07.11. aus) | ✘ | ✔ nur CloudKit | ✔ Dienst |
| **Community lesen / kommentieren / liken / Fragen** | **✔** Windows ↔ Windows/Web im Lauf (Kommentar mit Stelle, Antwort, Like, Mitteilungen, Frage + Antwort). **✘ zu iPad/Mac** | ✔ CloudKit; CloudKit-Production-Schema im Repo nicht als erledigt belegt | ✘ | ✔ CloudKit, aus Xcode sieht der Mac die Production-Daten nicht | ✔ Dienst |
| **Anmeldung: E-Mail + Passwort** | **✔** Lauf und Browserfenster: anmelden, abmelden; das Token wird laut Code in der Windows-Anmeldeinformationsverwaltung abgelegt (im Lauf eine Ersatzdatei, damit das echte Token dieses PCs unberührt bleibt) und steht nie in der Zustandsdatei | ✔ im Konto-Menü | ✘ | ✔ | ✔ |
| **Anmeldung: mit Apple** (Konto vom iPad) | **✘ heute** (Dienst ohne Services-ID). Umweg „Passwort festlegen“ funktioniert (im Lauf geprüft); die App erklärt ihn jetzt | ✔ Code (`loginWithApple`), nie mit echtem Apple-Token gegen den Dienst geprüft (P85-01 offen) | ✘ | ◐ ungeprüft | ✘ gleiche Ursache |
| **Abgleich Notizen zwischen Geräten** (Hochschuldateien) | **✔** drei Geräte schreiben gleichzeitig, kein Strich geht verloren (Lauf); Löschen wandert mit. **Erst ab Pro AI** (Entscheidung 04.11.) | ✔ Code + Verträge; **nie zwischen echtem iPad und Windows geprüft** (Gate G2) | ✘ | ◐ zählt als zweites Gerät, kein Hintergrundabgleich | ✔ im Dienst |
| **Abgleich: Module, Lernplan, Karteikarten, Einstellungen** | ✔ Modul im Lauf; Rest laut Tests | ✔ | ✘ | ✔ | ✔ |
| **Abgleich: eigene Dokumente** (Notizbuch, importierte PDF/Bild) | **✔ seit 12.11. abends** (vorher ✘): PC 1 → Web → PC 2 und zurück, mit Notizen, Bildern, Umbenennen, Löschen (Lauf 49/49, `tests/test_own_docs_sync.py`); bis 75 MB je Datei; ab Pro AI/Probe. **Dienst auf dem Server braucht diesen Zweig** | ✘ Swift-Teil fehlt (Mac-Auftrag); das veröffentlichte iPad merkt nichts davon | ✘ | ✘ wie iPad | ✔ (Web ist der Dienst selbst) |
| **Lerngruppen auf mehreren Geräten** | ✔ seit 12.11.: auf anderem Gerät beigetretene Gruppe erscheint mit „Code hier einmal eingeben“ (Browser-Test mit zwei Geräten) | ✔ iCloud (eigene Welt, E2) | ✘ | ✔ iCloud | ✔ wie Windows |
| **Community neu laden** | ✔ seit 12.11.: beim Zurückkommen ins Fenster, höchstens 1× je Minute, nie mit Entwurf oder offenem Fenster | ✘ (Mac-Auftrag, gleiche Regel) | ✘ | ✘ | ✔ wie Windows |
| **Abo / Rechte** | ◐ Konto-Pflicht, 7 Tage Probe wie Pro AI ✔; Apple-Abo vom iPad gilt (Dienst kennt es am Konto, Gerät offen); **Bezahlen per Stripe: nicht eingerichtet** | ✔ StoreKit; Sandbox-Kauf offen (G3). Übernimmt vom Dienst nur die Probe, keinen Stripe-Tarif | ✘ | ◐ Kauf ungeprüft | ◐ wie Windows |
| **Installer / Store** | ◐ `0.6.0` im Code; Installer wegen GitHub-Abrechnung nicht gebaut, unsigniert, kein Updater; Store-Werte fehlen | ✔ 1.0.2 veröffentlicht | ✘ | ◐ Schalter „Mac“ im Repo nicht belegt | – |

Veraltete Doku, die dem Code widerspricht (geprüft): `docs/WINDOWS-LUECKEN-2026-11-05.md` Abschnitt 6 und
`docs/release/APP-STORE.md` Zeile 65 behaupten, ein iPad mit StudiNow-Konto nutze die Dienst-Community. Seit 07.11. ist
das aus (`communityViaService = false`, `StudoraAccountLink.swift:209`).

## 4. Was ich geändert habe (alles mit Test)

| Änderung | Warum (Befund) | Test |
| --- | --- | --- |
| `GET /api/app-account/providers` und Anmeldebildschirm: „Mit Apple/Google anmelden“ nur, wenn der Dienst es im Browser kann; sonst Hinweis „Konto mit Apple auf dem iPad angelegt?“ mit Knopf **Passwort festlegen** (öffnet den richtigen Reiter im Browser) | Live-Dienst meldet `apple: true`, `apple_web_client_id: null`: der Knopf führte auf eine Seite ohne Apple-Knopf | `tests/test_windows_fertigstellung_2026_11_12.py` (7 Fälle), `tests/js/account-gate.test.mjs`; Lauf mit Passwort-Weg im Browser |
| Anmeldeseite des Dienstes (`login.js`): bei „Apple“ aus der Windows-App ohne Apple-Knopf kein Verweis auf einen nicht vorhandenen Knopf | gleiche Ursache | Skript-Prüfung, Lauf |
| Community-Karte zeigt den **wirksamen** Tarif („Pro AI (Probe)“) statt des gespeicherten „Free“ | Karte zeigte „StudiNow Free“ mitten in der Probe | `test_community_card_shows_the_plan_the_pc_really_works_with` |
| **Bild importieren**: Pillow in `requirements.txt` (13.0.0) und im PyInstaller-Paket | Ohne Pillow wurde ein PNG als „Name.pdf“ abgelegt, Editor und Vorschau konnten es nicht öffnen | `test_imported_image_becomes_a_real_pdf_page`; im Editor geöffnet |
| Abgleich: Stand des eigenen Abrufs von Schwarzem Brett/Blubber bleibt am Gerät (`sync.DEVICE_FETCH_RE`, dieselben vier Schlüssel wie `DeviceSync.swift`; die Windows-App sendet sie nicht, **und seit dem Abend nimmt auch der Dienst sie weder an noch gibt er sie heraus**) | Zwei PCs desselben Kontos überschrieben sich den Zeitpunkt (Befund 5.6 in `docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md`); die Liste `LOCAL_SETTINGS` bleibt unverändert, weil der Mac-Test genau zehn Schlüssel erwartet | `test_own_fetch_state_stays_on_the_device`, `test_the_list_the_mac_test_reads_is_unchanged`, `tests/test_sync.py::test_device_fetch_state_is_neither_taken_nor_handed_out` |
| Dienst liefert die Domain-Bestätigungsdatei von Apple aus (`/.well-known/apple-developer-domain-association.txt`, nur Dienst, nur wenn der Inhaber die Datei hinterlegt) | Ohne sie lässt sich die Services-ID (E1) womöglich nicht bestätigen | `test_apple_domain_association_file_is_served_only_when_the_owner_put_it_there`; als öffentliche Seite im Routen-Inventar `tests/test_rechte_alle_routen.py` eingetragen |
| `tools/e2e-windows-konto.py` | Wiederholbarer echter Lauf (Abschnitt 2); der Inhaber kann ihn selbst starten | der Lauf selbst, Ende mit Code 0 nur bei lauter Treffern |

Nichts an Tarifen, Preisen, Limits, Verträgen in `packages/shared-contracts` oder an dem, was das veröffentlichte iPad
vom Dienst bekommt, wurde geändert. Nur Windows-/Web-Seite und ein reiner Zusatz-Pfad (`/api/app-account/providers`,
gibt es im Dienst nicht).

## 4a. Nachtrag am Abend: eigene Dokumente, Lerngruppen, Neu laden, Sicherung

| Änderung | Warum (Befund) | Test |
| --- | --- | --- |
| **Eigene Dokumente abgleichen (E3, Windows ↔ Dienst/Web).** Neue Dienst-Wege `GET /api/sync/own-documents` (Liste mit SHA-256 und Grabsteinen), `PUT …/{id}` (Beschreibung: Art, Titel, Ordner, Papierkorb, Favorit), `PUT …/{id}/content` (Datei roh, mit `?sha256=`; zählt zum Speicherkontingent des Kontos, `%PDF`-Prüfung), `DELETE …/{id}`, `GET /api/sync/assets` und `PUT /api/sync/assets/{ordner}/{name}` (Bilder in Notizen). Gemeinsame Regeln in `app/own_docs.py`, Windows-Teil `app/own_docs_sync.py`, eingehängt in den bestehenden Abgleich (`sync_client.run`) | Notizbücher und importierte PDFs blieben auf dem Gerät, auf dem sie entstanden | `tests/test_own_docs_sync.py` (10 Fälle: beide Richtungen, gleichzeitige Notizen, Löschen in beide Richtungen, „im Web gelöscht, am PC weiter bearbeitet → bleibt und geht neu hoch“, Tarif Plus → nichts, älterer Dienst → übriger Abgleich läuft, zu große Datei, Prüfungen von Kennung/Inhalt/Kontingent/Hochschuldatei) und der echte Lauf |
| Regeln: **Notizen zu eigenen Dokumenten** kommen im Abruf nur, wenn das Gerät `own=1` sendet – das **veröffentlichte iPad bekommt also nichts Neues** (es kennt die Datei nicht und würde sonst stolpern). Recht wie Notizen (`can_sync_annotations`: Pro AI und Probe). Größte Datei 75 MB (die Antwort des Dienstes ist bei 80 MB gedeckelt). Bei Konflikt gewinnt die Beschreibung des Geräts, das zuletzt geändert hat; die PDF nur, wenn sich der Inhalt wirklich unterscheidet. Endgültig löschen hinterlässt einen Grabstein; hat das andere Gerät inzwischen geändert, bleibt das Dokument (lieber doppelt als verloren). | | `test_published_ipad_does_not_get_notes_of_own_documents` |
| **Sicherung des Dienstes enthält jetzt eigene Dokumente** (`deploy/backup_snapshot.py` nahm den ganzen Ordner `files/` aus – auch `files/Eigene Dokumente/` mit den im Web hochgeladenen PDFs). Hochschuldateien bleiben weiter draußen. | Echte Lücke: nach einer Wiederherstellung wären Web-Importe weg gewesen | `tests/test_deploy.py` (Sicherung enthält `files/Eigene Dokumente/…`, nicht `files/Mathe I/…`) |
| **Konto-Karte der Windows-App** zeigt „Eigene Dokumente … mit der Web-App: 2 hochgeladen, 1 geholt …“, zu große Dateien mit Namen und Fehler | Man soll sehen, was passiert ist | `tests/js/own-docs-line.test.mjs` |
| **Lerngruppen auf mehreren Geräten** (Plan 5.4): Web/Windows zeigen Gruppen, denen das Konto auf einem anderen Gerät beigetreten ist, mit „Code hier einmal eingeben“ bzw. „Verlassen“; falscher Code wird abgewiesen. Der Code liegt weiter nie beim Dienst | Zweiter Browser/PC kannte die Gruppe nicht | `tests/js/community-logic.test.mjs` (pendingGroups), `tests/test_web_community_groups_devices.py` (zwei Geräte im Browser) |
| **Community neu laden** (Plan 5.5): beim Zurückkommen ins Fenster, höchstens einmal je Minute, nie bei einem angefangenen Text oder offenen Fenster, Scrollstand bleibt | Offene Ansicht blieb alt | `tests/js/community-refresh.test.mjs` |
| `tools/e2e-windows-konto.py` um eigene Dokumente erweitert | | 49 von 49 |

**Vor dem Aufspielen auf den Server (Inhaber):** Die Datenschutzerklärung nennt den Abgleich eigener Dokumente der
Windows-App noch nicht (Abschnitt 7 und der Absatz „Windows-App, Abgleich mit dem iPad“ in Abschnitt 8 zählen Notizen,
Module usw. auf). Rechtstexte ändere ich nicht selbst (Entwurf, anwaltliche Prüfung). Vorschlag für den Satz in
`docs/release/DATENSCHUTZ.md` und `site/datenschutz.html`: *„Ab Pro AI (und in der Probe) gleicht die Windows-App auch
deine eigenen Dokumente ab – selbst angelegte Notizbücher, selbst importierte PDFs und Bilder bis 75 MB je Datei –,
damit sie im Web und auf deinen anderen Geräten erscheinen; sie liegen dann in deinem Konto wie im Web hochgeladene
Unterlagen und zählen zu deinem Speicherplatz. Dateien deiner Hochschule sendet die App weiterhin nie.“*

**Bekannte Grenze:** Meldet man sich am selben PC mit einem **anderen** StudiNow-Konto an, gleicht der PC wie bisher bei
G2 (Module, Notizen) alles Vorhandene in das neue Konto ab – jetzt also auch die eigenen Dokumente. Für einen PC mit
einer Person ist das richtig; wer PCs teilt, sollte vorher „Zurücksetzen“ nutzen. Nicht geändert.

## 5. Entscheidungen und Aufgaben für den Inhaber

**E1 – Apple im Browser einschalten (Voraussetzung für „Mit Apple anmelden“ auf Windows und im Web).** Im
Apple-Entwicklerkonto (Zertifikate, IDs & Profile → Identifikatoren → neue **Services-ID**, z. B. `de.uniflow.ai.web`):
„Mit Apple anmelden“ aktivieren, Domain `app.studinow.app` eintragen, Rückkehr-URL `https://app.studinow.app/login`.
Verlangt Apple dabei (wie üblich) eine **Bestätigungsdatei** für die Domain, die Datei von Apple herunterladen und auf den
Server in das Datenvolumen des Dienstes kopieren, z. B.
`docker compose -f deploy/docker-compose.yml cp ./apple-developer-domain-association.txt app:/data/apple-developer-domain-association.txt`;
der Dienst liefert sie dann unter `https://app.studinow.app/.well-known/apple-developer-domain-association.txt` aus (neu
heute, mit Test; ohne Datei antwortet er 404). Danach in `deploy/.env` des Servers
`LERNAPP_APPLE_WEB_CLIENT_ID=<die Services-ID>` setzen und den Dienst neu starten. **Der Dienst auf dem Server muss dafür
den Stand dieses Zweigs bekommen** (die Datei-Route ist neu); die Anmeldeseite selbst läuft dort schon mit `develop`. Die App-Kennung (`de.uniflow.ai`) bleibt in `LERNAPP_APPLE_CLIENT_IDS`. Der Dienst
prüft beide (`app/social_login.py`); die Anmeldeseite blendet den Apple-Knopf dann von selbst ein, die Windows-App
ebenfalls. *Ich vermute, dass Apples Benutzerkennung je Entwicklerteam gilt und die Services-ID unter demselben Team
dieselbe Kennung wie die iPad-App liefert; das steht in keiner Datei und ist nie geprüft. Nach dem Einrichten einmal mit
einem Konto vom iPad auf Windows prüfen.*

**E2 – Community zusammenlegen („Plan A“ aus `docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md` Abschnitt 5).** Heute
sind es zwei Community-Welten. Plan A: iPad und Mac nutzen auch den Dienst (Konto Pflicht für die Community). Der Dienst
kann schon alles (Fragen, Korrekturen, Mitteilungen, Lesezeichen, Stapel); es fehlt die Swift-Seite
(`ServiceCommunityService`: Fragen/Antworten 1 Tag, Korrekturen 1 Tag, Mitteilungen/Lesezeichen 1–2 Tage, Stapel 1 Tag,
Umstellung mit App-Tests). Das muss die Mac-Sitzung bauen; ohne diese Entscheidung bleiben Windows und iPad getrennt.

**E3 – Eigene Dokumente abgleichen. Am Abend gebaut (Windows + Dienst), Abschnitt 4a.** Berichtigung meiner Aussage vom
Nachmittag: Der Dienst speichert schon heute Nutzerdateien – alles, was jemand im Web importiert, liegt im Konto
(`files/Eigene Dokumente/`, Kontingent `LERNAPP_UPLOAD_QUOTA_MB`, im Deploy 512 MB je Konto); diese Dateien fehlten aber
in der Sicherung (behoben). Der neue Abgleich nutzt genau diesen Speicher und dieses Kontingent. Das veröffentlichte
iPad bekommt nichts Neues (Notizen eigener Dokumente nur mit `own=1`). Offen: **Swift-Teil für iPad/Mac**
(`docs/AUFTRAG-MAC-2026-11-12.md`), **Satz in der Datenschutzerklärung** (Abschnitt 4a, Vorschlag) und **Dienst auf dem
Server aktualisieren**.

**E4 – Bezahlen unter Windows.** Stripe ist im Dienst nicht eingerichtet (`purchase.web.available = false`). Ohne Stripe
oder Apple-Abo ist ein Windows-Nutzer nach 7 Tagen gesperrt. Schlüssel und Preise im Stripe-Konto des Inhabers
(`docs/ABO-SYSTEM.md`); ich habe nichts an Zahlungsprodukten oder Preisen angefasst.

**E5 – Zur Kenntnis:** (a) Notizen zwischen Geräten gibt es erst ab **Pro AI** (Entscheidung 04.11.), Plus gilt je
Gerät; Windows-Nutzer mit iPad sollten das vorab erfahren. (b) „Höchstens 3 Geräte je Person“ steht in
`docs/release/TESTFLIGHT-500-2026-11-08.md`, ich habe im Code keine Durchsetzung gefunden.

## 6. Nur auf echten Geräten prüfbar (Checkliste für den Inhaber)

1. **Windows-Laptop, frischer Start:** Installer (erst bauen: GitHub-Abrechnung oder lokal mit Rust) → Anmeldebildschirm →
   E-Mail/Passwort → Probe-Leiste. „Mit Apple anmelden“ nur nach E1; vorher muss der gelbe Hinweis mit „Passwort
   festlegen“ erscheinen.
2. **Stift und Touch im Tauri-Fenster (WebView2):** schreiben, radieren, Zoomen. Im Browserfenster dieser Sitzung meldete
   der PDF-Arbeitsfaden „Fehler beim Laden des Skripts“ (`pdf.worker`), das Dokument lud trotzdem über den Ersatzweg;
   ob WebView2 genauso reagiert, ist offen.
3. **Konto vom iPad auf Windows** (nach E1): auf dem iPad mit Apple am StudiNow-Konto angemeldet → Windows → „Mit Apple
   anmelden“ → derselbe Name/dieselbe E-Mail, dieselbe Probe/dasselbe Abo.
4. **Notizen iPad ↔ Windows** (Pro AI oder Probe): auf dem iPad schreiben, in Windows „Jetzt abgleichen“; gleichzeitig auf
   beiden schreiben; es darf kein Strich fehlen (Gate G2 offen).
5. **Abo-Übernahme:** Apple-Sandbox-Abo auf dem iPad kaufen → Windows zeigt es nach „Erneut prüfen“.
6. **Community Windows ↔ iPad/Mac** erst nach E2.
7. **Installer-Größe, SmartScreen, Deinstallieren (Daten bleiben):** laut `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md`
   Abschnitt 5.
8. **iPhone** (Zweig `feature/iphone`): `docs/IPHONE-STAND-2026-11-06.md` auf dem Zweig, nie auf einem echten iPhone.

## 7. Prüfergebnisse

| Prüfung | Ergebnis |
| --- | --- |
| `node --test tests/js/*.test.mjs` | 441 von 441 bestanden |
| `pytest -q tests` (Gesamtlauf, 20 Min.) | 3253 bestanden, 94 fehlgeschlagen, 4 Fehler beim Aufbau, 25 übersprungen. **91 davon schlagen genauso im unveränderten `origin/develop` fehl** (gleiche Dateien dort laufen lassen; Ursache ist dieser PC: Bash-Skripte mit Windows-Pfaden, `time.tzset` gibt es unter Windows nicht, fehlende Verknüpfungen, Playwright-Seiten). **2 kamen von mir** (neue Variable fehlte in `deploy/.env.example`, neue öffentliche Route fehlte im Routen-Inventar `tests/test_rechte_alle_routen.py`): behoben, danach 192 von 192 in den Dateien zu Konto, Abgleich, Anmeldung, Sicherheit, Betrieb und Rechten bestanden. **5 sind wackelig**: 4 Browser-Tests bestehen allein gestartet auf beiden Ständen; der Test mit dem statischen Webserver scheitert allein gestartet auf beiden Ständen. Ein dritter Fehler von mir (Schutztest gegen den Blubber-Abruf im Abgleich) fiel schon im Vergleichslauf auf und ist behoben. |
| `python tools/e2e-windows-konto.py` | 36 von 36 Prüfungen bestanden (Dienst + 2 Windows-PCs + „iPad“ + zweites Konto) |
| **Nachtrag am Abend:** `node --test tests/js/*.test.mjs` | 449 von 449 bestanden |
| **Nachtrag am Abend:** `pytest -q tests` (Gesamtlauf, 18 Min.) | 3266 bestanden, 93 fehlgeschlagen, 4 Fehler beim Aufbau, 25 übersprungen, 2 xfailed. **91 davon sind dieselben wie im unveränderten `origin/develop`** (Umgebung, siehe oben). Die übrigen 6 sind Zeit- bzw. Browser-Tests: allein gestartet bestehen `test_ai_lastfest` (2) und `test_web_editor_ai` (2); `test_web_studyplan` wackelt – auf diesem Zweig mal ein Fehler, mal 8 von 8 – und hat auf dem unveränderten `develop` ebenfalls einen roten Fall; `test_site` scheitert allein auf beiden Ständen (bekannt). Neu: `tests/test_own_docs_sync.py` 10/10, `tests/test_web_community_groups_devices.py`, Routen-Inventar mit den neuen Wegen grün |
| **Nachtrag am Abend:** `python tools/e2e-windows-konto.py` | **49 von 49** (neu: 13 Prüfungen eigene Dokumente PC 1 → Web → PC 2 und zurück, Löschen) |
| Tauri-/Rust-Tests, Installer-Bau | **nicht möglich** auf diesem PC (Rust fehlt); GitHub Actions ist wegen der Abrechnung gesperrt |
| Echte Geräte (iPad, iPhone, Mac, Windows-Laptop) | **nicht geprüft** |

## 8. Übergabe an die Mac-Sitzung

**Seit dem Abend als fertiger Auftrag: `docs/AUFTRAG-MAC-2026-11-12.md`** (Server aktualisieren, Plan A, eigene
Dokumente auf dem iPad, Passwort festlegen, Neu laden). Die Punkte unten sind der Stand vom Nachmittag.

Nur Wünsche; ich habe an `apps/apple` nichts geändert.

- **Plan A (E2)** nach Entscheidung des Inhabers: `ServiceCommunityService` mit Fragen/Antworten, Korrekturen,
  Mitteilungen, Lesezeichen und Kartenstapeln fertig machen, `communityViaService` wieder einschalten. Der Dienst-Weg ist
  durch `tools/e2e-windows-konto.py` mit einem „iPad-Konto“ (Header `X-StudiNow-Client: ios`) erprobt.
- **„Passwort für andere Geräte festlegen“** im iPad-Konto-Menü: ruft `POST /api/account/password/reset-request` mit der
  eigenen Adresse auf (öffentlich, immer gleiche Antwort). Das ist der Weg für Apple-Konten auf Windows, solange E1 fehlt;
  danach wird das iPad einmal abgemeldet (Reset beendet alle Sitzungen) und meldet sich mit Apple wieder an, der Dienst
  verknüpft über die bestätigte Adresse.
- **`link/apple` in der Oberfläche** (Konto zuerst auf Windows, dann auf dem iPad mit Apple verknüpfen): Endpunkt und
  `StudoraAccount.linkApple` sind da, es fehlt der Knopf.
- **Eigene Dokumente (E3):** Dienst und Windows sind fertig; Vertrag in `docs/VERTRAEGE-KONTO-SYNC.md` („Eigene
  Dokumente“), Swift-Teil im Mac-Auftrag.
- Die Liste `DeviceSyncCore.localSettings` bleibt wie sie ist; Windows und Dienst halten zusätzlich die Abrufstände
  per Muster `sync.DEVICE_FETCH_RE` am Gerät (auch `studip_bulletin_fetched_at` ohne `_v2`).
