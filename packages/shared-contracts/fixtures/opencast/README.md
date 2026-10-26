# Opencast-Aufzeichnungen (erfundene Seiten)

Nachbau der serverseitig gerenderten Stud.IP-Seite `plugins.php/opencastpluginluh/media/index?cid=<Kurs>` des
LUH-Opencast-Plugins im Aufbau von `docs/QIS-STUDIP-STRUKTUR.md` (Abschnitt Opencast). Alle Werte sind erfunden:
Rechner `*.example.test`, keine echten Kurse, Titel, Namen oder Kennungen. Geprüft von Swift (`OpencastTests` im Kern,
`RecordingsAppTests` in der App): Lesen der Tabelle, Abruf im Stud.IP-Abgleich, Ablage in der lokalen Datenbank,
Ordnung nach Fach und Lehrwoche, Vorschlag zu Dokument und Lernpaket.

| Datei | Antwort | Inhalt |
| --- | --- | --- |
| `media-index-videos.html` | 200 | Tabelle `table.media-table` mit drei Zeilen `tr.media-table-row`: Vorlesung mit 1080p/720p/480p, Zentralübung ohne 1080p und ohne Autor („-“), altes Video aus einem früheren Semester mit kurzer Kennung |
| `media-index-empty.html` | 200 | Reiter vorhanden, `tbody` leer (noch keine Aufzeichnungen) |
| `media-index-no-plugin.html` | 500 | Kurs ohne Reiter: „navigation item '/course/opencast/index' not found“ – heißt „kein Opencast“, kein Fehler |
