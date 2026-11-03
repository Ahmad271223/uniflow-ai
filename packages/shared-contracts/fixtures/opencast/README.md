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
| `media-index-paged.html`, `media-index-page2.html`, `media-index-series-b.html` | 200 | Liste mit Seitenzahlen und Reiter „Serie B“ (Aufbau angenommen, 03.11.2026): der Abruf folgt Links desselben Kurses unter `plugins.php/opencastpluginluh/` (ohne Player, Upload, anderen Kurs) und zählt jedes Video einmal |
| `media-index-embedded.html` | 200 | Seite ohne `table.media-table`: `<video>` mit `<source>`, Videoliste als JSON im `<script>` (Aufbau der API des Plugins V3) und Player-`<iframe>` des Plugins V3 auf dem Stud.IP-Host; fremder iframe zählt nicht |
| `v3-course-videos.json` | 200 | Antwort des Opencast-Plugins V3 `plugins.php/opencastv3/api/courses/{id}/videos` (`{videos, count}`, Felder nach lib/Models/Videos.php): Kamera- und Folienfassungen, Audio zählt nicht, http-Fassung und Papierkorb fallen weg |
| `courseware-media-blocks.json` | 200 | Container einer Courseware-Seite mit Blöcken (`include=blocks`): Video aus Stud.IP-Datei und von YouTube, Link auf Vimeo (zählt) und auf eine Institutsseite (zählt nicht), iframe, Embed, Audio mit und ohne Datei, Opencast-Block des Plugins V3, Video als mp4-Adresse, leerer Video-Block |

Dazu lesen `OpencastSourcesTests` (Kern) und `RecordingSourcesAppTests` (App) Videodateien aus dem Dateibaum (JSON:API `file-refs`,
erfundene Antworten in den Tests) und Links auf Videoplattformen aus Beschreibung und Sonstiges eines Kurses.
