# App Store Connect – Texte und Angaben (iPad, Mac „Designed for iPad“)

**Entwurf, Stand 04.11.2026 (26.10.2026), Sprache de-DE, für StudiNow 1.0 (Build 3).** Die Felder stehen in
`text`-Blöcken mit Feldnamen und werden so in App Store Connect eingefügt; `tests/test_release_texts.py` prüft Längen
und dass kein öffentlicher Text KI-Funktionen bewirbt (Entscheidung des Inhabers vom 25.10.2026, unten „Offene
Entscheidung KI“). Zeichen inklusive Leerzeichen. Satzteile in `[[…]]` sind Schalter aus `docs/release/angaben.json`
(`funktionen`): `tools/rechtstexte-fuellen.py` übernimmt oder streicht sie; in App Store Connect nur die gefüllte
Fassung einfügen.

**Vor dem Einreichen prüfen – Aussagen, die vom Stand der iPad-App abhängen:**

| Aussage im Text | Schalter | Stand 04.11.2026 | Gilt nur, wenn |
|---|---|---|---|
| Universität Hildesheim (Learnweb, LSF) | `ipad_hildesheim` | gebaut, nur mit erfundenen Antworten geprüft | Inhaber hat mit einem echten Hildesheim-Konto am Gerät geprüft und die Erlaubnis der Uni; sonst nur die LUH nennen |
| Abgabefristen, Ankündigungen der Lehrenden, Feiertage im Kalender | `ipad_fristen` | gebaut (Fristen, Ankündigungen, Feiertage auf dem iPad) | mit echten LUH-Daten am Gerät gesehen |
| Skriptsuche zur Aufgabe | `ipad_skriptsuche` | gebaut (Kandidatenseiten ohne KI, Plus) | am Gerät mit einem echten Übungsblatt geprüft |
| Community online (Kanal nach Lehrwoche, Fragen und Antworten) | `ipad_community_online` | gebaut (CloudKit, Container `iCloud.de.uniflow.ai`) | neue Datensatztypen in Production deployt (`docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md`) und mit zwei iCloud-Konten durchgespielt |
| „ohne Tracking“ | – | stimmt | solange kein Analyse-SDK eingebaut wird |
| StudiNow Free, Plus und Pro AI (Pro-AI-Karte nur mit Produkt aus dem Store) | – | stimmt (`UFPlanCatalog.sellable`, Entscheidung 04.11.2026) | Pro AI erst mit dem StudiNow-Dienst einreichen (Abschnitt „In-App-Käufe“); Pro Connect gibt es auf dem iPad nicht |

## Name, Untertitel, Werbetext

```text name
StudiNow – Studium & Notizen
```

```text subtitle
Skripte, Handschrift, Lernplan
```

```text promo
Skripte und Übungsblätter aus Stud.IP, Lernkalender und Stundenplan, Handschrift mit dem Apple Pencil und Karteikarten – alles auf deinem iPad, ohne Tracking.
```

## Beschreibung (max. 4000 Zeichen)

```text description
StudiNow bringt dein Studium an einen Ort: die Dateien und Termine aus den Systemen deiner Hochschule, dein Stundenplan, dein Lernkalender, deine Karteikarten und deine handschriftlichen Notizen – auf dem iPad, mit dem Apple Pencil.

FÜR STUDIERENDE DER LEIBNIZ UNIVERSITÄT HANNOVER[[ UND DER UNIVERSITÄT HILDESHEIM]]
Melde dich wie gewohnt bei Stud.IP[[ bzw. Learnweb]] an. StudiNow holt neue Skripte, Übungsblätter und Folien aus deinen Kursen, ordnet sie nach Modulen und Lehrwochen und übernimmt deine Vorlesungs- und Übungstermine[[, Abgabefristen und Ankündigungen der Lehrenden]]. Deine Zugangsdaten bleiben bei dir; die App liest nur und schreibt nichts in die Hochschulsysteme.

ÜBERSICHT UND LERNKALENDER
• Die Übersicht zeigt, was heute ansteht: Lernpakete, Termine an der Uni und neue Dateien
• Wochenraster mit deinen Vorlesungen und Übungen aus Stud.IP
• Lernkalender mit Lernpaketen je Modul und Lehrwoche in deinen freien Zeitfenstern: Vorlesung nacharbeiten, Übungen, Nachholen, „Woche retten“
[[• Abgabefristen, Quiz-Termine, Feiertage und vorlesungsfreie Zeit auf einen Blick]]
• Aufgaben abhaken, Zeitmesser mit Stoppuhr, Countdown und Pomodoro

DOKUMENTE LESEN UND BESCHREIBEN
• Bibliothek mit Modulordnern, Favoriten, zuletzt geöffneten Dokumenten und Papierkorb
• PDFs lesen, zoomen, durchsuchen, Lesezeichen setzen
• Mit Plus: Schreiben mit dem Apple Pencil in Apples Werkzeugpalette – Stift, Marker, Radierer, Lasso, Text, Formen und Notizzettel; Seiten einfügen, drehen und sortieren; Notizen als PDF exportieren
• Mit Plus: Übung und Skript nebeneinander[[, mit Skriptsuche zur Aufgabe]]

LERNEN UND GEMEINSAM LERNEN
• Mit Plus: eigene Karteikarten mit Wiederholung nach dem Leitner-System und „Frei üben“ im eigenen Tempo
• Mit Plus: Lösungen zu Übungsblättern mit anderen vergleichen: als verschlüsselte Datei, die nur öffnen kann, wer dieselbe PDF hat[[; dazu online in der Community deines Kurses nach Lehrwoche, mit Fragen und Antworten, unter Pseudonym, mit Melden und Sperren]]

DEINE DATEN
• Deine Dateien, Notizen und Pläne liegen auf deinem iPad. Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort speichert StudiNow nicht und überträgt es nie; merken kann es auf Wunsch iOS im Schlüsselbund.
• Was du mit anderen teilst, liegt verschlüsselt in Apples iCloud – nie mit deinem Namen oder deiner E-Mail-Adresse.

STUDINOW FREE UND PLUS
StudiNow Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Lesen, Stundenplan, Lernkalender, Lernplanung und Zeitmesser. Zum Start hast du 7 Tage Probe mit allem – ohne Zahlungsdaten, danach gilt Free. StudiNow Plus (1,99 € pro Monat) schaltet das Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, die Community deines Kurses und das Teilen eigener Lösungen frei. Das Abo verlängert sich automatisch um einen Monat, wenn es nicht mindestens 24 Stunden vor Ende des laufenden Zeitraums in den Einstellungen deines Apple-Kontos gekündigt wird. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Schlüsselwörter (max. 100 Zeichen, durch Komma getrennt)

Wörter aus Name und Untertitel (StudiNow, Studium, Notizen, Skripte, Handschrift, Lernplan) indiziert Apple ohnehin;
sie stehen hier nicht noch einmal. Keine fremden Marken (z. B. ChatGPT) in Name, Untertitel oder Schlüsselwörtern
(Richtlinie 2.3.7). „Learnweb“ und „Hildesheim“ erst mit dem Schalter `ipad_hildesheim` ergänzen (dafür „PDF“ und
„Hochschule“ streichen).

```text keywords
Stud.IP,Uni,Hochschule,Apple Pencil,Stundenplan,Lernkalender,Karteikarten,Übungsblatt,PDF,Hannover
```

## Neue Funktionen in dieser Version (1.0)

Bei der ersten Version zeigt der App Store dieses Feld nicht an; für 1.0.1 ff. ersetzen.

```text whats-new
Erste Version: Dateien und Termine aus Stud.IP, Bibliothek nach Modulen, Stundenplan, Lernkalender mit Lernplanung, Zeitmesser. Mit StudiNow Plus: Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, Community und Lösungen teilen.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| Plattform, Geräte | iPad (iPadOS 17 oder neuer); Mac mit Apple-Chip über „Designed for iPad“ (in App Store Connect unter Preise und Verfügbarkeit freischalten oder abschalten); kein iPhone |
| Primäre Sprache | Deutsch |
| Kategorie | Bildung; zweite Kategorie: Produktivität |
| Support-URL | `https://studinow.app/support` (Kontakt per E-Mail support@studinow.app) |
| Marketing-URL | `https://studinow.app` (optional) |
| Datenschutz-URL | `https://studinow.app/datenschutz` |
| Nutzungsbedingungen (EULA) | eigene unter `https://studinow.app/nutzungsbedingungen` (App-Informationen → Lizenzvereinbarung) oder Apples Standard-EULA – Entscheidung des Inhabers; der Link steht in der Beschreibung und auf der Tarifseite der App |
| Copyright | © 2026 IT solutions by Ahmad Fakih |
| Händlerstatus (DSA) | Händler; Name, Anschrift, E-Mail wie im Impressum (IT solutions by Ahmad Fakih, Inhaber Ahmad Fakih, Baldurstraße 5, 30657 Hannover, support@studinow.app; werden im Store angezeigt); Telefonnummer verlangt Apple zusätzlich – vom Inhaber in App Store Connect eintragen |
| Bundle-ID, SKU | `de.uniflow.ai` (`docs/RELEASE-VORBEREITUNG.md`); SKU frei wählbar, z. B. `studinow-ipad` |
| Version, Build | 1.0 (`MARKETING_VERSION`), Build 3 (`CURRENT_PROJECT_VERSION`, je Upload +1) |
| Mit Apple anmelden | Fähigkeit aktiv; Konto löschen in der App (Richtlinie 5.1.1(v)) |
| Exportkontrolle | Vorschlag (Entscheidung des Inhabers): „Ja, die App verwendet Verschlüsselung“ → „Keine der genannten Algorithmen“ – StudiNow nutzt nur die Verschlüsselung des Betriebssystems (HTTPS über URLSession, AES-256-GCM und HKDF aus Apples CryptoKit), keine eigene oder fremde Krypto-Bibliothek. Danach `ITSAppUsesNonExemptEncryption = NO` in `project.yml`, damit die Frage nicht bei jedem Build kommt |

## Altersfreigabe (Fragebogen in App Store Connect)

| Frage | Antwort | Begründung |
|---|---|---|
| Kindersicherung, Altersprüfung in der App | nein | – |
| Uneingeschränkter Webzugang | nein | Webansichten nur für die Anmeldeseiten der Hochschulen (bekannte Adressen); Links öffnen Safari |
| Nutzergenerierte Inhalte | **ja** | Community: Lösungen, Fragen, Antworten, Kommentare; Melden, Blockieren, Moderation durch den Anbieter, Kontaktadresse |
| Nachrichten und Chat | nein | keine Direktnachrichten zwischen Nutzern; Fragen und Antworten sind öffentliche Beiträge in der Community eines Kurses |
| Werbung | nein | – |
| Grobe Sprache, Horror, Alkohol/Tabak/Drogen, sexuelle Inhalte oder Nacktheit, Gewalt, Waffen, Glücksspiel (auch simuliert), Wettbewerbe | keine | – |
| Medizinische Inhalte, Gesundheit und Wellness | keine | – |

Die Stufe berechnet App Store Connect aus den Antworten. Zielgruppe sind Studierende (Datenschutzerklärung,
Abschnitt 16: nicht für Kinder unter 16); eine höhere Stufe als 4+ wegen nutzergenerierter Inhalte ist unkritisch.

## App-Datenschutz (Nutrition Labels)

**StudiNow 1.0 für das iPad (ohne StudiNow-Dienst), wie eingereicht.** Grundlage: Code-Stand 04.11.2026,
`apps/apple/UniFlow/PrivacyInfo.xcprivacy` und `docs/release/DATENSCHUTZ.md` (Abschnitte 3, 8a, 8b). „Erfasst“ heißt
nach Apples Definition: verlässt das Gerät und bleibt für uns oder Partner länger abrufbar, als die Anfrage dauert.

Frage „Erfassen Sie oder Ihre Drittanbieter Daten aus dieser App?“ → **Ja**.

| Datentyp | Erfasst | Mit Identität verknüpft | Für Tracking | Zweck | Was genau |
|---|---|---|---|---|---|
| Kennungen → Nutzer-ID | ja | ja | nein | App-Funktionalität | CloudKit-Nutzerkennung (zufällig, nur für StudiNow), die Apple als Ersteller in jeden Community-, Wochentest- und Bibliotheks-Datensatz einträgt; dient Zurückziehen, Melden, Blockieren und Moderation |
| Nutzerinhalte → Andere Nutzerinhalte | ja | ja | nein | App-Funktionalität | veröffentlichte Lösungen (Notizen verschlüsselt), Fragen, Antworten, Kommentare, Korrekturvorschläge, Likes, Meldungen, Lerngruppen, gemeinsame Wochentests und Einträge der Bibliothek (CloudKit, Inhalte verschlüsselt); bei verbundener KI Seitentext, Markierung und Frage, die das Gerät direkt an OpenAI schickt |
| Kontaktinformationen, Gesundheit und Fitness, Finanzinformationen, Standort, sensible Daten, Kontakte, Browserverlauf, Suchverlauf, Käufe, Nutzungsdaten, Diagnose, sonstige Daten | nein | – | – | – | – |

Warum so:

- **Mit Apple anmelden:** Die Apple-Kennung, Name und E-Mail bleiben auf dem iPad (Schlüsselbund, Einstellungen);
  nichts geht an einen Server des Entwicklers. Das ist keine Erfassung. Gibt der Inhaber die Apple-Kennung trotzdem als
  „Nutzer-ID“ an, ändert das an der Tabelle nichts (Nutzer-ID ist ohnehin angegeben).
- **Verknüpft ja:** Jeder CloudKit-Datensatz trägt die Nutzerkennung des Erstellers; Apple nennt Daten nur dann „nicht
  verknüpft“, wenn Kennungen vor der Erfassung entfernt werden. Das Pseudonym ist kein Name. Die vorsichtige Angabe
  kostet nichts; eine zu knappe wäre ein Prüfungsrisiko.
- **KI über das eigene ChatGPT:** freiwillig, nur nach Verbinden und Zustimmung; die Daten gehen an das Konto des
  Nutzers bei OpenAI, nicht an StudiNow. Sie fallen unter „Andere Nutzerinhalte“, das ohnehin angegeben ist.
- **Käufe:** StoreKit 2 prüft auf dem Gerät; kein Server des Entwicklers erhält Kaufdaten.
- **Diagnose:** keine Absturz- oder Analyse-SDKs; Absturzberichte über Apple (TestFlight, Xcode Organizer) sind Apples
  eigene Erfassung und nicht anzugeben.
- **Hochschul-Passwörter** speichert die iPad-App nicht (Entscheidung vom 27.10.2026): Im Anmeldefenster (WKWebView
  ohne eigene Skripte) kann sie nur iOS selbst mit Passwort-Autofill im Schlüsselbund bzw. iCloud-Schlüsselbund
  sichern – das ist Apples Funktion, nicht eine Erfassung durch den Entwickler. Auf dem Gerät bleiben nur
  Sitzungs-Cookies und der Learnweb-Schlüssel; beides verlässt das Gerät nicht. Ältere Testfassungen hatten
  Zugangsdaten auf Wunsch selbst im Schlüsselbund abgelegt; die aktuelle Fassung löscht solche Einträge beim ersten
  Start.

**Später, ab Anbindung des StudiNow-Dienstes (Konto, Geräteabgleich, Community im Dienst):**

| Datentyp | Erfasst | Mit Identität verknüpft | Für Tracking | Zweck |
|---|---|---|---|---|
| Kontaktinformationen → E-Mail-Adresse | ja | ja | nein | App-Funktionalität (Konto) |
| Kennungen → Nutzer-ID | ja | ja | nein | App-Funktionalität |
| Nutzerinhalte → andere Nutzerinhalte (Dokumente, Notizen, Kalender; Community-Pakete verschlüsselt) | ja | ja | nein | App-Funktionalität |
| Käufe → Kaufverlauf (Abo-Status) | ja | ja | nein | App-Funktionalität |
| Standort, Kontakte, Gesundheit, Finanzdaten, Browserverlauf, Nutzungsdaten, Diagnose | nein | – | – | – |

Hochschul-Zugangsdaten, die der Nutzer für den automatischen Abgleich im Konto speichert (nur über Web/PC, nicht in der
iPad-App), sind „Anmeldedaten“ im
Sinne von Apples Definition **nicht** erfasst, wenn sie nur verschlüsselt zur Erbringung der vom Nutzer
eingerichteten Funktion gespeichert werden; [[mit Apple-Dokumentation zum Zeitpunkt der Einreichung abgleichen]].

## In-App-Käufe

Tarife nach `docs/ABO-SYSTEM.md`; Namen, Preise und Produkt-IDs aus `packages/shared-contracts/fixtures/plans/plans.json`.
**Die App bietet StudiNow Free, StudiNow Plus und StudiNow Pro AI an** (Entscheidung des Inhabers vom 04.11.2026,
`UFPlanCatalog.sellable`). StudiNow Free hat kein Produkt. **Keine Einführungsangebote:** die 7-Tage-Probe läuft in der
App selbst, ohne Kauf und ohne Zahlungsdaten (einmal je Apple-ID), danach gilt Free. Der Inhaber legt in App Store
Connect zwei automatisch verlängerbare Abos in der Abo-Gruppe „StudiNow“ an:

| Feld | StudiNow Plus | StudiNow Pro AI |
|---|---|---|
| Produkt-ID | `de.uniflow.plus.monthly` (die Kennung bleibt bei `de.uniflow`, Bundle-ID `de.uniflow.ai`) | `de.uniflow.proai.monthly` |
| Abo-Gruppe / Stufe | StudiNow / Stufe 2 | StudiNow / Stufe 1 (höchste) |
| Referenzname | StudiNow Plus (monatlich) | StudiNow Pro AI (monatlich) |
| Anzeigename (max. 30) | StudiNow Plus | StudiNow Pro AI |
| Beschreibung (max. 45) | Stift, Karteikarten, Community, Lösungen | Alles aus Plus, mehr über den StudiNow-Dienst |
| Preis | 1,99 € pro Monat (Preisstufe nach App Store Connect) | 3,99 € pro Monat |
| Einführungsangebot | keins | keins |
| Einreichen | **mit der ersten App-Version** | **erst, wenn der StudiNow-Dienst läuft** (vorher nicht anlegen oder nicht zur Prüfung geben) |
| Prüf-Screenshot | Tarifseite der App (`~/Studora-Builds/appstore-screenshots/iap-tarifseite.png`) | Tarifseite mit der Pro-AI-Karte (erst mit dem Dienst) |
| Prüfhinweis zum Abo | „Plus schaltet Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, die Community (lesen und schreiben) und das Teilen eigener Lösungen frei; StudiNow Free hat keine Community. Kaufen und Wiederherstellen auf der Tarifseite (Einstellungen → Zugang & Darstellung → Tarif → „Tarif wechseln“).“ | „Pro AI enthält alles aus Plus; die weiteren Funktionen laufen über den StudiNow-Dienst, die App sagt das auf der Karte.“ |

Das Plus-Abo muss **zusammen mit der ersten App-Version** eingereicht werden (Version → In-App-Käufe und Abonnements →
Produkt auswählen), sonst prüft Apple es nicht mit. Solange Pro AI in App Store Connect fehlt, liefert StoreKit das
Produkt nicht; die Tarifseite zeigt dann nur Free und Plus und darunter den Satz „StudiNow Pro AI folgt mit dem
StudiNow-Dienst.“ ohne Preis und ohne Kaufknopf. Sobald das Produkt da ist, erscheint die Pro-AI-Karte mit dem Preis aus
dem Store und der Zeile, dass Pro AI den StudiNow-Dienst braucht. StudiNow Pro Connect gibt es seit dem 04.11.2026
nicht mehr (`docs/PREISLISTE.md`); `de.uniflow.proconnect.monthly` nicht anlegen. Die App prüft den Kauf
nur auf dem Gerät (StoreKit 2); kein Konto beim Dienst, kein `appAccountToken`.

Pflichttexte auf der Tarifseite in der App: Preis und Laufzeit, automatische Verlängerung, Kündigung in den
Einstellungen, Links zu Nutzungsbedingungen und Datenschutzerklärung, „Käufe wiederherstellen“. Was den
Online-Dienst braucht, steht auf den Karten unter „in Vorbereitung“, nie als enthalten.

## Hinweise für die App-Prüfung (Review Notes)

Auf Englisch, damit jede Prüferin sie lesen kann; Bezeichnungen der Oberfläche stehen auf Deutsch in Anführungszeichen,
wie sie in der App erscheinen. Anmeldedaten für ein Demo-Konto: keine (Feld „Anmeldung erforderlich“ ausschalten bzw.
leer lassen – die Demo braucht kein Konto, „Mit Apple anmelden“ nimmt die Prüfer-Apple-ID). Kontakt: Ahmad Fakih,
support@studinow.app, Telefon vom Inhaber. Die Notizen beschreiben den Build ehrlich, also auch die KI über das eigene
ChatGPT (Richtlinie 2.3.1: keine versteckten Funktionen) – sie sind kein Werbetext.

Demo nur für Prüfer (Entscheidung des Inhabers 04.11.2026): normale Nutzer sehen die Demo nirgends – kein Eintrag in
den Einstellungen, kein Hinweis in leeren Ansichten oder im ersten Start. Einziger Weg ist der kleine Textlink
„Ohne Hochschulkonto ansehen (Demo)“ ganz unten auf der Anmeldeseite der Hochschule (Wortlaut in der App und hier
gleich, `tests/test_release_texts.py`). Solange die Demo aktiv ist, steht oben eine schmale Leiste „Demo-Inhalte –
erfunden, ohne Hochschule“ mit „Beenden“; „Beenden“ entfernt alles, was die Demo angelegt hat, und führt zurück zur
Anmeldeseite. Die Store-Bildschirmfotos zeigen die Leiste nicht (nur im Test ausgeblendet, `docs/release/SCREENSHOTS.md`).

```text review-notes
StudiNow is a study app for students of Leibniz Universität Hannover (Germany). Its university features (course files, timetable) use the student's personal university account, which we cannot share. Please use the built-in demo content, which needs no university account:

1. Tap "Mit Apple anmelden" (Sign in with Apple). It is required because the app keeps the data of each Apple account and each university strictly separate on the device. Nothing is sent to a server of ours; the Apple user ID stays on the iPad.
2. Choose a plan ("StudiNow Free" is enough) and the university "Leibniz Universität Hannover". A 7-day trial with everything unlocked starts automatically with the first sign-in, no purchase and no payment details needed (once per Apple ID, stored on the device, not on a server). After the trial the app falls back to "StudiNow Free" and locked features show an unlock prompt; nothing created during the trial is lost.
3. On the following university login page tap the small text link "Ohne Hochschulkonto ansehen (Demo)" at the very bottom, below "Später anmelden". This creates a demo module with three PDFs, timetable, study calendar, five flashcards, a deadline and an announcement (all made up by us, no university content). In demo mode the app does not contact the university and asks for no login.
While the demo is active, a slim bar "Demo-Inhalte – erfunden, ohne Hochschule" is shown at the top of every screen. To leave the demo, tap "Beenden" in that bar and confirm: all demo content is removed and the app returns to the university login page. The demo is for review only and offered nowhere else.

Subscriptions: "StudiNow Plus" (monthly, no introductory offer) can be tested in the sandbox on the plan page ("Einstellungen" → "Zugang & Darstellung" → "Tarif" → "Tarif wechseln"), including "Käufe wiederherstellen". Plus unlocks writing with Apple Pencil, exercise and script side by side, flashcards, creating weekly tests (with the user's own ChatGPT, see AI below), the community and sharing own solutions. The plan page lists "StudiNow Pro AI" only when the App Store returns that product; it is submitted later together with our online service, and its card states that it needs that service. The free trial is not an App Store offer: it is the app's own 7-day trial described above. After Plus ends, all notes stay readable and exportable. Terms: https://studinow.app/nutzungsbedingungen, privacy: https://studinow.app/datenschutz.

Account deletion: "Einstellungen" → "Zugang & Darstellung" → "Konto" → "Konto löschen" deletes all data of the account on the device.

Community (user-generated content, guideline 1.2): students of the same course can share their notes on an exercise sheet, ask questions and comment. Content is stored in our public CloudKit database, encrypted with keys derived from the course or the PDF, and shown under a pseudonym. Every post and solution can be reported ("Melden") and its author blocked ("Blockieren"). We review reports in the CloudKit Dashboard within 24 hours, remove content and ban users. Contact: support@studinow.app. It needs Plus (or the trial). Reading works without an iCloud account; posting requires iCloud.

AI (optional, off by default): users who have their own paid ChatGPT plan can connect it under "Einstellungen" → "Erweitert" → "KI über mein ChatGPT" (Sign in with ChatGPT by OpenAI). Before connecting, the app explains what is sent and asks for consent. Requests (page text, selection, question) go directly from the device to OpenAI and count against the user's own ChatGPT plan. StudiNow does not sell AI, runs no AI server and never sees requests or answers. Without a connection the AI area ("KI-Start", "KI-Hilfe" in the editor) explains how to connect, and every other feature works. We cannot provide a ChatGPT account for review.

No tracking, no ads, no third-party analytics or SDKs. The universities have not endorsed the app; it only reads data the student can see anyway.
```

## Bildschirmfotos (iPad Pro 13", 2064 × 2752)

Fertige Bilder, Reihenfolge und Bildunterschriften: `docs/release/SCREENSHOTS.md` (Bilder unter
`~/Studora-Builds/appstore-screenshots/`). Nur echte App-Inhalte mit erfundenen Daten, keine Uni-Logos ohne Erlaubnis,
keine echten Namen oder Noten.

## Offene Entscheidung KI (Inhaber, vor dem Einreichen)

Der Build enthält den KI-Bereich (KI-Start, KI-Hilfe im Editor, Wochentest erstellen, Karteikarten aus Dokument,
„Schon erklärt“ aus der Bibliothek) über das **eigene ChatGPT** des Nutzers (`ChatGPTLink.available` ist in jedem
Build wahr). Die öffentlichen Texte oben bewerben ihn nicht (Entscheidung vom 25.10.2026, geprüft von
`tests/test_release_texts.py`); die Prüfhinweise beschreiben ihn, weil Apple versteckte Funktionen ablehnt.

| Weg | Was zu tun ist | Risiko |
|---|---|---|
| A: KI in 1.0, nicht beworben (Stand der Texte) | nichts; Bildschirmfotos 4 und 7 (KI-Hilfe, Wochentest) zeigen sie trotzdem – ggf. durch andere ersetzen | OpenAI verlangt für bezahlte Apps die Aufnahme über die Warteliste (`docs/KI-CHATGPT-PLAN.md`, Abschnitt 9); Prüfer können die KI ohne ChatGPT-Abo nicht testen |
| B: KI in 1.0 und beworben | Absatz unten in die Beschreibung (vor „DEINE DATEN“), Test `test_store_texts_promise_no_ai` und `docs/release/README.md` anpassen | wie A, dazu fremde Marke „ChatGPT“ im Text (nur beschreibend erlaubt, nie in Name, Untertitel, Schlüsselwörtern) |
| C: KI erst in 1.1 | `ChatGPTLink.available` im Release auf `false` (eine Zeile), KI-Start ohne KI zeigt dann nur den Weg; Bildschirmfotos 4 und 7 weglassen, KI-Absatz aus den Prüfhinweisen streichen | keins für die Prüfung; KI kommt später als Update |

Fertiger Absatz für Weg B (nicht in einem `text`-Feld, damit die Prüfung der Texte greift, bis der Inhaber entscheidet):

```markdown
KI MIT DEINEM EIGENEN CHATGPT (FREIWILLIG)
• Verbinde dein ChatGPT-Abo und frag zur offenen Seite: erklären, zusammenfassen, Aufgabe Schritt für Schritt, nur Hinweise, Lösung prüfen
• Wochentest aus den Unterlagen der Woche, Karteikarten aus einem Dokument
• „Schon erklärt“: Seiten, die andere mit derselben Datei schon einordnen ließen, siehst du sofort – ohne eigene Anfrage
Die Anfragen gehen direkt von deinem iPad an OpenAI und zählen gegen dein ChatGPT-Abo. StudiNow verkauft keine KI und speichert keine Anfragen.
```
