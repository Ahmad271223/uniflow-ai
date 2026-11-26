# Absturzmeldung: Vertrag zwischen App und Dienst

Erfundene Daten, kein echtes Gerät. Unterlage: `docs/ABSTURZMELDUNG-2026-11-25.md`.

- `metrickit-diagnostic.json`: ein Diagnose-Paket in Apples Format (`MXDiagnosticPayload.jsonRepresentation()`):
  zwei Abstürze, ein Hänger. Enthält mit Absicht Dinge, die das Gerät **nicht** verlassen dürfen (Text einer
  Ausnahme mit einem Dateinamen, Speicherangaben, Region, Prozessnummer, Kennung der App).
- `metrickit-metric.json`: ein Messwerte-Paket (`MXMetricPayload.jsonRepresentation()`), nur die Teile, die die App
  liest: Tageszählung „von iOS beendet“.
- `upload.json`: genau der Rumpf, den die App daraus für `POST /api/diagnose/crashes` baut (feste Kennungen:
  Installation `0123…cdef`, Meldungen `…01` bis `…05`; die App selbst ist 1.0.7 (49), iPad, Quelle Store).

Wer prüft was:
- `apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/CrashReportTests.swift`: aus den beiden Paketen entsteht
  genau `upload.json`.
- `tests/test_crash_reports.py`: der Dienst nimmt `upload.json` an, und die Auswertung zählt daraus die erwarteten
  Abstürze je Tag, Version und Geräteart.
