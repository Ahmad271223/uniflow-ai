# Stand der Mac-Sitzung (Abstimmung mit der PC-Sitzung)

Stand 26.10.2026, 02:00. Damit nichts doppelt entsteht: Daran arbeitet die Mac-Sitzung gerade (Zweige nur lokal,
kommen nach vollständiger Prüfung auf `develop`).

| Teil | Stand | Zweig (lokal) |
| --- | --- | --- |
| S3 Stud.IP-Dateien in die lokale Datenbank, Bibliothek, Notizen, Editor offline | fertig, geprüft | `wip/int-s345-fix` |
| S4 Fach, Art, Lehrwoche, Module | fertig, geprüft | `wip/int-s345-fix` |
| S5 Stundenplan aus Stud.IP (Kurszeiten, Einzeltermine, ICS, Gruppenwahl) | fertig, geprüft | `wip/int-s345-fix` |
| S6 Lernlogik (study.py: Pakete, Lernplan, Woche retten, Übersicht) | im Bau | `wip/s6-lernplan-2` |
| Hochschulwahl im ersten Start, Datentrennung je (Apple-Nutzer, Uni), Umzug alter LUH-Daten | gebaut | `wip/hochschulwahl` |
| Zugangsdaten je Uni im Schlüsselbund, Anmeldeseite **nur vorausfüllen** (Entscheidung des Inhabers) | fertig, geprüft | `wip/hochschulen-2-fix` |
| Hildesheim: dünne Schicht über dem Kern der PC-Sitzung (URLSessionUniTransport, Anmeldung LSF/Learnweb-SSO, Ablauf, Uni & Noten) | als Nächstes | – |

Die Mac-Sitzung übernimmt den Hildesheim-Kern der PC-Sitzung (`UniFlowCore/Hildesheim/`) und entfernt ihre eigene
doppelte Fassung. Kurse und Dateien schreiben Stud.IP und Learnweb danach über **eine** gemeinsame Funktion wie
`store_course_files` in Python.

**Bitte an die PC-Sitzung:** bis diese Stände auf `develop` sind, keine Änderungen an `apps/apple/UniFlow/`
(App), `UniFlowCore/LocalBackend/`, `UniFlowCore/Store/` und `UniFlowCore/Hildesheim/`. Python, Web und Doku
bleiben frei; Änderungen an `app/*.py`, die portierte Logik betreffen, zieht die Mac-Sitzung nach.
