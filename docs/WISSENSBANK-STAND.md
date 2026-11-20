# StudiNow-Wissensbank – Stand 20.11.2026 (Zweig `server/wissensbank`, Basis `origin/release/1.0.7` c9dcc5b9)

## Fertig

- **Dienst** (`app/wissensbank.py`): Bibliothek aus `LERNAPP_WISSENSBANK_DIR` (Standard `/data/wissensbank`), Schalter
  `LERNAPP_WISSENSBANK` (Standard aus). Nur Pro AI und nur Konten der LUH (Hochschule am Konto, nicht Angabe der App).
- **Zuordnung über den Wortlaut**: Kandidaten über Dateititel (`quellen`, NFC, ohne Endung/Leerraum) bzw. Kurs; Entscheidung
  per 3-Wort-Shingles. Schwellen: Überlappung ≥ 0,6 mit Folien-/Aufgabentext, 0,75 ohne, +0,1 bei Kurs-Suche, mind. 8
  gemeinsame Shingles, Folien zusätzlich Jaccard ≥ 0,5. Zahlen samt Nachbarwörtern (Multimenge) müssen bei Aufgaben genau
  stimmen. Seitennummer nur Gleichstand-Entscheider. „identisch mit G00xx Seite N“ wird aufgelöst.
- **Ablauf in `/api/ai/relay`**: erstes Mal Antwort aus der Wissensbank (1 Credit, `tutor:wissensbank`, Kontingent und
  Rate-Limit wie KI); Wiederholung derselben Stelle → normale KI + `feedback_token`. `POST /api/ai/feedback`: Ja =
  Kandidat (ohne Konto, ohne Frage, ungeprüft), Nein = Stimme für die vorher gelieferte Antwort. Auswahl je Stelle:
  Wahl des Inhabers, sonst freigegebener Kandidat mit mehr Stimmen als die Bibliothek, sonst Bibliothek.
- **Prüf-Werkzeug**: `python -m app.wissensbank_pruefen --liste/--zeigen/--freigeben/--ablehnen/--waehlen/--bibliothek`.
- **Konto**: Löschen und Export umfassen die neuen Tabellen; offene Ja/Nein-Fragen verfallen nach 7 Tagen.
- **Hochladen**: `tools/wissensbank-hochladen.sh SERVER_IP` (nur `katalog.json` + `.md`, nicht ausgeführt).
- **App**: sendet `wissensbank`-Angaben nur, wenn `GET /api/entitlements` `wissensbank: true` meldet; Abzeichen „Aus der
  StudiNow-Wissensbank“ (+ geprüft / KI-Lösung, ungeprüft), Ja/Nein-Frage, lokales `/api/ai/feedback`; Wissensbank-
  Antworten nie in den geteilten Erklärungsspeicher.
- **Entwurf** Datenschutz/AGB + Urheberrechts-Hinweis: `docs/release/ENTWURF-1-0-7.md` (Abschnitt „StudiNow-Wissensbank“).

## Tests

- Python: `tests/test_wissensbank.py` 38 grün (erfundenes Fixture, 22 Zuordnungsfälle alle richtig, 0 falsche Treffer).
  Volle Suite: 3969 grün, 1 rot (`test_p80_05_06…`: Logging im Relay) – behoben und danach grün nachgeprüft
  (`test_audit_p58_87_server.py`, `test_ai_relay.py`, `test_wissensbank.py`: 78 grün). Volle Suite danach nicht neu gelaufen.
- Swift-Kern: 1770 Tests, 0 Fehler (inkl. `WissensbankTests`, 6).
- App im Simulator (Klon `fix-wissensbank`): `WissensbankAppTests` + `CreditsDisplayAppTests` grün. Größerer Lauf aller
  KI-Hilfe-App-Tests (20 Klassen) lief noch, Ergebnis offen. Kein echtes Gerät.
- Lokal (nicht committet) an der echten Bibliothek: 594/600 richtig + 3 gleichwertig, 3 kein Treffer, 0 falsch;
  Aufgabe mit geänderter Zahl 0/187 Treffer.

## Fehlt / nächste Schritte

1. KI-Hilfe-App-Tests (20 Klassen) im Simulator erneut laufen lassen; volle Python-Suite einmal neu.
2. Verlauf der KI-Hilfe speichert Abzeichen/Frage nicht (nach Neustart weg) – bewusst einfach gehalten.
3. Rechtliche Prüfung (Urheberrecht, Musterlösungen der Lehrenden), dann Upload und `LERNAPP_WISSENSBANK=1`.

## Offene Fragen

- Musterlösungen der Lehrenden ausliefern oder nur eigene Erklärungen/Lösungen?
- MAC-ANLEITUNG.md der Bibliothek sagt „nicht auf Server“ – Entscheidung dort vermerken.
- Probe-Konten (zählen als Pro AI) einbeziehen? Derzeit ja.
