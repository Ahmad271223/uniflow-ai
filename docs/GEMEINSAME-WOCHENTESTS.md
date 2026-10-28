# Gemeinsame Wochentests der Kursgruppe

Stand 28.10.2026 (ersetzt den Stand vom 25.10.). Vorgabe des Inhabers: **Alle, die in derselben Woche dasselbe Modul
(denselben Hochschulkurs) haben, bekommen denselben Wochentest.** Jeder bearbeitet ihn selbst, Punkte rechnet der
Dienst, und es gibt eine freiwillige Rangliste. Dieses Dokument ist zugleich der Auftrag für die Apple-Apps (iPad, Mac
über die iPad-App): Dienst und Windows-App sind fertig, das iPad baut dieselbe Oberfläche gegen dieselben Endpunkte.

Code: `app/weekly_tests.py` (Dienst), `app/community_api.py` (Endpunkte `/api/community/weekly/...`),
`app/server.py` (`/api/weekly/group|materials|request` auf dem Gerät), `app/static/views-weekly.js` (Windows).
Tests: `tests/test_weekly_tests.py`, `tests/test_weekly_local.py`.

Die ältere Regel (Test teilen, wenn alle Dateien denselben Inhalts-Hash haben, `app/testshare.py`) gilt weiter für die
**eigenen** Wochentests auf dem Gerät. Der gemeinsame Test hier ist der offizielle Test der Kursgruppe.

## 1. Wer bekommt welchen Test

Ein gemeinsamer Test gehört zu genau einer **Kursgruppe und Kalenderwoche**:

```
group_key = sha256("studora.weekly.v1\0" + Hochschule + "\0" + course_key + "\0" + Semester + "\0" + ISO-Woche)
course_key = sha256("uniflow.community.course.v1\0" + Hochschule + "\0" + Kurs-ID)   # wie in der Community
```

- **Kurs eines Moduls:** die Veranstaltung des Moduls mit Art `vorlesung`; gibt es keine, die mit der kleinsten ID.
  Gleiche Regel auf allen Geräten, sonst landen Studierende desselben Moduls in verschiedenen Gruppen.
- **Woche:** ISO-Kalenderwoche (`2026-W44`), nicht die Lehrwoche. Der Vorlesungsbeginn kann je Gerät verschieden
  erkannt werden; die Kalenderwoche ist für alle gleich.
- **Semester:** normalisiert (`WiSe 26/27` = `WiSe 2026/27`), ohne Angabe `ohne-semester`.
- Andere Hochschule, anderes Semester oder andere Woche ergeben einen anderen Test. Unis werden nie gemischt.
- Teilnehmen dürfen Konten ab **Studora Plus** (`can_access_shared_tests` in `app/plans.py`), sonst 403 `plan_required`.

## 2. Ablauf und KI-Nutzung (wann, wo, wie oft)

| Schritt | Wo | KI? | Wie oft |
| --- | --- | --- | --- |
| A. Material der Woche sammeln | Gerät (`GET /api/weekly/materials`) | nein | je Anfrage |
| B. Themen der Woche bestimmen | Dienst, Teil der Erstellung | ja (in D enthalten) | 1× je Kursgruppe und Woche |
| C. Altklausuren zuordnen | Gerät (Begriffs-Überlappung, ≥ 4 gemeinsame Begriffe, beste 8 Seiten) und Dienst (KI entscheidet, ob es passt) | nur in D | 1× je Gruppe/Woche |
| D. Test erstellen (15 Aufgaben) | Dienst, Anfrage `weekly:generate` | ja | 1× je Gruppe/Woche |
| E. Test prüfen | Dienst: feste Prüfung im Code, dann Anfrage `weekly:review` | ja | 1× je Gruppe/Woche |
| Bearbeiten, Zwischenspeichern | Gerät + Dienst | nein | – |
| Bewerten: MC, Mehrfachauswahl, Zahl | Dienst, fester Code | nein | je Abgabe |
| Bewerten: offene Antworten | Dienst, Anfrage `weekly:grade` (alle offenen Antworten einer Abgabe in einer Anfrage) | ja | je Abgabe mit offenen Antworten |
| Rangliste | Dienst | nein | – |

Die Erstellung läuft **genau einmal** je Kursgruppe und Woche: Der Eintrag mit `group_key` ist eindeutig. Fragen 100
Studierende gleichzeitig an, entsteht ein Test (Test `test_concurrent_requests_create_one_test`). Die KI-Anfragen
von Erstellung und Prüfung laufen über den Dienst-Kostenrahmen (`user_id=None`), die Bewertung über den Kostenrahmen
des Kontos, das abgibt.

### A. Material (nur Texte, nie Dateien)

Das Gerät schickt Seitentexte, keine PDFs:

- alle Dateien der Lehrwoche mit Art Vorlesung, Übung, Lösung, Skript; Unterart Gruppenübung, Hörsaalübung, Tutorium
  (höchstens 12 Dateien, je 40 Seiten, je Seite 6.000 Zeichen);
- aus dem Skript nur die passenden Seiten (Volltextsuche des Moduls mit dem Wochenstoff, 12 Treffer);
- Altklausuren nur Seiten mit mindestens 4 gemeinsamen Begriffen mit dem Wochenstoff (beste 8).

Der Dienst begrenzt auf 140.000 Zeichen und verlangt mindestens Vorlesung, Übung oder Skript (nur Altklausur reicht
nicht → 400 `materials_missing`). Gemessen auf dem echten Datenbestand (Kopie, 28.10.2026, KW 44): 12.000 bis 64.000
Zeichen je Modul, Zusammenstellen 0,03 bis 2,7 s.

### D. Erstellung

Vorgaben im Prompt (`_gen_prompt`): erst Themen bestimmen, dann genau 15 Aufgaben: 5 `short` (Grundwissen, Definition,
kleine Rechnung), 6 `medium` (mehrstufige Anwendung), 4 `hard` (Transfer, klausurnah). Nur Stoff bis zu dieser Woche.
Bevorzugt automatisch prüfbare Typen `mc`, `multi`, `number`; höchstens 4 offene (`short`, `text`, `calc`). Jede
Musterlösung selbst nachrechnen. Punkte zusammen 100. Altklausuren nach `LERNAPP_WEEKLY_PAST_EXAMS`:

- `inspire` (Standard): nur als Vorbild, neu formuliert, Kennzeichen `past_exam_like`;
- `reuse`: 1 bis 2 Aufgaben übernehmen, wenn alle nötigen Verfahren behandelt wurden, Kennzeichen `past_exam`
  (nur einschalten, wenn die Weitergabe erlaubt ist).

Jede Aufgabe trägt Quellen (`{"q": "Q2", "page": 3}`), Q-Nummern zeigen auf das Material.

### E. Prüfung

1. Fester Code (`check_question`): Stufe und Typ bekannt, Text lang genug, 1 bis 40 Punkte, Optionen 2 bis 8,
   Lösungsbuchstaben passen zu den Optionen (MC genau einer), Zahl mit Toleranz, Musterlösung vorhanden, keine Dublette.
2. Zweite KI-Anfrage prüft jede Aufgabe gegen das Material (lösbar, richtig nachgerechnet, gedeckt, Schwierigkeit,
   Quellen). Durchgefallene fliegen raus; nur bei offenen Aufgaben darf die Prüfung eine Musterlösung korrigieren.
3. Bleiben mindestens 12 Aufgaben, wird veröffentlicht; die Punkte werden auf genau 100 gebracht (Rundungsrest auf die
   größte Aufgabe). Sonst Status `failed` mit Grund, ein neuer Versuch ist möglich.

### Bewertung

- `mc`: Buchstabe gleich; `multi`: volle Punkte nur bei genau der richtigen Menge, sonst 0 (keine Teilpunkte);
  `number`: innerhalb der Toleranz (Komma und Punkt).
- Offene Antworten: eine KI-Anfrage je Abgabe mit Musterlösung und Schema, Punkte begrenzt auf das Maximum. Unsicher
  (Zuversicht < 0,6) → `needs_review`, nicht in der Rangliste. KI nicht erreichbar → `grading_pending`.
- Bewertet wird **nur im Dienst**. Das Gerät schickt Antworten, nie Punkte.

## 3. Regeln für Versuche und Rangliste

- Der **erste** Versuch je Konto ist der offizielle (`official=1`, eindeutiger Index). Danach beliebig viele
  Übungsversuche, die nie zählen.
- Lösungen, Erklärungen und typische Fehler kommen erst nach der Abgabe des offiziellen Versuchs.
- Zwischenspeichern mit `PUT` (je Aufgabe gilt der zuletzt gespeicherte Stand); auf einem anderen Gerät weitermachen
  geht, weil der offene Versuch im Dienst liegt. Abgeben zweimal (zwei Geräte) liefert dasselbe Ergebnis.
- Rangliste: nur, wer zustimmt (beim Abgeben oder später), mit selbst gewähltem Namen (2 bis 24 Zeichen, keine
  E-Mail) oder Pseudonym. Sichtbar erst nach der Frist (`closes_at` = Veröffentlichung + 7 Tage); vorher nur die Zahl
  der gewerteten Abgaben, auch der eigene Platz erst danach. Gleiche Punkte = gleicher Platz (1, 1, 3).
- Manipulation: Versuch-IDs anderer Konten → 404; abgegebene Versuche lassen sich nicht ändern; Punkte vom Gerät
  werden ignoriert; Erstellung je Konto höchstens 10 je Tag (`weekly_generate_user`).

## 4. Endpunkte

Im Dienst (Studora-Konto, Bearer):

| Methode und Pfad | Zweck |
| --- | --- |
| `GET /api/community/weekly/{course_key}?term=` | Tests der Kursgruppe im Semester, mit eigenem Stand |
| `GET /api/community/weekly/{course_key}/{week}?term=` | Test der Woche ohne Lösungen (mit, wenn abgegeben); 404 `not_generated` |
| `POST /api/community/weekly/{course_key}/{week}` `{term, materials}` | Test holen oder einmal erstellen lassen (202) |
| `POST /api/community/weekly/tests/{id}/attempt` `{practice?}` | offiziellen Versuch beginnen/fortsetzen bzw. Übungsversuch |
| `PUT /api/community/weekly/attempts/{id}` `{answers}` | Zwischenspeichern |
| `POST /api/community/weekly/attempts/{id}/submit` `{answers, leaderboard, display_name}` | Abgeben und bewerten |
| `POST /api/community/weekly/attempts/{id}/leaderboard` `{on, display_name?}` | Ranglisten-Zustimmung ändern |
| `GET /api/community/weekly/tests/{id}/leaderboard` | Rangliste (`visible`, `participants`, `entries`, `my_rank`) |

Antworten: `mc` = `"B"`, `multi` = `"A,C"`, `number` = Text (`"3,5"`), sonst Freitext.

Auf dem Gerät (Windows-App; das iPad bildet dasselbe selbst):

| Methode und Pfad | Zweck |
| --- | --- |
| `GET /api/weekly/group?module_id=&date=` | `course_key`, `term`, `week`, `monday`, `course_title`; 404 `no_course` |
| `GET /api/weekly/materials?module_id=&date=` | Material der Woche (nur Texte) |
| `POST /api/weekly/request` `{module_id}` | Gruppe + Material bilden und an den Dienst schicken; ohne Konto 409 `not_linked` |

## 5. Oberfläche (Windows fertig, iPad nachbauen)

„Tests & Wiederholung“ zeigt oben **„Gemeinsamer Wochentest deiner Kursgruppe“**, je Modul eine Zeile: noch kein Test
→ „Erstellen lassen“; ohne Material → klare Meldung; wird erstellt → Fortschritt; fertig → „Starten“, „Weiter“ oder
„Ergebnis“ mit Punkten. Darunter die eigenen Tests wie bisher.

- **Bearbeiten** (`#/exams/w/{id}`): Kopf mit Woche, Zahl der Aufgaben je Stufe, Punkten und Themen; Leiste mit
  Aufgabennummern (beantwortet hervorgehoben); je Aufgabe Stufe, Punkte, Zeitbedarf, Hinweis „nach Altklausur“, Eingabe
  je Typ (Optionen mit Buchstaben, Zahlenfeld, Textfeld) und Quelle. Speichern nach 1,2 s automatisch, zusätzlich
  lokal; „Später weiter“.
- **Abgeben:** Hinweis auf leere Aufgaben, Ranglisten-Zustimmung, Name.
- **Ergebnis:** Punkte und Prozent, Hinweis bei unsicherer oder ausstehender Bewertung, je Aufgabe eigene Antwort,
  Lösung, Erklärung, Rückmeldung, typische Fehler und Quelle als Link, der die eigene Datei an der Seite öffnet
  (`/api/files/by-fingerprint/{sha256}`); „Noch einmal üben“.
- **Rangliste:** vor der Frist Datum und Zahl der Abgaben, danach Tabelle (Platz, Name, Punkte, %, Zeit), eigene Zeile
  hervorgehoben, Schalter zum Ein- und Austragen.

Geprüft am 28.10.2026 im Browser mit einer Kopie des echten Datenbestands und einem eigenen Testdienst mit Schein-KI:
Erstellen für Elektrotechnische Grundlagen (Vorlesung, Hörsaalübung, 2 Skriptseiten), Bearbeiten, Weitermachen nach
Löschen des lokalen Zwischenspeichers, Abgeben, Lösungen, Quellen-Link, Rangliste vor und nach der Frist, nachträgliche
Zustimmung, Übungsversuch. Die echte KI wurde dabei nicht aufgerufen.

## 6. Kosten

Gerechnet wird in Tokens; Euro ergeben sich aus dem Preis des eingestellten Modells (`LERNAPP_AI_MODEL`,
`LERNAPP_AI_PRICE_IN_EUR`, `LERNAPP_AI_PRICE_OUT_EUR`). Annahme: rund 3,7 Zeichen je Token bei deutschem Text.

| Anfrage | Eingabe | Ausgabe | Wie oft |
| --- | --- | --- | --- |
| Erstellen (`weekly:generate`) | ca. 40.000 Tokens (Material bis 140.000 Zeichen, typisch 55.000) | ca. 7.000 | 1× je Kursgruppe und Woche |
| Prüfen (`weekly:review`) | ca. 22.000 (Material gekürzt auf 60.000 Zeichen + Aufgaben) | ca. 1.000 | 1× je Kursgruppe und Woche |
| Bewerten (`weekly:grade`) | ca. 3.000 | ca. 600 | je Abgabe mit offenen Antworten |

Damit kostet ein Test **einmal** rund 62.000 + 8.000 Tokens, egal wie viele ihn schreiben; je Abgabe kommen höchstens
3.600 Tokens dazu, ohne offene Antworten nichts.

Rechenbeispiel (Annahmen, bitte mit der echten Preisliste ersetzen): je Mitglied 5 Module × 4 Wochen = 20 offizielle
Tests im Monat plus 20 % Übungsversuche, 80 % der Abgaben mit offenen Antworten, im Schnitt **20 Studierende je
Kursgruppe** (bei mehr Nutzern eher mehr, dann sinkt der Erstellungsanteil). Beispielpreise je 1 Mio. Tokens:
kleines Modell 0,40 € Eingabe / 1,60 € Ausgabe, großes Modell 2,00 € / 8,00 €.

| Test-Nutzer | Tests im Monat | Erstellen + Prüfen (groß) | Bewerten (klein) | Bewerten (groß) | Summe groß + klein | Summe alles groß |
| --- | --- | --- | --- | --- | --- | --- |
| 5.000 | 5.000 | ca. 940 € | ca. 210 € | ca. 1.040 € | **ca. 1.150 €** | ca. 1.980 € |
| 10.000 | 10.000 | ca. 1.880 € | ca. 410 € | ca. 2.070 € | **ca. 2.290 €** | ca. 3.950 € |
| 20.000 | 20.000 | ca. 3.760 € | ca. 830 € | ca. 4.150 € | **ca. 4.590 €** | ca. 7.910 € |
| 30.000 | 30.000 | ca. 5.640 € | ca. 1.240 € | ca. 6.220 € | **ca. 6.880 €** | ca. 11.860 € |
| 50.000 | 50.000 | ca. 9.400 € | ca. 2.070 € | ca. 10.370 € | **ca. 11.470 €** | ca. 19.770 € |

Je Test-Nutzer und Monat sind das rund **0,23 €** (Erstellen groß, Bewerten klein) bzw. 0,40 € (alles groß). „Test-
Nutzer“ sind nur Konten ab Plus, die wirklich jede Woche alle Tests schreiben; bei 25 % Plus-Anteil unter allen Nutzern
und halber Nutzung ist es rund ein Achtel davon. Ohne gemeinsame Tests (jeder seinen eigenen) wäre der Erstellungsanteil
20-mal so hoch.

Wichtig für den Betrieb:

- `LERNAPP_AI_BUDGET_EUR` (Gesamtbudget im Monat, Standard **50 €**) muss vor dem Start passend gesetzt werden, sonst
  antwortet der Dienst ab dem Erreichen mit 503 `ai_budget_exhausted`; Abgaben werden dann `grading_pending`.
- Ein eigenes, günstigeres Modell nur für die Bewertung ist noch nicht einstellbar (heute ein Modell für alles).
- Speicher: ein Test rund 30 KB, eine Abgabe rund 5 KB; bei 50.000 Test-Nutzern etwa 5 GB im Monat in `community.db`.
  Vor dem großen Start braucht es eine Aufbewahrungsregel für alte Abgaben (offen).
