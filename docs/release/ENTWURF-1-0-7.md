# Entwurf 1.0.7 (19.11.2026) – nichts davon ist veröffentlicht

Texte für App Store, Datenschutz und Nutzungsbedingungen zu Version 1.0.7 (Build 46, Zweig `release/1.0.7`).
Erst nach Okay des Inhabers übernehmen: Store-Texte in `APP-STORE.md` (Block `whats-new-proai`, `review-notes-proai`),
Rechtstexte in `DATENSCHUTZ.md` / `NUTZUNGSBEDINGUNGEN.md`, dann Website hochladen (`tools/site-hochladen.sh`).

## Neu in dieser Version (App Store, Deutsch)

Stand 24.11.2026 (Build 47): Entscheidung des Inhabers – in 1.0.7 KEIN Klausur-Generator/Verkauf von Probeklausuren,
KEINE Wissensbank, KEINE fertigen Erklärungen/Formelblätter (Schalter aus, Code bleibt). Dafür Widgets, iPhone-Stundenplan
mit Woche, Schutz beim Konto-Löschen, Community- und Schreib-Verbesserungen.

```text
WIDGETS
„Nächster Termin“ und „Mensa heute“ für Home- und Sperrbildschirm: was gerade läuft, was als Nächstes kommt, und der Speiseplan deiner Mensa – ohne die App zu öffnen.

STUNDENPLAN AUF DEM IPHONE: TAGE UND WOCHE
Schalte zwischen deinen Tagen und der ganzen Woche um. In der Woche steht bei jedem Termin das Fach, gleichzeitige Termine erscheinen übersichtlich zusammen.

KONTO LÖSCHEN NUR NOCH MIT FACE ID
Bevor dein Konto gelöscht wird, fragt StudiNow nach Face ID oder deinem Code. Die Daten auf dem Gerät lassen sich danach noch 30 Tage zurückholen.

SCHREIBEN UND NOTIZEN
Die Schrift bleibt beim Zoomen scharf und haftet am Blatt, das Lasso geht ohne Tastatur, Bilder lassen sich in Notizen einfügen, und die Lösung neben dem Dokument öffnet sich als echte PDF.

COMMUNITY
Lösungen gelten jetzt für alle Fassungen derselben PDF – auch wenn die Datei in Stud.IP neu hochgeladen wurde.

AUSSERDEM
Mensa mit Fotos (Hannover), fehlende Leistungen selbst eintragen, Prüfungsanmeldungen auf allen Geräten, auf dem iPhone ziehen zum Aktualisieren und klarere Kopfzeilen, zuverlässigere KI-Hilfe.

Dazu viele kleinere Verbesserungen und Fehlerbehebungen.
```

## Hinweis für Apples Prüfer (Englisch, an `review-notes-proai` anhängen)

```text
[1.0.7 Build 47: Klausur-Generator ist AUS – dieser Absatz entfällt bis auf den Satz zur Mensa.] New in 1.0.7 – Exam generator (Pro AI): In a module, tap "Klausur-Generator", pick lecture slides, past exams and exercises, then "Probeklausuren erstellen". The service creates up to ten practice exams with worked solutions as PDF; each costs 15 AI credits (taken from the monthly Pro AI credits, then from purchased credit packs, no new in-app purchase). If generation fails, nothing is charged. [VOR ÜBERNAHME PRÜFEN: Geht der Klausur-Generator in der Demo? Sonst diesen Satz weglassen und angeben, dass er ein Pro-AI-Konto mit Credits braucht.] Mensa: dish photos are loaded directly from the public Studentenwerk Hannover menu service (Studi|Futter), like the menu itself.
```

## Datenschutz – neue Absätze

**Mensa (neu, z. B. als Abschnitt 4b):**

> **Mensa.** Den Speiseplan und, in Hannover, die Fotos der Gerichte lädt die App direkt beim jeweiligen Studentenwerk
> (Studentenwerk Hannover über Studi|Futter, Studentenwerk OstNiedersachsen, ersatzweise OpenMensa). Dabei erhält der
> Anbieter die bei jedem Abruf üblichen Angaben (IP-Adresse, Zeitpunkt, Gerätetyp). An StudiNow geht dabei nichts;
> deine Auswahl (Mensa, Preisgruppe, Allergene) bleibt auf dem Gerät. Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

**Klausur-Generator (neu, z. B. als Abschnitt 8d):**

> **Klausur-Generator (Pro AI).** Erstellst du Probeklausuren, schickt die App den Text der gewählten Seiten
> (Vorlesungen, Altklausuren, Übungen) einmal an den StudiNow-Dienst. Der Dienst gibt ihn zum Erzeugen an einen
> KI-Auftragsverarbeiter weiter (Abschnitt 8c) und löscht die Seitentexte spätestens 3 Stunden danach. Gespeichert
> bleiben die erzeugten Probeklausuren und eine Themenübersicht, ohne Bezug zu deinem Konto; wer dieselben Unterlagen
> hat, kann dieselben Probeklausuren kaufen. Zu deinem Konto speichern wir nur, welche Probeklausuren du gekauft hast
> (für den Zugriff und eine Erstattung). Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

(Löschfrist: `MATERIAL_HOURS = 3` in `app/exam_shop.py`, geprüft 19.11.2026.)

## Nutzungsbedingungen – neuer Punkt (§ Credits)

> **Probeklausuren:** Eine Probeklausur aus dem Klausur-Generator kostet 15 Credits. Kann sie nicht erstellt werden,
> wird nichts abgebucht. Probeklausuren sind eine Lernhilfe, von einer KI erstellt und geprüft, aber nicht fehlerfrei;
> sie sagen nichts darüber, was in deiner echten Klausur drankommt.

## Offene Punkte vor dem Einreichen von 1.0.7

- Urheberrecht: Probeklausuren entstehen aus Folien und Altklausuren und werden anderen Nutzern verkauft – vor dem
  Start rechtlich prüfen lassen (Inhaber weiß Bescheid).
- Server-Update mit neuem Docker-Bild (`reportlab`, Schriften, `tools/klausur_pdf`) und Prüfung im Container.
- Bildschirmfoto für den Klausur-Generator (optional).

## Datenschutz – Prüfungsanmeldungen im Geräteabgleich

Entwurf (20.11.2026, Entscheidungen des Inhabers „Ja, abgleichen“, „Status ja, aber ohne bestanden“, „Prüfer bleibt nur
auf dem Gerät“), z. B. als Ergänzung in Abschnitt 7 nach „… Karteikarten und Einstellungen“:

> **Angemeldete Prüfungen.** Mit dem StudiNow-Konto speichert der Dienst die Liste deiner angemeldeten Prüfungen, wie
> die App sie im QIS, LSF oder Campusmanagement deiner Hochschule gelesen hat, im Datenbereich deines Uni-Kontos, damit
> sie auch auf deinen anderen Geräten erscheint. Gespeichert werden je Prüfung: Prüfungsnummer, Bezeichnung, Semester,
> Datum, Uhrzeit, Raum, Versuch, Status der Anmeldung (z. B. angemeldet, zugelassen, storniert), Rücktrittsfrist,
> Prüfungsform und der Abschluss bzw. Studiengang, wie die Seite ihn nennt. Nicht gespeichert werden Noten,
> Prüfungsergebnisse (etwa „bestanden“ oder „nicht bestanden“; an ihrer Stelle steht im Dienst nur „abgeschlossen“) und
> der Name der Prüferin oder des Prüfers; das bleibt nur auf dem Gerät, das die Liste gelesen hat. Die Liste wird mit deinem Konto gelöscht, spätestens 30 Tage nach
> dessen Löschung; eine Prüfung, von der du dich abmeldest, verschwindet beim nächsten Abruf auch im Dienst.
> Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

Was im Code dazu gilt (geprüft 20.11.2026, Zweig `sync-pruefungsanmeldungen`):

- Abgeglichene Spalten von `exam_registrations`: `pruefungsnr`, `text`, `semester`, `datum`, `time`, `room`, `versuch`,
  `status` (ohne Ergebnis, siehe unten), `withdraw`, `form`, `abschluss`. Nur auf dem Gerät: `pruefer`, `raw` (ganze
  Zeile der QIS-Seite, enthält den Prüfer mit) und `fetched_at` (`sync.DEVICE_ONLY_COLUMNS`, Swift
  `DeviceSyncCore.localColumns`). Der Dienst verwirft diese Spalten auch, wenn ein Gerät sie doch schickt. Eine
  Notenspalte hat die Tabelle nicht.
- Status ohne Ergebnis: steht im Status ein Ergebnis („bestanden“, „nicht bestanden“, „endgültig nicht bestanden“,
  Kürzel BE / NB / EN), schickt das Gerät statt dessen „abgeschlossen“ (zählt auf den anderen Geräten als „nicht mehr
  angemeldet“, verrät weder bestanden noch nicht bestanden); der Dienst speichert und liefert das Ergebnis nie, und ein
  Gerät überschreibt sein eigenes Ergebnis nicht mit dem Stand des Dienstes (`sync.DEVICE_ONLY_VALUES`,
  `qis_registrations.is_result_status`, Swift `QISRegistrationsSync.isResultStatus`; gleiche Beispiele in
  `fixtures/sync/cases.json`).
- Prüfer: bleibt nur auf dem Gerät (Entscheidung des Inhabers); die App zeigt ihn nirgends an.
- Anzeige: Ein Gerät, das die Liste nie selbst gelesen hat, zeigt bei den Prüfungsanmeldungen „Stand von deinem anderen
  Gerät, <Datum Uhrzeit>“ (letzte Änderung im Dienst).
- Android gleicht die Tabelle noch nicht ab (die Android-App liest keine Prüfungsanmeldungen und überspringt unbekannte
  Tabellen); der Satz „auf deinen anderen Geräten“ stimmt für iPad, iPhone, Mac und Windows.

## StudiNow-Wissensbank (Entwurf 20.11.2026, Zweig `server/wissensbank`)

Funktion im Dienst hinter dem Schalter `LERNAPP_WISSENSBANK` (Standard aus). Die App zeigt nichts, solange der Dienst
sie nicht meldet. Gilt nur für Pro AI und nur für Konten der Leibniz Universität Hannover (Hochschule am Konto).

**Stand 22.11.2026:** Fassung unten ersetzt den Entwurf vom 20.11. Sie deckt ab, was inzwischen im Dienst läuft:
eingekreister Bereich („Bereich an KI“) geht mit, Vorab-Frage bei „Seite erklären“, KI mit Auszügen
(`LERNAPP_WISSENSBANK_KONTEXT`), gemerkte KI-Antworten (`LERNAPP_WISSENSBANK_MERKEN=sofort`, Entscheidung des Inhabers:
nur dieselbe Stelle, direkt, 1 Credit). **Noch nicht vom Inhaber freigegeben, noch nicht auf der Website.**

**Datenschutz (neu, z. B. als Ergänzung zu Abschnitt 8c „KI-Hilfe“):**

> **StudiNow-Wissensbank (Pro AI, Leibniz Universität Hannover).** Fragst du die KI-Hilfe zu einer Seite, zu
> markiertem Text oder zu einem eingekreisten Bereich, schickt die App zusätzlich den Dateinamen, wie er in Stud.IP
> heißt, den Kursnamen, die Seitenzahl und den Text der Seite bzw. den im Ausschnitt erkannten Text an den
> StudiNow-Dienst. Diese Angaben stehen ohnehin schon in der Anfrage an die KI. Der Dienst vergleicht den Text mit der
> StudiNow-Wissensbank, einer von uns erstellten Sammlung von Erklärungen und Lösungen.
>
> *Antwort aus der Wissensbank.* Passt die Stelle genau, bekommst du die Antwort aus der Wissensbank statt einer neuen
> KI-Antwort; sie ist mit „Aus der StudiNow-Wissensbank“ gekennzeichnet.
>
> *KI-Antwort mit Wissen aus der Wissensbank.* Passt keine Stelle genau, kann der Dienst der KI passende Auszüge aus
> der Wissensbank mitgeben. Die Antwort bleibt eine KI-Antwort und ist mit „Mit Wissen aus der StudiNow-Wissensbank“
> gekennzeichnet.
>
> *Gemerkte KI-Antworten.* Enthält deine Anfrage nichts Persönliches (keine eigene Frage, keine eigene Lösung, keine
> eigenen Notizen, auch nicht im eingekreisten Bereich), speichern wir die KI-Antwort zusammen mit dem Dateinamen, dem
> Kursnamen, der Seitenzahl und dem Text des Ausschnitts aus dem Kursmaterial – ohne Bezug zu deinem Konto. Dein
> bisheriges Gespräch mit der KI-Hilfe geht in solche Anfragen nicht ein. Fragt ein anderer Nutzer desselben Kurses zu
> genau derselben Stelle derselben Datei, bekommt er diese Antwort statt einer neuen KI-Antwort; sie ist als „Gemerkte
> KI-Antwort“ gekennzeichnet.
>
> *Was wir zu deinem Konto speichern.* Welche Stellen der Wissensbank und welche gemerkten Antworten du schon bekommen
> hast (Stelle und Zeitpunkt), damit du beim nächsten Mal eine neue KI-Antwort bekommst. Danach fragt die App: „Gefällt
> dir diese Antwort besser?“ Deine Antwort („Ja“ oder „Nein“) zählt als Stimme für oder gegen die bisherige Antwort;
> bei „Ja“ kann die neue KI-Antwort als Vorschlag für die Wissensbank gespeichert werden – ohne Bezug zu deinem Konto
> und ohne deine Frage. Bis du antwortest, höchstens 7 Tage, liegt die KI-Antwort mit deinem Konto verknüpft beim
> Dienst; danach wird diese Verknüpfung gelöscht. Die Liste der bekommenen Stellen wird mit deinem Konto gelöscht und
> ist im Datenexport enthalten. Gemerkte Antworten ohne Kontobezug bleiben gespeichert, bis sie abgewählt oder von uns
> entfernt werden.
>
> Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (Erklärungen und Lösungen der KI-Hilfe); für gemerkte Antworten und
> Vorschläge Art. 6 Abs. 1 lit. f DSGVO (gleiche Antworten nicht mehrfach erzeugen, Verbesserung der Wissensbank).

**Nutzungsbedingungen (neuer Punkt im § Credits):**

> **Antworten aus der StudiNow-Wissensbank und gemerkte KI-Antworten:** Eine Antwort aus der Wissensbank und eine
> gemerkte KI-Antwort kosten je 1 Credit. Eine KI-Antwort mit Wissen aus der Wissensbank wird wie jede KI-Antwort
> berechnet. Fragst du dieselbe Stelle noch einmal, bekommst du eine neue KI-Antwort, die wie üblich berechnet wird.
> Auch Antworten aus der Wissensbank und gemerkte KI-Antworten können Fehler enthalten; Lösungen mit dem Hinweis
> „KI-Lösung, ungeprüft“ sind nicht mit einer offiziellen Musterlösung verglichen.

**Für den Inhaber (nicht veröffentlichen):**

- **Urheberrecht – vor dem Einschalten rechtlich prüfen lassen.** Die Wissensbank enthält wörtliche Übertragungen von
  Folien- und Aufgabentexten (`>`-Zitate, „Folientext“, „Aufgabentext“) und Lösungen zu Übungsblättern und
  Altklausuren der Lehrenden. Mit der Wissensbank gehen diese Texte an andere Studierende, die dieselbe Datei geöffnet
  haben – also an Personen, die das Material über Stud.IP schon haben, aber trotzdem als Weitergabe durch StudiNow. Die
  frühere Regel der Bibliothek („nicht auf Server, nur für den Inhaber“, MAC-ANLEITUNG.md Abschnitt 2) ist mit dieser
  Entscheidung überholt; das sollte in der privaten Bibliothek auch so vermerkt werden. Offene Fragen: Zitatrecht /
  § 60a UrhG (Unterricht und Lehre) für ein kommerzielles Angebot? Musterlösungen der Lehrenden weitergeben? Vorschlag
  bis zur Klärung: nur Erklärungen und selbst gelöste Aufgaben ausliefern, keine Musterlösungen der Lehrenden.
- **Nur LUH:** Der Dienst prüft die Hochschule am Konto (`users.university == "luh"`), nicht die Angabe der App.
- **Prüfen der Vorschläge:** `docker compose exec app python -m app.wissensbank_pruefen --liste` (dann `--zeigen ID`,
  `--freigeben ID`, `--ablehnen ID`, je Stelle `--waehlen SCHLÜSSEL --antwort bibliothek|ID|auto`).
- **Hochladen:** `tools/wissensbank-hochladen.sh SERVER_IP` (nur `katalog.json` und die `.md`-Dateien, keine Prüfskripte,
  keine PDFs) nach `/data/wissensbank` im Daten-Volume; damit liegt die Bibliothek auch in den Sicherungen des Servers.
  Einschalten: `LERNAPP_WISSENSBANK=1` in `deploy/.env`, Dienst neu starten.
