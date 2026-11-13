# Plan: Ein Konto, alle Geräte (13.11.2026)

Grundlage: `docs/ALLE-GERAETE-TEST-2026-11-13.md` (43 von 49 Prüfungen erfüllt; Notizen, Lernkalender, Karteikarten
und Module laufen zwischen Windows, iPad, iPhone und Web). **Umsetzung erst nach OK des Inhabers**, auf eigenem Zweig
von `develop`, nichts pushen, nichts hochladen.

Aufwand in Arbeitstagen einer Sitzung (Programmieren + Tests), ohne Wartezeit für App-Prüfung und Dienst-Update.

## Übersicht und empfohlene Reihenfolge

| # | Schritt | Wer merkt es | Aufwand | Braucht |
|---|---|---|---|---|
| 1 | iPad/iPhone gleichen direkt nach einer Änderung ab (nicht erst beim nächsten Öffnen) | jeder mit 2 Geräten | **1 Tag** | neue App-Version |
| 2 | Hinweis „überall gleich anmelden“ + Anmeldewege verknüpfen | wer mit Apple „E-Mail verbergen“ startet | **3 Tage** | App-Version, Windows-Version, kleines Dienst-Update |
| 3 | Grenze 3 Geräte je Person (Dienst und Apps) | wer ein 4. Gerät anmeldet | **5 Tage** | Dienst-Update, App- und Windows-Version |
| 4 | Eigene Dokumente und Notizbücher abgleichen (Pro AI) | jeder Pro-AI-Nutzer mit eigenen PDFs | **12–15 Tage** | Dienst-Update mit Speicher, App- und Windows-Version, Datenschutzerklärung |
| 5 | Eine gemeinsame Community über den Dienst | alle Community-Nutzer | **10–14 Tage** | Dienst-Update, App-Version, Umzug der iCloud-Beiträge |

Begründung der Reihenfolge: 1 ist klein und macht den heutigen Abgleich erst im Alltag spürbar. 2 kommt früh, weil
jedes neu entstehende Doppelkonto später mühsam zusammengeführt werden muss. 3 vor 4, weil eigene Dokumente
Speicher im Dienst belegen und die Grenze vorher stehen soll. 5 zuletzt: größter Umbau, betrifft auch Nutzer ohne
mehrere Geräte.

Vor jeder Freigabe: ein kurzer Gerätetest mit dem echten iPad und einem Windows-Laptop (½ Tag, mit dem Inhaber), und
der Rundgang `tools/g2-geraete-rundgang.py` wird um den jeweiligen Schritt erweitert und muss grün sein.

---

## 1. Abgleich direkt nach einer Änderung (iPad, iPhone) – 1 Tag

Heute: einziger Auslöser ist das Öffnen der App (höchstens alle 3 Minuten) bzw. der Knopf „Jetzt abgleichen“
(`UniFlowApp.swift`, `StudoraAccountLink.syncNow`).

- Nach einer Änderung (Notiz gespeichert, Lernpaket, Karte) wenige Sekunden warten und dann abgleichen, gebündelt
  wie unter Windows (`sync_client.kick`, 4 s).
- Beim Wechsel in den Hintergrund einmal senden (Hintergrund-Zeit wie beim Speichern von Dokumenten,
  `DocumentStore.flushInBackground`).
- Solange die App offen ist, alle 3 Minuten abrufen; offene Ansichten laden bei Änderungen neu (gibt es schon:
  `.uniflowAccountSynced`).
- Gilt automatisch für iPhone (gleicher Code); auf `iphone/universal` mitnehmen.
- Test: Rundgang + neuer Test in UniFlowCore für das Bündeln.

**Stand 13.11.2026 (OK des Inhabers „Ja, Schritt 1“): umgesetzt auf `sync/alle-geraete`, nicht veröffentlicht.**
- `UniFlowCore/DeviceSyncKick.swift` (`DeviceSyncKicker`): bündelt Änderungen (5 s Ruhe, spätestens 30 s), nie zwei
  Läufe zugleich, `flush()` für den Hintergrund; welche Anfragen zählen, wie `_NO_KICK` der Windows-App.
- `LocalTransport` meldet jede gelungene Änderung an Daten des Kontos (`.uniflowLocalDataChanged`);
  `StudoraAccountLink` stößt damit den Abgleich an (nur für den eigenen Container), ruft im Vordergrund alle 3 Minuten
  ab (`startForegroundSync`) und sendet beim Wechsel in den Hintergrund (`sendPendingChanges`, mit
  Hintergrund-Zeit in `UniFlowApp`). Bringt ein Abgleich Daten anderer Geräte, laden die Fenster neu (wie beim Öffnen).
- Tests: `DeviceSyncKickTests` (6), drei neue in `AuditPaket40x45AppTests` (Änderung → gesendet, Hintergrund →
  sofort gesendet, anderer Container → nichts).
- Offen: iPhone-Zweig `iphone/universal` muss develop (bzw. diesen Zweig) übernehmen; Gerätetest am echten iPad.

## 2. Gleicher Anmeldeweg, Konten verknüpfen – 3 Tage

Befund: Apple/Google mit derselben bestätigten E-Mail landen schon im selben Konto. Getrennte Konten entstehen vor
allem durch Apple „E-Mail verbergen“ auf dem iPad + E-Mail-Konto am Laptop.

a) **Hinweis** (1 Tag)
- iPad/iPhone (Karte „StudiNow-Konto“) und Windows/Web (Konto-Seite): „Angemeldet als … über Apple / Google /
  E-Mail. Melde dich auf allen Geräten genauso an.“
- Ist die Adresse eine verborgene Apple-Adresse (`@privaterelay.appleid.com`): „Am Laptop bitte ‚Mit Apple
  anmelden‘ wählen, nicht E-Mail.“ (Die Windows-App kann Apple-Anmeldung im Browser schon.)
- Windows-Anmeldemaske: Satz „Auf dem iPad mit Apple angemeldet? Dann hier auch ‚Mit Apple anmelden‘.“

b) **Weitere Anmeldewege zum Konto hinzufügen** (2 Tage)
- Der Dienst kann das schon (`accounts.link_identity`, `unlink`, Passwort setzen per Zurücksetzen). Es fehlt die
  Bedienung: in allen Apps „Mit Google verknüpfen“, „Mit Apple verknüpfen“, „Passwort festlegen“.
- Danach kann sich jemand mit verborgener Apple-Adresse am Laptop auch mit E-Mail + Passwort anmelden.

c) **Zwei bestehende Konten zusammenführen** – nicht als eigene Funktion empfohlen
- Ein echtes Zusammenführen (Daten, Abos, Community-Namen zweier Konten) ist aufwendig und riskant (5+ Tage).
- Einfacher Weg, der heute schon fast geht: Auf dem Gerät mit den Daten des „falschen“ Kontos abmelden und mit dem
  richtigen anmelden; der erste Abgleich bringt die Daten ohne Doppelte ins richtige Konto. Unter Windows klappt das
  (lokale Daten bleiben beim Kontowechsel). Auf dem iPad hat jedes Konto einen eigenen Datenbereich – dort bräuchte
  es eine Frage „Daten dieses iPads ins neue Konto mitnehmen?“ (+1–2 Tage, falls gewünscht).
- Abo: Ein Apple-Abo hängt am Konto, bei dem es gekauft wurde; ob „Käufe wiederherstellen“ es auf das andere Konto
  umzieht, ist vor Umsetzung zu prüfen.

## 3. Grenze 3 Geräte je Person – 5 Tage

Heute: keine Grenze; im Test hatte ein Konto 7 Anmeldungen, alle gleichen ab.

**Dienst** (2 Tage)
- Ein Gerät = eine Anmeldung mit Geräte-Kennung (`sessions.device_id`, gibt es schon). Dieselbe Kennung erneut
  angemeldet zählt nicht doppelt.
- Beim Anmelden des 4. Geräts: Antwort „Geräte-Grenze erreicht“ mit der Liste der Geräte (Name, zuletzt benutzt),
  statt einfach eine weitere Sitzung anzulegen. Gilt für E-Mail-, Apple-, Google- und Windows-Browser-Anmeldung.
- Geräte, die 30 Tage nicht benutzt wurden, zählen nicht mehr (Sitzungen laufen ohnehin nach 30 Tagen aus).
- Abgleich, Notizen und Community prüfen die Grenze zusätzlich je Anfrage (falls alte Sitzungen noch bestehen).
- Unterscheidbare Namen: Windows schickt den PC-Namen mit („StudiNow für Windows – Laptop-Anna“), iPad/iPhone den
  Gerätenamen.

**Apps** (3 Tage: iPad/iPhone 1½, Windows ½, Web ½, Tests ½)
- Bei „Geräte-Grenze erreicht“: Liste zeigen, ein Gerät abmelden, dann automatisch weiter anmelden.
- In den Konto-Einstellungen „Meine Geräte (2 von 3)“ mit Abmelden (Windows/Web haben die Liste schon,
  iPad/iPhone haben die Schnittstelle, `StudoraAccount` Zeile 188/255).

## 4. Eigene Dokumente und Notizbücher abgleichen (Pro AI) – 12–15 Tage

Heute: alles in „Eigene Dokumente“ wird ausdrücklich übersprungen (Datei und Notizen darauf).

**Dienst** (3–4 Tage)
- Neuer Abgleich-Eintrag „eigene Datei“: Name, Art (PDF, Notizbuch, Whiteboard), Modul/Ordner, Größe,
  Prüfsumme, Seitenformat; Löschen wie bei allen anderen Einträgen (mit Papierkorb).
- Hochladen und Herunterladen des Inhalts je Prüfsumme (eine Datei liegt nur einmal im Dienst). Speicherplatz je Konto
  wie bei der Web-Oberfläche: Standard 2 GB (`UPLOAD_QUOTA_MB`), mit verständlicher Meldung bei vollem Speicher.
- Notizen auf eigenen Dateien wie Notizen auf Hochschul-PDFs (gleiche Konfliktregeln, Striche beider Geräte bleiben).
- Nur mit Pro AI (Recht wie `can_sync_annotations`); Plus behält eigene Dokumente auf dem Gerät.

**iPad/iPhone** (4–5 Tage)
- Beim Import und nach Änderungen hochladen (im Hintergrund, auf Wunsch nur im WLAN).
- Dateien anderer Geräte erscheinen sofort in der Liste, der Inhalt lädt beim Öffnen bzw. im Hintergrund.
- Eigene Dokumente brauchen eine geräteübergreifend eindeutige Kennung; vorhandene lokale Kennungen werden beim
  ersten Abgleich zugeordnet.

**Windows** (3 Tage), **Web** (1 Tag, kann eigene Dokumente im Dienst schon anzeigen), **Tests** (1–2 Tage, Rundgang
Abschnitt 4 muss grün werden).

Zu beachten: Inhalte eigener Dokumente liegen dann auf dem Server → **Datenschutzerklärung und Store-Angaben
anpassen**; Speicherkosten im Dienst steigen (2 GB × Pro-AI-Nutzer als Obergrenze).

## 5. Eine gemeinsame Community über den Dienst – 10–14 Tage

Heute: iPad über iCloud, Windows und Web über den Dienst – zwei getrennte Communitys. Der Dienst kann inzwischen
Lösungen, Fragen/Antworten je Modul, Korrekturen, geteilte Kartenstapel, Lesezeichen und Benachrichtigungen; die
iPad-Anbindung an den Dienst kann bisher nur Lösungen.

- **iPad/iPhone** (6–8 Tage): Anbindung an den Dienst für alles, was heute über iCloud läuft (Fragen/Antworten,
  Korrekturen, Kartenstapel, Seiten-Erklärungen, Dokument-Zuordnung, Benachrichtigungen), dann den Schalter
  `communityViaService` für alle einschalten. Voraussetzung ist ein StudiNow-Konto – das legt die App beim ersten
  Start mit Apple ohnehin an.
- **Dienst** (2–3 Tage): fehlende Teile für Seiten-Erklärungen und Dokument-Zuordnung, Last prüfen.
- **Umzug** (2–3 Tage): bestehende iCloud-Beiträge beim ersten Start der neuen Version in den Dienst übernehmen
  (eigene Beiträge der Person), danach iCloud nur noch lesen und später abschalten.
- Gilt dann für alle Tarife gleich; Moderation an einer Stelle.

---

## Entscheidungen des Inhabers (vor Umsetzung)

1. Reihenfolge wie oben (1 → 2 → 3 → 4 → 5)?
2. Geräte-Grenze: Zählt das Web als Gerät? (Vorschlag: nein.) Gilt die Grenze für alle Tarife? (Vorschlag: ja.)
3. Konten: Reicht Hinweis + Verknüpfen, oder soll das iPad beim Kontowechsel Daten mitnehmen können (+1–2 Tage)?
4. Eigene Dokumente: Speicher je Pro-AI-Konto 2 GB? Hochladen auch über Mobilfunk erlaubt?
5. Community: alte iCloud-Beiträge übernehmen (Vorschlag) oder neu anfangen?
