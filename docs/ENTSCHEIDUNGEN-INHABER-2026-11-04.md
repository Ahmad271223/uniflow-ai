# Entscheidungen des Inhabers (04.11.2026)

- Windows-App heißt auch im Installer, Startmenü und Programmordner **StudiNow** (`productName`, Version 0.5.0).
- Fragen je Kurs in der Community nur für Mitglieder (wer den Kurs hat oder hatte), wie auf dem iPad.
- Tesseract für die Texterkennung kommt in den Windows-Installer.
- **Tarife** (Preisliste: `docs/PREISLISTE.md`):
  - Plus 1,99 €: eigenes ChatGPT nutzen, **4 neue KI-Tests** im Monat, Karteikarten selbst anlegen, teilen und die
    anderer nutzen (ein Recht `can_use_flashcards`, `docs/KARTEIKARTEN-STAPEL-2026-11-04.md`).
  - Pro AI 3,99 €: StudiNow-KI und eigenes ChatGPT, **20 neue KI-Tests** im Monat, KI erstellt Karteikarten nach Fach,
    Lernwoche und Anzahl (`can_use_ai_generated_questions`), fertige Fragen je Vorlesungswoche (2–3 × 15) mit vorbereiteten Lösungen und Erklärungen aus
    der Bibliothek (`can_use_prepared_week_sets`).
  - Eigenes ChatGPT verbinden bleibt für alle Tarife frei (OpenAI-Regeln); Plus verkauft Tests, Karteikarten und Teilen.
  - Plus gilt je Gerät: kein Notizen-Abgleich zwischen Geräten (Recht `can_sync_annotations` erst ab Pro AI).
  - **Pro Connect entfällt**: nur noch Free, Plus und Pro AI. Seine Rechte gehören zu Pro AI; ein alter Eintrag
    `pro_connect` zählt als Pro AI (`plans.LEGACY_PLANS`, `billing.normalize_plan`). Stripe kennt nur noch `plus` und `pro_ai`.
- 05.11.2026: Pro AI bleibt bei 100 Credits = 1 € als harte Obergrenze je Monat (vor jeder Anfrage wird ihre
  Obergrenze reserviert, nie mehr berechnet; `app/credits.py`, `app/ai_prices.worst_case_microeur`).
- 05.11.2026: StudiNow-KI mischt drei Modelle nach Aufgabe, etwa 50 % DeepSeek (nur über einen EU-Anbieter, Scaleway
  Paris), 25 % ChatGPT, 25 % Claude Sonnet 5.5 (Amazon Bedrock Frankfurt) für schwere Fälle
  (`docs/KI-MODELLMISCHUNG-2026-11-05.md`).
