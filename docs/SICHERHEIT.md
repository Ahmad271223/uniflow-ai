# Sicherheit: behobene Lücken, Restrisiken, empfohlene Schritte

Stand 25.10.2026, Zweig `develop`. Alle Korrekturen sind durch Tests abgesichert (`tests/test_security.py`,
`tests/test_security_extended.py`). **Sie wirken erst, wenn der Server mit dem Stand von `develop` neu gestartet wird.**

## 1. Behobene Lücken

| Lücke | Wer hätte sie nutzen können | Korrektur | Test |
| --- | --- | --- | --- |
| Beliebige Dateien lesen (`.env`, SSH-Schlüssel, Claude-Anmeldung …) über `\` in der Datei-ID | jede Anfrage vom PC; im WLAN-Modus jedes Gerät mit PIN | IDs und Dateinamen nur `[A-Za-z0-9_-]`, Pfad muss im Asset-Ordner liegen | 9 Varianten (`..\`, kodiert, Vollbreiten-Punkte, `C:\`) |
| Beliebige Dateien schreiben (z. B. `.bat` in Autostart) | wie oben, dazu fremde Webseiten (siehe nächste Zeile) | wie oben, nur Audio-Endungen bei Aufnahmen | Traversal im Pfad und im Dateinamen |
| Fremde Webseite löst Aktionen aus (Formular an `127.0.0.1`) | jede Webseite, die im Browser des PCs offen war, während der Server lief | Änderungen nur mit eigener oder ohne `Origin` | POST/PUT/PATCH/DELETE, fremder Port, Groß/Klein |
| DNS-Rebinding (fremder Hostname zeigt auf den PC) | gezielt präparierte Webseite | nur IP-Adressen, `localhost`, eigener Rechnername | 4 fremde Hosts, 3 erlaubte |
| HTML/SVG aus Stud.IP oder Uploads läuft mit den Rechten der App | wer in einen Stud.IP-Ordner hochladen kann, den du abonnierst (z. B. Gruppenordner) | nur PDF/Bilder/Text inline, sonst Download; `nosniff`; Sandbox ohne Skripte | HTML-Datei, SVG-Asset, PDF |
| Server aus dem Internet erreichbar (Portweiterleitung, öffentliches WLAN) | jeder, der den Port erreicht | nur Clients aus privaten Netzen (RFC 1918, Tailscale 100.64/10, IPv6-ULA, Link-Local); WLAN-Modus startet nicht in Windows-Netzen vom Typ „Öffentlich“ | 4 öffentliche, 6 private Adressen |
| Gleichzeitiges Speichern überschreibt still | zwei eigene Geräte | Versionsprüfung in einer Schreibtransaktion | paralleler Test |
| PIN in Einstellungsantworten, Cookie für Skripte lesbar | – | PIN nur in `/api/network`, Cookie `HttpOnly` | ja |
| Uploads mit falscher Endung/fremdem Inhalt | Gerät mit PIN | Bild-Endungen, PDF-Kopf `%PDF` | ja |

Geprüft ohne Befund: SQL (alle dynamischen Spalten über feste Listen, Suche parametrisiert), KI-Aufrufe
(`claude -p` ohne Shell, Argumente als Liste), statische Dateien (Starlette verhindert Verlassen des Ordners, getestet).

## 2. Bewertung: wurden die Lücken genutzt?

Nicht feststellbar, aber es gibt keine Spuren:
- Autostart-Ordner: nur Einträge, die älter sind als die App.
- Keine Dateien mit dem Namensmuster der Upload-Endpunkte außerhalb von `data/assets`, keine fremden Ordner im Projekt.
- Server-Zugriffe wurden nicht in Dateien protokolliert (nur im Konsolenfenster), ein Nachweis ist daher nicht möglich.

Erhöhtes Risiko bestand, wenn `Start-iPad.cmd` im **eduroam** lief: Windows führt eduroam als „Öffentlich“, und es gibt
eine eingehende Firewall-Regel „Python“ für öffentliche Netze. Andere Geräte im eduroam konnten den Port also erreichen
(sofern eduroam Geräte nicht voneinander abschottet). Sie brauchten die PIN; bis zur Fehlversuchs-Sperre (24.10.)
war Durchprobieren unbegrenzt möglich.

## 3. Empfohlener Wechsel von Zugangsdaten (vorsorglich)

Über die Leselücke war jede Datei deines Windows-Benutzers lesbar. Vorhanden sind (nur Namen geprüft, keine Inhalte):

| Priorität | Zugang | Warum | Wie |
| --- | --- | --- | --- |
| 1 | **LUH-ID-Passwort** (WebSSO/Stud.IP), ggf. QIS/IDM | steht im Klartext in `.env` | im IDM der LUH ändern, dann in der App unter Einstellungen → Zugang neu eintragen |
| 1 | **SSH-Schlüssel** in `~/.ssh` (mehrere private Schlüssel, u. a. für Server) | geben Zugriff auf Server | neue Schlüssel erzeugen, auf den Servern eintragen, alte aus `authorized_keys` entfernen |
| 2 | **Claude-Anmeldung** (`~/.claude/.credentials.json`) | Sitzungs-Token | in Claude Code abmelden und neu anmelden; auf claude.ai unter Einstellungen aktive Sitzungen prüfen |
| 2 | **WLAN-PIN der App** | war in Antworten sichtbar | unten |
| – | GitHub (`gh`) | liegt im Windows-Anmeldespeicher, nicht als Datei | kein Wechsel nötig |
| – | Docker, npm | keine Zugangsdaten in den Dateien gefunden | – |

Neue PIN erzeugen (am PC, Server läuft):
```powershell
Invoke-RestMethod -Method Put -Uri http://127.0.0.1:8765/api/settings -ContentType application/json -Body '{"lan_pin":""}'
```
Die neue PIN steht danach in der App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen.

## 4. Firewall (als Administrator selbst ausführen)

Diese Einstellungen ändern Sicherheitseinstellungen von Windows; ich führe sie nicht aus.

Regel der App nur für private Netze:
```powershell
netsh advfirewall firewall set rule name="StudIP-LernApp" new profile=private
```

Python-Freigabe für öffentliche Netze abschalten:
```powershell
Get-NetFirewallRule -DisplayName "Python" | Where-Object { $_.Profile -match "Public" } | Disable-NetFirewallRule
```

## 5. Restrisiken

- Ohne Konten und HTTPS ist der Server nur für das eigene Heimnetz gedacht. Nie per Portweiterleitung freigeben.
- `GET /api/tests/{id}` setzt beim ersten Aufruf den Startzeitpunkt (harmlose Nebenwirkung eines Lesezugriffs).
- Stud.IP-Download-Adressen kommen aus den Stud.IP-Daten und werden nicht auf den Stud.IP-Host beschränkt
  (geringes Risiko; Änderung erst mit Test gegen den echten Abgleich).
- Zugangsdaten liegen weiter im Klartext in `.env` (Einzelplatz). Für Konten siehe `SICHERHEITSKONZEPT-KONTEN.md`.
