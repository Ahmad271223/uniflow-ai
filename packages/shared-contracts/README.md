# Gemeinsame Verträge aller UniFlow-Plattformen

Web (`app/static`), iPad (`apps/apple`), später Windows und Android nutzen denselben Server, dieselben Notizen und
dieselben Regeln. Diese Dateien sind die einzige Quelle für Format und Verhalten; Tests auf allen Plattformen lesen
dieselben Beispieldaten.

| Datei | Inhalt | Geprüft von |
| --- | --- | --- |
| `annotations.schema.json` | Notizmodell Version 2 (JSON Schema) | `tests/test_contracts.py` |
| `API.md` | Endpunkte, Zugang, Fehlercodes | – |
| `fixtures/documents/*.json` | Beispieldokumente (Web-Editor, iPad) | Python, Swift |
| `fixtures/merge/cases.json` | Zusammenführungs-Fälle mit erwartetem Ergebnis | Swift (`SharedFixtureTests`), Node (`tests/js`) |

## Versionierung

- **Notizmodell**: Feld `version` (heute `2`). Neue optionale Felder sind keine neue Version. Eine neue Version gibt
  es nur, wenn sich die Bedeutung bestehender Felder ändert.
- **API**: Pfade bleiben unter `/api`. Inkompatible Änderungen bekommen einen neuen Pfad (`/api/v2/...`); der alte
  bleibt mindestens eine App-Store-Version lang erhalten.
- **Clients** schicken künftig `X-UniFlow-Client: ios/0.2.0` mit, damit der Server alte Versionen erkennen kann.

## Migrationsregeln

1. **Unbekannte Felder bleiben erhalten.** Jeder Client liest das ganze Dokument, ändert nur, was er kennt, und
   schreibt alles andere unverändert zurück (Swift: `JSONValue`, Web: `migrate()` übernimmt fremde Felder).
2. Ein Client, der eine neuere `version` sieht als er kennt, öffnet das Dokument **nur lesend** und speichert nicht.
   (Regel festgelegt, in Web und iPad noch nicht umgesetzt; nötig erst mit Version 3.)
3. Migrationen laufen beim Laden im Speicher; gespeichert wird erst bei einer echten Änderung durch den Nutzer.
4. Native Zusatzdaten (`pkdrawing`) sind nur gültig, solange `objectsSig` zu den Objekten passt. Andere Plattformen
   ignorieren sie, lassen sie aber stehen.

## Konfliktregeln

- Speichern immer mit `base_version`. Der Server prüft die Version und schreibt in **einer** Transaktion; bei
  abweichender Version antwortet er `409` mit `{version, data}`.
- Der Client führt objektweise zusammen (Basis = letzter bestätigter Stand). Regeln siehe `fixtures/merge/cases.json`:
  neu auf einer Seite → bleibt; auf einer Seite gelöscht und auf der anderen unverändert → gelöscht; gelöscht gegen
  geändert → bleibt; beide verschieden geändert → Stand des speichernden Geräts.
- Danach erneut mit der neuen `base_version` senden. Ein Upload gleichzeitig je Dokument und Gerät; was während
  eines Uploads entsteht, bleibt ungesendet und geht mit der nächsten Runde.

## Plattformübergreifend bearbeitbar

| Inhalt | Web | iPad |
| --- | --- | --- |
| Striche (Punkte, Breiten, Farbe, Deckkraft, Werkzeug) | bearbeiten | bearbeiten |
| PencilKit-Pinselstruktur | erhalten, nicht sichtbar | sichtbar |
| Text, Formen, Bilder | bearbeiten | erhalten, noch nicht sichtbar |
| eingefügte Seiten (leer/Bild/PDF) | bearbeiten | erhalten, noch nicht sichtbar |
| Lesezeichen, Gliederung, Notiz | bearbeiten | erhalten |

„Erhalten“ heißt: geht beim Speichern auf dieser Plattform nicht verloren, ist dort aber nicht bearbeitbar. Nichts
davon wird als kompatibel bezeichnet, solange es auf einer Plattform nur sichtbar ist.
