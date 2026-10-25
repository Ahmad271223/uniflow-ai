# GitHub Actions: Abrechnung prüfen und freigeben

Seit 25.10.2026, 00:15 Uhr startet GitHub für `Ahmad271223/uniflow-ai` keine Jobs mehr. Meldung in jedem Lauf:

```
The job was not started because recent account payments have failed or your spending limit needs to be increased.
```

Das ist **kein Fehler im Code**: Die Jobs hatten 0 Schritte und keinen Runner. Ich ändere keine Zahlungsdaten und
erhöhe keine Limits; das kannst nur du.

## 1. Prüfen (ca. 5 Minuten)

1. Auf github.com oben rechts auf das Profilbild → **Settings** → links **Billing and licensing**
   (direkt: <https://github.com/settings/billing>).
2. **Payment information**: Steht dort eine fehlgeschlagene Zahlung oder eine abgelaufene Karte?
   (<https://github.com/settings/billing/payment_information>)
3. **Usage** bzw. **Overview**: Wie viele Actions-Minuten sind in diesem Monat verbraucht? Private Repositories im
   kostenlosen Tarif haben ein Monatskontingent (zuletzt 2.000 Minuten); macOS-Minuten zählen dabei zehnfach,
   Windows doppelt, Linux einfach. Die aktuellen Werte stehen auf der Seite selbst.
4. **Budgets and alerts** (früher „Spending limit“): Steht das Actions-Budget auf 0 € mit „Stop usage when budget
   limit is reached“? Dann stoppt GitHub nach dem Freikontingent.

## 2. Möglichkeiten

| Möglichkeit | Kosten | Folge |
| --- | --- | --- |
| Bis zum Monatswechsel warten | keine | Kontingent erneuert sich am 1. des Monats; bis dahin keine Builds |
| Zahlungsmittel korrigieren | keine sofortigen Kosten | nötig, wenn eine Zahlung fehlgeschlagen ist |
| Actions-Budget erhöhen (z. B. 5 €) | nur tatsächliche Nutzung über dem Freikontingent | Builds laufen sofort weiter; Budget begrenzt die Kosten |
| Repository öffentlich machen | keine | veröffentlicht den gesamten Code; **nicht empfohlen**, nur mit deiner Entscheidung |
| eigener Mac als Runner (später) | keine Minuten für macOS | Mac muss eingeschaltet sein; Einrichtung über Settings → Actions → Runners |

## 3. Verbrauch dieses Projekts (gemessen)

| Workflow | Dauer | zählt als |
| --- | --- | --- |
| Apple: Linux-Kern | ~1 min | 1 min |
| Apple: macOS-Kern + iPad-Simulator | 2–5 min | 20–50 min |
| CI (Python, Sicherheit, Web) | je ~1 min, 3 Jobs | ~3 min |
| Windows (Tauri, nur manuell) | geschätzt 10–20 min | 20–40 min |

Ein vollständiger Apple-Lauf kostet also etwa 25–55 Kontingent-Minuten.

## 4. Nach der Freigabe

Siehe Abschnitt „Checkliste, sobald GitHub Actions wieder läuft“ in `RELEASE-READINESS.md`.
