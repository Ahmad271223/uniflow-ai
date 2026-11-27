# Abruf zweimal am Tag (27.11.2026, für Build 51)

Auftrag des Inhabers (27.11.2026, wörtlich):

> „die app soll 2 mal am tag pro nuter bei anmelden sichs selber einlogen außer ein nutzer drückt seber auf sync bsp
> dannn wird es öfters abgerufen aber mail immer mail nicht nur 2 ,al das gerne öfters baue das auch in dene nächste
> build hinzu“

Zweig `app/abruf-zweimal-taeglich` (Arbeitsordner `~/Studora-Builds/wt-abruf-zweimal`), abgezweigt von
`release/1.0.8-alles` @ 8f3cb718 (enthält schon `app/abruf-schonen`). Lokal, nichts gepusht, nicht im Release-Zweig.

## Was sich ändert

| Punkt | Bis jetzt (Abruf schonen, 26.11.) | Jetzt |
|---|---|---|
| Stud.IP, Learnweb, Moodle, Campusmanagement von selbst | 8–18 Uhr alle 30 Minuten (20× am Tag) | **zweimal am Tag**: ab 8 Uhr und ab 14 Uhr |
| QIS (LUH), LSF (Hildesheim), Noten | höchstens alle 4 Stunden (3× am Tag) | **zweimal am Tag** wie oben |
| Uni-Mail (SOGo) | 8–18 Uhr alle 30 Minuten + beim Öffnen (≤ alle 5 min) | **unverändert** – alle 30 Minuten + beim Öffnen |
| Versatz je Gerät | 0–29 Minuten | Portale: eigener Versatz 0–59 Minuten (8:00–8:59, 14:00–14:59); Uni-Mail behält ihren |
| Termin verpasst (App zu, iOS weckt nicht) | – | beim nächsten Öffnen bis 18 Uhr nachgeholt, nie zwei Abgleiche von selbst näher als 2 Stunden |
| Abgebrochener Lauf (Dateien noch nicht geladen) | alle 5 Minuten weiter, ohne Grenze | höchstens 3 Fortsetzungen je Zeitfenster |
| Reiner Mail-Abruf | meldete nebenbei abgelaufene Stud.IP-, QIS-, Learnweb-/LSF-Zugänge neu an | meldet **nur die Uni-Mail** an |
| „Sync“ von Hand | sofort, alle Portale | **unverändert**: sofort, so oft man will |

Ein „Sync“ von Hand zählt für sein Zeitfenster: Tippt jemand um 9 Uhr auf „Sync“, kommt von selbst trotzdem nur noch
der Nachmittag (ab 14 Uhr). Ein „Sync“ um 13 Uhr schiebt den Nachmittag auf 15 Uhr (2 Stunden Abstand).

Außerhalb von 8 bis 18 Uhr gleicht die App weiter nichts von selbst ab (Regel vom 17.11.2026).

### Verhältnis zu „Noten alle 4 h“ (Abruf schonen)

Kein Widerspruch: „zweimal am Tag“ ist strenger als „alle 4 Stunden“. QIS folgt jetzt einfach den zwei Fenstern
(`AutoSync.portalIntervals` ist weg). Die 4 Stunden (`AutoSync.gradesInterval`) gelten nur noch innerhalb des
Datei-Abgleichs der Uni Hildesheim und der HsH, der selbst nur zweimal am Tag läuft – Noten kommen dort also auch
morgens und nachmittags. Versatz, Retry-After und das Weck-Signal an ein Gerät bleiben, wie sie sind.

## Wo (alle Wege fragen dieselbe Regel)

- Kern `AutoSyncSchedule.swift`: neuer Plan `AutoSyncSchedule.twiceDaily` (Felder `slotHours = [8, 14]`,
  `interval` = 2 h Mindestabstand), `currentSlotStart`, `nextRun` mit festen Fenstern; `AutoSyncLedger.overrides`
  (eigener Plan je Portal, Uni-Mail → `standard`), `maxContinuations = 3`; `AutoSyncStagger.slotOffset`
  (Schlüssel `uniflow.autosync.slotStaggerSeconds`, nur auf dem Gerät).
- App `AutoSync.swift`: `AutoSync.schedule` = zweimal am Tag (mit Versatz), `AutoSync.mailSchedule` = 30 Minuten;
  Noten-Termin wird bei einem reinen Mail-Abruf nicht mehr verbraucht.
- `OpenSync.swift` / `StoredLoginConnect.swift`: `connectWithStoredLogin(only:)` – der Abgleich von selbst verbindet nur
  die fälligen Portale; Liste der Bescheinigungen nur, wenn QIS bzw. Learnweb/LSF mitlaufen.
- Gilt für iPad, iPhone und Mac gleich: offene App (Zeitgeber, Öffnen, Rückkehr), Hintergrundlauf von iOS, Weck-Signal
  und Mac-Takt rufen alle `ContainerManager.autoSyncDue` → `AutoSyncLedger`.
- Texte: Einstellungen „Im Hintergrund abgleichen“ (`BackgroundSyncCard.timingShort` u. a.) und der Hinweis bei
  Stud.IP sagen jetzt „zweimal am Tag“, die Uni-Mail „alle 30 Minuten“.

## Tests

- Kern (`swift test`, voll): **1966 Tests, 0 Fehler** (20 übersprungen wie bisher), darin neu
  `AbrufZweimalTaeglichTests` (16 Tests: ein Tag = 8:00 und 14:00, Versatz, Nachholen mit 2 h Abstand, „Sync“ von Hand,
  nächster Termin, Zeitumstellung, Uni-Mail 20× gegen Portale 2×, Pause, höchstens 3 Fortsetzungen, Versatz).
- App (eigener Simulator „Abruf-Zweimal iPad“ D1D5E9D3…, iOS 27.2, eigener Bauordner `~/Studora-Builds/dd-abruf-zweimal`,
  mit Signatur): **17 Klassen, 207 Tests, 0 Fehler** – AutoSyncAppTests, BackgroundNewsAppTests,
  BackgroundReloginAppTests, BackgroundSyncAppTests, EinstellungenKlarAppTests, HintergrundAnmeldungAppTests,
  HsHAppTests, StoredLoginConnectTests, SyncAllPortalsTests, UniMailAppTests (118) sowie AuditRunde11AppTests,
  AuditRunde0910AppTests, DataSeparationAppTests, HildesheimParityAppTests, HildesheimAppTests, GoettingenAppTests,
  ReleaseUniversitiesAppTests (89). Neu: `SyncAllPortalsTests.testAutomaticSyncTwiceADayButMailEveryThirtyMinutesAndMailRunsSignInOnlyTheMail`.
- Nicht gelaufen: die ganze App-Testsammlung, iPhone-Simulator und Mac (gleicher Code, kein eigener Weg). Am echten
  Gerät noch nicht geprüft.

## Offen

- **Release:** Den Zweig mischt nur die Build-Sitzung in `release/1.0.8-alles` (Build 51).
- **Server:** nichts nötig. Das Weck-Signal ist am Server aus; wird es eingeschaltet, weckt es öfter, als die App
  abruft – die App fragt dann trotzdem nur in den zwei Fenstern (und die Uni-Mail). Den Takt von `app/wake_push.py`
  an die zwei Fenster anzupassen wäre ein eigener Schritt mit Okay des Inhabers.
- **Am Gerät prüfen:** Nach 8 Uhr ein Abgleich von selbst, danach bis 14 Uhr nur die Uni-Mail; „Sync“ holt sofort alles.
