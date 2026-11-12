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
3. **Eigene Dokumente (selbst angelegte Notizbücher, importierte PDFs und Bilder):** Sie gleichen sich **nirgends**
   ab – weder zwischen zwei Windows-PCs noch mit dem iPad. Nur Notizen auf Hochschul-Dateien (Stud.IP/Learnweb) wandern
   mit dem Konto, und das erst ab Pro AI.

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
| **Abgleich: eigene Dokumente** (Notizbuch, importierte PDF/Bild) | **✘** im Lauf bestätigt: kommt auf PC 2 nicht an | ✘ (steht als „folgt später“ im Vertrag) | ✘ | ✘ | ✘ |
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
| Abgleich: Stand des eigenen Abrufs von Schwarzem Brett/Blubber bleibt am Gerät (`_OWN_FETCH_RE` in `app/sync_client.py`, dieselben vier Schlüssel wie `DeviceSync.swift`) | Zwei PCs desselben Kontos überschrieben sich den Zeitpunkt (Befund 5.6 in `docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md`); die Liste `LOCAL_SETTINGS` bleibt unverändert, weil der Mac-Test genau zehn Schlüssel erwartet | `test_own_fetch_state_stays_on_the_device`, `test_the_list_the_mac_test_reads_is_unchanged` |
| Dienst liefert die Domain-Bestätigungsdatei von Apple aus (`/.well-known/apple-developer-domain-association.txt`, nur Dienst, nur wenn der Inhaber die Datei hinterlegt) | Ohne sie lässt sich die Services-ID (E1) womöglich nicht bestätigen | `test_apple_domain_association_file_is_served_only_when_the_owner_put_it_there`; als öffentliche Seite im Routen-Inventar `tests/test_rechte_alle_routen.py` eingetragen |
| `tools/e2e-windows-konto.py` | Wiederholbarer echter Lauf (Abschnitt 2); der Inhaber kann ihn selbst starten | der Lauf selbst, Ende mit Code 0 nur bei lauter Treffern |

Nichts an Tarifen, Preisen, Limits, Verträgen in `packages/shared-contracts` oder an dem, was das veröffentlichte iPad
vom Dienst bekommt, wurde geändert. Nur Windows-/Web-Seite und ein reiner Zusatz-Pfad (`/api/app-account/providers`,
gibt es im Dienst nicht).

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

**E3 – Eigene Dokumente abgleichen.** Notizbücher haben nur ein paar KB, importierte PDFs bis zu 50 MB. Dafür müsste der
Dienst **Nutzerdateien speichern** (Speicherplatz auf dem Server, Datenschutztext, Löschfristen). Bisher speichert er
bewusst keine Dateien. Vorschlag zum Vorgehen: erst Notizbücher (ohne Dateien), dann importierte Dateien mit Obergrenze
je Konto. Beides braucht einen neuen Teil im Vertrag G2 und Arbeit auf iPad und Windows; ich habe es **nicht** gebaut,
weil eine Änderung am Abgleich das veröffentlichte iPad treffen könnte, das ich nicht prüfen kann.

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
| Tauri-/Rust-Tests, Installer-Bau | **nicht möglich** auf diesem PC (Rust fehlt); GitHub Actions ist wegen der Abrechnung gesperrt |
| Echte Geräte (iPad, iPhone, Mac, Windows-Laptop) | **nicht geprüft** |

## 8. Übergabe an die Mac-Sitzung

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
- **Eigene Dokumente (E3)**, falls der Inhaber es will: gemeinsam mit mir den Vertrag G2 erweitern, damit das
  veröffentlichte iPad nicht stolpert (neue Einträge im Abruf nur, wenn der Client sie anfordert).
- Die Liste `DeviceSyncCore.localSettings` bleibt wie sie ist; Windows hat jetzt zusätzlich `OWN_FETCH_SETTINGS`
  (`studip_bulletin_fetched_at` ohne `_v2`), die das iPad nicht schreibt.
