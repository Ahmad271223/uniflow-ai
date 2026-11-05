# KI-Vergleich: DeepSeek, gpt-6-luna und Claude Sonnet 5.5 (05.11.2026)

Frage des Inhabers: **Wer generiert bessere Antworten?** Verglichen werden DeepSeek (`deepseek-flash` über
api.deepseek.com), OpenAI `gpt-6-luna` und Claude Sonnet 5.5 (Amazon Bedrock, eu-central-1). Alle bekommen die echten
Prompts der App. Vorgänger: [KI-MODELLVERGLEICH-2026-10-25.md](KI-MODELLVERGLEICH-2026-10-25.md) (Haiku gegen Sonnet,
Text gegen PDF).

Werkzeug: `tools/ki-vergleich.py`, Aufgaben in `tools/ki_vergleich_tasks.py`, Tests in `tests/test_ki_vergleich.py`
(nur mit der Attrappe, ohne Netz).

## Ausführen

Immer mit dem Python der Projektumgebung (`.venv`, Python 3.13). Das System-Python 3.9 hat die Pakete der App nicht.

```sh
cd ~/uniflow-ai

# 1. Probelauf gegen die lokale Attrappe (kein Netz, keine Schlüssel nötig)
.venv/bin/python tools/ki-vergleich.py --dry-run

# 2. Kostenschätzung für den echten Lauf (kein Netz)
.venv/bin/python tools/ki-vergleich.py --estimate

# 3. Echter Lauf mit allen Anbietern, deren Schlüsseldatei vorhanden ist
.venv/bin/python tools/ki-vergleich.py

#    Nur einzelne Anbieter oder Aufgaben, zum Beispiel ein kurzer Test vorab (2 Aufgaben × 1 Anbieter):
.venv/bin/python tools/ki-vergleich.py --only deepseek --tasks mathe-loesen,info-loesen
.venv/bin/python tools/ki-vergleich.py --list            # alle Aufgaben

# 4. Blindbewertung öffnen, bewerten, „Export JSON“, dann auswerten
open ~/Studora-Builds/ki-vergleich/<Zeitstempel>/bewertung.html
.venv/bin/python tools/ki-vergleich.py auswerten ~/Studora-Builds/ki-vergleich/<Zeitstempel> ~/Downloads/bewertung-<Zeitstempel>.json
```

Weitere Schalter: `--out <Ordner>` (statt `~/Studora-Builds/ki-vergleich/<Zeitstempel>`), `--seed <Zahl>` (feste
Mischung A/B/C), `--keys-dir <Ordner>` (Standard `~/Studora-Builds/keys`).

### Schlüssel

Nur aus Dateien, nur zur Laufzeit gelesen, nie ausgegeben, protokolliert oder gespeichert. Fehlermeldungen werden
geschwärzt (`ai_backend.scrub` und die Schlüssel selbst). Die `.env` des Projekts wird **nicht** geladen. Fehlt eine
Datei, fällt der Anbieter weg (Meldung „übersprungen: …“).

| Datei in `~/Studora-Builds/keys/` | Inhalt |
| --- | --- |
| `deepseek.key` | nur der API-Schlüssel von platform.deepseek.com |
| `openai.key` | nur der API-Schlüssel von OpenAI |
| `bedrock.env` (optional) | Zeilen `KEY=Wert`: entweder `AWS_BEARER_TOKEN_BEDROCK=…` (API-Schlüssel von Bedrock) oder `AWS_ACCESS_KEY_ID=…` und `AWS_SECRET_ACCESS_KEY=…` (dazu optional `AWS_SESSION_TOKEN=…`); optional `AWS_REGION=eu-central-1` (nur `eu-*` erlaubt) und `BEDROCK_MODEL=…` (Standard `anthropic.claude-sonnet-5-5`, wie `LERNAPP_ANTHROPIC_MODEL` im Dienst) |

## Was verglichen wird

21 Aufgaben, jede einmal je Modell mit **demselben** System-Text, Prompt, Antwortschema und derselben Ausgabegrenze:

| Art | Prompt-Baustein der App | System | Ausgabegrenze | Aufgaben |
| --- | --- | --- | --- | --- |
| Erklären | `ai.tutor_prompt("explain", …)` | `ai.TUTOR_SYSTEM` | 2.000 (`tutor`) | Mathe (Mittelwertsatz), Signale und Systeme (Faltung), Elektrotechnik (Maschenregel), Informatik (Zweierkomplement, Demo-Skript), BWL (Gewinnschwelle), Recht (Abstraktionsprinzip) |
| Aufgabe lösen | `ai.tutor_prompt("steps", …)` | `ai.TUTOR_SYSTEM` | 2.000 | Kurvendiskussion, Laplace mit Konvergenzgebiet und Stabilität, Spannungsteiler, Demo-Übungsblatt 1 (Dualzahlen, Zweierkomplement), Break-even mit Zusatzauftrag, Minderjährigen-Fall (§§ 107, 108, 110 BGB) |
| Karteikarten (8) | `ai.flashcards_prompt(…, count=8)` mit `ai.FLASHCARDS_SCHEMA` | `ai.SYSTEM` | 3.000 | Folgen und Reihen, Wechselstrom, Rechtsformen |
| Wochentest (5) | `ai._test_prompt` über `ai.week_test_options({"count": 5})` | `ai.SYSTEM` | 9.000 (`weekly_test`) | Signale und Systeme (Laplace), Demo Informatik (alle drei Demo-Dateien) |
| Antworten bewerten | `ai.grade_prompt` | `ai.SYSTEM` | 2.000 (`test_grading`) | Elektrotechnik (5 Aufgaben), Bürgerliches Recht (4 Aufgaben), mit erfundenen Antworten und bekannten Sollpunkten |
| Ganzes Dokument | `doc_explain.plan_steps("lecture", …)` + `step_prompt` (ein Schritt „full“) | `doc_explain.SYSTEM` | 3.500 | 10 Seiten Sortierverfahren (Informatik), 10 Seiten Kosten- und Leistungsrechnung (BWL) |

Gesendet wird über die Anbieter-Klassen des Dienstes: `ai_backend.OpenAIProvider` (Responses API, `reasoning.effort`
wie im Dienst, Standard `low`, `store: false`), `ai_providers.AnthropicProvider` (Messages API über
`AnthropicBedrockMantle`, `effort` medium) und `ai_providers.OpenAICompatProvider` für DeepSeek (Chat Completions als
Strom mit `include_usage`).

Abweichungen von der App, bewusst:

- **DeepSeek direkt über api.deepseek.com** (Auftrag des Inhabers für diesen Vergleich). Der Dienst selbst lässt
  deepseek.com nicht zu (`check_eu_base_url`) und nutzt DeepSeek nur über Scaleway in der EU. Deshalb gehen an DeepSeek
  nur erfundene Aufgaben, öffentliches Lehrbuchwissen und der Demo-Inhalt der App, nie Daten von Studierenden.
- DeepSeek kennt kein `json_schema`; bei Karteikarten geht stattdessen `response_format: json_object` mit. Kein
  `reasoning_effort` an DeepSeek.
- Wochentest mit **5** statt 6 Aufgaben: Die App erlaubt nur 5, 10, 15 oder 20 (`WEEK_TEST_COUNTS`), Verteilung
  1 leicht, 2 mittel, 2 schwer.
- Nur der Textweg (kein PDF), ohne Stud.IP-Kontext, Quellen und Gesprächsverlauf. Kein Zwischenspeicher, keine Credits.

## Was gemessen wird

Je Aufruf eine Zeile in `results.jsonl`: Aufgabe, Art, Fach, Anbieter, gemeldetes Modell, Startzeit (UTC), Latenz
(Gesamtzeit) und Zeit bis zum ersten Textstück (`ttft_s`), Eingabe-Tokens, davon Cache-Treffer, Ausgabe-Tokens (bei
OpenAI und Claude inklusive Denk-Tokens; `reasoning_tokens` getrennt, soweit gemeldet), Kosten in US-Dollar, Preiszeit
(DeepSeek `peak`/`offpeak`), Fehler (geschwärzt), Budget-Abbruch, Ergebnis der automatischen Vorprüfung.

Kosten (USD je 1 Mio. Tokens):

| Modell | Eingabe | Cache-Treffer | Ausgabe | Quelle |
| --- | --- | --- | --- | --- |
| deepseek-flash, außerhalb der Spitzenzeit | 0,15 | 0,003 | 0,60 | Preistabelle des Inhabers |
| deepseek-flash, Spitzenzeit (Mo–Fr 01:00–04:00 und 06:00–10:00 UTC) | 0,30 | 0,006 | 1,20 | Preistabelle des Inhabers; maßgeblich ist die Startzeit jedes Aufrufs |
| gpt-6-luna | 0,10 | 0,01 | 0,50 | `app/ai_prices.py` |
| Claude Sonnet 5.5, Bedrock eu-central-1 | 2,20 | 0,11 | 11,00 | `app/ai_prices.py` (EU-Endpunkt, +10 %) |

**Harte Budgetgrenze je Anbieter:** DeepSeek 1,50 $, OpenAI 1,50 $, Bedrock 3,00 $. Vor jedem Aufruf wird die
Obergrenze berechnet (Eingabe-Bytes + 512 Tokens zum vollen Preis, DeepSeek zum Spitzenpreis, plus die volle
Ausgabegrenze). Würde sie das Budget überschreiten, hört dieser Anbieter auf; die übrigen Aufgaben stehen als
„übersprungen“ in `results.jsonl` und `summary.md`. Meldet ein Anbieter keine Nutzung, zählt die Obergrenze.

### Kosten je Lauf (Schätzung mit `--estimate`, 21 Aufgaben)

| Anbieter | Eingabe-Tokens | Ausgabe-Tokens erwartet | erwartet | Obergrenze (alle Ausgaben voll) |
| --- | --- | --- | --- | --- |
| DeepSeek | ≈ 9.400 | ≈ 27.000 | 0,02 $ (außerhalb der Spitze), 0,04 $ (Spitze) | 0,09 $ |
| gpt-6-luna | ≈ 9.400 | ≈ 38.000 (mit Denk-Tokens) | 0,02 $ | 0,04 $ |
| Claude Sonnet 5.5 | ≈ 9.400 | ≈ 35.000 (mit Denken) | 0,41 $ | 0,78 $ |
| **zusammen** | | | **≈ 0,45 $** | **≤ 0,91 $** |

Ein Lauf bleibt also weit unter den Budgets; das Guthaben von 2 € bei DeepSeek reicht für viele Läufe. Laufzeit:
Die drei Anbieter laufen parallel, jeder arbeitet seine Aufgaben nacheinander ab (die Latenz bleibt so unverfälscht).
Erwartet sind etwa 10 bis 20 Minuten.

## Automatische Vorprüfung

Wo das Ergebnis feststeht, prüft das Werkzeug selbst (`checks` in `results.jsonl`, Spalte in `summary.md`, aufklappbar
in der Bewertungsseite). Es ist eine grobe Vorprüfung, kein Urteil:

- **Aufgabe lösen:** bekannte Ergebnisse als Muster im Text (nach Entfernen von Leerzeichen, LaTeX und Formatierung),
  zum Beispiel H(1|5), T(3|1), W(2|3); X(s) = 3/(s+2) mit Re{s} > −2; 2 mA, 4 V, 8 V, 16 mW; 101010, 1100100, 11111111,
  182, 11011011; 3.000 Stück, 20.000 €, 2.500 €; §§ 107, 108, 110 und „unwirksam“.
- **Karteikarten:** gültiges JSON, genau 8 Karten mit Frage und Antwort (`ai.check_flashcards`), keine doppelten Fragen.
- **Wochentest:** gültiges JSON, Form und Verteilung wie in der App (`ai.check_week_test`), jede Multiple-Choice-Lösung
  ist genau eine der Optionen, 100 Punkte.
- **Bewerten:** gültiges JSON, Punkte je Aufgabe im Sollbereich (eindeutige Fälle exakt, zum Beispiel MC richtig = volle
  Punkte, falscher Wert = 0, leere Antwort = 0; offene Antworten mit Spanne), `max` richtig, `total` gleich der Summe.
- **Ganzes Dokument:** Antwort zerlegt mit `doc_explain.parse_blocks`: beginnt mit „Überblick“, endet mit
  „Prüfungsrelevant“, jede Überschrift mit [S. x], Abschnitte decken mindestens 8 der 10 Seiten.
- **Erklären:** nur ein weicher Hinweis (mindestens 60 % der erwarteten Stichworte kommen vor).

## Blindbewertung

`bewertung.html` ist eine statische Seite ohne Netz und ohne externe Bibliotheken. Je Aufgabe stehen die Antworten
gemischt und als A/B/C beschriftet; Anbieter- und Modellnamen kommen in der Seite nicht vor (die Zuordnung steht nur in
`key.json`). Je Antwort 1 bis 5 für **Richtigkeit**, **Verständlichkeit** und **Vollständigkeit** und eine freie Notiz.
Alles wird im Browser gespeichert (localStorage, je Lauf). „Export JSON“ lädt `bewertung-<Lauf>.json` herunter,
„Import“ lädt eine solche Datei wieder (zum Weitermachen auf einem anderen Rechner), „Rohtext“ zeigt die Antworten
unverändert. Karteikarten, Wochentests und Bewertungen erscheinen als Liste bzw. Tabelle.

`auswerten` verbindet den Export mit `key.json` und schreibt `auswertung-<Zeit>.md`: Mittel je Anbieter und Kriterium,
wie oft ein Anbieter die beste Antwort hatte, Mittel je Art, Anteil bestandener Vorprüfungen und Kosten.

## Ergebnisordner

`~/Studora-Builds/ki-vergleich/<Zeitstempel>/` (beim Probelauf mit `-dry`):

| Datei | Inhalt |
| --- | --- |
| `results.jsonl` | eine Zeile je Aufruf (siehe oben), ohne Antworttext |
| `answers/<Aufgabe>/<Anbieter>.md` | Antworten als Markdown |
| `tasks.json` | System-Text, Prompt, Ausgabegrenze und Prüfregeln je Aufgabe |
| `bewertung.html` | Blindbewertung |
| `key.json` | Zuordnung A/B/C zu Anbieter, Seed, Modelle |
| `summary.md` | Tokens, Kosten, Latenz (Median), Fehler, Vorprüfung je Anbieter und Aufgabe |

## Stand 05.11.2026

- Probelauf `--dry-run` (Attrappe mit denselben Anbieter-Klassen, nur der Transport ist ausgetauscht): 21 Aufgaben × 3
  Anbieter, keine Fehler; die Vorprüfung erkennt die eingebauten Fehler der Attrappe (bei „DeepSeek“ fehlt absichtlich
  je ein Ergebnis); die Bewertungsseite zeigt alle Aufgaben, speichert und zählt.
- `tests/test_ki_vergleich.py` (9 Tests, Netz gesperrt): Prompts aus den Bausteinen der App, DeepSeek-Spitzenzeit und
  Kosten, Probelauf mit allen Dateien, keine Namen in der Bewertungsseite, Budgetgrenze, Schlüssel nur aus Dateien und
  nie in den Ergebnissen, Anbieter ohne Schlüsseldatei übersprungen, Vorprüfung an realistischen Antworten, Auswertung.
- Der echte Lauf steht noch aus. Er startet, sobald der Inhaber die Schlüsseldateien abgelegt hat.

## Grenzen

Eine Antwort je Modell und Aufgabe, also keine Streuung. Die Aufgaben sind kurz und erfunden (keine echten Folien, keine
Scans). Die Vorprüfung sucht nur nach Mustern. Deshalb entscheidet die Blindbewertung des Inhabers. DeepSeek läuft hier
direkt in China, im Dienst wäre es Scaleway in der EU (anderes Modell `deepseek-v4.1-flash-1017`, andere Preise in Euro).
