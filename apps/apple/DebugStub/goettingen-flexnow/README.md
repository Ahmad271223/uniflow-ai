# Nachbildung FlexNow 2 der Uni Göttingen (nur Debug-Builds und Tests)

Von Hand geschrieben am 27.11.2026, im Aufbau, wie FlexNow 2 am 27.11.2026 im Chrome des Inhabers mit seinem
Testkonto aussah (`~/Studora-Builds/goettingen/STRUKTUR-ECHT-FLEXNOW-2026-11-26.md`, Abschnitt „Zweiter Blick“).
Alle Namen, Kürzel, Daten und Fristen sind **erfunden**. Beschreibung: `docs/GOETTINGEN-FLEXNOW-2026-11-27.md`.

| Datei | Was |
|---|---|
| `flexnow.html` | Anmeldeseite: Formular POST an `/FN2AUTH/FN2AuthServlet?op=Login` mit `kennung`, `kennwort` und den versteckten Feldern `emrexSessionId`, `emrexReUrl` (Namen wie echt). „Login“ führt hier zu `flexnow-angemeldet.html`. |
| `flexnow-angemeldet.html` | Studentenschnittstelle `/FN2SSS/`, Startansicht „Aktuelles“ so, wie sie nach dem Nachladen dasteht: „Neueste Meldungen“, „Neueste Ergebnisse“ (beide leer), „Aktuelle Prüfungen“ mit `ul.class-list` → `div.class-list-head` „Modul: …“ → li → `div.PrfContainerAktuelles` → „Prüfung: <Kürzel>: <Titel> (<Art>)“ → `div.prfangs ul li div.prfangBlock.angemeldet.first` mit `form.prfangFormAktuelles` (versteckte Kennungen, hier `stub1`/`stub2`) und `div.primaryData div.info-inner` (p „WS26/27“, `span.titelBez`, `div.class-list-head.signed`, `span.fristBis` mit b „Abmeldung möglich im Zeitraum:“). Zwei Prüfungen: Vorleistung (Abmeldung bis 10.12.2026, 23:59 Uhr) und Klausur (bis 15.01.2027). |
| `aktuelles-leer.html` | „Aktuelle Prüfungen“ mit „Derzeit sind Sie zu keinen aktuellen Prüfungen angemeldet.“ – **Wortlaut geraten** (am Testkonto war eine Prüfung angemeldet). |
| `aktuelles-unfertig.html` | „Aktuelle Prüfungen“, Liste noch nicht nachgeladen: darf nie als „keine angemeldet“ gelten. |

Nicht nachgebildet, weil nicht gesehen: ein Block ohne Klasse `angemeldet`, ein Prüfungstermin mit Tag und Raum, die
englische Fassung, die Fehlermeldung bei falschem Passwort, der Notenbaum mit Noten.

`flexnow.html` und `flexnow-angemeldet.html` kopiert `tools/build-goettingen-stub.py` zusätzlich in
`DebugStub/goettingen/`, damit für den Simulator ein Ordner reicht:
`-UFUniversity goettingen -UFOnboarding login -UFLoginStub <…>/DebugStub/goettingen`.
