# Dienst-Update 13.11.2026 (zweites) – vorbereitet, nicht ausgerollt

Stand: `develop` bei `2639e54c` (Server-Code gleich `6f1eff9d` = Build 37). Auf dem Server läuft seit 13.11.2026 11:07
`21ecc168` (siehe `DEPLOY-DIENST-2026-11-13.md`). Ausrollen nur mit Freigabe des Inhabers.

## Warum

Build 37 (TestFlight) braucht den neuen Dienst für zwei Dinge, die sonst nicht wirken:

- **Uni-Mail „Mit KI verbessern“**: der Dienst kennt die Aufgabe `mail` und das Kontingent `ai_mail` (Pro AI, 50 je
  Monat, ohne Credits) erst mit diesem Update. Vorher bekommt das iPad beim Antippen eine Fehlermeldung.
- **KI erklärt einfacher**: die Hauptanweisung der StudiNow-KI (System-Text) wählt der Dienst. Ohne Update antwortet die
  KI auf iPad, Mac, Web und Windows weiter im alten, fachlicheren Stil.

Dazu am PC und im Web: abgewählte Fächer („Was soll in den Lernkalender?“) bekommen nie Lernpakete, Lernblöcke oder
Lernziele (Fehlerbericht des Inhabers 13.11.2026, „Mathe 1“).

## Was sich im Dienst-Code ändert (`21ecc168` → `2639e54c`)

| Datei | Was |
|---|---|
| `app/ai.py` | `TUTOR_SYSTEM` und die Modi einfacher; `MAIL_INSTRUCTION`, `mail_prompt` |
| `app/doc_explain.py` | „Ganze Vorlesung erklären“: einfache Worte, Kernidee je Abschnitt |
| `app/ai_relay.py` | Aufgabe `mail` (Recht `can_use_ai_explanations`, Kontingent `ai_mail`) |
| `app/plans.py` | Kontingent `ai_mail`: Pro AI 50, Plus 0, Free 0 |
| `app/study.py`, `app/smart_goals.py`, `app/server.py` | abgewählte Fächer nie planen; beim Abwählen unberührte automatische Pakete entfernen |

- Datenbanken: keine neuen Tabellen oder Spalten. Das Kontingent `ai_mail` nutzt die vorhandene Tabelle der
  Monatskontingente.
- Gelöscht wird nur, was das Abwählen eines Fachs ausdrücklich verlangt: unberührte, automatisch erzeugte Lernpakete
  dieses Fachs.
- `deploy/.env`: nichts Neues. Die Apple-Schlüssel für den Widerruf beim Löschen fehlen weiter (siehe erstes Update).

## Tests (13.11.2026, gleicher Server-Code)

- Python (`.venv/bin/python -m pytest`, ohne `tests/test_pwa.py`): **3.486 bestanden**, 5 übersprungen, 2 erwartet rot,
  keiner rot
- Browser-Logik (`node --test tests/js/`): **450 / 450**
- Swift-Kern **1.510** und iPad-App **1.598** Tests ohne Fehler (Build 37)
- Nicht geprüft: echte KI-Antworten (die Tests nutzen eine Attrappe), ein Lauf gegen den Server mit echtem Konto.

## Ablauf (auf dem Mac, im Projektordner `~/uniflow-ai`)

1. **Backup auf dem Server**:
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'bash /srv/uniflow/app/deploy/backup.sh'`
2. **Code übertragen und neu bauen** (der Server ist kein Git-Ordner; `deploy/.env` und die Daten bleiben):
   `git archive 2639e54c | ssh -i ~/.ssh/studinow_server root@46.225.32.3 'tar -x -C /srv/uniflow/app && cd /srv/uniflow/app/deploy && docker compose up -d --build'`
3. **Prüfen:**
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'cd /srv/uniflow/app/deploy && docker compose ps && docker compose logs --tail=50 app && ./dienst-check.sh --no-mail --verbose'`
   Danach am iPad mit Build 37:
   - eine Erklärung anfordern; sie soll kurz und einfach sein;
   - in Uni-Mail „Neue E-Mail“ → Text schreiben → „Mit KI verbessern“;
   - ein Fach abwählen und prüfen, dass es keine Lernpakete bekommt.
4. **Zurück, falls etwas nicht geht:** Schritt 2 mit dem alten Stand: `git archive 21ecc168 | ssh …`
