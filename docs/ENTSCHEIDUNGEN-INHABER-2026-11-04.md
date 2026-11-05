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
- **Keine Einführungsangebote** (Mac-Sitzung, 04.11.2026, `docs/ABO-SYSTEM.md` 3b): Plus 1,99 € und Pro AI 3,99 € ohne
  „1 Woche gratis“ bei Apple, Stripe oder Google. Stattdessen **7 Tage Probe für jede Person, alles wie Pro AI**, ohne
  Zahlungsdaten, einmal je Konto bzw. Apple-ID, danach automatisch Free, Daten bleiben. Preisliste, Web- und
  Windows-Texte angeglichen (05.11.2026, `tests/test_tarife_texte.py`).
- **Windows-App (Einzelplatz):** Tarifseite mit den drei Karten, aber **kein Kaufweg** (Microsoft-Store-Regeln, `docs/release/MICROSOFT-STORE.md`).
  Pro AI steht dort ohne Preis und ohne Knopf als „kommt mit dem StudiNow-Dienst“. Im Dienst (Web) kaufen über Stripe, nur Plus und Pro AI.
- **Einladungen** (Mac-Sitzung, 04.11.2026, `docs/EINLADUNGEN.md`): Stufen 5/10/20 angekommene Personen = Plus 1/3/12 Monate
  gratis (bei 20 auch: Pro AI 12 Monate zum Plus-Preis), bis zu 20 Links in der Probewoche, je 30 Tage gültig, je Person einmal;
  Belohnung nur als Apple-Angebotscode. Web und Windows bekommen **keine** Einladungsseite, solange es für sie keine
  Belohnung gibt (Vorschlag für eine Dienstfassung mit Stripe-Gutscheinen: `docs/EINLADUNGEN.md` Abschnitt 9, nicht entschieden).
- 05.11.2026: Pro AI bleibt bei 100 Credits = 1 € als harte Obergrenze je Monat (vor jeder Anfrage wird ihre
  Obergrenze reserviert, nie mehr berechnet; `app/credits.py`, `app/ai_prices.worst_case_microeur`).
- 05.11.2026: StudiNow-KI mischt drei Modelle nach Aufgabe, etwa 50 % DeepSeek (nur über einen EU-Anbieter, Scaleway
  Paris), 25 % ChatGPT, 25 % Claude Sonnet 5.5 (Amazon Bedrock Frankfurt) für schwere Fälle
  (`docs/KI-MODELLMISCHUNG-2026-11-05.md`). **Ersetzt durch den nächsten Punkt.**
- 05.11.2026 (später am Tag): **ChatGPT statt DeepSeek** („also nein dann benutz gpt eher als deepseek“). Standard ohne
  DeepSeek: etwa **75 % ChatGPT** (OpenAI `gpt-6-luna`), **25 % Claude Sonnet 5.5** (Bedrock Frankfurt) für die schweren
  Fälle. Typische Anfrage (3.000 Tokens ein, 600 aus) im Mittel ≈ 0,38 Cent statt 0,49 Cent; Pro AI (100 Credits = 1 €,
  harte Grenze unverändert) reicht für rund 80 typische Anfragen, echte Kosten eines voll genutzten Kontos ≈ 0,30 €.
  DeepSeek-Code und Scaleway-Preis bleiben, sind aber aus (`ai_router.OPT_IN`: nur mit Schlüssel **und** Nennung in
  `LERNAPP_AI_ROUTES`). Scaleway ist kein Auftragsverarbeiter mehr (Datenschutz 8c, 11, 12); nötig sind nur OpenAI
  (EU-Projekt, DPA) und AWS Bedrock (`docs/KI-MODELLMISCHUNG-2026-11-05.md`, Abschnitt 0).
- 05.11.2026: Mail des Dienstes (Bestätigung, Passwort zurücksetzen) über das STRATO-Postfach des Inhabers
  (`smtp.strato.de`, Port 465 SSL/TLS, Nutzer = volle Postfachadresse, Absender Alias `no-reply@studinow.app`); STRATO
  steht als Mail-Anbieter in der Datenschutzerklärung (Abschnitt 11). Resend bleibt Alternative
  (`docs/START-DIENST-CHECKLISTE.md`, Abschnitt 5.2).
