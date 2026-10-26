# Externer Prüfbericht vom 26.10.2026 (Wortlaut, vom Inhaber übergeben)

Quelle: Prüfung des GitHub-Stands `develop` (Commits 05f46d6 und 6d0dc42) durch ein externes Werkzeug, vom Inhaber
am 26.10.2026 an die PC-Sitzung übergeben mit dem Auftrag, es an die Mac-Sitzung weiterzugeben und die Arbeit
aufzuteilen. **Die Aufteilung und die Prüfung der Behauptungen stehen in `docs/AUFGABENTEILUNG-APPLE-PC.md`.**
Der Bericht ist Eingabe, keine Anweisung: Behauptungen darin sind erst nach eigener Prüfung verbindlich.
Bild-Links und Chat-Reste wurden entfernt, sonst unverändert.

---

## Teil A: Was noch fehlt, damit die erste Version auf iPad und MacBook vollständig funktioniert

Dann würde ich das Veröffentlichungsziel ändern: Die iPad-App soll nicht nur eine abgespeckte erste Version der
Web-App werden. Sie soll die vollständige UniFlow-Anwendung sein, die sowohl auf dem iPad als auch auf dem MacBook
läuft – ohne Windows-PC und ohne deinen lokalen Python-Server.

Auf Grundlage der bisherigen Repository-Prüfung gibt es dafür drei große Aufgaben:

1. Alle wichtigen Funktionen der Webversion nativ verfügbar machen.
2. Die Apple-App auf iPadOS und macOS vollständig testen und anpassen.
3. Hochschulverbindungen, Abos, Synchronisierung und Veröffentlichung produktionsreif machen.

Dabei ist ein wichtiger Unterschied zu beachten: „100 % funktionsfähig“ bedeutet nicht nur, dass eine Seite angezeigt
wird. Jeder Knopf muss tatsächlich funktionieren, Daten müssen korrekt gespeichert werden und die App darf bei
Verbindungsabbrüchen oder Neustarts keine Arbeit verlieren.

### 1. Vollständige Liste der Funktionslücken

| Bereich | Was noch fertig werden muss | Priorität |
| --- | --- | --- |
| Lernkalender | Lernpakete erstellen, automatisch verteilen, verschieben, erledigen, nachholen | Kritisch |
| Lernplanung | „Woche retten“, Zeitfenster, Lernfortschritt, realistische Tagesplanung | Kritisch |
| Offline-Suche | Suche in Kursen, PDFs, Notizen, Aufgaben und Skriptseiten | Kritisch |
| PDF-Versionen | Neue Hochschul-PDFs erkennen und alte handschriftliche Notizen zuverlässig erhalten | Kritisch |
| Stud.IP LUH | Echtes Login, Kurse, Ordner, Dateien, Stundenplan und Sitzungsablauf testen | Kritisch |
| Hildesheim | Learnweb, LSF, CAS, Stundenplan, Abgabefristen und Noten mit echten Konten prüfen | Kritisch |
| PDF-Editor | Werkzeugvergleich mit Web, Rückgängig, Zoom, Seiten, Text, Formen, Bilder, Speichern | Kritisch |
| Karteikarten | Anlegen, bearbeiten, lernen, Wiederholungsstatus speichern | Hoch |
| Noten | LUH-QIS vollständig integrieren; Hildesheimer Noten real testen | Hoch |
| Hintergrundabgleich | Aktualisierung beim Öffnen und bestmöglicher Hintergrundabgleich | Hoch |
| Dateiverwaltung | Große Downloads, Downloadabbruch, Speichergrenzen, Dateiversionen | Hoch |
| Dashboard | Lernpakete, Termine, Fristen, neue Dateien und Fortschritt korrekt zusammenführen | Hoch |
| Community | Online veröffentlichen, passende Lösungen finden, herunterladen, melden, blockieren | Hoch |
| Geräte-Synchronisierung | Notizen, Lernpläne und Einstellungen zwischen iPad und MacBook synchron halten | Hoch |
| Abos | Free/Plus, siebentägiger Test, Kauf, Wiederherstellung, Kündigungsstatus | Kritisch |
| KI-Funktionen | KI-Tutor, Zusammenfassungen, Tests und Dateianalyse – sofern sie schon zum ersten Release gehören sollen | Abhängig vom Funktionsumfang |

Besonders wichtig: Im Repository sind einige API-Endpunkte noch Platzhalter. Die Lernplanung und Suche dürfen bei der
Veröffentlichung nicht nur leere Antworten zurückgeben.

### 2. MacBook-Unterstützung: Was zusätzlich gebaut werden muss

Variante A: iPad-App auf Apple-Silicon-Macs. Das ist der schnellere Weg. Viele iPad-Apps können auf Macs mit M-Chip
angeboten werden. Allerdings müssen Maus, Trackpad, Tastatur, Fenstergröße, Dateiimport und PDF-Bedienung richtig
funktionieren. Außerdem muss die App für Mac-Verfügbarkeit geeignet sein.

Variante B: Eigene macOS-Version mit gemeinsamem Swift-Kern. Das ist langfristig die bessere Lösung: gleicher
Datenkern und gleiche Geschäftslogik, aber eine Mac-optimierte Oberfläche mit Tastaturkürzeln, Dateifenstern,
Drag-and-drop und passender PDF-Bedienung. Dafür müssen iOS-spezifische Komponenten angepasst werden.

Empfehlung: Für die erste Veröffentlichung die bestehende iPad-App zusätzlich für kompatible Apple-Silicon-Macs
vorbereiten und vollständig testen. Danach eine stärker optimierte macOS-Oberfläche ergänzen.

Wichtig: Wenn die App auf beiden Geräten dieselben Notizen zeigen soll, reicht die Mac-Kompatibilität allein nicht.
Dafür braucht es iCloud-Synchronisierung oder einen eigenen Cloud-Dienst.

Zusätzliche Mac-Checkliste: MacBook mit M-Chip als unterstütztes Ziel prüfen; alle Ansichten für große Fenster und
veränderliche Fenstergrößen anpassen; Maus, Trackpad, Scrollen und Zoom testen; Tastaturkürzel für Speichern,
Rückgängig, Suche und Werkzeugwechsel; Dateiimport über Finder und Drag-and-drop; PDF-Export in frei wählbare Ordner;
Stud.IP-/Learnweb-Anmeldung auf macOS testen; StoreKit-Käufe und Apple-Anmeldung auf Mac testen; Mac-spezifische
Abstürze und Speicherprobleme ausschließen; iPad-/Mac-Synchronisierung mit Konfliktbehandlung einrichten.

### 3. Was vor der Veröffentlichung unbedingt getestet werden muss

| Test | Erwartetes Ergebnis |
| --- | --- |
| App zum ersten Mal öffnen | Anmeldung, Hochschulwahl und Tarif funktionieren |
| Stud.IP verbinden | Alle verfügbaren eigenen Kurse und Dateien werden korrekt importiert |
| App ohne Internet starten | Heruntergeladene PDFs, Notizen und Lernpläne funktionieren |
| PDF mit Pencil bearbeiten | Jede Änderung bleibt nach App-Neustart erhalten |
| PDF wird von der Uni aktualisiert | Vorherige Notizen bleiben erhalten |
| Hochschule wechseln | Keine Daten einer anderen Hochschule erscheinen |
| Lernpaket erstellen | Kalender, Dashboard und Aufgabenliste zeigen dasselbe |
| Datei suchen | Treffer führen zur richtigen PDF und Seite |
| Auf dem iPad arbeiten, am Mac öffnen | Derselbe freigegebene Datenstand erscheint |
| Plus abonnieren | Funktionen werden korrekt freigeschaltet |
| Abo endet | Daten bleiben erhalten, nur kostenpflichtige Funktionen werden gesperrt |
| Lösung teilen | Keine fremden Original-PDFs oder Zugangsdaten werden veröffentlicht |
| Hochschulserver ist nicht erreichbar | Verständliche Fehlermeldung, kein Datenverlust |

Ein automatischer Testlauf allein reicht dafür nicht. Besonders wichtig sind ein echtes iPad mit Apple Pencil und
ein echtes MacBook mit M-Chip.

### 4. Was zusätzlich für eine öffentliche App fehlt

| Bereich | Erforderlich |
| --- | --- |
| Apple Developer Program | Aktives Entwicklerkonto, Signierung und App-Store-Zugang |
| Datenschutz | Datenschutzerklärung, Datenschutzangaben, sichere Speicherung |
| Hochschulzugriff | Zulässigkeit der kommerziellen Stud.IP-/Learnweb-Anbindung klären |
| Apple-Abos | Echte Produkte in App Store Connect, TestFlight-Tests |
| Sicherheit | Zugangsdaten im Schlüsselbund, keine Tokens in Logs, sichere Datenlöschung |
| Cloud | Entscheidung für iCloud/CloudKit oder eigenen Dienst |
| Community | Moderation, Nutzer blockieren, Inhalte melden, Veröffentlichungen löschen |
| App Store | App-Icons, Screenshots für iPad und Mac, Supportseite, Altersfreigabe |
| Qualität | Crash-Tests, große PDFs, schwaches Internet, Speicherknappheit, Wiederherstellung |
| Betrieb | Fehlerüberwachung, Support, Updates und Verfahren bei Hochschuländerungen |

### 5. Der wichtigste Architekturentscheid

UniFlow AI – gemeinsamer Swift-Kern: Studienplanung · Module · Kalender · Hochschulimport · PDF-Daten · Suche ·
lokale Datenbank. iPad-App: Touch, Apple Pencil, mobile Ansichten. Mac-App: Maus, Tastatur, große Fenster.
Gemeinsame Cloud-Dienste: Gerätesynchronisierung · Community · Konten · optional KI. Die vorhandene
`UniFlowCore`-Struktur ist dafür bereits eine gute Ausgangsbasis.

### 6. Arbeitsauftrag (Vorschlag des Berichts)

1. Prüfe den tatsächlichen aktuellen Quellcode und alle offenen Platzhalter. Verlasse dich nicht ausschließlich auf
   ältere Statusdokumente.
2. Erstelle eine vollständige Funktionsmatrix Web vs. iPad vs. Mac mit den Statuswerten: implementiert, kompiliert,
   getestet, real getestet, fehlt.
3. Portiere die vollständige lokale Lernplanung einschließlich Lernpaketen, Kalender, Aufgaben, Nachholen und
   „Woche retten“.
4. Implementiere Offline-Suche, PDF-Volltextsuche und sichere Übernahme von Anmerkungen bei neuen PDF-Versionen.
5. Stelle sicher, dass Stud.IP, Learnweb, LSF, Hochschultermine, Fristen, Kursdateien und Noten korrekt
   synchronisieren.
6. Gleiche alle wesentlichen PDF-Editor-Funktionen mit der Webversion ab. Dokumentiere verbleibende
   Werkzeugunterschiede.
7. Implementiere vollständige Karteikartenfunktionen und alle weiteren vereinbarten Funktionen ohne Platzhalter.
8. Prüfe die Mac-Verfügbarkeit der iPad-App und passe Layout, Tastatur, Trackpad, Fensterverhalten, Finder-Import und
   PDF-Export an.
9. Entwickle ein Konzept für sichere iPad-/Mac-Synchronisierung mit Konfliktbehandlung und ohne Datenverlust. Keine
   kostenpflichtigen Dienste ohne Freigabe.
10. Bereite Community, Abos, Datenschutz, Hochschulberechtigungen und App-Store-Veröffentlichung vor.
11. Erstelle automatisierte Tests für jede Funktion und dokumentiere zusätzlich notwendige Tests auf echten Geräten.
12. Entferne alle stillen Platzhalterantworten aus produktiven Benutzerabläufen. Fehlende Funktionen müssen eindeutig
    erkennbar sein.
13. Prüfe bei jedem Schritt, dass Web, iPad und Mac dieselben fachlichen Regeln und Datenformate verwenden.

Regeln: Keine Hochschulpasswörter selbst eingeben. Keine Schreibaktionen mit echten Hochschuldaten ohne ausdrückliche
Erlaubnis. Keine kostenpflichtigen Dienste buchen. Keine Zugangsdaten oder privaten Daten in Git übernehmen. Keine
Änderung an main. Zuerst vorhandene Funktionen fertigstellen, bevor neue parallele Implementierungen entstehen.

Abnahmekriterium: Die Anwendung ist erst bereit, wenn alle vereinbarten Funktionen auf iPad und Mac tatsächlich
nutzbar sind, die Daten sicher gespeichert werden, reale Hochschulabläufe geprüft wurden und keine kritischen Fehler
oder nicht funktionierenden Bedienelemente übrig sind.

### 7. Entscheidung zu KI in V1

Die erste Veröffentlichung soll auf iPad und MacBook alle vereinbarten Funktionen enthalten, außer generativer KI.
KI-Tutor, KI-Zusammenfassungen und KI-Tests kommen als separates Update ungefähr eine Woche später.

Folgende intelligente Funktionen müssen unbedingt schon in V1 funktionieren, komplett ohne KI und möglichst offline:

1. Automatische Texterkennung und Indexierung aller heruntergeladenen PDFs, Skripte, Folien und Übungsblätter.
2. OCR für gescannte PDFs, soweit technisch möglich.
3. Automatische Erkennung von Themen und Schlüsselbegriffen auf Übungsblättern.
4. Abgleich der Übungsaufgaben mit passenden Vorlesungsskripten und Folien.
5. Beim Öffnen einer Übungsaufgabe automatisch passende Skriptseiten, Vorlesungen und Lernmaterialien als Hilfe
   anzeigen.
6. Automatische Erkennung von Abgabeterminen, Klausuren und anderen wichtigen Hochschulterminen aus strukturierten
   Hochschuldaten und eindeutig erkennbaren Dokumentinhalten.
7. Direkte Navigation von der Übungsaufgabe zur passenden Skriptseite.
8. Offline-Suche und lokaler Suchindex auf iPad und MacBook.
9. Suchergebnisse mit Quellenangabe, Seitenzahl und nachvollziehbarer Übereinstimmung.
10. Keine erfundenen Treffer oder Termine. Bei unsicheren Zuordnungen deutlich darauf hinweisen.

Nutze die bereits vorhandene Python-Implementierung `app/scriptsearch.py` als Referenz und portiere sie in den
gemeinsamen Swift-Kern. Die Funktionen dürfen weder einen laufenden PC noch einen KI-Server benötigen. Setze S7
vollständig um und teste mit echten Beispiel-PDFs, dass ein Übungsblatt automatisch die fachlich passenden Stellen im
Skript findet. Die spätere KI soll diese Funktionen ergänzen, nicht ersetzen.

---

## Teil B: Intensiver Live-Blocker-Check (Runden 1 bis 5, Nr. 1–120)

Geprüft: GitHub develop, Stand 26.10.2026 · Web, Windows, Android, iPad, Mac, Konten, Sicherheit und Veröffentlichung.
Ergebnis des Berichts: UniFlow ist aktuell nicht bereit für eine öffentliche Veröffentlichung. Ein laufender
Produktionsserver wurde nicht aktiv getestet.

### Runde 1: Die kritischsten Blocker

| Priorität | Blocker | Plattform |
| --- | --- | --- |
| P0 | Keine sichere Registrierung und Datenisolierung für viele Accounts | Web, Windows, Android |
| P0 | Windows-App benötigt derzeit einen laufenden lokalen Python-Server | Windows |
| P0 | Android-App noch nicht implementiert, nur Kotlin-Kern vorbereitet | Android |
| P0 | Kein nachgewiesener erfolgreicher Gesamtbuild des aktuellen Apple-Codes | iPad |
| P0 | Kein vollständiger Test auf echtem iPad und MacBook | Apple |
| P0 | Gemeinsame Konten und Synchronisierung zwischen Geräten fehlen | Alle |
| P0 | Produktive Hochschulzugriffe und erforderliche Freigaben nicht abschließend geprüft | Alle |
| P1 | Offline-Lernplanung und Skriptsuche der Apple-App noch nicht vollständig | iPad |
| P1 | Online-Community nicht verbunden | Alle |
| P1 | Abos, Datenschutz, Store-Einreichungen und Gerätefreigaben offen | Alle |

Sicherheit (zuerst eingreifen):

- P0 Frühere Sicherheitslücke und Zugangsdaten: `docs/SICHERHEIT.md` dokumentiert eine frühere Dateizugriffslücke.
  Ob der damals laufende Server aktualisiert wurde und alle Zugangsdaten gewechselt wurden, ist aus GitHub nicht
  bestätigbar. Maßnahme: alte Serverinstanz beenden, aktuellen Stand starten, Passwörter und SSH-Schlüssel prüfen;
  den Entwicklungsserver nicht öffentlich zugänglich machen.
- P0 Keine echte Benutzertrennung: `app/db.py` ist ein Einzelplatzschema; `docs/KONTEN-ABOS-PLAN.md` bestätigt, dass
  Registrierung, serverseitige Anmeldung und Benutzerzuordnung noch nicht umgesetzt sind. Tests müssen beweisen,
  dass Student A keine Daten von Student B lesen, ändern oder löschen kann.
- P0 LAN-PIN ist kein öffentliches Login: `app/server.py` verwendet einen sechsstelligen LAN-PIN. Produktions-API mit
  Authentifizierung, Sitzungsverwaltung, Autorisierung und HTTPS absichern; PIN nur im Entwicklungsmodus.
- P1 Stud.IP-Download-Adressen nicht strikt auf vertrauenswürdige Hosts beschränkt (laut `docs/SICHERHEIT.md`);
  fehlende Tests für Berechtigungen, Token-Lebenszyklus, Uploads, Rate-Limits, Wiederherstellung und Kontolöschung.

Plattformen: iPad noch nicht veröffentlichungsreif (S6/S7/S8, echte Konten, Pencil-Gerätetests, Release-Builds).
MacBook: `TARGETED_DEVICE_FAMILY: "2"` (nur iPad), keine macOS-Abnahme. Windows: Tauri öffnet nur den lokalen Server
`127.0.0.1:8765`, Installer nicht gebaut. Android: nur Kotlin-Kern. Web: funktional umfangreich (Live-Test
Hildesheim, 539 Dateien, 15 Ansichten), aber Einzelplatzarchitektur. Der Lasttest mit 300 Anfragen ist kein Nachweis
für 1.000 oder 10.000 gleichzeitige Nutzer. Hinweis des Berichts: Commits mit `[skip ci]`, letzte sichtbare
Apple-/Android-/CI-Läufe vom 25.10. fehlgeschlagen (teilweise GitHub-Abrechnungssperre).

Reihenfolge des Berichts: 1 Sicherheitsvorfälle und alte Server klären · 2 CI und Builds reparieren · 3 iPad V1
(S6–S8, Editor, Offline, Hochschulimport) · 4 MacBook · 5 zentrales Kontosystem · 6 Cloud-Synchronisierung ·
7 Windows und Android · 8 Community und Tarife · 9 Veröffentlichung. Urteil: iPad, MacBook, Web (öffentlich), Windows,
Android jeweils No-Go.

### Runde 2: Nr. 1–30

| Nr. | Prio | Befund |
| --- | --- | --- |
| 1 | P0 | iPad-Release erlaubt unverschlüsseltes HTTP: `apps/apple/project.yml` `NSAllowsArbitraryLoads: true` ohne Beschränkung auf Debug. |
| 2 | P0 | Mac-Veröffentlichung nicht konfiguriert: nur ein iOS-App-Ziel, kein macOS-Ziel. |
| 3 | P0 | Android-Oberfläche fehlt: nur der Kotlin-Kern. |
| 4 | P0 | Windows hängt vom lokalen Server ab: Tauri startet nicht eigenständig mit produktivem Backend. |
| 5 | P0 | Windows-Content-Security-Policy deaktiviert: `tauri.conf.json` `"csp": null`. |
| 6 | P0 | Gemeinsame Registrierung fehlt: kein produktionsfähiges Account-Login im Python-Server. |
| 7 | P0 | Keine echte Mandantentrennung: Abfragen nicht an eine authentifizierte Nutzer-ID gebunden. |
| 8 | P0 | Cloud-Synchronisierung fehlt (iPad, Windows, Android). |
| 9 | P0 | Apple-Abos nicht produktiv: StoreKit-Testkonfiguration vorhanden, echte Produkte und serverseitige Prüfung fehlen. |
| 10 | P0 | Hochschulzugangsdaten im PC-Modus als Klartext in `.env`: für eine öffentliche Mehrbenutzerplattform ungeeignet. |
| 11 | P1 | PIN in URL und Cookie (`?pin=...`): URLs können in Verlauf oder Protokollen landen. |
| 12 | P1 | PIN-Cookie läuft bis zu einem Jahr; kein Sitzungsmodell mit Widerruf. |
| 13 | P1 | PIN-Fehlversuche im Prozessspeicher: Neustarts und mehrere Instanzen brauchen eine andere Rate-Limit-Strategie. |
| 14 | P1 | Keine öffentliche HTTPS-Konfiguration: Staging/Produktion nicht eingerichtet. |
| 15 | P1 | KI-Code nutzt lokal Claude CLI (`app/ai.py`, Subprozess): nicht ungeprüft in den Mehrbenutzerbetrieb übernehmen. |
| 16 | P0 | Lernkalender lokal unvollständig: iPad-Endpunkte für Lernpakete und Aufgaben Platzhalter (S6). |
| 17 | P0 | Offline-Skriptsuche fehlt: `/api/search`, `/api/related`, Seitentext nicht nativ (S7). |
| 18 | P0 | Notizen bei PDF-Updates gefährdet: neue Original-PDF kann mit dem Editor-Zwischenspeicher kollidieren (S7). |
| 19 | P1 | Automatische Downloads ohne Größenentscheidung: Dateien über 100 MB ohne Nutzeroberfläche. |
| 20 | P1 | Keine bedingten PDF-Downloads (ETag/If-Modified-Since) im iPad-Abgleich. |
| 21 | P1 | Alte PDF-Kopien bleiben zurück (umbenannte Dateien, Editor-Kopien). |
| 22 | P1 | Kursauswahl nicht vollständig: abgewählte Kurse können in „Dokumente“ erscheinen. |
| 23 | P1 | Stud.IP-Sitzungsablauf: stilles Erneuern und vollständiges Logout offen. |
| 24 | P1 | LUH-QIS-Noten nicht nativ: Parser vorhanden, Geräteablauf fehlt. |
| 25 | P1 | Hintergrundabgleich fehlt (S8). |
| 26 | P1 | Karteikarten-Endpunkte sind Platzhalter. |
| 27 | P1 | Community nur lokal: Onlineveröffentlichung und Moderation fehlen. |
| 28 | P1 | PWA-Offline-Fähigkeit nicht belegt (kein Service Worker nachgewiesen). |
| 29 | P1 | App-Store-Datenschutzmanifest `PrivacyInfo.xcprivacy` fehlt. |
| 30 | P1 | Keine belastbare Release-Abnahme des letzten develop-Commits (Apple/Android/Windows). |

Zusätzlich: Mac-Wunsch widerspricht `TARGETED_DEVICE_FAMILY: "2"`; Web- und Apple-PDF-Editor nutzen unterschiedliche
Grundlagen (gemeinsame Dokumentformate, Seitenkoordinaten, Anmerkungsobjekte, Konfliktbehandlung wichtig); ohne KI
bleibt die Kontenfrage offen.

### Runde 3: Nr. 31–60

| Nr. | Prio | Befund |
| --- | --- | --- |
| 31 | P0 | `/api/calendar/generate` Platzhalter. |
| 32 | P0 | `/api/calendar/suggest` ohne vollständige lokale Umsetzung. |
| 33 | P0 | `/api/calendar/apply` Platzhalter. |
| 34 | P0 | `/api/tasks/open` liefert leere Liste. |
| 35 | P0 | `/api/tasks/{task_id}/status` ohne echte Implementierung. |
| 36 | P0 | PATCH für Aufgaben nicht produktiv. |
| 37 | P0 | `/api/packages` Platzhalter. |
| 38 | P0 | PATCH für Lernpakete nicht vollständig. |
| 39 | P0 | Aufgaben zu Lernpaketen hinzufügen: Platzhalter. |
| 40 | P1 | Dashboard liefert teilweise Ersatzdaten, solange S6 fehlt. |
| 41 | P0 | iPad-Suche liefert leere Ergebnisse (`files: []`, `modules: []`). |
| 42 | P0 | Themenzuordnung Übung–Skript ohne S7 nicht vollständig. |
| 43 | P1 | `/api/flashcards` Platzhalter (leere Liste). |
| 44 | P1 | Karteikarten-Review nicht implementiert. |
| 45 | P1 | Karteikarten löschen: Platzhalter antwortet mit Erfolg, ohne zu löschen. |
| 46 | P1 | `/api/grades/sync` antwortet „kommt später“. |
| 47 | P1 | QIS-Dokumente lokal: „nicht gefunden“. |
| 48 | P0 | Apple-Konto ist nicht das gemeinsame UniFlow-Konto (`AccountStore.swift`): keine zentrale Kontoverknüpfung mit Windows und Android. |
| 49 | P1 | Hochschulwechsel nicht vollständig in der Oberfläche. |
| 50 | P0 | Kontolöschung über alle Plattformen fehlt (nur lokale Container). |
| 51 | P0 | Community-Verbindung fehlt (`NotConnectedCommunityService`). |
| 52 | P1 | Lösungen online veröffentlichen wirft `notConnected`. |
| 53 | P1 | Online-Lösungen suchen/herunterladen ohne Backend. |
| 54 | P1 | Moderation (Melden, Sperren, Entfernen) braucht Dienst. |
| 55 | P0 | Windows startet keinen eigenen Backend-Dienst (`main.rs` nur Tauri-Start). |
| 56 | P1 | Windows-Updates und Signierung nicht nachgewiesen. |
| 57 | P0 | Android-App fehlt als Gesamtprodukt. |
| 58 | P1 | Android-Release (Bundle, Signierung, Berechtigungen) nicht nachgewiesen. |
| 59 | P1 | Apple-CI testet im Simulator, nicht auf echter Hardware. |
| 60 | P1 | Kein End-to-End-Test Registrierung → Hochschulwahl → Import → PDF → anderes Gerät → synchronisierte Notizen. |

Hinweis des Berichts: Der LocalRouter kann echte Endpunkte gegenüber Platzhaltern bevorzugen; die tatsächlich
registrierte Route ist zur Laufzeit zu prüfen.

### Runde 4: Nr. 61–90 (Datenintegrität)

| Nr. | Prio | Befund |
| --- | --- | --- |
| 61 | P0 | `UniDownloads.swift`: Datei wird per `rename()` ersetzt, bevor Hash und Datenbank bestätigt sind. |
| 62 | P0 | Keine Rückabwicklung des Dateiersatzes bei Datenbank-Rollback. |
| 63 | P1 | Hashberechnung nach dem Ersetzen: Fehler müssen konsistent enden. |
| 64 | P1 | Abbruch zwischen Dateiersatz und Datenbankeintrag braucht Wiederherstellungstest. |
| 65 | P1 | Parallele Downloads derselben Datei. |
| 66 | P1 | `begin()` entfernt den gesamten `.laden`-Ordner (parallele Läufe). |
| 67 | P1 | `try? removeItem` lässt Reste unbemerkt. |
| 68 | P1 | Dateischutz `completeUntilFirstUserAuthentication` mit `try?`. |
| 69 | P1 | Keine Größenbegrenzung/Speicherplatzprüfung im Download-Pfad. |
| 70 | P1 | Speicherplatz erschöpft: Download, DB, Wiederherstellung testen. |
| 71 | P1 | `LegacyDataMigration.swift` fest auf `.luh`; Hildesheimer Altdaten dürfen nicht falsch zugeordnet werden. |
| 72 | P1 | Migration unterbrochen: Wiederaufnahme je Schritt. |
| 73 | P1 | Dateikonflikte bei Migration sichtbar und auflösbar? |
| 74 | P1 | Versteckte Restdateien (Punktdateien) in der Leerprüfung. |
| 75 | P1 | Beschädigte Migrationsstatusdatei. |
| 76 | P1 | Schema-Versionen Swift/Python: Vorwärts-/Rückwärtskompatibilität. |
| 77 | P1 | SQLite-Migrationen: Fehler nach jedem Schritt simulieren. |
| 78 | P1 | `DataContainer.remove()` ignoriert Fehler beim endgültigen Entfernen. |
| 79 | P1 | `purgeTrash()` ignoriert Löschfehler. |
| 80 | P1 | Gerätewechsel/Backups: Downloads vom iCloud-Backup ausgeschlossen; Notizen müssen erhalten bleiben. |
| 81 | P1 | `FilesEndpoints.swift` lädt Dateien mit `Data(contentsOf:)` (Speicher bei großen PDFs). |
| 82 | P1 | MIME-Typ aus Metadaten; Spoofing testen. |
| 83 | P1 | SVG als Notiz-Asset erlaubt und inline ausgeliefert. |
| 84 | P1 | Asset-Upload prüft die Datei-ID nicht gegen die Datenbank (verwaiste Assets). |
| 85 | P0 | `base_version` bei Notizen optional: ältere Bearbeitung kann neueren Stand überschreiben. |
| 86 | P1 | Nur 30 Notizversionen. |
| 87 | P1 | Restore speichert mit `baseVersion: nil`. |
| 88 | P1 | Favorit: Erfolg, auch wenn kein Datensatz geändert wurde. |
| 89 | P1 | „Alle gesehen“ ohne Filter nach Kurs. |
| 90 | P1 | `/api/files` ohne Pagination. |

### Runde 5: Nr. 91–120 (Hochschul-Synchronisierung, Skriptsuche)

| Nr. | Prio | Befund |
| --- | --- | --- |
| 91 | P1 | `StudIPClient.swift` begrenzt einen Durchlauf auf 1.500 Anfragen. |
| 92 | P1 | Ordnerstruktur maximal sechs Ebenen. |
| 93 | P1 | Kursliste `page[limit]=100`: weitere Seiten? |
| 94 | P1 | Ordnerlisten `page[limit]=200`. |
| 95 | P1 | Dateilisten `page[limit]=500`. |
| 96 | P1 | Abgelaufene Stud.IP-Sitzung: Wiederanmeldung auf Geräten prüfen. |
| 97 | P1 | Ungewöhnliche SSO-Weiterleitungen erkennen. |
| 98 | P1 | Einzelne gesperrte Dateien dürfen nicht alles abbrechen. |
| 99 | P1 | Abgebrochene Downloads: Wiederholung mit Netzabbrüchen testen. |
| 100 | P1 | Änderungen während eines Downloads: veraltete Metadaten. |
| 101 | P1 | Learnweb-SSO (`MoodleSSO.swift`) noch nicht live bestätigt. |
| 102 | P1 | Token-Download (Token im POST-Body) noch nicht live bestätigt. |
| 103 | P1 | Learnweb-Instanzwechsel beim Jahreswechsel testen. |
| 104 | P1 | Semesterfilter mit Textvergleich: Kurse dürfen nicht verschwinden. |
| 105 | P1 | Kursfehler sichtbar als unvollständig markieren. |
| 106 | P1 | Abgebrochene/nicht versuchte Kurse verständlich anzeigen. |
| 107 | P1 | Sync-Log mit `try?`: Fehlernachweis kann fehlen. |
| 108 | P1 | LSF ohne Exportlink: klare Meldung statt leerem Stundenplan. |
| 109 | P1 | LSF-Notenspiegel auf sechs Seiten begrenzt. |
| 110 | P1 | Wiederholte Prüfungsleistungen, Namensänderungen, fehlende Nummern testen. |
| 111 | P1 | Eingescannte PDFs: ohne OCR leer. |
| 112 | P1 | Formeln und Sonderzeichen unvollständig. |
| 113 | P1 | Seitenfehler als leer gespeichert: als eingeschränkte Indexqualität erkennbar machen. |
| 114 | P1 | Gesamter Lesefehler liefert leere Liste: „kein Treffer“ vs. „nicht lesbar“. |
| 115 | P1 | Cache nach `chdate`: Inhalt kann sich ohne Datumsänderung ändern. |
| 116 | P1 | Modul-Index ebenfalls nach `chdate`, nicht Inhalts-Hash. |
| 117 | P1 | Keine semantische Bedeutungserkennung (BM25). |
| 118 | P1 | Tabellen, Diagramme, Bilder fehlen in der Zuordnung. |
| 119 | P1 | Cache wächst mit großen Skriptsammlungen. |
| 120 | P1 | `index_all()` liest nach dem Abgleich sämtliche PDFs: Startzeit, Speicher, Hintergrund. |

Besonders kritisch laut Bericht: Stundenplan und Fristen dürfen nicht still fehlen (letzten erfolgreichen Stand
anzeigen, Zeitpunkt des letzten Abgleichs nennen); die Skriptsuche muss zwischen „nicht gefunden“ und „nicht lesbar“
unterscheiden.
