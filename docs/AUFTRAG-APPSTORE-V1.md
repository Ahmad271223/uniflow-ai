# Auftrag: App-Store-Version 1 (iPad) und Abos

Stand 25.10.2026, Vorgabe des Inhabers. **Dieses Dokument hat Vorrang** vor der Reihenfolge in
`docs/UEBERGABE-MAC.md` und `docs/PRUEFBERICHT-IPAD.md`. Die Regeln aus der Übergabe gelten weiter (echte Daten,
schreibende Tests nur mit Zustimmung, `[skip ci]`, kein `main`, keine Passwörter eintippen).

## 1. Fahrplan

| Phase | Wann | Plattformen | Editor | Anmeldung |
|---|---|---|---|---|
| **V1** | jetzt | **iPad im App Store** – noch kein Play Store, kein Windows | **Apple-Editor** (PencilKit + PDFKit, der vorhandene native Editor) | **Mit Apple anmelden** |
| **V2** | ca. 1 Monat nach V1 | zusätzlich **Android (Play Store)** und **Windows** | **eigener UniFlow-Editor** (1:1 wie im Web). Auf Apple in den Einstellungen wählbar: „Apple-Editor“ oder „UniFlow-Editor“. Windows und Android: nur UniFlow-Editor | zusätzlich **Google** und **SMS** |

Abos gibt es **von Anfang an**: **Free** dauerhaft ohne Abo; **Plus** beginnt mit **7 Tagen kostenlos als
Apple-Einführungsangebot** („1 Woche gratis“, entschieden am 25.10.2026), danach kostenpflichtig, wenn nicht gekündigt
(Abschnitt 4 und 5). **Entscheidung des Inhabers vom 25.10.2026: Pro und KI entfallen vorerst** – es gibt nur Free
(mit Lernplanung) und Plus (zusätzlich Schreiben mit Apple Pencil und Community).

## 2. Was das für V1 bedeutet

1. **V1 läuft ohne den PC-Server.** Wer die App aus dem App Store lädt, hat keinen UniFlow-Server. Alles, was heute
   über `/api/...` vom PC kommt, muss in V1 auf dem iPad selbst entstehen:
   - **Datenhaltung lokal** (SQLite, Schema aus `app/db.py`, mit Migrationen) – Prüfbericht F3.
   - **Logik auf dem Gerät:** Swift-Port von `app/study.py` (Lernpakete, Zeitfenster, Machbarkeit, Kalender,
     Nachholen, „Woche retten“, Übersicht), `app/timetable.py` (Termine, Ausnahmen, freie Fenster, ICS) und
     `app/scriptsearch.py` (Skriptsuche ohne KI). Einordnung der Dateien ohne KI wie `study.effective_type`
     (Stud.IP-Ordner, Dateiname).
   - **Datenquelle Stud.IP direkt** (`StudIPClient`/`StudIPSync`, Anmeldung durch den Nutzer auf der echten Seite):
     Kurse, Ordner, Dateien, dazu Termine und Kurszeiten (`seminar-cycle-dates`, siehe `docs/QIS-STUDIP-STRUKTUR.md`) –
     Prüfbericht F5. Dateien bleiben nur auf dem Gerät (Urheberrecht, `docs/IPAD-STUDIP-SYNC.md`).
   - Bewährter Weg: Das lokale Backend beantwortet dieselben Endpunkte mit derselben JSON-Form wie der Python-Server,
     dann bleiben die fertigen 1:1-Ansichten unverändert. Antworten mit dem Python-Server auf derselben
     Testdatenbank vergleichen.
   - Der Verbindungsbildschirm zum PC-Server bleibt nur als Modus für den Inhaber (Entwicklung, eigene Daten).
2. **Editor in V1 = Apple-Editor.** Der vorhandene PencilKit-Editor wird fertig und stabil gemacht, im neuen Design
   (Dokumentansicht wie im Web: Kopfzeile, Tabs, geteilte Ansicht, Skript-Hinweis, Vollbild). Pflicht für V1:
   Prüfbericht K3 (Dokument öffnen, Notizbücher, „gelesen“, Seite/Aufgabe) und K4 (Hochformat).
   Der 1:1-Port des Web-Editors (Prüfbericht F1) wird zur **Editor-Version für V2**.
3. **Ein Notizformat für beide Editoren:** Apple-Editor und UniFlow-Editor speichern in dasselbe Format
   (`packages/shared-contracts/annotations.schema.json`, `StrokeConverter`), damit Notizen beim Editorwechsel und ab
   V2 auf Windows/Android erhalten bleiben. Heute verlustbehaftet: PencilKit-Tinten außer Stift/Bleistift/Marker
   werden als „Stift“ gespeichert, Text/Formen/Bilder sind im Apple-Editor nur sichtbar. Für V1 reicht: nichts geht
   verloren, was in V1 entstehen kann.
4. **KI entfällt in V1** (Entscheidung des Inhabers vom 25.10.2026, Abschnitt 6): KI-Funktionen werden weder
   angeboten noch beworben – nichts vortäuschen. Ein KI-Schlüssel darf nie in der App liegen.
5. **iPad-only:** `TARGETED_DEVICE_FAMILY` auf `2` (heute `1,2` mit iPhone).

## 2a. Erster Start – Vorgabe des Inhabers (25.10.2026, verbindlich)

**App laden → mit Apple ID registrieren → Free oder Plus wählen → direkt die UniFlow-Oberfläche.**
Keine PIN, keine Serveradresse, kein Verbindungsformular, keine weiteren Pflichtschritte.

| Schritt | Bildschirm | Einzelheiten |
|---|---|---|
| 1 | **Begrüßung** im UniFlow-Design | Logo, ein Satz, Knopf „Mit Apple anmelden“ (`SignInWithAppleButton`, Umfang Name und E-Mail). Nutzerkennung (`credential.user`) im Schlüsselbund speichern |
| 2 | **Tarif wählen** | Zwei Karten Free / Plus mit den Inhalten aus Abschnitt 4; Preise aus `Product.displayPrice`, bei Anspruch „1 Woche gratis“ (Abschnitt 5). „Free nutzen“ → weiter. „Plus – 1 Woche gratis“ → Apple-Kaufdialog → nach Erfolg weiter, bei Abbruch bleibt die Seite. Dazu „Käufe wiederherstellen“ und Links zu Nutzungsbedingungen und Datenschutzerklärung (Pflicht bei Abos) |
| 3 | **UniFlow-Oberfläche** | App-Rahmen mit Seitenleiste, Übersicht – sofort, ohne Zwischenschritt |

- **Stud.IP verbinden geschieht in der App**, nicht beim Start: Solange Stud.IP nicht verbunden ist, zeigt die
  Übersicht oben eine Karte „Stud.IP verbinden“ (öffnet die echte Stud.IP-Anmeldung, `StudIPView`); ebenso in den
  Einstellungen.
- **Späterer Start:** angemeldet → direkt die Übersicht. Beim Start still
  `ASAuthorizationAppleIDProvider().getCredentialState(forUserID:)` prüfen; bei `revoked` oder `notFound` zurück zur
  Begrüßung (lokale Daten bleiben). Die Tarifwahl erscheint nur beim ersten Mal; danach Tarif wechseln, kündigen
  (`manageSubscriptionsSheet`) und wiederherstellen in den Einstellungen.
- **Nie im normalen Start:** das Formular „UniFlow-Server“ (Adresse, PIN), Hinweise auf den PC, `Start-iPad.cmd` oder
  PINs. Die Verbindung zum eigenen PC-Server wandert in die Einstellungen unter „Entwicklung“ → „Mit eigenem
  UniFlow-Server verbinden“ (nur für den Inhaber zum Prüfen mit seinen Daten).
- **Ohne PC-Server:** Damit nach dem Start Daten erscheinen, braucht V1 das lokale Backend (Abschnitt 2, Punkt 1).
  Bis es fertig ist, zeigt die App leere Zustände mit dem Weg zu „Stud.IP verbinden“ – **keine Beispieldaten**.
- **Testen:** „Mit Apple anmelden“ braucht die Fähigkeit *Sign in with Apple*, die es nur mit dem bezahlten Apple
  Developer Program gibt (richtet der Inhaber ein). Bis dahin den Ablauf bauen und alles außer der echten Anmeldung im
  Simulator prüfen; nur in Debug-Builds darf ein deutlich beschrifteter Knopf „Anmeldung überspringen (Debug)“ die
  Anmeldung überbrücken. „Mit Apple anmelden“ erst nach einer echten Anmeldung auf „Getestet“ setzen.
- **Konto löschen** in den Einstellungen (Richtlinie 5.1.1(v)): lokale Kontodaten und Schlüsselbund-Einträge
  entfernen, zurück zur Begrüßung; Abos kündigt der Nutzer bei Apple (Hinweis mit Link zur Abo-Verwaltung).

**Abnahme:**
1. Neuinstallation im Simulator: Begrüßung → Mit Apple anmelden → Tarifwahl → Übersicht. Nirgends Adresse oder PIN.
2. „Free nutzen“ und „Plus – 1 Woche gratis“ (StoreKit-Testkonfiguration) führen beide zur Übersicht; mit Plus sind
   die Plus-Funktionen frei, mit Free gesperrt (Schloss, Weg zur Abo-Seite).
3. Zweiter Start: direkt die Übersicht.
4. Konto löschen → Begrüßung.

## 3. Neue Reihenfolge für den Mac

1. **Erster Start** (Abschnitt 2a): Begrüßung, Mit Apple anmelden, Tarifwahl, danach direkt UniFlow; das
   Verbindungsformular aus dem normalen Start entfernen.
2. Prüfbericht **K2–K11** und **K3/K4** (K1 entfällt, keine KI in V1).
3. **Lokales Backend** (F3) mit **Stud.IP direkt** als Datenquelle (F5) – damit ist auch Offline (F2) erfüllt.
4. **Abos vollständig** (Abschnitt 4 und 5: Sperren je Tarif, Probewoche, Wiederherstellen, Verwalten) und
   **Konto löschen**.
5. **Apple-Editor** fertig und stabil (Dokumentansicht im neuen Design).
6. **App-Store-Vorbereitung** (Abschnitt 7), Bildvergleich, Gerätetest mit Apple Pencil.
7. Danach **V2**: UniFlow-Editor 1:1 (F1), Editor-Wahl in den Einstellungen, Windows/Android.

## 4. Abos – was in welchem Tarif enthalten ist

Grundlage: `docs/KONTEN-ABOS-PLAN.md` und `app/billing.py` (dort noch Free/Plus/Pro; der PC-Server dient nur der
Entwicklung). **Preise und Umfang legt der Inhaber fest.**

**Entscheidung des Inhabers (25.10.2026): Pro und KI entfallen vorerst komplett.** Es gibt nur **Free** und **Plus**;
die Lernplanung gehört zu Free. Keine KI-Zeilen, kein Pro, kein KI-Kontingent. Das ersetzt auch die Angaben zu Pro in
Abschnitt 2a (Tarifwahl: zwei Karten Free / Plus) und in der Startnachricht.

| Funktion | Free | Plus |
|---|:---:|:---:|
| Mit Apple anmelden, Stud.IP verbinden, Kurse/Ordner/neue Dateien abgleichen | ✓ | ✓ |
| Dokumente öffnen, lesen und durchsuchen, Bibliothek, Ordner, Favoriten | ✓ | ✓ |
| Meine Module (Fächer geordnet), Stundenplan ansehen | ✓ | ✓ |
| Lernkalender ansehen, Aufgaben abhaken | ✓ | ✓ |
| **Lernplanung**: Lernplan erstellen, Lernkombination, freie Zeitfenster, Nachholen, „Woche retten“ | ✓ | ✓ |
| Zeitmesser (Stoppuhr, Countdown, Pomodoro) | ✓ | ✓ |
| Vorhandene Notizen ansehen und als PDF exportieren | ✓ | ✓ |
| Uni & Noten (QIS: Notenspiegel, Bescheinigungen) – vorerst außerhalb der Tarife, sobald nativ vorhanden (F4) | bald | bald |
| **Schreiben mit Apple Pencil** (Stift, Marker, Radierer, Lasso), Seiten einfügen/drehen/Papierkorb, Lesezeichen | – | ✓ |
| **Community über CloudKit** (Plus): Lösungen als Datei teilen und im Editor ansehen (S9) sowie in der Community veröffentlichen, finden, laden, zurückziehen, melden, blockieren, Lerngruppen (S9b, `docs/LOESUNGEN-TEILEN.md` Abschnitt 7); läuft nur in einem Build mit iCloud-Container (Developer Program), sonst sagt die App „nicht verfügbar“ und der Dateiweg bleibt | – | ✓ |
| **Übung und Skript nebeneinander** + Skriptsuche zur Aufgabe | – | ✓ |
| Eigene Karteikarten mit Wiederholung | – | ✓ |
| ab V2: UniFlow-Editor (auf Apple wählbar) | – | ✓ |
| ab V2: Abgleich zwischen eigenen Geräten (iPad, Windows, Android) | – | ✓ |
| **Preis** | 0 €, dauerhaft | 1,99 €/Monat (kein Einführungsangebot; 7 Tage Probe mit allem für jede Person, Abschnitt 5) |

Regeln:
- **Herabstufen:** Notizen bleiben vollständig erhalten, lesbar und exportierbar; nur Bearbeiten wird gesperrt.
- **Sperren sichtbar machen:** Gesperrte Funktionen zeigen ein Schloss und führen zur Abo-Seite, statt zu
  verschwinden oder still nichts zu tun.
- **„bald“ ehrlich kennzeichnen:** Uni & Noten ist in keinem Tarif freigeschaltet, bis es auf dem iPad wirklich
  funktioniert; die Community (Plus) ist über CloudKit umgesetzt und nur in einem Build mit iCloud-Container
  freigeschaltet – ohne Container erscheint kein Menüpunkt „Community“, der Knopf „In der Community veröffentlichen“
  bleibt gesperrt und die Einstellungen sagen, warum (nichts vortäuschen); Lösung als Datei teilen und ansehen geht
  immer.
- **KI** entfällt vorerst (Abschnitt 6); KI-Funktionen werden weder angeboten noch beworben.

## 5. Abos technisch (V1)

**Entscheidung des Inhabers vom 04.11.2026 (ersetzt die Entscheidung vom 25.10.2026 „Apple-Einführungsangebot auf
Plus, eigene Probe wird nicht gebaut“):** drei Tarife **Free**, **Plus 1,99 €/Monat** (`de.uniflow.plus.monthly`) und
**Pro AI 3,99 €/Monat** (`de.uniflow.proai.monthly`), **keine Apple-Einführungsangebote**. Jede Person bekommt ab dem
ersten Start **7 Tage „Probe“ mit allem wie Pro AI**, ohne Zahlungsdaten, einmal je Apple-ID; danach automatisch Free.
Alles, was in der Probe entsteht, bleibt; gesperrte Funktionen zeigen danach „Jetzt freischalten“ (die vorhandene
Plus-Sperre, `UFLockedSheet`/`UFLockedCard`). Wer Plus kauft, hat Plus; wer Pro AI kauft, Pro AI (StoreKit-Berechtigung
wie bisher). Der Dienst hat diese Probe für StudiNow-Konten schon (`app/plans.py` `TRIAL`, `app/billing.py`
`start_trial`); das iPad macht dasselbe **ohne Dienst**.

- **StoreKit 2**, eine Abo-Gruppe „StudiNow“ mit zwei Produkten: `de.uniflow.plus.monthly` (Stufe 2) und
  `de.uniflow.proai.monthly` (Stufe 1), in `apps/apple/UniFlowTests/UniFlow.storekit` und `Purchases/Plans.swift`
  (`UFPlanCatalog.sellable`). Kein `introductoryOffer` in beiden `.storekit`-Dateien. `de.uniflow.pro.monthly` (alt)
  und `de.uniflow.proconnect.monthly` geben in der App keinen kaufbaren Tarif (Pro Connect bleibt nur im Vertrag).
- **Probe auf dem iPad** (`Purchases/LocalTrial.swift`, `UFLocalTrial`): Mit der ersten Anmeldung (Sign in with Apple
  ist Pflicht) hält die App den Beginn fest, geschlüsselt mit einem Hash der Apple-Nutzer-ID
  (`DataContainerKey.userScope`), nie die ID selbst. Ablage im **Schlüsselbund des Geräts** (eigener Dienst
  `de.uniflow.ai.trial`, nur dieses Gerät, überlebt eine Neuinstallation) **und** im **iCloud-Schlüssel-Wert-Speicher**
  (`NSUbiquitousKeyValueStore`, zweites iPad derselben Apple-ID). Gelesen werden beide, der frühere Beginn gilt; ohne
  iCloud zählt der Schlüsselbund allein. Reine Funktionen „läuft / Resttage / vorbei“ mit Uhr von außen
  (`UFLocalTrial.state`, `resolve`), Resttage aufgerundet wie `billing.trial_info`. Während der Probe ist der wirksame
  Tarif `pro_ai` (dieselbe Rechte-Tabelle wie der Dienst, `plans.json`); danach Free, es sei denn StoreKit meldet Plus
  oder Pro AI. **Vorrang:** Dienst-Probe (`StudoraAccountLink.planStatus`) > App Store > Probe auf dem iPad > Free
  (`UFPlanPrecedence`). Startargument `-UFPlan` (Debug) setzt einen festen Tarif ohne Proben.
- **Oberfläche:** Übersicht mit `TrialBanner` („Probe: noch n Tage alles frei“, danach „Deine Probe ist vorbei“ mit
  „Tarife ansehen“ und „Bei Free bleiben“; Free bleibt nutzbar). Tarifseite (`PlanPickerView`) mit den Karten Free,
  Plus und Pro AI; die Pro-AI-Karte erscheint **nur, wenn StoreKit das Produkt liefert** (vor dem StudiNow-Dienst steht es
  nicht im Store, dann nur Free und Plus plus der Satz „StudiNow Pro AI folgt mit dem StudiNow-Dienst.“) und trägt die
  ehrliche Zeile „StudiNow Pro AI braucht den StudiNow-Dienst …“. Preise nur aus `Product.displayPrice`; Kopf der Seite
  „7 Tage Probe mit allem, danach Free – ohne Zahlungsdaten“, solange die Probe läuft. „Aktueller Tarif“ ist immer der
  gekaufte Tarif (`Entitlements.purchasedPlan`), nie die Probe. Einstellungen → Tarif zeigt während der Probe
  „Probe: noch n Tage alles frei“.
- **Berechtigung in V1 auf dem Gerät:** `Transaction.currentEntitlements` (von StoreKit signiert und geprüft),
  `Transaction.updates` beobachten, „Käufe wiederherstellen“ (`AppStore.sync()`), „Abo verwalten“
  (`manageSubscriptionsSheet`). Ab V2 prüft zusätzlich der Server (`/api/billing/apple/verify`,
  App Store Server Notifications), weil das Abo dann auch auf Windows/Android gelten soll.
- **Tests:** mit der StoreKit-Testkonfiguration im Simulator (kaufen je Tarif, Ablauf, Verlängerung, Kündigung,
  Erstattung, Wiederherstellen, Karten mit und ohne Pro-AI-Produkt: `PurchaseTests`, `PurchaseV2PlanSwitchTests`),
  Unit-Tests für die Zuordnung Produkt → Tarif → Funktion (`EntitlementTests`, `PlanContractTests`) und für die Probe
  (`LocalTrialTests`: Zustandsautomat mit festen Daten, frühester Beginn, Vorrang, Probe-Karte, Schlüsselbund).
- **Noch einzurichten (Inhaber):** Berechtigung `com.apple.developer.ubiquity-kvstore-identifier` in
  `UniFlow.entitlements` (sonst nur Schlüsselbund, s. `docs/RELEASE-VORBEREITUNG.md`); in App Store Connect beide
  Produkte ohne Einführungsangebot, Pro AI erst mit dem Dienst einreichen (`docs/release/APP-STORE.md`).
- **Keine echten Produkte, keine Preise in App Store Connect, keine Einreichung zur App-Prüfung** ohne ausdrückliche
  Freigabe des Inhabers. Alles Kostenpflichtige (Developer Program, Produkte, Dienste) richtet der Inhaber selbst ein.

## 6. Entscheidungen des Inhabers

| Thema | Stand |
|---|---|
| **Tarife** | **Ergänzt am 04.11.2026 (iPad):** die App bietet Free, Plus (1,99 €) und Pro AI (3,99 €) an; Pro Connect gibt es auf dem iPad nicht, die Pro-AI-Karte nur mit Produkt aus dem Store (Abschnitt 5). **Ersetzt am 27.10.2026:** vier Tarife StudiNow Free/Plus/Pro Connect/Pro AI (0/1,99/2,99/3,99 €), siehe `docs/ABO-SYSTEM.md`. Bisher: **Entschieden (25.10.2026):** nur Free und Plus; Pro entfällt vorerst. Free mit Lernplanung, Plus zusätzlich mit Schreiben (Apple Pencil) und Community (Abschnitt 4) |
| **Community** | **Entschieden (26.10.2026):** Community über CloudKit (Plus), später tauschbar (Supabase/eigener Dienst hinter `CommunityService`). Berechtigung = Kenntnis der Kurs-ID oder des Kursnamens, keine Bestätigung der Hochschule. Moderation macht der Inhaber im CloudKit Dashboard (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 7). Braucht das Developer Program (iCloud-Container) |
| **Art der 7 Tage** | **Ersetzt am 04.11.2026:** eigene 7-Tage-Probe mit allem wie Pro AI für jede Person ab dem ersten Start, ohne Zahlungsdaten, einmal je Apple-ID, auf dem iPad ohne Dienst (Schlüsselbund und iCloud-Schlüssel-Wert-Speicher); keine Apple-Einführungsangebote; danach Free (Abschnitt 5). Bisher: **Entschieden (25.10.2026):** Apple-Einführungsangebot, 1 Woche gratis auf Plus |
| **KI in V1** | **Ersetzt am 27.10.2026:** StudiNow-KI über das Backend (KI-Tests ab Plus, Pro AI mit eigener OpenAI-API), Kostenkontrolle im Dienst, siehe `docs/ABO-SYSTEM.md`. Bisher: **Entschieden (25.10.2026):** KI entfällt vorerst komplett, keine KI-Zeilen und keine KI-Kontingente. KI bräuchte ohne PC einen kostenpflichtigen Dienst und einen kleinen eigenen Server (der Schlüssel darf nicht in die App) |
| **Preise** | Plus 1,99 €/Monat, Pro AI 3,99 €/Monat, keine Einführungsangebote (04.11.2026; Plus-Preis seit 25.10.2026). Offen: Jahresabo ja/nein |
| **Server für V2** | Offen. Google- und SMS-Anmeldung, Abgleich zwischen Geräten und Abos über Plattformen hinweg brauchen einen gehosteten Dienst (Kosten, Betrieb, Datenschutz). SMS kostet pro Nachricht |
| **Apple Developer Program** | Offen, Anmeldung durch den Inhaber. 99 €/Jahr, Voraussetzung für „Mit Apple anmelden“, TestFlight, App Store und echte Abos |
| **Rechtliches vor dem Start** | Offen. Datenschutzerklärung (URL in App Store Connect), Impressum, Abo-Bedingungen; rechtliche Prüfung des Stud.IP-Abrufs für andere Studierende (`docs/IPAD-STUDIP-SYNC.md`, Abschnitt 8) |

## 7. App-Store-Vorbereitung (V1)

- `NSAllowsArbitraryLoads` entfernen; Stud.IP läuft über HTTPS, der PC-Modus nur für lokale Adressen
  (`NSAllowsLocalNetworking`). **Erledigt (Abnahme 26.10.2026):** keine ATS-Ausnahme im Release, lokales Netz nur Debug.
- Datenschutz-Manifest `PrivacyInfo.xcprivacy` und Datenschutzangaben in App Store Connect (gesammelte Daten:
  Anmeldung, Käufe; keine Weitergabe; kein Tracking). **Manifest erledigt (26.10.2026)**; die Angaben in App Store
  Connect trifft der Inhaber (Checkliste `RELEASE-VORBEREITUNG.md`).
- Anmeldung: „Mit Apple anmelden“ als Fähigkeit (braucht das Developer Program); **Konto löschen** in der App.
  Vorgabe des Inhabers: Anmeldung beim ersten Start (Abschnitt 2a). Risiko bei der App-Prüfung (Richtlinie
  5.1.1(v): Pflichtanmeldung ohne kontobezogene Funktionen) – auf der Begrüßung kurz zeigen, wofür das Konto dient
  (Abo, Stud.IP-Zuordnung, ab V2 Abgleich zwischen Geräten); lehnt Apple ab, entscheidet der Inhaber.
- Ab V2 mit Google-Anmeldung: Richtlinie 4.8 ist durch „Mit Apple anmelden“ erfüllt.
- Texte, Bildschirmfotos (iPad 13"), Altersfreigabe, Support-URL; `docs/RELEASE-VORBEREITUNG.md`.
- Gerätetest mit Apple Pencil (`docs/MAC-IPAD-CHECKLISTE.md`), TestFlight erst nach Freigabe.

## Startnachricht für die Mac-Sitzung

> Hol mit `git pull` den neuen Stand und lies zuerst `docs/AUFTRAG-APPSTORE-V1.md` – das hat Vorrang. V1 ist die
> iPad-App im App Store mit Apple-Editor, „Mit Apple anmelden“ und Abos (Free dauerhaft; Plus mit 1 Woche gratis als Apple-Einführungsangebot). Sie
> muss ohne meinen PC-Server laufen. Beginne mit dem ersten Start (Abschnitt 2a: App laden → mit Apple ID registrieren
> → Free/Plus wählen → direkt UniFlow, ohne PIN) und arbeite dann nach der Reihenfolge in Abschnitt 3. Keine echten Produkte, keine
> Einreichung, nichts Kostenpflichtiges ohne mich; offene Entscheidungen (Abschnitt 6) fragst du mich.
