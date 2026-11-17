# Weck-Signal (Stand 17.11.2026)

Auftrag des Inhabers vom 17.11.2026. Dieses Dokument beschreibt den Teil auf dem Server.
Code: `app/wake_push.py` (Speicher, Zeitplan, Versand), `app/wake_push_api.py` (die zwei Adressen für die App),
Tests: `tests/test_wake_push.py`.

**Im Auslieferzustand ist das Weck-Signal AUS.** Der Server sendet erst, wenn es eingeschaltet ist und der Schlüssel
von Apple hinterlegt wurde (Abschnitt 5).

## 1. Was es ist

StudiNow speichert Uni-Passwörter nur auf dem Gerät. Der Server kann deshalb nicht selbst bei der Hochschule
nachsehen, ob es etwas Neues gibt. Das kann nur die App.

Damit die App das auch tut, wenn sie geschlossen ist, schickt der Server ihr ein **Weck-Signal**: eine stille
Nachricht über Apple. Man sieht und hört sie nicht. Die App wacht kurz auf, gleicht selbst mit der Hochschule ab und
legt sich wieder schlafen.

- **Wann:** zwischen **08:00** und **18:00** Uhr, nach der Uhrzeit **des Geräts** (wer in New York ist, wird nach
  New Yorker Zeit geweckt). 08:00 gehört dazu, 18:00 nicht mehr.
- **Wie oft:** alle **30 Minuten**, also höchstens **20-mal am Tag** je Gerät.
- **Gestaffelt:** Jedes Gerät hat einen festen Versatz von 0 bis 29 Minuten. Ein Gerät mit Versatz 7 wird um 08:07,
  08:37 … 17:37 geweckt. So fragen nicht alle Geräte in derselben Minute bei der Hochschule an. Der Versatz wird aus
  dem Geräte-Token berechnet und bleibt immer gleich.
- **Nie doppelt:** In einem 30-Minuten-Abschnitt bekommt ein Gerät höchstens ein Signal. Das gilt auch nach einem
  Neustart des Servers, weil der Zeitpunkt des letzten Signals in der Datenbank steht.
- **Sommer- und Winterzeit** werden richtig gerechnet (geprüft für die Tage der Umstellung).
- **Nachholen:** War der Server kurz weg, gibt es für den laufenden Abschnitt ein Signal, nicht mehrere auf einmal.
  Nach 18:00 wird nichts mehr nachgeholt.

Die drei Zahlen (8, 18, 30) stehen im Code an genau einer Stelle: oben in `app/wake_push.py`
(`WINDOW_START_HOUR`, `WINDOW_END_HOUR`, `INTERVAL_MINUTES`).

## 2. Was der Server speichert – und was nicht

Je Konto und Gerät ein Eintrag in der Tabelle `push_tokens` (in `accounts.db`). Darin steht **nur**:

| Feld | Bedeutung |
|---|---|
| Konto | zu welchem StudiNow-Konto das Gerät gehört |
| Geräte-Kennung | dieselbe Kennung, die die App schon beim Anmelden schickt (wie bei der Geräte-Regel) |
| APNs-Token | die Adresse des Geräts bei Apple für Push-Nachrichten |
| Plattform | `ios`, `ipados` oder `macos` |
| App-Version | z. B. `1.0.6 (45)` |
| Zeitzone | z. B. `Europe/Berlin` |
| Umgebung | `production` (App Store, TestFlight) oder `sandbox` (Testbuild aus Xcode) |
| vier Zeitpunkte | angelegt, zuletzt gemeldet, zuletzt gesendet, letzter Fehlercode von Apple |

**Nicht gespeichert:** keine Uni-Passwörter, keine Uni-Daten, keine Kurse, keine Noten, kein Standort. Der Server
erfährt auch nicht, ob und was die App nach dem Wecken abgleicht. Die Nachricht selbst enthält nichts außer dem
Weck-Zeichen: `{"aps":{"content-available":1}}`.

Wann ein Eintrag wieder verschwindet:

- **Abmelden** in der App: der Eintrag dieses Geräts ist sofort weg.
- **„Andere Geräte abmelden“**, **ein Gerät in der Liste abmelden**, **Passwort ändern oder zurücksetzen**: die
  Einträge der abgemeldeten Geräte sind sofort weg.
- **Konto löschen:** alle Einträge des Kontos sind sofort weg (nicht erst nach 30 Tagen).
- **Apple meldet, dass es das Gerät oder die App darauf nicht mehr gibt:** der Eintrag wird gelöscht.
- **Die App hat sich 60 Tage nicht mehr gemeldet:** der Eintrag wird beim täglichen Aufräumen gelöscht.
- Ein Token gehört immer nur zu einem Konto. Meldet sich auf demselben Gerät ein anderes Konto an, wandert der Eintrag
  zu diesem Konto.

Im **Datenexport** („Meine Daten“) stehen die Einträge in `konto.json` unter `weck_signal_geraete`.

Im **Protokoll** des Servers steht nie ein Token, nur eine gekürzte Prüfsumme (10 Zeichen), mit der man einen Eintrag
wiederfindet.

## 3. Einstellungen (Datei `deploy/.env` auf dem Server)

| Name | Bedeutung |
|---|---|
| `STUDINOW_WAKE_PUSH` | `1` schaltet ein. Alles andere (auch leer oder nicht vorhanden) heißt: aus. |
| `APNS_KEY_PATH` | Pfad der Schlüsseldatei von Apple (`AuthKey_….p8`) im Container |
| `APNS_KEY_ID` | Key-ID dieses Schlüssels (10 Zeichen, steht bei Apple neben dem Schlüssel) |
| `APNS_TEAM_ID` | Team-ID (10 Zeichen). Fehlt sie, nimmt der Server `LERNAPP_APPLE_TEAM_ID`, falls gesetzt. |
| `APNS_TOPIC` | Bundle-ID der App. Muss nicht gesetzt werden, Standard ist `de.uniflow.ai`. |

Die Schlüsseldatei gehört **nie** ins Repository. Im Repository liegt kein Schlüssel, auch kein Platzhalter.

## 4. Ausschalten

In `deploy/.env` die Zeile `STUDINOW_WAKE_PUSH=1` entfernen oder auf `0` setzen, dann:

```
cd /srv/uniflow/app/deploy && docker compose up -d
```

Der Server sendet dann nichts mehr und schreibt einmal ins Protokoll:
`Weck-Signal: ausgeschaltet (STUDINOW_WAKE_PUSH ist nicht 1). Es wird nichts an Apple gesendet.`
Die gemeldeten Geräte bleiben gespeichert, damit nach dem Einschalten sofort wieder gesendet werden kann.

## 5. Einschalten – was zu tun ist, sobald der Schlüssel da ist

Der Schlüssel existiert noch nicht. Ihn kann nur der Inhaber im Apple-Developer-Konto anlegen.

1. **Schlüssel bei Apple anlegen:** developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → „+“ →
   Haken bei **Apple Push Notifications service (APNs)** → anlegen → Datei `AuthKey_XXXXXXXXXX.p8` herunterladen.
   Das geht nur **einmal**. Die **Key-ID** (die zehn Zeichen im Dateinamen) notieren. Die **Team-ID** steht unter
   Membership.
2. **App-Kennung prüfen:** Unter Identifiers bei `de.uniflow.ai` muss **Push Notifications** angehakt sein.
3. **Neuen Stand auf den Server bringen und neu bauen** (wie bei jedem Update, mit `--build`). Das ist nötig, weil ein
   kleines Zusatzpaket (`h2`, siehe Abschnitt 8) installiert werden muss.
4. **Schlüsseldatei auf den Server legen**, so dass der Container `jobs` sie lesen kann. Ohne Änderung an
   `docker-compose.yml` geht das über den gemeinsamen Datenordner:

   ```
   cd /srv/uniflow/app/deploy
   docker compose exec -u root jobs mkdir -p /data/apns
   docker compose cp /pfad/zu/AuthKey_XXXXXXXXXX.p8 jobs:/data/apns/AuthKey_XXXXXXXXXX.p8
   docker compose exec -u root jobs sh -c 'chown -R uniflow:uniflow /data/apns && chmod 700 /data/apns && chmod 600 /data/apns/*.p8'
   ```

   Hinweis: Die Datei liegt damit im Daten-Volume. Wer sie lieber getrennt halten will, hängt sie in
   `deploy/docker-compose.yml` beim Dienst `jobs` als eigene Datei nur zum Lesen ein (das ist eine Änderung am
   Server-Aufbau und noch nicht gemacht).
5. **In `deploy/.env` eintragen:**

   ```
   STUDINOW_WAKE_PUSH=1
   APNS_KEY_PATH=/data/apns/AuthKey_XXXXXXXXXX.p8
   APNS_KEY_ID=XXXXXXXXXX
   APNS_TEAM_ID=<Team-ID>
   ```
6. **Neu starten:** `docker compose up -d`
7. **Prüfen:**

   ```
   docker compose exec jobs python -m app.wake_push --status
   docker compose logs jobs | grep "Weck-Signal"
   ```

   `--status` sendet nichts. Es zeigt, ob alles eingerichtet ist, wie viele Geräte gemeldet sind und wann zuletzt
   gesendet wurde. Steht dort statt „bereit“ ein Satz wie „es fehlt APNS_KEY_ID“, ist genau das noch zu tun.

Solange eingeschaltet ist, aber etwas fehlt (Schlüsseldatei, Key-ID, Team-ID), sendet der Server nichts und schreibt
den Grund **einmal** ins Protokoll.

Das Weck-Signal läuft nur im Dienst `jobs` (dort, wo auch die Löschfristen laufen). Die API-Container senden nichts.
Am eigenen PC und in der Windows-App gibt es das Weck-Signal nicht.

## 6. Wie der Server mit Apple spricht

- Adresse: `api.push.apple.com` für `production`, `api.sandbox.push.apple.com` für `sandbox`, über HTTP/2.
- Anmeldung mit einem kurzlebigen Ausweis (JWT, ES256), den der Server aus dem Schlüssel, der Key-ID und der Team-ID
  erzeugt. Er wird 50 Minuten lang wiederverwendet und nie öfter als alle 20 Minuten erneuert (Vorgabe von Apple).
- Kopfzeilen: `apns-push-type: background`, `apns-priority: 5`, `apns-topic: de.uniflow.ai`, dazu
  `apns-expiration` = Ende des 30-Minuten-Abschnitts. Dadurch wird ein Gerät, das erst abends wieder Netz hat, nicht
  nachträglich um 22 Uhr geweckt.
- **Ungültige Geräte:** Antwortet Apple mit 410 oder mit 400 und `BadDeviceToken`, `Unregistered` oder
  `DeviceTokenNotForTopic`, wird der Eintrag gelöscht.
- **Apple bittet um Pause (429, 503 und andere 5xx) oder ist nicht erreichbar:** der Server hört sofort auf und wartet
  erst 1 Minute, dann 2, 4, 8 … höchstens 30 Minuten. Nennt Apple selbst eine Wartezeit, gilt die. Nach der Pause wird
  mit einem einzelnen Versuch geprüft, ob es wieder geht. Es gibt keinen Sturm von Anfragen.
- **Apple lehnt die Einrichtung ab** (falscher Schlüssel, falsche Team-ID, falsche Bundle-ID): 30 Minuten Pause und
  ein Satz im Protokoll, was zu prüfen ist. Deshalb wird kein Gerät gelöscht.
- Ein Fehler beim Weck-Signal hält den übrigen Dienst nie auf und kann ihn nicht zum Absturz bringen.

## 7. Grenzen (wichtig für die Erwartung)

Ein Weck-Signal ist eine Bitte an iOS, keine Garantie.

- **iOS drosselt stille Nachrichten.** Apple entscheidet je Gerät, ob und wann die App wirklich geweckt wird (Akku,
  Nutzung der App, Netz). Bei 20 Signalen am Tag kommen meist nicht alle an. Apple nennt als Richtwert höchstens zwei
  bis drei stille Nachrichten je Stunde; mit zwei je Stunde liegt StudiNow darin.
- **Vom Nutzer beendete App:** Wer die App im App-Umschalter nach oben wegwischt, bekommt kein Weck-Signal mehr, bis
  er die App wieder öffnet.
- **Stromsparmodus** und ausgeschaltete **Hintergrundaktualisierung** (Einstellungen → Allgemein): iOS weckt die App
  dann selten oder gar nicht.
- **Kein Netz:** Das Signal verfällt mit dem Ende seines 30-Minuten-Abschnitts.
- **Kurze Laufzeit:** iOS gibt der App nach dem Wecken nur etwa 30 Sekunden.
- **App nie geöffnet oder Mitteilungen/Push für die App nicht registriert:** dann gibt es kein Token und kein Signal.
- Der Server weiß nicht, ob ein Signal angekommen ist. „Zuletzt gesendet“ heißt: an Apple übergeben.

## 8. Technik: neues Zusatzpaket `h2`

Apple nimmt Push-Nachrichten nur über HTTP/2 an. Python kann das von Haus aus nicht. Der vorhandene HTTP-Client
(`httpx2`, kommt schon mit dem Anthropic-Paket) kann es, sobald das kleine Paket `h2` installiert ist. Es steht jetzt
in `requirements.txt` (`h2==4.4.1`, reines Python, bringt `hpack` und `hyperframe` mit). Fehlt es, bleibt das
Weck-Signal aus und der Server sagt das einmal im Protokoll; alles andere läuft weiter.

Der Versand steckt hinter einer kleinen Schnittstelle (`Http2Transport`). In den Tests wird sie durch eine Attrappe
bzw. einen eigenen kleinen HTTP/2-Server auf dem Testrechner ersetzt. **Kein Test sendet an Apple.**

## 9. Vertrag für die App

Anmeldung wie bei allen Konto-Adressen: Kopfzeile `Authorization: Bearer <Sitzungs-Token>`. Fehler haben die übliche
Form `{"detail": "<Meldung>", "code": "<stabiler Code>"}`. Das Token steht nur im Rumpf, nie in der Adresse.

### Gerät melden: `PUT /api/account/push-token`

```json
{
  "token": "<APNs-Token als Hex, 64 bis 200 Zeichen>",
  "platform": "ios | ipados | macos",
  "app_version": "1.0.6 (45)",
  "timezone": "Europe/Berlin",
  "environment": "production | sandbox"
}
```

- `token`, `platform`, `timezone` sind Pflicht. `app_version` (höchstens 40 Zeichen) und `environment` dürfen fehlen;
  ohne `environment` gilt `production`. Testbuilds aus Xcode melden `sandbox`.
- Beliebig oft aufrufbar. Derselbe Aufruf noch einmal ändert nur Zeitzone, Version, Umgebung und „zuletzt gemeldet“.
- Die App sollte melden: nach dem Anmelden, bei jedem Start, wenn Apple ein neues Token liefert und wenn sich die
  Zeitzone ändert.

Antwort 200:

```json
{
  "ok": true,
  "push": {"platform": "ipados", "app_version": "1.0.6 (45)", "timezone": "Europe/Berlin", "environment": "production",
           "created_at": "2026-11-17T09:12:00Z", "last_seen_at": "2026-11-17T09:12:00Z"},
  "schedule": {"from": "08:00", "to": "18:00", "every_minutes": 30, "offset_minutes": 7}
}
```

### Meldung zurücknehmen: `DELETE /api/account/push-token`

Rumpf `{"token": "<Hex>"}` löscht genau dieses Token, wenn es dem Konto gehört. Ohne Rumpf: der Eintrag des Geräts
dieser Sitzung. Antwort 200 `{"ok": true, "removed": 0 oder 1}`. Nichts zu löschen ist kein Fehler.
Die App muss das vor dem Abmelden nicht aufrufen: Abmelden entfernt den Eintrag selbst.

### Fehler

| Status | Code | Wann |
|---|---|---|
| 400 | `push_token_invalid` | Token kein Hex, kürzer als 64, länger als 200 oder ungerade Länge |
| 400 | `timezone_invalid` | Zeitzone ist kein bekannter Name wie `Europe/Berlin` |
| 400 | `platform_invalid` | Plattform nicht `ios`, `ipados`, `macos` |
| 400 | `environment_invalid` | Umgebung nicht `production`, `sandbox` |
| 400 | `app_version_invalid` | App-Version länger als 40 Zeichen oder mit Steuerzeichen |
| 400 | `invalid_input` | ein Feld ist kein Text (Zahl, Liste …) |
| 400 | `push_not_applicable` | Aufruf aus der Web-Oberfläche oder der Windows-App (nur die Apple-Apps melden ein Gerät) |
| 401 | `unauthenticated` | keine oder ungültige Anmeldung |
| 429 | `rate_limited` | mehr als 60 Meldungen je Stunde und Konto (Kopfzeile `Retry-After`) |
| 501 | `not_hosted` | nicht im gehosteten Dienst (eigener PC) |

## 10. Noch offen (nicht Teil dieses Stands)

- Der APNs-Schlüssel (Abschnitt 5, nur der Inhaber).
- `deploy/.env.example` nennt die neuen Einstellungen noch nicht.
- Datenschutzerklärung: Das Geräte-Token und die Zeitzone sollten dort genannt werden, bevor eingeschaltet wird.
- Ein echter Versand an Apple wurde nicht geprüft (kein Schlüssel, bewusst kein Test gegen Apple). Geprüft ist alles
  bis zur Übergabe an einen nachgebauten Apple-Server.
