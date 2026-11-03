# CloudKit: Schema für Production (Stand 03.11.2026)

Vor dem nächsten App-Store-Build in der CloudKit Console (iCloud-Container der App, öffentliche Datenbank)
anlegen bzw. ergänzen. In Development legt die App die Typen beim ersten Schreiben selbst an; dort lassen sie
sich mit „Deploy Schema Changes…“ nach Production übernehmen. Bis dahin zeigt die App 0 Likes/Kommentare und
keine Korrekturen, statt abzustürzen.

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

Bei allen drei zusätzlich: Index `recordName` → Queryable.

Hinweise:
- Fragen und Antworten im Reiter „Diskussion“ einer Community sind `Comment`-Datensätze mit
  `solutionID = "space:<Community-Schlüssel>"`; Likes auf Fragen sind `Like` mit `solutionID = "post:<ID>"`.
  Dafür ist kein weiterer Typ nötig.
- `payload` ist immer mit dem Community-Schlüssel verschlüsselt (Text, Pseudonym, Stellen, Korrektur-Tinte).

## Bestehender Typ `Report`

- Feld `commentID` (String) ergänzen
- `solutionID` → Queryable

## Rechte (Security Roles)

Standard für `Comment`, `Like`, `Correction`: Lesen für alle, Erstellen für angemeldete iCloud-Nutzer,
Ändern/Löschen nur für den Ersteller. Moderation (z. B. `status = hidden`) über das CloudKit Dashboard.
