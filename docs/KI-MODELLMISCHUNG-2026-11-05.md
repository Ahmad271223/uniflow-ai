# KI-Modellmischung: ChatGPT und Claude Sonnet 5.5 (DeepSeek aus), Stand 05.11.2026

## 0. Neue Entscheidung: ChatGPT statt DeepSeek (05.11.2026, gilt)

Der Inhaber hat am 05.11.2026 nach dem Kostenvergleich (Abschnitt 4: DeepSeek bei Scaleway kostet je Anfrage fast
fünfmal so viel wie `gpt-6-luna`) entschieden: **„also nein dann benutz gpt eher als deepseek“**.

- **Standard jetzt:** kein DeepSeek in den Wegen. Der frühere DeepSeek-Anteil geht an ChatGPT (OpenAI `gpt-6-luna`).
  Sonnet 5.5 (Bedrock Frankfurt) behält die schweren Fälle.
- **Neue Verteilung** bei der typischen Nutzung (`TYPICAL_MIX`, `ai_router.expected_share()`): **OpenAI 75 %,
  Sonnet 25 %, DeepSeek 0 %** (vorher 49/26/25).
- **Kosten je typischer Anfrage** (3.000 Tokens Eingabe, 600 Ausgabe, ohne Cache): 0,75 × 0,066 Cent + 0,25 × 1,32 Cent
  ≈ **0,38 Cent** (mit OpenAI über die USA 0,375 Cent; vorher ≈ 0,49 Cent).
- **Pro AI (100 Credits = 1 €, harte Grenze unverändert):** ChatGPT-Anfrage 1 Credit, Sonnet-Anfrage 2 Credits, im Mittel
  1,25 Credits. Das reicht für rund **80 typische Anfragen** im Monat (wie vorher, weil auch DeepSeek 1 Credit kostete).
  Echte Kosten eines voll genutzten Kontos: etwa 80 × 0,38 Cent ≈ **0,30 €** (vorher ≈ 0,40 €), höchstens 1 €.
- **DeepSeek bleibt im Code, ist aber aus:** Adapter `OpenAICompatProvider` (app/ai_providers.py), Sperre für Adressen in
  China und der Scaleway-Preis in app/ai_prices.py bleiben. `ai_router.OPT_IN`: DeepSeek zählt nur als eingerichtet, wenn
  `LERNAPP_DEEPSEEK_API_KEY` gesetzt ist **und** `LERNAPP_AI_ROUTES` ihn nennt (oder `LERNAPP_AI_PROVIDER=deepseek`).
  Ein Schlüssel allein schickt nie Daten an Scaleway, auch nicht als Ersatz. Die alte Mischung steht als
  `ai_router.DEEPSEEK_ROUTES_EXAMPLE` und als auskommentierte Zeile in `deploy/.env.example`; wer sie einschaltet, muss
  vorher den AVV mit Scaleway abschließen und Scaleway wieder in die Datenschutzerklärung (8c, 11, 12) aufnehmen.
- **Datenschutzerklärung:** Scaleway ist kein Auftragsverarbeiter mehr; genannt sind OpenAI und Amazon Web Services
  (Bedrock Frankfurt). Mail-Anbieter ist STRATO (Abschnitt 11).
- **Der Inhaber braucht jetzt nur:** OpenAI (Projekt mit EU-Datenresidenz beantragen, DPA annehmen) und AWS (Bedrock,
  Sonnet 5.5 in eu-central-1). Kein Scaleway-Konto.

Die Abschnitte 1 bis 8 unten beschreiben die Recherche und die erste Mischung vom selben Tag; wo sie vom Stand oben
abweichen, gilt Abschnitt 0.

## Erste Entscheidung (05.11.2026, ersetzt durch Abschnitt 0)

Entscheidung des Inhabers (05.11.2026): Die StudiNow-KI im Dienst soll mehrere Modelle mischen. Zuerst waren 40 % DeepSeek,
30 % ChatGPT und 30 % Claude Sonnet 5.5 gewünscht, dann **„oder mach 50 deepseek“**: etwa **50 % DeepSeek, 25 % ChatGPT,
25 % Sonnet**. Bedingung: DeepSeek **nur über einen Anbieter in der EU**, nie über die Server von DeepSeek in China
(DSGVO). Verteilt wird **nach Aufgabe**, nicht zufällig: günstige Modelle für einfache Aufgaben, Sonnet für schwere Fälle.
Pro AI bleibt bei **100 Credits = 1 €** im Monat, jetzt als **harte Obergrenze** („okay dann lass es bei 100 credits 1€“).

Alle Angaben wurden am 05.11.2026 auf öffentlichen Seiten gelesen. **[geprüft]** heißt: auf einer offiziellen Seite oder
in einer offiziellen Preisliste gesehen. **[abgeleitet]** heißt: daraus geschlossen. **[ungeprüft]** heißt: nur aus
Drittquellen oder gar nicht gefunden. Es gab keine echten Aufrufe bei einem Anbieter; alle Tests laufen mit Attrappen.

## 1. Vergleich

Preise gelten je 1 Mio. Tokens (Eingabe / zwischengespeicherte Eingabe / Ausgabe). Der Dienst zählt einen Dollar als
einen Euro, das ist absichtlich vorsichtig (`LERNAPP_AI_USD_EUR=1`).

| Anbieter und Modell | Preis | Ort | Firma | AVV/DPA | Schnittstelle | Bilder | Urteil |
|---|---|---|---|---|---|---|---|
| **Scaleway** `deepseek-v4.1-flash-1017` | **0,60 € / 0,12 € / 1,80 €** [geprüft, Katalog] | Paris (OPCORE), „bleibt in Europa“ [geprüft] | Scaleway SAS, FR | Teil des Vertrags, selbst herunterladen (Konsole → Organisation → Verträge) [geprüft] | `https://api.scaleway.ai/v1`, OpenAI-kompatibel (Chat Completions) [geprüft] | ja [geprüft] | **gewählt**; Status „preview“ |
| Scaleway `deepseek-v4-flash-0731` | 0,40 € / 0,08 € / 0,80 € [geprüft] | wie oben | wie oben | wie oben | wie oben | nein | günstiger, nur Text; per `LERNAPP_DEEPSEEK_MODEL` wählbar |
| Nebius Token Factory, DeepSeek V4.1-Flash / V4-Pro | 0,30 $ / 1,20 $ [ungeprüft] | serverlos „Global“, kann sich ohne Ankündigung ändern [geprüft] | Nebius Group N.V., NL | in den AGB | OpenAI-kompatibel | – | **nein**: keine EU-Garantie ohne eigenen Endpunkt |
| OVHcloud AI Endpoints, IONOS AI Model Hub, STACKIT | – | EU | EU | ja | OpenAI-kompatibel | – | kein DeepSeek im Angebot [geprüft] |
| DeepSeek selbst (`api.deepseek.com`) | – | China | – | – | – | – | **ausgeschlossen**; der Dienst lehnt diese Adresse ab |
| **Amazon Bedrock** `anthropic.claude-sonnet-5-5`, eu-central-1, EU-Endpunkt | **2,20 $ / 0,11 $ / 11,00 $** [geprüft, AWS-Preisliste; +10 % Regionalaufschlag] | Frankfurt; EU-Profile „bleiben in der Geografie“ [geprüft] | AWS EMEA | automatisch über die AWS Service Terms (mit SCC) [geprüft] | Messages API (Mantle-Endpunkt), offizielles SDK `AnthropicBedrockMantle` | ja | **gewählt** |
| Google Vertex, Sonnet 5.5, Multi-Region „eu“ | 2,20 $ / – / 11,00 $ [abgeleitet: +10 % laut Anthropic] | EU | Google | Cloud-DPA [ungeprüft] | Messages API (`AnthropicVertex`) | ja | gleichwertige Reserve |
| Anthropic direkt, Sonnet 5.5 | 2,00 $ / 0,10 $ / 10,00 $ [geprüft] | `inference_geo` nur „global“ oder „us“, **kein EU** [geprüft] | Anthropic | in den Commercial Terms [geprüft] | Messages API | ja | nur mit `LERNAPP_ANTHROPIC_ALLOW_NON_EU=1` |
| **OpenAI** `gpt-6-luna`, Standard | **0,10 $ / 0,01 $ / 0,50 $** [geprüft] | USA | OpenAI | DPA in der Services Agreement [geprüft]; EWR-Daten bei OpenAI Ireland [ungeprüft] | Responses API | ja | **gewählt** (heutiger Stand) |
| OpenAI mit EU-Datenresidenz (`eu.api.openai.com`) | +10 % für Modelle ab 05.03.2026 [geprüft], also etwa 0,11 / 0,011 / 0,55 $ [abgeleitet] | EWR und Schweiz; „Systemdaten“ eventuell außerhalb [geprüft] | OpenAI | wie oben | Responses API und Chat Completions [geprüft] | ja | **empfohlen**, braucht aber die Freischaltung durch den Vertrieb (ZDR oder geänderte Missbrauchsprüfung) |

Quellen (gelesen 05.11.2026):

- DeepSeek-Modelle: <https://api-docs.deepseek.com/quick_start/pricing>
- Scaleway-Preise: öffentlicher Katalog
  <https://api.scaleway.com/product-catalog/v2alpha1/public-catalog/products?product_types=generative_apis>
- Scaleway-Modelle: <https://www.scaleway.com/en/docs/generative-apis/reference-content/supported-models/>
- Scaleway-Datenschutz (keine Speicherung, kein Training, höchstens 2 Wochen bei Fehlern oder Missbrauch):
  <https://www.scaleway.com/en/docs/generative-apis/reference-content/data-privacy/>
- Scaleway-Verträge (AVV): Doku-Seite „download-scaleway-contracts“. Gelesen über das Quell-Repository
  `github.com/scaleway/docs-content`, weil scaleway.com Abrufe mit 403 ablehnt.
- Nebius: docs.tokenfactory.nebius.com (legal-quick-guide, deprecation notice)
- OVHcloud: <https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models>
- IONOS: <https://docs.ionos.com/cloud/ai/ai-model-hub/models/llms>
- STACKIT: <https://docs.stackit.cloud/products/data-and-ai/ai-model-serving/basics/available-shared-models/>
- Claude-Preise: <https://platform.claude.com/docs/en/about-claude/pricing>
- Claude-Datenresidenz: <https://platform.claude.com/docs/en/manage-claude/data-residency>
- Claude auf Bedrock: <https://platform.claude.com/docs/en/build-with-claude/claude-in-amazon-bedrock>
- AWS-Preisliste eu-central-1: `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonBedrockFoundationModels/current/eu-central-1/index.json`
- AWS, regionsübergreifende Inferenz in einer Geografie:
  <https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html>
- Vertex: <https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/partner-models/claude/sonnet-5-5>
- OpenAI-Datenresidenz: <https://developers.openai.com/api/docs/guides/your-data>
- OpenAI-Preise: <https://developers.openai.com/api/docs/pricing>

**Ungeprüft, vor dem Start klären:**

1. Liefert Scaleway serverlos mit `stream_options.include_usage` die Nutzung am Ende des Stroms? Fehlt sie, rechnet der
   Dienst die Reservierung ab. Das ist sicher, aber teurer für das Konto.
2. Begrenzt `max_tokens` bei DeepSeek auf Scaleway auch die Denk-Tokens? Der Dienst sendet `reasoning_effort: none`,
   dann entsteht kein Denken.
3. Bedrock: Läuft `anthropic.claude-sonnet-5-5` in eu-central-1 über den **EU-Endpunkt** (nicht „Global“)? Das in der
   Konsole prüfen. Gibt es dort eine eigene EU-Profil-ID, sie in `LERNAPP_ANTHROPIC_MODEL` eintragen.
   Ungeprüft ist auch, ob London oder Zürich als Ziel dienen; beide haben einen Angemessenheitsbeschluss der EU.
4. Gilt der EU-Aufschlag bei OpenAI auch für `gpt-6-luna`? Das Erscheinungsdatum steht nicht in der Doku.
5. Den genauen Ablauf zum Abschluss des DPA bei OpenAI prüfen: Die Seite lehnte den Abruf ab.

## 2. Empfehlung je Anbieter

- **DeepSeek (seit Abschnitt 0 aus, nur noch zum Wiedereinschalten):** Scaleway mit `deepseek-v4.1-flash-1017`. Das ist das einzige gefundene EU-Unternehmen mit
  EU-Garantie, Speicherung null als Standard und einem AVV zum Selbst-Herunterladen; es liest auch Bilder.
  Achtung: Je Anfrage ist es **teurer als `gpt-6-luna`** (siehe Abschnitt 4).
- **Claude Sonnet 5.5:** Amazon Bedrock in eu-central-1 über den EU-Endpunkt. Der Preis steht in einer offiziellen
  Liste, die Daten bleiben in der EU, und der DPA gilt automatisch. Vertex „eu“ ist die Reserve. Direkt bei Anthropic
  gibt es heute keine EU-Verarbeitung.
- **OpenAI:** Den Vertrieb jetzt um ein Projekt mit EU-Datenresidenz bitten. Danach
  `LERNAPP_OPENAI_BASE_URL=https://eu.api.openai.com/v1` setzen; der Dienst rechnet dann von selbst 10 % mehr. Bis zur
  Freischaltung läuft OpenAI wie heute über die USA (DPF/SCC).

## 3. Wie der Dienst mischt (app/ai_router.py)

Je Anfrage wählt der Router aus `request_id` und Zweck ein Modell nach Gewicht. Das geschieht per Hash, ohne Zufall:
Eine Wiederholung derselben `request_id` landet beim selben Modell.

| Weg | Zwecke | Gewichte (Stand Abschnitt 0; vorher in Klammern) |
|---|---|---|
| einfach (`default`) | Erklären, Zusammenfassen, Begriffe, Hinweise, Karteikarten, Dokument-Index, Vorlesung im ganzen Dokument | OpenAI 100 (DeepSeek 65 · OpenAI 35) |
| mittel | eigene Frage (`tutor:ask`), ähnliche Aufgabe, Wochentests, Testfragen | OpenAI 75 · Sonnet 25 (DeepSeek 50 · OpenAI 25 · Sonnet 25) |
| **schwer** | Schritt für Schritt (`tutor:steps`), Lösung prüfen/bewerten (`tutor:check`), „Erkläre alle Aufgaben“ (`tutor:doc_tasks`), Rechnen oder Herleiten in Frage oder Markierung, **„Antwort war falsch“** (`second_opinion: true` bei `/api/ai/tutor` und `/api/ai/document/step`: neu erzeugt, nie aus dem Zwischenspeicher) | Sonnet 100 |

Weitere Regeln:

- **Rechnen erkennen** ohne KI (`looks_math`). Das gilt nur für Frage und Markierung, nicht für den Seitentext:
  Schlüsselwörter wie herleiten, beweisen, berechnen, ableiten, Integral oder „zeige, dass“, oder viele Formelzeichen.
- **Bilder** gehen nur an Modelle, die Bilder lesen (`vision` in app/ai_prices.py).
- **Ersatz:** Hinter dem gewählten Modell stehen die anderen. Gewechselt wird nur, wenn der Anbieter nichts berechnet
  hat: 5xx, 429, 401/403, keine Verbindung oder Zeitüberschreitung vor der Antwort. Bricht eine schon angenommene
  Antwort ab, gibt es keinen Wechsel; abgerechnet wird genau einmal.
- **Notschalter:** `LERNAPP_AI_DISABLED=anthropic` schaltet einen Anbieter ab (oder mehrere, mit Komma). Fehlt einem
  Anbieter der Schlüssel, ist er ebenfalls raus; die anderen des Weges übernehmen seinen Anteil.
- **Einstellen:** `LERNAPP_AI_ROUTES` (JSON) legt Wege je Zweck, den schweren Weg, die schweren Zwecke und die
  Rechen-Regel fest.

**Ergebnis für eine typische Nutzung** (Annahme `TYPICAL_MIX`, nicht gemessen; je 100 Anfragen: 60 einfach, 20 mittel,
20 schwer, davon 7 durch Rechnen oder Zweitmeinung): **OpenAI 75 %, Sonnet 25 %, DeepSeek 0 %** (erste Mischung:
DeepSeek 49 %, OpenAI 26 %, Sonnet 25 %; `ai_router.expected_share()`, im Test auf ±3 Prozentpunkte geprüft). Die echte Verteilung zeigt
`GET /api/billing/ai-usage` unter `by_provider` (nur Inhaber).

## 4. Kosten

Typische Anfrage mit 3.000 Tokens Eingabe und 600 Tokens Ausgabe, ohne Cache:

| Modell | Rechnung | Kosten |
|---|---|---|
| DeepSeek V4.1-Flash (Scaleway) | 3.000 × 0,60 € + 600 × 1,80 € | 0,288 Cent |
| gpt-6-luna (EU, +10 %) | 3.000 × 0,11 $ + 600 × 0,55 $ | 0,066 Cent (USA: 0,060) |
| Sonnet 5.5 (Bedrock EU) | 3.000 × 2,20 $ + 600 × 11,00 $ | 1,32 Cent |
| erste Mischung 49/26/25 (DeepSeek/OpenAI/Sonnet) | | ≈ 0,49 Cent je Anfrage |
| **Mischung 75/25 (OpenAI/Sonnet), gilt** | 0,75 × 0,066 + 0,25 × 1,32 | **≈ 0,38 Cent je Anfrage** (USA: 0,375) |

Die Mischung ist etwa **6-mal so teuer wie nur `gpt-6-luna`**; fast alles davon ist Sonnet für die schweren Fälle. Für
Studierende zählt die Rundung: Jede Anfrage kostet mindestens 1 Credit. Eine typische Anfrage über OpenAI kostet
1 Credit, über Sonnet 2 Credits. Im Mittel sind das etwa 1,25 Credits; mit 100 Credits reicht Pro AI also für rund
80 typische Anfragen statt 100. Die echten Kosten eines voll genutzten Pro-AI-Kontos liegen bei etwa 0,30 € (erste
Mischung: 0,40 €), höchstens 1 €.

## 5. Harte Grenze je Konto (100 Credits = 1 €)

- **Vor jedem Aufruf** reserviert der Dienst die Obergrenze für das **teuerste Modell der Anbieter-Kette**, Ersatz also
  eingeschlossen (`ai_prices.worst_case_microeur`):
  - Eingabe-Tokens höchstens so viele wie Bytes in UTF-8, denn bei Byte-BPE ist ein Token mindestens ein Byte;
  - dazu 512 Tokens Aufschlag und das JSON-Schema;
  - Bilder im schlimmsten Fall;
  - die volle Ausgabegrenze inklusive Denken, alles zum vollen Preis.
- **Reicht der Rest nicht**, wird die Ausgabegrenze verkleinert, aber nicht unter 400 Tokens. Sonst gibt es
  429 `credits_exhausted`.
- **Gleichzeitige Anfragen** reservieren nacheinander (`BEGIN IMMEDIATE`). Zusammen können sie nie mehr reservieren, als
  der Monat noch hat.
- **Abgerechnet** wird danach die echte Nutzung, aber nie mehr als reserviert. Bei einer verfallenen Reservierung ist es
  nie mehr als der freie Rest. Meldet ein Anbieter keine Nutzung, oder bricht eine angenommene Antwort ohne Nutzung ab,
  wird die Reservierung berechnet.
- **Antworten dürfen höchstens 10 Minuten laufen**, kürzer als der Verfall einer Reservierung (15 Minuten).
- **Zwischengespeicherte und geteilte Antworten** kosten 0 Credits und zählen nicht.
- **Nicht genutzt:** die `fallbacks` von Anthropic auf andere Claude-Modelle. Deren Preis stünde nicht in der
  Reservierung. Lehnt Claude eine Anfrage ab, endet sie mit 422 `ai_refused`; die verbrauchten Tokens werden abgerechnet.

## 6. Zwischenspeicher über Modelle hinweg

- **`ai_cache`:** Der Schlüssel besteht aus Zweck, System-Prompt, Prompt und Schema, **ohne Modell**; die Fassung heißt
  jetzt `c2:`. In der Spalte `model` steht, welches Modell die Antwort geschrieben hat; ein Treffer meldet es als
  `source_model`.
- **`doc_explain_cache`** war schon unabhängig vom Modell (`step_hash`) und speichert das Modell mit.
- **Erklärungsspeicher (`page_explain`)** speichert nur Chiffrate der Geräte; das Modell steht im verschlüsselten Inhalt.

## 7. Was der Inhaber anlegen und unterschreiben muss

Seit Abschnitt 0 nur noch **AWS** (2.) und **OpenAI** (3.); Scaleway (1.) entfällt, solange DeepSeek aus ist.

1. **Scaleway (entfällt, nur falls DeepSeek wieder eingeschaltet wird):**
   - Konto mit Organisation und Projekt in fr-par anlegen.
   - Unter IAM einen API-Schlüssel erzeugen und als `LERNAPP_DEEPSEEK_API_KEY` eintragen.
   - Unter Organisation → Verträge den AVV herunterladen und ablegen.
   - Ein Budget-Limit in der Abrechnung setzen.
2. **AWS:**
   - Ein Konto anlegen und in Bedrock (eu-central-1) den Modellzugang für Claude Sonnet 5.5 anfragen.
   - Einen Bedrock-API-Schlüssel (`LERNAPP_ANTHROPIC_API_KEY`) oder einen IAM-Nutzer nur mit `bedrock:InvokeModel*`
     anlegen (`AWS_ACCESS_KEY_ID` und `AWS_SECRET_ACCESS_KEY`).
   - Prüfen, dass der EU-Endpunkt genutzt wird.
   - Den DPA nimmt man mit den AWS Service Terms an; einen Budget-Alarm setzen.
3. **OpenAI:**
   - Das bestehende Konto behalten und den DPA annehmen (platform.openai.com → Settings).
   - Beim Vertrieb ein Projekt mit EU-Datenresidenz beantragen. Danach einen Schlüssel aus diesem Projekt nehmen und
     `LERNAPP_OPENAI_BASE_URL` setzen.
4. **Datenschutzerklärung:** Abschnitt 8c nennt die zwei Auftragsverarbeiter (OpenAI, AWS). Vor der Veröffentlichung rechtlich
   prüfen lassen.

## 8. Dateien

- `app/ai_router.py` (neu): Wege, Gewichte, schwere Fälle, Ersatz-Reihenfolge, `expected_share`; seit Abschnitt 0
  `OPT_IN` und `DEEPSEEK_ROUTES_EXAMPLE` (`app/ai_backend.configured_providers` prüft beides).
- `app/ai_providers.py` (neu): DeepSeek in der EU (OpenAI-kompatibel), Claude über das SDK (Bedrock oder direkt),
  Sperre für Adressen in China.
- `app/ai_backend.py`: Kette, Reservierung für die Obergrenze, Verkleinern, Ersatz, Cache ohne Modell, `by_provider`.
- `app/ai_prices.py`: neue Modelle, Euro-Preise, EU-Aufschlag bei OpenAI, Bedrock-IDs, `worst_case_microeur`.
- `app/credits.py`: Abrechnung höchstens bis zur Reservierung.
- `app/server.py` und `app/doc_explain_api.py`: `second_opinion`, Kostenzeile mit dem Modell des Weges.
- `app/week_library.py`: Kosten mit dem Modell der Antwort.
- `requirements.txt`: `anthropic[bedrock]==2.1.0`.
- Konfiguration und Rechtstexte: `deploy/.env.example`, `docs/START-DIENST-CHECKLISTE.md`,
  `docs/release/DATENSCHUTZ.md` (seit Abschnitt 0 ohne Scaleway), `site/datenschutz.html` (`tools/gen-site.py`).
- Tests: `tests/test_ai_routing.py`.
