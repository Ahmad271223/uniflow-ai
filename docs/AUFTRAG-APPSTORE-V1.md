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
| **Community**: Lösungen als Datei teilen und im Editor ansehen (S9, `docs/LOESUNGEN-TEILEN.md`); Online-Community folgt (Knopf deaktiviert, „Community-Dienst noch nicht verbunden“) | – | ✓ |
| **Übung und Skript nebeneinander** + Skriptsuche zur Aufgabe | – | ✓ |
| Eigene Karteikarten mit Wiederholung | – | ✓ |
| ab V2: UniFlow-Editor (auf Apple wählbar) | – | ✓ |
| ab V2: Abgleich zwischen eigenen Geräten (iPad, Windows, Android) | – | ✓ |
| **Preis** | 0 €, dauerhaft | 1,99 €/Monat, 1 Woche gratis (Apple-Einführungsangebot) |

Regeln:
- **Herabstufen:** Notizen bleiben vollständig erhalten, lesbar und exportierbar; nur Bearbeiten wird gesperrt.
- **Sperren sichtbar machen:** Gesperrte Funktionen zeigen ein Schloss und führen zur Abo-Seite, statt zu
  verschwinden oder still nichts zu tun.
- **„bald“ ehrlich kennzeichnen:** Uni & Noten ist in keinem Tarif freigeschaltet, bis es auf dem iPad wirklich
  funktioniert; von der Community ist nur der Teil freigeschaltet, der ohne Dienst wirklich funktioniert (Lösung als
  Datei teilen und ansehen, Plus). Veröffentlichen in der Online-Community bleibt deaktiviert – nichts vortäuschen.
- **KI** entfällt vorerst (Abschnitt 6); KI-Funktionen werden weder angeboten noch beworben.

## 5. Abos technisch (V1)

- **StoreKit 2**, eine Abo-Gruppe „UniFlow“ mit **einem** Produkt: `de.uniflow.plus.monthly` (in
  `apps/apple/UniFlowTests/UniFlow.storekit` und `Purchases/PurchaseStore.swift`). `de.uniflow.pro.monthly` entfällt
  vorerst (Entscheidung 25.10.2026) und gibt in der App keinen Tarif mehr.
- **7 Tage kostenlos – entschieden (Inhaber, 25.10.2026): Apple-Einführungsangebot „1 Woche gratis“ auf Plus.**
  Umsetzung:
  - StoreKit-Testkonfiguration (`apps/apple/UniFlowTests/UniFlow.storekit`): beim Plus-Produkt
    `introductoryOffer` mit `paymentMode: free`, `subscriptionPeriod: P1W`, `numberOfPeriods: 1` (eingetragen).
    In App Store Connect richtet der Inhaber dasselbe Angebot später selbst ein.
  - Anspruch prüfen mit `Product.SubscriptionInfo.isEligibleForIntroOffer` (je Abo-Gruppe, Apple merkt sich die
    Nutzung pro Apple ID): Hat jemand die Woche schon genutzt, zeigt die Abo-Seite den normalen Preis statt
    „1 Woche gratis“.
  - Vor dem Kauf klar sichtbar: „1 Woche gratis, danach 1,99 €/Monat, monatlich kündbar“
    (Richtlinie 3.1.2); Preise immer aus `Product.displayPrice`, nie fest im Code.
  - Während der Gratiswoche gilt der volle Umfang von Plus (StoreKit liefert die Berechtigung wie bei
    einem bezahlten Abo). Wird gekündigt, endet der Zugang mit der Woche und die App fällt auf Free zurück.
  - Free bleibt ohne Abo dauerhaft nutzbar. Eine Probezeit ohne Zahlungsdaten (eigene 7-Tage-Freischaltung) wird
    **nicht** gebaut.
- **Berechtigung in V1 auf dem Gerät:** `Transaction.currentEntitlements` (von StoreKit signiert und geprüft),
  `Transaction.updates` beobachten, „Käufe wiederherstellen“ (`AppStore.sync()`), „Abo verwalten“
  (`manageSubscriptionsSheet`). Ab V2 prüft zusätzlich der Server (`/api/billing/apple/verify`,
  App Store Server Notifications), weil das Abo dann auch auf Windows/Android gelten soll.
- **Tests:** mit der StoreKit-Testkonfiguration im Simulator (kaufen, Probezeit, Ablauf, Verlängerung, Kündigung,
  Erstattung, Wiederherstellen) und Unit-Tests für die Zuordnung Produkt → Tarif → Funktion.
- **Keine echten Produkte, keine Preise in App Store Connect, keine Einreichung zur App-Prüfung** ohne ausdrückliche
  Freigabe des Inhabers. Alles Kostenpflichtige (Developer Program, Produkte, Dienste) richtet der Inhaber selbst ein.

## 6. Entscheidungen des Inhabers

| Thema | Stand |
|---|---|
| **Tarife** | **Entschieden (25.10.2026):** nur Free und Plus; Pro entfällt vorerst. Free mit Lernplanung, Plus zusätzlich mit Schreiben (Apple Pencil) und Community (Abschnitt 4) |
| **Art der 7 Tage** | **Entschieden (25.10.2026):** Apple-Einführungsangebot, 1 Woche gratis auf Plus (Abschnitt 5) |
| **KI in V1** | **Entschieden (25.10.2026):** KI entfällt vorerst komplett, keine KI-Zeilen und keine KI-Kontingente. KI bräuchte ohne PC einen kostenpflichtigen Dienst und einen kleinen eigenen Server (der Schlüssel darf nicht in die App) |
| **Preise** | Plus 1,99 €/Monat (25.10.2026). Offen: Jahresabo ja/nein |
| **Server für V2** | Offen. Google- und SMS-Anmeldung, Abgleich zwischen Geräten und Abos über Plattformen hinweg brauchen einen gehosteten Dienst (Kosten, Betrieb, Datenschutz). SMS kostet pro Nachricht |
| **Apple Developer Program** | Offen, Anmeldung durch den Inhaber. 99 €/Jahr, Voraussetzung für „Mit Apple anmelden“, TestFlight, App Store und echte Abos |
| **Rechtliches vor dem Start** | Offen. Datenschutzerklärung (URL in App Store Connect), Impressum, Abo-Bedingungen; rechtliche Prüfung des Stud.IP-Abrufs für andere Studierende (`docs/IPAD-STUDIP-SYNC.md`, Abschnitt 8) |

## 7. App-Store-Vorbereitung (V1)

- `NSAllowsArbitraryLoads` entfernen; Stud.IP läuft über HTTPS, der PC-Modus nur für lokale Adressen
  (`NSAllowsLocalNetworking`).
- Datenschutz-Manifest `PrivacyInfo.xcprivacy` und Datenschutzangaben in App Store Connect (gesammelte Daten:
  Anmeldung, Käufe; keine Weitergabe; kein Tracking).
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
