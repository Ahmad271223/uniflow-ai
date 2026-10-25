# Stud.IP-Abgleich auf dem iPad (ohne Playwright)

Stand 25.10.2026. Ziel: Dateien, Termine und Kurse direkt auf dem iPad abgleichen. Das LUH-Passwort bleibt beim
Studierenden, der zentrale Dienst bekommt weder Passwort noch Stud.IP-Token (Vorgabe vom 25.10.).

## 1. Warum Playwright dort nicht geht

Heute meldet sich `app/studip_sync.py` mit einem ferngesteuerten Chromium (Playwright) über WebSSO an und nutzt danach
die JSON:API mit dem Session-Cookie. Auf iPadOS gibt es keinen fernsteuerbaren Browser, und Apps dürfen keinen eigenen
Browser-Prozess starten. Benötigt wird ein offizieller Anmeldeweg.

## 2. Optionen

| | A: Stud.IP-OAuth2 mit PKCE (empfohlen) | B: WebSSO im App-Browser + Cookie | C: PC als Abgleich-Station |
| --- | --- | --- | --- |
| Anmeldung | Systemfenster `ASWebAuthenticationSession` mit der Hochschul-SSO-Seite | eingebettete `WKWebView` mit der SSO-Seite | wie heute (Playwright am PC) |
| Sieht die App das Passwort? | nein | technisch möglich (eingebettete Seite) | ja, liegt in `.env` am PC |
| Dauerhafter Zugriff | Refresh-Token im Schlüsselbund | Session-Cookie, läuft nach Stunden ab, dann neu anmelden | solange der PC läuft |
| Abgleich im Hintergrund | ja (Token reicht) | kaum (Cookie abgelaufen) | ja, aber nur mit PC |
| Abhängigkeit | LUH-Administration muss einen OAuth2-Client für UniFlow anlegen | keine | PC |
| Aufwand | mittel | mittel | vorhanden |

**Belege zu A:** Stud.IP enthält einen OAuth2-Server mit „Authorization Code Grant mit PKCE“ und „Refresh Token Grant“;
Endpunkte `…/dispatch.php/api/oauth2/authorize` und `…/dispatch.php/api/oauth2/token`, einziger Scope `api`; Clients
legt ein Root-Administrator unter `…/dispatch.php/admin/oauth2` an; Apps müssen PKCE nutzen
([Stud.IP-Entwicklerdoku OAuth2](https://docs.gitlab.studip.de/entwicklung/functions/oauth2/)). Eine fremde
Bibliothek nutzt denselben Weg gegen die JSON:API (`jsonapi.php/v1/`) mit Client-ID und eigenem URL-Schema
([Dart-Paket studip](https://pub.dev/documentation/studip/latest/)).

**Bei der LUH geprüft (ohne Anmeldung):** `https://studip.uni-hannover.de/dispatch.php/api/oauth2/authorize` antwortet
mit HTTP 500, eine erfundene Adresse daneben mit HTTP 400. Der OAuth2-Teil ist also in der Installation vorhanden;
ob er eingerichtet ist und ob es einen Client für Apps gibt, ist **nicht geprüft** und muss bei der LUH erfragt werden.

## 3. Empfehlung

1. **Jetzt:** Anfrage an das Stud.IP-Team der LUH (ELSA/Stud.IP-Support): OAuth2-Client für eine studentische App,
   öffentlicher Client mit PKCE, Weiterleitung `de.uniflow.ai:/oauth/callback` (oder Universal Link), Scope `api`.
2. **Bis zur Antwort:** Option B als Übergang auf dem iPad (Anmeldung beim Öffnen der App, Cookie nur im Schlüsselbund,
   nie an den Dienst), dazu Option C für Nutzer mit PC.
3. **Mit OAuth2:** Option A als Standard; B nur noch als Rückfall für Hochschulen ohne OAuth2-Client.

## 4. Zuverlässigkeit unter iPadOS

iPadOS führt Hintergrundarbeit nicht zu festen Uhrzeiten aus. „8:00 und 15:00 Uhr“ wie am PC ist daher nicht garantierbar.

| Auslöser | Verhalten | Einsatz |
| --- | --- | --- |
| App wird geöffnet / kommt in den Vordergrund | sofort | immer abgleichen (inkrementell, nur Änderungen) |
| `BGAppRefreshTask` (frühestens 8:00 / 15:00) | System entscheidet nach Nutzung, Akku, Netz; ca. 30 s Laufzeit | Dateiliste holen, Downloads anstoßen |
| `BGProcessingTask` | meist nachts beim Laden | große Downloads, Textauszug für die Skriptsuche |
| Hintergrund-`URLSession` | Downloads laufen weiter, auch wenn die App beendet wird | PDF-Downloads |
| Stille Push-Nachricht vom Dienst um 8:00/15:00 | weckt die App kurz; wird vom System gedrosselt | Auslöser für A; braucht APNs (Developer Program) |

Realistisches Versprechen an Nutzer: „Neue Dateien erscheinen spätestens beim Öffnen der App und meist schon vorher.“

## 5. Technische Schnittstelle (Entwurf)

- `StudIPAuth`: liefert ein gültiges Zugriffstoken (A) bzw. Cookie (B); erneuert über Refresh-Token; meldet „Anmeldung
  nötig“, statt still zu scheitern.
- `StudIPClient`: `courses()`, `folders(course)`, `files(folder, since:)`, `download(fileRef) -> URL`,
  `events(range)`; nutzt dieselben JSON:API-Routen wie `app/studip_sync.py`
  (`users/{id}/courses`, `courses/{id}/events`, `folders`, `file-refs/{id}/content`).
- Ergebnis in dieselbe lokale Struktur wie heute (Modul, Lehrwoche, Ordnertyp), damit Kalender, Module und
  Skriptsuche unverändert bleiben.

## 6. Tests (wenn umgesetzt)

- Ablauf mit Test-Instanz von Stud.IP (eigene Docker-Instanz) und Testkonto; nie mit echten LUH-Zugangsdaten in CI.
- Token-Ablauf, Widerruf, Netzabbruch während Downloads, App-Beendigung während Hintergrund-Downloads.
- Am Gerät: Hintergrundabgleich über mehrere Tage beobachten (Zeitpunkte protokollieren).
