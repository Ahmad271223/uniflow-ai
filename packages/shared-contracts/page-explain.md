# Erklärungsspeicher: Datensatz `PageExplain` (Format 1, Stand 04.11.2026)

Gemeinsame Antworten der KI-Hilfe für ganze Seiten („Einmal erklären, alle profitieren“,
docs/ERKLAERUNGSSPEICHER-2026-11-04.md). **V1 (iPad): nur CloudKit, der Python-Dienst ändert sich nicht.** Diese
Datei beschreibt das Format, damit der Dienst es später spiegeln kann (`app/`), ohne dass das iPad etwas ändern muss.
Die Swift-Seite (`UniFlowCore/Solutions/PageExplain.swift`, `PageExplainTests`) ist die Referenz.

## Datensatz

| Feld | Typ | Inhalt |
| --- | --- | --- |
| `recordName` | String | `<fileKey>#<page>#<mode>#<variant>` |
| `fileKey` | String, abfragbar | HMAC-SHA256 des Datei-SHA mit Kontext `uniflow.docindex.filekey.v1` (wie `DocIndex`, `file_key` in `app/doc_index.py`), 64 Hexziffern |
| `page` | Int | Seite der PDF, ab 1 (Seite 0 gibt es hier nicht) |
| `mode` | String | `explain`, `explain_simple`, `summary`, `terms`, `steps`, `hints` (die Modi der KI-Hilfe, `ai.TUTOR_MODES`) |
| `variant` | Int | 1…3 |
| `payload` | String | Chiffrat, Base64 (unten), höchstens 256 KiB |
| `version` | Int | Formatfassung, heute `1` |
| `createdAt` | String | ISO 8601, UTC |
| `ownerRecordName` | String | Nutzerkennung des Erstellers beim Dienst (nur Moderation) |

Nicht enthalten: Seitentext, Seitenbild, Namen, der Datei-SHA. Ungeteilt bleiben alle Antworten auf eine Frage,
mit markiertem Text, „Lösung prüfen“, „Ähnliche Aufgabe“ und Karteikarten.

## Regeln

- **Höchstens drei Varianten je `<fileKey>#<page>#<mode>`.** Ein Datensatz wird **nie überschrieben**, auch nicht vom
  Ersteller; der Dienst lehnt ein zweites Anlegen desselben Namens ab (CloudKit: `serverRecordChanged`).
- Wer live fragt, belegt den niedrigsten freien Platz; bei einem Wettlauf den nächsten. Sind alle drei belegt, bleibt
  die Antwort auf dem Gerät (lokale Variante 0, nie beim Dienst).
- Leser nehmen die niedrigste vorhandene Variante. Quellenmarken `[n]` sind im geteilten Text entfernt.
- Eine neue Formatfassung (`version`) mischt sich nicht mit alten Datensätzen (Zusatzdaten tragen `format:<version>`).

## Verschlüsselung (`PageExplainCrypto`)

Wie `DocIndex` (`DocIndexCrypto`): Base64 aus Version (1 Byte, `0x01`), Salz (32 Byte), Nonce (12 Byte) und
AES-256-GCM-Chiffrat mit 16-Byte-Tag.

- Schlüsselstoff: `"<fileSHA>|<pageHash>"` (beides Hex, klein) – nur wer die Datei hat, rechnet ihn. `pageHash` ist der
  Seiten-Abdruck des Dokument-Index (`page_hash` in `app/doc_index.py`).
- HKDF-SHA256 mit `salt` und `info = "uniflow-pageexplain/v1|page:<page>|mode:<mode>"`.
- Zusatzdaten (AAD): `"uniflow-pageexplain/v1|<fileKey>|<page>|<mode>|<variant>|format:<version>"`.
- Klartext: JSON mit sortierten Schlüsseln
  `{"v": 1, "page": n, "pageHash": "…", "mode": "…", "variant": k, "text": "Antwort (Markdown)", "model": "…" | null, "createdAt": "…"}`.
  Beim Lesen müssen `page`, `pageHash`, `mode` und `variant` zum Datensatz passen, sonst gilt der Datensatz als unlesbar.

## Später im Dienst

Spiegelt der Dienst den Speicher, nimmt er dieselben Datensätze entgegen (Anlegen nur, wenn der Name frei ist;
Abfrage nach `fileKey`) und reicht Chiffrate weiter. Er kann sie nicht lesen. Für Web und Windows gilt dann dieselbe
Varianten-Regel wie bei den Wochentests (`packages/shared-contracts/fixtures/testshare/cases.json`).
