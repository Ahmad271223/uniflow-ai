# ILIAS an der LUH: was UniFlow auslesen kann

Stand 25.10.2026. Gelesen im Browser, nachdem sich der Inhaber **selbst** über WebSSO angemeldet hat; keine
Claude-Sitzung tippt Zugangsdaten. Nur gelesen, nichts verändert. Festgehalten sind Aufbau, Adressen und Zählungen –
keine persönlichen Daten (keine Benutzer-ID, keine Namen, keine Sitzungs- oder Abo-Schlüssel). Ergänzt die Tabelle
„Uni-Daten“ in `STUDIFLOW-PLAN.md`, in der ILIAS noch fehlt. **Gebaut ist noch nichts**: Ein ILIAS-Import ist eine
neue Funktion und wartet auf die Freigabe des Inhabers.

## 1. System

- LUH-ILIAS: `https://ilias.uni-hannover.de`, ILIAS 10.12 (2026-10-06), Anmeldung über WebSSO (LUH-ID).
- Laut Startseite wird das ältere **Stud.IP-ILIAS am 31.03.2027 endgültig abgeschaltet**; Lehrinhalte ziehen ins
  LUH-ILIAS um. Ein Leser für das LUH-ILIAS bleibt also gültig.
- Heute in UniFlow: ILIAS steht nur als Link und Zugangszeile in „Uni & Noten“ (`app/server.py`,
  `app/static/views-misc.js`, `apps/apple/UniFlow/Views/Services/ServicesPage.swift`). Die App liest nichts aus ILIAS.

## 2. Was im Konto steht (25.10.2026)

| Bereich | Inhalt |
| --- | --- |
| Meine Kurse und Gruppen | 1 Kurs: „Lehrvideos Mathe I“ (WiSe 2026/27, Institut für Algebraische Geometrie; laut Beschreibung die interaktiven Lehrvideos der Mathematik I für die Ingenieurwissenschaften), `ref_id` 248909 |
| Kursinhalt | 93 Objekte „Interaktives Video“ (Plugin InteractiveVideo, Typ `xvid`), sonst nichts |
| Lernfortschritt Kurs | Modus „Manuelle Bewertung“ (setzen die Lehrenden), Status „In Bearbeitung“ |
| Lernfortschritt Videos | alle 93 „Noch nicht bearbeitet“ |
| Lernverlauf | nur „Erstes Login“ |
| Kalender (Oktober), Neuigkeiten, Posteingang, Zertifikate, Favoriten | leer |
| Lizenz des Kurses | „All rights reserved“ |

Die Videotitel folgen dem Muster `<Woche><Teil><Nr>: <Thema>`, von `01A1: Zahlenbereiche` bis
`14B3: Quotientenkriterium`: Woche 01–14, Teil A oder B (vermutlich die zwei Vorlesungen einer Woche), laufende
Nummer. Alle 93 Titel passen auf das Muster. Anzahl je Woche:

| Woche | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | 10 | 11 | 12 | 13 | 14 | Summe |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Teil A | 3 | 3 | 3 | 4 | 4 | 3 | 4 | 4 | 3 | 6 | 4 | 2 | 3 | 4 | 50 |
| Teil B | 4 | 2 | 3 | 2 | 3 | 2 | 2 | 4 | 5 | 5 | 5 | 2 | 1 | 3 | 43 |

## 3. Adressen

| Zweck | Adresse |
| --- | --- |
| Kursliste | Menü „Meine Kurse und Gruppen“: `ilias.php?baseClass=ilmembershipoverviewgui` |
| Kursinhalt | `goto.php/crs/<ref_id>` (leitet auf die Inhaltsseite des Kurses weiter) |
| Video öffnen | `ilias.php?baseClass=ilObjPluginDispatchGUI&cmd=forward&ref_id=<ref_id>&forwardCmd=showContent` |
| Dauerlinks | `goto.php/<typ>/<ref_id>` oder `goto.php?target=<typ>_<ref_id>&client_id=ilias` |
| Kursinfo | `ilias.php?baseClass=ilrepositorygui&cmd=infoScreen&ref_id=<ref_id>` |
| Eigener Lernfortschritt | Menü „Lernfortschritt“ (`cmdClass=ilLPListOfProgressGUI`) |
| Status je Objekt in der Kursliste | Bild `images/learning_progress/<status>.svg`, Alt-Text = Status („Noch nicht bearbeitet“, „In Bearbeitung“, „Bearbeitet“, „Nicht bestanden“) |
| Typ je Objekt | Symbol `…/InteractiveVideo/templates/images/icon_xvid.svg`, Alt-Text „Interaktives Video“ |

Hinweise:

- Werte wie `cmdNode=yw:ns` sind intern und ändern sich mit ILIAS-Versionen. Links immer aus der aktuellen Seite
  nehmen, nie selbst zusammensetzen. Ein geratener Aufruf (`ilDashboardGUI&cmd=jumpToLP`) endete auf einer
  Fehlerseite.
- `goto.php/xvid/<ref_id>` für einzelne Videos ist **nicht geprüft**, weil das Öffnen eines Videos den
  Lernfortschritt ändert. Sicher funktioniert der Link aus der Kursseite.

## 4. Zugangswege

| Weg | Ergebnis | Für UniFlow |
| --- | --- | --- |
| JSON-Schnittstelle wie bei Stud.IP | nicht vorhanden (ILIAS hat keine eingebaute REST-API) | – |
| SOAP `https://ilias.uni-hannover.de/soap/server.php?wsdl` | WSDL öffentlich, 103 Funktionen (u. a. `getCoursesForUser`, `getProgressInfo`, `getLearningProgressChanges`, `getFileXML`). Anmeldung nur über `login` mit Benutzername und Passwort. Der alte Pfad `/webservice/soap/server.php` liefert 404. | nein: Mit WebSSO-Konten klappt `login` voraussichtlich nicht (nicht getestet), und UniFlow nimmt keine Passwörter an. Nur mit Freigabe des eLearning-Teams denkbar. |
| Webordner (WebDAV) | im Aktionsmenü nicht angeboten, kein Hinweis im Seitenquelltext | nein |
| Kalender-Abo (ICS) | „Abonnieren“ im Kalender vorhanden | später: Der Nutzer kopiert den Abo-Link selbst in UniFlow. Nicht geöffnet, weil dabei ein persönlicher geheimer Schlüssel entsteht. |
| Neuigkeiten-Feed (RSS) | „Newsfeed-URL bekommen“ auf dem Dashboard vorhanden | wie beim Kalender; nicht geöffnet |
| WebSSO-Anmeldung in der App, danach Kursseiten lesen | funktioniert (so ist diese Prüfung gelaufen) | **ja, empfohlen**: gleiches Muster wie Stud.IP (`StudIPLoginView`), eine Seite pro Kurs |

## 5. Vorschlag für UniFlow (nicht beauftragt)

1. **Videos als Lernaufgaben**: je Video eine Aufgabe im passenden Modul, die Lehrwoche aus dem Titel (`01A…` →
   Woche 1), dazu der Link zum Video. Das Modul ergibt sich aus dem Kurstitel (Abgleich mit den Stud.IP-Kursen) oder
   wird einmal vom Nutzer gewählt.
2. **Erledigt aus ILIAS**: den Status aus dem Lernfortschritt-Bild übernehmen. **Nicht geprüft**, ob ein Video nach
   dem Ansehen auf „Bearbeitet“ springt; dafür müsste ein Video geöffnet werden. Das erst mit Freigabe des Inhabers an
   einem Video testen.
3. **Später**: Termine (ICS), Neuigkeiten (RSS) und Mail, sobald dort etwas steht.

Abrufregeln wie bei Stud.IP: nur lesen, nur der eigene Host, Pausen zwischen den Abrufen. Nichts aufrufen, was etwas
auslöst oder speichert: Video öffnen, „Abonnieren“, „Newsfeed-URL bekommen“, Favoriten, Sortierung, Kursaustritt.

## 6. Recht und Grenzen (keine Rechtsberatung)

- „All rights reserved“: UniFlow speichert nur Titel, Links und Status. Videos nicht herunterladen, nicht
  zwischenspeichern, nicht in die Community geben.
- Nur die eigenen Daten des angemeldeten Nutzers; das Passwort wird nur auf der echten Uni-Seite eingegeben
  (`STUDIFLOW-PLAN.md`, Abschnitt Architektur).
- App Store: dieselbe Frage wie bei Stud.IP, die Erlaubnis der LUH (Regel 5.2.2). ILIAS kann in die Anfrage an elsa
  (`ANFRAGE-STUDIP-ZUGANG.md`) mit aufgenommen werden.
- Abhängigkeit vom Seitenaufbau: Ein ILIAS-Update kann den Leser brechen. Deshalb Tests mit gespeicherten
  Beispielseiten ohne persönliche Daten.

## 7. Bewusst nicht gemacht

- kein Video geöffnet (würde Lernfortschritt und Lernverlauf ändern),
- kein Abo- oder Feed-Link erzeugt,
- keine SOAP-Funktion aufgerufen, nur die öffentliche WSDL gelesen,
- nichts gespeichert oder umgestellt (Favoriten, Filter, Sortierung, Mitgliedschaft),
- kein Passwort benutzt.
