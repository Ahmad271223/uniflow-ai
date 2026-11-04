# CloudKit: Schema für Production (Stand 03.11.2026)

Vor dem nächsten App-Store-Build in der CloudKit Console (iCloud-Container der App, öffentliche Datenbank)
anlegen bzw. ergänzen. In Development legt die App die Typen beim ersten Schreiben selbst an; dort lassen sie
sich mit „Deploy Schema Changes…“ nach Production übernehmen. Bis dahin zeigt die App 0 Likes/Kommentare und
keine Korrekturen, statt abzustürzen.

**Schemadatei (04.11.2026):** alle Typen dieser Seite stehen in `apps/apple/Config/cloudkit-schema.ckdb` (Grammatik von
`cktool`/Console-Import). Importieren mit `xcrun cktool import-schema --team-id <TEAM-ID> --container-id iCloud.de.uniflow.ai
--environment development --file apps/apple/Config/cloudkit-schema.ckdb` (vorher `xcrun cktool save-token`), danach in der
Console „Deploy Schema Changes…“ nach Production. `tests/test_page_explain.py` prüft die Datei offline gegen die Tabelle unten.

## Neue Datensatztypen

| Typ | Feld | Typ | Index |
|---|---|---|---|
| `Comment` | `solutionID` | String | Queryable |
| | `parentID`, `status`, `createdAt`, `editedAt`, `payload`, `ownerRecordName`, `removedID` | String | – |
| | `createdOrder` | Int(64) | – |
| `Like` | `solutionID` | String | Queryable |
| | `ownerRecordName`, `createdAt` | String | – |
| `Correction` | `solutionID` | String | Queryable |
| | `solutionOwner` | String | Queryable |
| | `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `createdOrder` | Int(64) | – |

| `WeeklyTest` (04.11.2026) | `shareKey` | String | Queryable |
| | `status`, `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `variant` | Int(64) | – |

| `DocIndex` (04.11.2026) | `fileKey` | String | Queryable |
| | `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `page`, `version` | Int(64) | – |

| `PageExplain` (04.11.2026) | `fileKey` | String | Queryable |
| | `mode`, `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `page`, `variant`, `version` | Int(64) | – |

| `WeekCardStack` (04.11.2026) | `shareKey` | String | Queryable |
| | `status`, `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `variant` | Int(64) | – |

| `CardStackShare` (04.11.2026) | `communityKey` | String | Queryable |
| | `kind`, `name`, `displayName`, `payload`, `createdAt`, `ownerRecordName` | String | – |
| | `week`, `cardCount`, `withdrawn` | Int(64) | – |

Bei allen neuen Typen zusätzlich: Index `recordName` → Queryable.

Hinweise:
- `WeeklyTest` (docs/GEMEINSAME-WOCHENTESTS.md, WeeklyTestCloudKit.swift): gemeinsame Wochentests, höchstens drei je
  Schlüssel. `recordName` ist `<shareKey>#<variant>` (variant 0..2), dadurch ist das Anlegen atomar und eindeutig;
  `status` ist `pending` (Platz belegt, Inhalt kommt) oder `ready`. `payload` ist der Test, verschlüsselt mit einem
  Schlüssel aus den Inhalts-Hashes der Dateien (HKDF-SHA256, AES-256-GCM); die Hashes liegen nie bei CloudKit. Keine
  Namen, keine Antworten. Rechte wie unten: Lesen für alle, Erstellen für angemeldete Nutzer, Ändern/Löschen nur für
  den Ersteller (dadurch gewinnt bei einem Wettlauf genau einer den Platz).
- `DocIndex` (docs/DOKUMENT-INDEX-2026-11-04.md, DocIndexCloudKit.swift): gemeinsamer Dokument-Index. `recordName` ist
  `<fileKey>#<page>` (Seite 0 = Zusammenfassung der Datei); `fileKey` ist ein HMAC des Datei-SHA, nicht der SHA.
  `payload` ist der Eintrag der Seite, verschlüsselt mit einem Schlüssel aus Datei-SHA und Seiten-Abdruck (HKDF-SHA256,
  AES-256-GCM); lesen kann nur, wer dieselbe Datei hat. Kein Seitentext, kein Bild, keine Namen.
- `PageExplain` (docs/ERKLAERUNGSSPEICHER-2026-11-04.md, PageExplainCloudKit.swift): Erklärungsspeicher der KI-Hilfe,
  Antworten für ganze Seiten (erklären, einfach erklären, zusammenfassen, Fachbegriffe, Aufgabe lösen, Hinweise).
  `recordName` ist `<fileKey>#<page>#<mode>#<variant>` (variant 1…3, nie überschrieben, höchstens drei je Schlüssel wie
  `WeeklyTest`); `payload` ist die Antwort, verschlüsselt mit demselben Schlüsselstoff wie `DocIndex` (Datei-SHA und
  Seiten-Abdruck), Zusatzdaten binden an Datei, Seite, Modus, Variante und Formatfassung. Kein Seitentext, keine Namen.
- `WeekCardStack` und `CardStackShare` (docs/KARTEIKARTEN-STAPEL-2026-11-04.md, CardStackCloudKit.swift): geteilte
  Wochenstapel (Vorlesung/Übung je Modul und Lehrwoche, wie `WeeklyTest`: `<shareKey>#<variant>`, höchstens drei) und
  eigene geteilte Stapel im Modul (`communityKey` wie die Community, `week` 0 = Allgemein, `payload` verschlüsselt mit
  dem Modul-Geheimnis). Likes und Meldungen nutzen `Like`/`Report` mit `solutionID = "cards:<id>"`.
- Fragen und Antworten im Reiter „Diskussion“ einer Community sind `Comment`-Datensätze mit
  `solutionID = "space:<Community-Schlüssel>"`; Likes auf Fragen sind `Like` mit `solutionID = "post:<ID>"`.
  Dafür ist kein weiterer Typ nötig.
- `payload` ist immer mit dem Community-Schlüssel verschlüsselt (Text, Pseudonym, Stellen, Korrektur-Tinte).

## Bestehender Typ `Report`

- Feld `commentID` (String) ergänzen
- `solutionID` → Queryable

## Rechte (Security Roles)

Standard für `Comment`, `Like`, `Correction`, `WeeklyTest`, `DocIndex`, `PageExplain`, `WeekCardStack`, `CardStackShare`: Lesen für alle, Erstellen für angemeldete iCloud-Nutzer,
Ändern/Löschen nur für den Ersteller. Moderation (z. B. `status = hidden`) über das CloudKit Dashboard.
