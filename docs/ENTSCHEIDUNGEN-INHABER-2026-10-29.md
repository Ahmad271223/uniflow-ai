# Entscheidungen des Inhabers vom 29.10.2026 (Mac-Sitzung)

Ergänzt `docs/ENTSCHEIDUNGEN-INHABER-2026-10-28.md` und Abschnitt 3 von
`docs/UEBERGABE-MAC-NEUE-SITZUNG-2026-10-29.md`. Gilt für iPad, Windows und Web gleich.

## 1. Wochentests

| Punkt | Entscheidung |
|---|---|
| Welche Module | **Jedes Modul** bekommt jede Woche automatisch einen Test (nicht nur ausgewählte). |
| Grundlage | **Alle Folien dieser Woche** des Moduls. |
| Umfang | **Genau 15 Aufgaben: 4 leicht, 6 mittel, 5 schwer.** Vom Inhaber ausdrücklich so bestätigt („mach genau so“). |
| Altklausur | Gibt es zum Modul eine Altklausur, ist **eine der 5 schweren Aufgaben im Klausurstil**. Die Summe bleibt 15. (Festlegung der Mac-Sitzung; der Inhaber kann sie ändern.) |
| Übungsblatt | Ist ein Übungsblatt offen, zeigt die App, **wo im Skript** der Stoff dazu steht (Seite). |

### Umsetzung

- **Aufgaben erzeugen braucht immer eine KI.** Auf dem iPad über das ChatGPT-Abo des Nutzers
  (`docs/KI-CHATGPT-PLAN.md`, Übergabe Abschnitt 4 A5), am PC über den bisherigen Weg (`app/ai.py`).
- **Prompt in Python und Swift byte-gleich**, über einen gemeinsamen Vertrag aus einem Generator, der nur `app/ai.py`
  importiert. Heute erzeugt `_test_prompt` in `app/ai.py` „etwa 8“ bzw. „etwa 12“ Aufgaben je nach Dauer, ohne feste
  Verteilung; das ändert sich auf 15 mit 4/6/5 und je Aufgabe ein Feld `difficulty` (`leicht`, `mittel`, `schwer`).
- **Prüfung der Antwort:** Ein erzeugter Wochentest wird nur angenommen, wenn er genau 15 Aufgaben mit genau dieser
  Verteilung hat. Sonst wird die Antwort verworfen und einmal neu angefordert; scheitert auch das, wird ein Fehler
  angezeigt statt eines falschen Tests. Tests dazu in Python und Swift, ohne echtes Netz.
- **Standard:** `tests_per_subject` ist auf dem iPad 0. Für „jedes Modul automatisch“ wird der Standard 1, und der
  Lernplan plant je Modul und Woche einen Test ein. Bestehende Nutzerwerte bleiben.
- **Stelle im Skript zum Übungsblatt**, zweistufig:
  1. Ohne KI, offline und in jedem Tarif: Fachbegriffe aus dem Übungsblatt gegen den gespeicherten Seitentext der
     Skripte des Moduls (`page_texts`, Volltextsuche). Die Seiten mit den meisten Treffern werden vorgeschlagen.
  2. Mit KI (wenn verbunden): dieselben Kandidatenseiten nummeriert an die KI, die die passende Stelle wählt und mit
     `[n]` belegt, wie der KI-Tutor mit Quellen und Seitenangabe (PC 3b12273). Die KI nennt nur Seiten, die ihr
     vorlagen.

## 2. Umsetzung in Python (erledigt von der Mac-Sitzung, 29.10.)

`app/ai.py` und `app/planner.py` setzen die Regel um (15 Aufgaben, 4/6/5, alle Folien der Woche, Klausuraufgabe,
Prüfung der Antwort, ein zweiter Versuch); gemeinsamer Vertrag `packages/shared-contracts/ai/`. Für Windows/Web bleibt
nur die Anzeige der Schwierigkeit je Aufgabe (Ende von `docs/STAND-MAC-SITZUNG.md`).

## 3. Start in zwei Stufen, Studora-Konto aber schon in V1 auf dem iPad

Antwort des Inhabers auf die Fragen in `docs/ABGLEICH-ORIGINALTEXTE-INHABER-2026-10-29.md` §3 („Konto schon in V1“):

- **Zwei Stufen bestätigt.** Stufe 1: Windows-Einzelplatz und iPad V1. Stufe 2: Geräteabgleich der Notizen (G2),
  Community über den Dienst (G4), Pro-Tarife mit Kaufprüfung.
- **Die Anmeldung am Studora-Konto (G1) kommt schon in V1 auf das iPad**, sobald Server, Domain und Mail-Anbieter
  stehen. Dasselbe Konto wie auf Windows, aber noch ohne Notiz-Abgleich.

### Plan für das iPad (Punkt B4, vorgezogen; nach A5)

Vertrag: `packages/shared-contracts/fixtures/account/contract.json` (aus `app/accounts.py`, `app/account_api.py`).

1. **Mit Apple:** Die vorhandene Anmeldung „Mit Apple anmelden“ löst ihr `identity_token` bei
   `POST /api/account/login/apple` ein (Konto über die Apple-Kennung `subject`, nie über die E-Mail). Braucht ein
   echtes Apple-Token, also das Apple-Team; bis dahin nur der zweite Weg testbar.
2. **Mit E-Mail und Passwort** (wer sich auf Windows registriert hat): `POST /api/account/login`, danach
   `POST /api/account/link/apple`, damit künftig Apple reicht. Registrieren, E-Mail bestätigen und Passwort
   zurücksetzen laufen über die Webseite des Dienstes (Link aus der App). Das Passwort merkt nur iOS (AutoFill),
   nie die App.
3. **Token** (`Authorization: Bearer`) nur im Schlüsselbund des Geräts, je Apple-Nutzer. Abmelden, „Gerät abmelden“
   (`DELETE /api/account/sessions/{id}`), Konto löschen (`POST /api/account/delete`) und Datenexport
   (`GET /api/account/export`) in den Einstellungen.
4. **Unsichtbar**, solange keine Dienst-Adresse in der Konfiguration steht (wie `BillingServiceLink`). Die App
   bleibt ohne Konto voll nutzbar; die Daten bleiben je (Apple-Nutzer, Hochschule) getrennt.
5. **Nicht in V1:** Notizen geräteübergreifend (G2), Community über den Dienst (G4). Die Einstellungen sagen das offen
   („Abgleich mit Windows folgt“).
6. **Tests:** gegen die Fälle des Vertrags mit einem Mock-Transport, ohne echtes Netz; Fehlercodes (`rate_limited`
   mit Retry-After, `email_unverified`, gesperrt) mit den Texten des Dienstes.
