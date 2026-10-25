# UniFlow für Android

**Stand 25.10.2026:** Nur der plattformunabhängige Kern (`core`, Kotlin/JVM) ist angelegt. Er setzt die gemeinsamen
Zusammenführungsregeln um und prüft sie gegen `packages/shared-contracts/fixtures/merge/cases.json`.
**Noch nicht gebaut:** Auf dem Entwicklungs-PC fehlen Gradle und Kotlin, und GitHub Actions war beim Anlegen
gesperrt (Kontingent). Der Workflow `.github/workflows/android.yml` baut und testet den Kern, sobald Actions wieder läuft.

## Aufbau

| Modul | Inhalt | Stand |
| --- | --- | --- |
| `core` | Notiz-Zusammenführung (gleiche Regeln wie Swift und Web) | Code + Tests, ungebaut |
| `app` (geplant) | Jetpack Compose, PDF-Anzeige (`PdfRenderer`), Stifteingabe | nicht begonnen |

## Geplante Stifteingabe

- `MotionEvent` mit `getHistoricalX/Y` (alle Zwischenpunkte), `TOOL_TYPE_STYLUS` vs. Finger für Handballen-Unterdrückung.
- Geringe Latenz: `androidx.input:input-motionprediction` und Front-Buffer-Rendering (`androidx.graphics:graphics-core`),
  alternativ die Jetpack-Ink-Bibliothek (`androidx.ink`), sobald stabil.
- Gleiches Notizformat und gleicher Server wie Web und iPad; Synchronisierung nach den Regeln in
  `packages/shared-contracts/README.md` (Revisionen, ein Upload gleichzeitig, 409 → zusammenführen).

Die Android-Stiftengine darf die Apple-Version nicht verzögern; sie folgt nach dem iPad-Gerätetest.

## Bauen

```bash
gradle -p apps/android :core:test
```
