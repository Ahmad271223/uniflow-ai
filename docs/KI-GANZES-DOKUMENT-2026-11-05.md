# KI-Hilfe für das ganze Dokument („Erkläre die ganze Vorlesung“, „Erkläre alle Aufgaben“), Stand 05.11.2026

Wunsch des Inhabers (05.11.2026): Sagt man der KI „nimm das Dokument, erkläre die ganze Vorlesung“ oder „erkläre alle
Aufgaben“, soll sie das können. Bis heute hilft die KI-Hilfe nur zur offenen Seite.

## Was der Nutzer sieht

- **Umfang** in der KI-Hilfe (iPad: Leiste über den Reitern, Web: Auswahl im KI-Tutor): **Diese Seite** (wie bisher) ·
  **Ganzes Dokument** · **Seiten …** (von–bis). Dazu zwei Schnellknöpfe: **Ganze Vorlesung erklären** und
  **Alle Aufgaben erklären**. Die Knöpfe nehmen den gewählten Umfang (bei „Diese Seite“ nur diese Seite).
- **Natürliche Sprache** im Eingabefeld: „Erkläre die ganze Vorlesung“, „Fasse das Dokument zusammen“, „Erkläre alle
  Aufgaben“, „Löse alle Aufgaben“, „Erkläre Seiten 5 bis 12“, „Fasse Kapitel 3 zusammen“, „alle Aufgaben auf dieser
  Seite“. Erkannt wird das ohne KI (`parse_intent`, feste Regeln, gleiche Ergebnisse in Python, Swift und Web).
  Alles andere bleibt eine normale Frage zur Seite.
- **Ergebnis als Blöcke**, die nacheinander erscheinen: bei der Vorlesung je Abschnitt ein Block (Kernideen, Formeln,
  „Prüfungsrelevant:“) und am Ende **Überblick** und **Prüfungsrelevant**; bei Aufgaben **ein Block je Aufgabe**
  (Aufgabe 1, 2a, …: was gefragt ist, nötiges Wissen, Lösungsweg, Ergebnis). Jeder Block trägt seine Seiten („S. 5–7“)
  als Knopf: Antippen springt zur Seite.
- **Kosten vorher:** Kostet ein Lauf mehr als 3 Credits (bzw. mehr als 3 Anfragen über das eigene ChatGPT), fragt die
  KI-Hilfe vorher: „Kostet etwa 6 Credits, du hast 74.“ mit **Starten** / **Abbrechen**. Reicht der Rest nicht:
  „Reicht nicht: kostet etwa 6 Credits, du hast 2. …“ und kein Start. Schon erklärte Teile kosten 0 und sind so
  beschriftet („Schon erklärt · 0 Credits“).

Credits gibt es nur im Dienst (Web, Windows über den Dienst): Pro AI 100 je Monat, Probe 25, Plus und Free 0 – der
ganze Lauf braucht dort dasselbe Recht wie die KI-Hilfe (`can_use_ai_explanations`, Pro AI und Probe); an den
Tarif-Schranken ändert sich nichts. Auf dem iPad läuft die KI über das eigene ChatGPT (0 Credits, „4 Anfragen über
dein ChatGPT“).

## Ablauf (gleich in Dienst und iPad)

1. `POST /api/ai/document/plan` `{file_id, page, mode?: "lecture"|"tasks", scope?: {kind: "page"|"all"|"range"|"chapter",
   from?, to?, chapter?}, question?}` → ohne KI. Mit `question` und ohne `mode` entscheidet `parse_intent`; keine
   Absicht erkannt → `{intent: false}` (der Client fragt dann wie bisher `/api/ai/tutor`). Sonst
   `{intent: true, mode, scope: {kind, from, to, label}, pages, steps: [{id, kind, from, to, title, tasks, cached}],
   calls, cached, estimate: {way, credits, calls}, balance, confirm, enough, message, skipped_pages}`.
2. Der Client ruft die Schritte nacheinander: `POST /api/ai/document/step` `{file_id, page, mode, scope, step, request_id?,
   force?}` → `{step, blocks: [{kind, title, from, to, text}], stored, credits}`. Der Dienst rechnet den Plan aus dem
   Dokument neu (der Client schickt keinen Prompt), jeder Schritt ist eine eigene Anfrage mit eigener `request_id`
   (nie doppelt berechnet, wie die KI-Hilfe) – so erscheinen die Blöcke nach und nach.

**Schritte.** Seitentext zuerst (iPad: Texterkennung nur für Seiten ohne Textebene, auf dem Gerät, kostenlos; Dienst:
Textebene). Seiten ohne Text nimmt das iPad aus dem Dokument-Index (Zusammenfassung der Seite, 0 Credits), sonst
werden sie ausgelassen und genannt (`skipped_pages`). Höchstens 150 Seiten je Lauf, je Seite 6000 Zeichen.

- Vorlesung: Seiten werden zu Teilen von höchstens 24 000 Zeichen gebündelt (`lecture`), danach ein kleiner
  **Überblick** (`overview`) aus den Abschnitten der Teile. Passt alles in einen Teil: ein einziger Aufruf (`full`)
  mit Überblick und Prüfungsrelevantem.
- Aufgaben: Aufgaben werden ohne KI erkannt (Zeilenanfang „Aufgabe 1“, „Übungsaufgabe 2a“, „Exercise 3“, …); ohne
  Treffer nimmt das iPad die Aufgaben aus dem Dokument-Index. Je Schritt höchstens 6 Aufgaben bzw. 12 000 Zeichen
  (`tasks`). Findet sich gar keine Aufgabe, sucht die KI sie seitenweise (`scan`).
- Kapitel: Überschrift „Kapitel 3“ / „3 Titel“ / „3.1 Titel“ bis vor Kapitel 4; Inhaltsverzeichnis-Seiten zählen
  nicht. Nicht gefunden → 422 `chapter_not_found` mit dem Hinweis, Seiten zu nennen.

## Speicher und Kosten

- **Schlüssel je Schritt** (`step_hash`): SHA-256 aus Formatfassung (`v1`), Sprache (`de`), Art, Seitenbereich,
  Aufgabenbezeichnungen und dem normalisierten Text der Seiten (wie der Seiten-Abdruck des Dokument-Index); beim
  Überblick statt Text die Schlüssel der Teile. Das Modell gehört nicht dazu, damit verschiedene ChatGPT-Modelle
  dieselbe Erklärung teilen; eine neue Formatfassung (`DOC_EXPLAIN_VERSION`) macht alle Schlüssel neu.
- **Dienst:** Tabelle `doc_explain_cache` in `accounts.db` (Schlüssel, Variante 1…3, Text, Modell, Zeitpunkt), für
  alle Konten gemeinsam – der nächste mit demselben Dokument zahlt 0. Kein Name, keine Datei, nur die erzeugte
  Erklärung. Treffer werden im Credits-Protokoll als `shared` (0 Credits) vermerkt.
- **iPad:** Erklärungsspeicher (`page_explain` lokal, CloudKit `PageExplain`), Datensatz
  `<fileKey>#<von>#doc1_<art>_<n>_<bis>#<variante>`, verschlüsselt mit dem Schritt-Schlüssel als Abdruck. Wer dieselbe
  Datei hat, bekommt den Lauf sofort und mit 0 Credits; „Neu erklären lassen“ fragt live (nächster freier Platz).
- **Was ein Lauf kostet** (StudiNow-KI, empfohlenes Modell `gpt-6-luna`; ein Credit = 1 Cent, je Anfrage aufgerundet):
  Vorlesung mit 40 Seiten (≈ 60 000 Zeichen) = 3 Teile + Überblick = **etwa 4 Credits**; Übungsblatt mit 8 Aufgaben =
  2 Schritte = **etwa 2 Credits**. Die echten Kosten je Anfrage liegen weit unter einem Cent; die Rundung je Anfrage
  bestimmt den Preis, darum sind die Teile groß. Der zweite Studierende mit derselben Datei zahlt **0**.

## Dateien

`app/doc_explain.py` (Regeln, Prompts, Speicher), `app/doc_explain_api.py` (Routen), `tests/test_doc_explain.py`;
`tools/gen-doc-explain-cases.py` → `packages/shared-contracts/fixtures/doc-explain/cases.json`;
Swift `UniFlowCore/AI/DocExplain.swift`, `LocalBackend/Endpoints/DocExplainEndpoints.swift`, `DocExplainTests`;
iPad `Views/TutorDocumentRun.swift` + `TutorPanel.swift`, `UniFlowTests/TutorDocumentAppTests.swift`;
Web `app/static/doc-explain-logic.js` + `editor.js`, `tests/js/doc-explain.test.mjs`.

## Offen

- Bilder ohne Text werden nicht an die KI geschickt (Texterkennung auf dem iPad; im Dienst nur die Textebene).
- Der Dienst teilt seinen Speicher noch nicht mit CloudKit (wie beim Erklärungsspeicher).
