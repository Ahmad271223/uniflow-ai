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
New in 1.0.7 – Exam generator (Pro AI): In a module, tap "Klausur-Generator", pick lecture slides, past exams and exercises, then "Probeklausuren erstellen". The service creates up to ten practice exams with worked solutions as PDF; each costs 15 AI credits (taken from the monthly Pro AI credits, then from purchased credit packs, no new in-app purchase). If generation fails, nothing is charged. In the demo (Hilfe → Ohne Hochschulkonto ansehen) the demo module contains slides and an old exam to try it. Mensa: dish photos are loaded directly from the public Studentenwerk Hannover menu service (Studi|Futter), like the menu itself.
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
> KI-Auftragsverarbeiter weiter (Abschnitt 8c) und löscht die Seitentexte spätestens 24 Stunden danach. Gespeichert
> bleiben die erzeugten Probeklausuren und eine Themenübersicht, ohne Bezug zu deinem Konto; wer dieselben Unterlagen
> hat, kann dieselben Probeklausuren kaufen. Zu deinem Konto speichern wir nur, welche Probeklausuren du gekauft hast
> (für den Zugriff und eine Erstattung). Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

(Vor Übernahme prüfen: Löschfrist `MATERIAL_HOURS` in `app/exam_shop.py`.)

## Nutzungsbedingungen – neuer Punkt (§ Credits)

> **Probeklausuren:** Eine Probeklausur aus dem Klausur-Generator kostet 15 Credits. Kann sie nicht erstellt werden,
> wird nichts abgebucht. Probeklausuren sind eine Lernhilfe, von einer KI erstellt und geprüft, aber nicht fehlerfrei;
> sie sagen nichts darüber, was in deiner echten Klausur drankommt.

## Offene Punkte vor dem Einreichen von 1.0.7

- Urheberrecht: Probeklausuren entstehen aus Folien und Altklausuren und werden anderen Nutzern verkauft – vor dem
  Start rechtlich prüfen lassen (Inhaber weiß Bescheid).
- Server-Update mit neuem Docker-Bild (`reportlab`, Schriften, `tools/klausur_pdf`) und Prüfung im Container.
- Bildschirmfoto für den Klausur-Generator (optional).
