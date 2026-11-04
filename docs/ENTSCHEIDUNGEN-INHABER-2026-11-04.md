# Entscheidungen des Inhabers (04.11.2026)

- Windows-App heißt auch im Installer, Startmenü und Programmordner **StudiNow** (`productName`, Version 0.5.0).
- Fragen je Kurs in der Community nur für Mitglieder (wer den Kurs hat oder hatte), wie auf dem iPad.
- Tesseract für die Texterkennung kommt in den Windows-Installer.
- **Tarife** (Preisliste: `docs/PREISLISTE.md`):
  - Plus 1,99 €: eigenes ChatGPT nutzen, **4 neue KI-Tests** im Monat, Karteikarten selbst anlegen, teilen und die
    anderer nutzen.
  - Pro AI 3,99 €: StudiNow-KI und eigenes ChatGPT, **20 neue KI-Tests** im Monat, KI erstellt Karteikarten nach Fach,
    Lernwoche und Anzahl, fertige Fragen je Vorlesungswoche (2–3 × 15) mit vorbereiteten Lösungen und Erklärungen aus
    der Bibliothek.
  - Eigenes ChatGPT verbinden bleibt für alle Tarife frei (OpenAI-Regeln); Plus verkauft Tests, Karteikarten und Teilen.
  - Plus gilt je Gerät: kein Notizen-Abgleich zwischen Geräten (Recht `can_sync_annotations` erst ab Pro AI).
  - **Pro Connect entfällt**: nur noch Free, Plus und Pro AI. Seine Rechte gehören zu Pro AI; ein alter Eintrag
    `pro_connect` zählt als Pro AI (`billing.LEGACY`). Stripe kennt nur noch `plus` und `pro_ai`.
