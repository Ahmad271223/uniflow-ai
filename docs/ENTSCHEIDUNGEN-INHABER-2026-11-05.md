# Entscheidungen des Inhabers (05.11.2026)

## Tarife angeglichen: Free ohne Community und ohne KI-Hilfe

Wortlaut des Inhabers (05.11.2026):

> „nein free ohne community und ohne ki hilfe aber man kann sein eigenes chatgpt einbinden und ihn fragen stellen bei
> folien aber nicht schreiben, bei plus kann man schreiben und chat fragen und community beitreten usw und kriegt von
> uns karteikarten begrenzt und wochentest und bei pro ai chat + editor + ki + 20 monatstest und unendlich viele
> karteikarten und test oder irgendwie so passe da endlich mal an oder schau wie wir das haben wollten davor“

**Auslegung des Koordinators** (Quelle aller Werte bleibt `app/plans.py`, Fixture
`packages/shared-contracts/fixtures/plans/plans.json`; Preise unverändert):

| | Free 0 € | Plus 1,99 € | Pro AI 3,99 € |
|---|:---:|:---:|:---:|
| PDFs lesen, Kurse, Abgleich, Stundenplan, Lernkalender, Lernplanung | ✓ | ✓ | ✓ |
| Eigenes ChatGPT verbinden und zu Folien fragen (`chatgpt_connection_premium`, Integration noch aus: „in Vorbereitung“) | ✓ | ✓ | ✓ |
| Schreiben: Stift, Textmarker, Editor-Werkzeuge (`can_annotate_pdf`, `can_use_pencilkit`) | – | ✓ | ✓ |
| **Community** lesen, beitreten, schreiben, Lösungen und Stapel teilen (`can_read_community` jetzt **ab Plus**) | – | ✓ | ✓ |
| Eigene Karteikarten (`can_use_flashcards`) | – (vorhandene lesen) | ✓ | ✓ |
| **Karteikarten-Stapel von StudiNow übernehmen** (Wochenstapel aus dem Pool, geteilte Stapel; neu `card_stacks_adopted`) | 0 | 4 / Monat | unbegrenzt (Fair Use 300) |
| Neue KI-Tests (`ai_tests_new`) | 0 | 4 / Monat | 20 / Monat |
| Tests aus der Bibliothek (`library_tests`) | 0 | 4 / Monat | unbegrenzt (Fair Use 300) |
| StudiNow-KI (Chat, Erklärungen, Zusammenfassungen, KI-Karteikarten auf Auftrag, fertige Wochenfragen) | – | – | ✓ (100 Credits, harte Grenze 1 €) |
| Notizen auf allen Geräten (`can_sync_annotations`) | – | – | ✓ |

- **Community ab Plus** (bisher Lesen in Free): Free sieht in der Community nur den Hinweis „Community ab Plus“ mit
  Weg zur Tarifseite; der Dienst antwortet auf Lese- und Mitmach-Routen mit `403 plan_required`. **Nichts wird
  gelöscht:** wer Plus verliert, kann eigene Beiträge, Lösungen und geteilte Stapel weiter zurückziehen (bestehende
  Regel), auch wenn das Lesen gesperrt ist.
- **Eigenes ChatGPT in jedem Tarif:** Die „Sign in with ChatGPT“-Bedingungen von OpenAI verbieten, die Nutzung des
  eigenen ChatGPT-Abos an einen bezahlten Tarif zu koppeln (`INTEGRATIONS["chatgpt"]["plan_gating_allowed"] = False`,
  `docs/ABO-SYSTEM.md` 4). Free darf zu Folien fragen, aber nicht schreiben (Schreiben ist Plus). Die offizielle
  Verbindung bleibt aus, bis OpenAI sie freigibt; die Oberfläche zeigt „in Vorbereitung“ bzw. „bald verfügbar“.
- **„Karteikarten von uns begrenzt“:** neues Kontingent `card_stacks_adopted`, Plus **4 je Monat** (Annahme des
  Koordinators, im Wortlaut ohne Zahl; änderbar nur in `app/plans.py`), Pro AI unbegrenzt mit Fair Use 300. Es zählt das
  Übernehmen fertiger Wochenstapel aus dem Pool und geteilter Stapel der Community; derselbe Stapel zählt im Monat nur
  einmal. Eigene Karten anlegen und üben zählt nicht.
- **„Wochentest“ bei Plus:** wie bisher 4 neue KI-Tests und 4 Bibliothekstests je Monat. **Pro AI:** „20 Monatstest“ =
  20 neue KI-Tests, „unendlich viele Karteikarten und Test“ = Bibliothek und Stapel unbegrenzt (Fair Use).
- Unverändert: Probe 7 Tage wie Pro AI mit 25 Credits; Plus gilt je Gerät; Konto- und Abo-Pflicht in Web und Windows
  (Free nur auf dem iPad, `docs/ENTSCHEIDUNGEN-INHABER-2026-11-04.md`, letzter Punkt).
- Stand des Codes je Funktion: `docs/TARIF-MATRIX-2026-11-04.md` (Nachtrag 05.11.2026); Preisliste `docs/PREISLISTE.md`.
