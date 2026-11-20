# Entwurf 1.0.7 (19.11.2026) – nichts davon ist veröffentlicht

Texte für App Store, Datenschutz und Nutzungsbedingungen zu Version 1.0.7 (Build 46, Zweig `release/1.0.7`).
Erst nach Okay des Inhabers übernehmen: Store-Texte in `APP-STORE.md` (Block `whats-new-proai`, `review-notes-proai`),
Rechtstexte in `DATENSCHUTZ.md` / `NUTZUNGSBEDINGUNGEN.md`, dann Website hochladen (`tools/site-hochladen.sh`).

## Neu in dieser Version (App Store, Deutsch)

```text
NEU: KLAUSUR-GENERATOR (PRO AI)
Wähle in einem Modul Vorlesungen, Altklausuren und Übungen – StudiNow erstellt daraus bis zu zehn Probeklausuren im Stil deiner echten Klausur, mit ausführlichen Lösungen als PDF. Jede Probeklausur kostet 15 Credits; geht etwas schief, wird nichts berechnet.

MENSA MIT FOTOS
In Hannover siehst du jetzt zu den meisten Gerichten ein Foto vom Studentenwerk – direkt in der Karte und groß in „Alle Angaben“.

KI-HILFE ZUVERLÄSSIGER
Fragst du gleich nach dem Öffnen, hängt das Dokument jetzt immer an. „Ganzes Dokument“ und Verweise lassen sich auch mit VoiceOver wählen.

ABO-WECHSEL
Wechselst du von Pro AI zu Plus, zeigt StudiNow sofort „ab der nächsten Verlängerung Plus“.

Dazu kleinere Verbesserungen und Fehlerbehebungen.
```

## Hinweis für Apples Prüfer (Englisch, an `review-notes-proai` anhängen)

```text
New in 1.0.7 – Exam generator (Pro AI): In a module, tap "Klausur-Generator", pick lecture slides, past exams and exercises, then "Probeklausuren erstellen". The service creates up to ten practice exams with worked solutions as PDF; each costs 15 AI credits (taken from the monthly Pro AI credits, then from purchased credit packs, no new in-app purchase). If generation fails, nothing is charged. [VOR ÜBERNAHME PRÜFEN: Geht der Klausur-Generator in der Demo? Sonst diesen Satz weglassen und angeben, dass er ein Pro-AI-Konto mit Credits braucht.] Mensa: dish photos are loaded directly from the public Studentenwerk Hannover menu service (Studi|Futter), like the menu itself.
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
