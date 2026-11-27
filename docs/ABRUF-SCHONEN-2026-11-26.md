# Abruf schonen (26.11.2026, in 1.0.8 Build 51 – Freigabe des Inhabers „Ja, in Build 51“)

Auftrag des Inhabers nach der Analyse der Uni-Abrufe: „Ja, alle drei bauen.“ Zweig `app/abruf-schonen`
(von `release/1.0.8-alles` @ 52ff61a3). Build 50 bleibt unverändert.

Grundregel unverändert: Alle Abfragen an QIS, Stud.IP, Learnweb, LSF, Moodle, Campus und Uni-Mail laufen auf dem
Gerät der Studierenden, nie über den StudiNow-Dienst.

## Was sich ändert

| Punkt | Vorher | Jetzt | Wo |
|---|---|---|---|
| Noten von selbst (QIS der LUH, LSF Hildesheim, Campus HsH) | alle 30 min, 20× am Tag | höchstens alle 4 h (08:00, 12:00, 16:00) | `AutoSync.gradesInterval`, `AutoSync.portalIntervals`, `autoGradesDue` |
| Beginn des Fensters | alle Geräte um Punkt 8:00, 8:30 … | fester Versatz je Gerät 0–29 min (z. B. 8:17, 8:47 …), Ende bleibt 18:00 | `AutoSyncSchedule.offset`, `AutoSyncStagger` |
| Weck-Signal des Dienstes | an jedes Gerät des Kontos | nur an das zuletzt benutzte Gerät je Konto | `app/wake_push.py` `wake_devices` |
| Meldung des Geräts beim Dienst | einmal je App-Start | zusätzlich beim Öffnen, wenn die letzte Meldung ≥ 1 h her ist | `WakePush.reportAgain` |
| „Retry-After“ der Uni bei 429/503 | übergangen (fest 1,5 s / 3 s) | bis 30 s abgewartet; verlangt die Uni mehr, gibt der Lauf auf; Stud.IP fragt dann im ganzen Lauf nichts mehr, der Abgleich von selbst ruht 2 h | `UniRetry.retryAfter`, `UniRetry.wait`, `StudIPClient.restUntil` |

Der Knopf „Sync“ fragt weiter alles sofort ab.

## Was zu tun bleibt

- **Server:** `app/wake_push.py` muss deployt werden, damit „ein Gerät je Konto“ wirkt. Das geht nur mit Okay des
  Inhabers. Ohne Deploy weckt der Dienst wie bisher jedes Gerät; die App-Teile wirken trotzdem.
- **Release:** Den Zweig mischt nur die Build-Sitzung in den nächsten Release-Zweig.
- **Am Gerät prüfen:** Ein Abgleich von selbst um 8 Uhr startet erst mit dem Versatz des Geräts. Noten kommen höchstens
  alle 4 Stunden von selbst, „Sync“ holt sie sofort.
