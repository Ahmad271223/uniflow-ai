# Externer Prüfbericht, Teil 2 (26.10.2026) – Apple-Runden 8–13 (Nr. 221–570) und Windows/Android (Nr. 571–681)

Wortlaut des externen Prüfers, vom Inhaber am 26.10.2026 übergeben. Zuordnung: **Apple-Punkte 221–570 bearbeitet die
Mac-Sitzung** (Vorgehen in `docs/STAND-MAC-SITZUNG.md`, Nachtrag „Apple-Prüfpunkte 221–570“), **Windows/Android
571–681 die PC-Sitzung** (Ergebnis in `docs/PRUEFPUNKTE-WINDOWS-ANDROID-571-681.md`). Der Prüfer betont selbst: Die
Punkte sind Prüfkandidaten, keine bestätigten Fehler; mehrere Verdachtsfälle sind durch vorhandene Tests widerlegt
(z. B. 381 Pagination, 572 pkdrawing-v2 in Kotlin). Die Nummern 591–652 lagen der PC-Sitzung nicht vor.

Dazu kam vom Inhaber ein Vorschlag „Ausbau der Nicht-Apple-Version“ (Mehrbenutzerplattform, Onboarding, Plattformen,
Produktregeln) – Abgleich mit dem Stand in `docs/PLATTFORM-STAND-2026-10-26.md`.

---

## Apple-Audit Runde 8 (Nr. 221–250) – Prüfstand develop, fbe3e989

### 221–230: StoreKit 2 und Plus-Abonnement

| Nr. | Priorität | Befund |
|---|---|---|
| 221 | P0 | Echte App-Store-Produkte fehlen: PurchaseStore.swift, Zeilen 4–8, dokumentiert, dass Produkte bisher nur in der lokalen StoreKit-Testkonfiguration existieren. Ein echter Plus-Kauf ist so noch nicht freigabefähig. |
| 222 | P1 | Abo nur auf dem Gerät verifiziert: Entitlements.swift, Zeilen 4–7, sieht serverseitige Verifikation erst für V2 vor. Für eine rein lokale V1 ist StoreKit-Verifikation möglich, für gemeinsame Konten reicht das allein nicht. |
| 223 | P1 | Transaktionsaktualisierungen: Der Listener für Transaction.updates muss bei App-Neustart, Verlängerung und Widerruf nachweislich zuverlässig laufen. |
| 224 | P1 | Unverifizierte Transaktionen: Entitlements.handle() lehnt sie ab. Zu prüfen ist, ob Nutzer verständlich erfahren, weshalb keine Freischaltung erfolgt. |
| 225 | P1 | Kauf mit Elternfreigabe: Der Zustand .pending darf keine Plus-Funktionen vorzeitig freischalten. |
| 226 | P1 | Kaufabbruch: Ein abgebrochener Kauf darf weder eine Freischaltung noch eine falsche Fehlermeldung erzeugen. |
| 227 | P1 | Abo-Erstattung: Widerrufene oder erstattete Transaktionen dürfen nicht weiterhin Plus freischalten. |
| 228 | P1 | Abo-Verlängerung: Bei einer erneuten Transaktion müssen Ablaufdatum und Berechtigungen korrekt aktualisiert werden. |
| 229 | P1 | StoreKit nicht erreichbar: Die App muss bei fehlender Internetverbindung verständlich reagieren und vorhandene Notizen erhalten. |
| 230 | P1 | Kauf wiederherstellen: PurchaseStore.restore() ruft AppStore.sync() auf. Das muss mit einem echten Sandbox-Konto und einem zweiten Gerät getestet werden. |

Konkreter Release-Blocker: Nr. 221. Solange die echten Produkte nicht in App Store Connect eingerichtet und getestet sind, sollte UniFlow keine bezahlten Plus-Abos öffentlich anbieten.

### 231–240: Apple WebKit, Hochschul-Login und Passwörter

| Nr. | Priorität | Befund |
|---|---|---|
| 231 | P1 | Login-Autofill in WebKit: UniversityLoginAutofill.swift füllt Benutzername und Passwort per callAsyncJavaScript ein. Die Zielprüfung muss mit manipulierten Loginseiten getestet werden. |
| 232 | P1 | Änderungen der Hochschul-Loginseite: Ändern sich HTML-Felder oder Formularstrukturen, kann das automatische Ausfüllen scheitern. |
| 233 | P1 | Weiterleitung zwischen CAS und Hochschuldiensten: Nach SSO-Weiterleitungen muss die App nur auf freigegebenen Loginhosts Zugangsdaten einsetzen. |
| 234 | P1 | JavaScript-Navigation: Der Code prüft Änderungen an history.pushState und replaceState. Umgehungsversuche müssen durch Sicherheitstests ausgeschlossen werden. |
| 235 | P1 | Passwort im falschen Formular: Das Autofill muss verhindern, dass Zugangsdaten in eingebettete Fremdformulare geschrieben werden. |
| 236 | P1 | Hochschulpasswort speichern: UniversityCredentialStore.save() schreibt Benutzername und Passwort getrennt. Teilweise fehlgeschlagene Schlüsselbundoperationen müssen zuverlässig rückgängig gemacht werden. |
| 237 | P1 | Passwort nach Neuinstallation: Die App erkennt eine Neuinstallation und löscht alte Hochschul-Schlüsselbundeinträge. Dieser Vorgang muss auch nach unterbrochenen Installationen sicher sein. |
| 238 | P1 | Hochschul-Login ohne gespeichertes Passwort: Der manuelle Login muss weiterhin funktionieren, wenn „Passwort merken“ deaktiviert ist. |
| 239 | P1 | Sitzungscookies laufen ab: StudIPCookieStore speichert Cookies lokal. Die App muss abgelaufene Sitzungen erkennen und erneute Anmeldung ermöglichen. |
| 240 | P1 | Cookies zwischen Konten: Der Transport verwendet getrennte Sitzungen und Datencontainer. Die Trennung muss bei schnellem Hochschul- und Kontowechsel getestet werden. |

Positiver Befund: UniTransportSession.swift enthält bereits Schutzmechanismen gegen unzulässige Weiterleitungen und das Weitergeben von Cookies an fremde Hosts. Diese Schutzmaßnahmen sollten mit gezielten Regressionstests abgesichert werden, statt sie als fehlend zu behandeln.

### 241–250: Apple-Lern-Timer, App-Lebenszyklus und Zuverlässigkeit

| Nr. | Priorität | Befund |
|---|---|---|
| 241 | P1 | Timer läuft über einen Task: StudyTimer.swift verwendet eine Schleife mit 500-ms-Pause. Nach iPadOS-Suspendierung muss die Zeit korrekt nachgeführt werden. |
| 242 | P1 | Timer nach App-Neustart: Der aktuelle Zustand muss bei einem vollständigen Neustart geprüft werden. |
| 243 | P1 | Countdown bei gesperrtem iPad: Wenn der Countdown während der Sperre endet, muss das Verhalten klar definiert sein. |
| 244 | P1 | Pomodoro-Phasen nach Unterbrechung: Arbeits- und Pausenphasen dürfen nach längerer Unterbrechung nicht falsch weiterlaufen. |
| 245 | P1 | Timer-Benachrichtigung: Für ein verlässliches Signal bei abgelaufenem Countdown muss eine lokale iPadOS-Benachrichtigung geprüft beziehungsweise implementiert werden. |
| 246 | P1 | Timer und Systemuhr: Manuelle Änderungen der Gerätezeit dürfen die Berechnung nicht unerwartet verfälschen. |
| 247 | P1 | Mehrere Fenster: Zwei gleichzeitig geöffnete iPad-Fenster dürfen keine widersprüchlichen Timerstände anzeigen. |
| 248 | P1 | Timer bei niedrigem Akkustand: Der Timer darf nicht darauf angewiesen sein, dass iPadOS die App dauerhaft im Hintergrund ausführt. |
| 249 | P1 | Timer nach Speicherwarnung: Die App muss auch nach einer vom System ausgelösten Beendigung sinnvoll wiederherstellen können. |
| 250 | P1 | Lernzeitstatistik: Prüfen, ob pausierte Zeiten, abgeschlossene Pomodoro-Runden und App-Unterbrechungen korrekt in Statistiken eingehen. |

Wichtigste Apple-Prioritäten dieser Runde: Nr. 221 (StoreKit-Release: echte Produkte, Sandbox-Käufe, Wiederherstellung, Kündigung), Nr. 231–240 (Hochschulzugangsdaten: Autofill, Cookie-Isolation, Kontowechsel unter realistischen Bedingungen), Nr. 241–249 (Timer: persistierte Zeitstempel und lokale Benachrichtigungen statt nur einer Task-Schleife).

Claude-Auftrag Runde 8 (Wortlaut): Prüfe im aktuellen develop-Branch ausschließlich die Apple-App und die zugehörigen Swift-Tests. Untersuche die Punkte 221–250 mit Schwerpunkt auf Purchases/Entitlements.swift, Purchases/PurchaseStore.swift, Services/UniversityLoginAutofill.swift, Services/UniversityCredentials.swift, Services/UniTransportSession.swift, Services/StudIPSync.swift, Views/Timer/StudyTimer.swift. Aufgaben: vollständiger StoreKit-2-Lebenszyklus (Kauf, Wiederherstellung, Ablauf, Widerruf, Familienfreigabe); Free-Nutzer erhalten keine Plus-Schreibrechte; Notizen bleiben bei Aboablauf erhalten; Autofill gegen manipulierte und weitergeleitete Loginseiten; Isolation von Cookies, Zugangsdaten und WebViews zwischen Nutzern; abgelaufene Hochschulsitzungen simulieren; Timer nach Suspendierung, Neustart und Gerätezeitsprung; lokale Benachrichtigungen für Countdown und Pomodoro; vorhandene Tests auf Lücken prüfen und Regressionstests hinzufügen. Für jeden bestätigten Fehler Datei, Zeile, Reproduktion, Auswirkung, Fix und Testnachweis; bestätigte Bugs, potenzielle Risiken und fehlende Live-Tests getrennt kennzeichnen. Keine Änderungen an Windows, Android oder Python; keine Pushes, keine Änderungen an main, keine echten Käufe. Abschließend eine Apple-Release-Matrix für iPad, TestFlight, App Store und Mac.

---

## Apple-Audit Runde 9 (Nr. 251–280)

### 251–260: SwiftUI-Dashboard und Datenaktualisierung

| Nr. | Priorität | Befund |
|---|---|---|
| 251 | P1 | Fehler beim Markieren neuer Dateien: DashboardView.swift verwendet try? für /api/files/mark-seen. Der Fehler wird nicht angezeigt. |
| 252 | P1 | Dashboard nach Kontowechsel: Der Dashboard-Zustand muss bei einem Wechsel zwischen Benutzerkonten vollständig neu aufgebaut werden. |
| 253 | P1 | Veraltete Antworten: Wenn zwei Dashboard-Ladevorgänge gleichzeitig laufen, darf die ältere Antwort nicht die neuere überschreiben. |
| 254 | P1 | Kalenderfehler bei vorhandenen Daten: Ein fehlgeschlagener Reload muss den letzten erfolgreichen Stand erhalten und einen Fehler anzeigen. |
| 255 | P1 | Aufgabenfortschritt: Die Anzeige berechnet den Fortschritt aus Aufgabenstatus. Unbekannte oder neue Statuswerte benötigen definierte Behandlung. |
| 256 | P1 | Tageswechsel um Mitternacht: Begrüßung, heutige Aufgaben und Termine müssen sich aktualisieren, ohne dass die App neu gestartet wird. |
| 257 | P1 | Feiertage und vorlesungsfreie Zeit: Die Dashboard-Zusammenfassung muss mit den tatsächlichen Kalenderdaten übereinstimmen. |
| 258 | P1 | Leerer Stundenplan vs. Ladefehler: Ein leerer Terminbereich darf nicht verschleiern, dass der Import gescheitert ist. |
| 259 | P1 | Gleichzeitige Synchronisierung und Anzeige: Neu eintreffende Dateien dürfen nicht doppelt oder mit veraltetem Status dargestellt werden. |
| 260 | P1 | Dashboard bei großer Datenmenge: Umfangreiche Kurse, Aufgaben und Termine benötigen Lasttests für die SwiftUI-Darstellung. |

Konkrete Stelle: DashboardView.swift, Zeilen 309–311 (verschluckter Fehler); die übrigen Punkte sind gezielte UI- und Integrationstests.

### 261–270: Apple-Prüfungen, Karteikarten und Antwortspeicherung

| Nr. | Priorität | Befund |
|---|---|---|
| 261 | P0-Kandidat | Prüfungsentwürfe in globalen UserDefaults: ExamsPage.swift, Zeilen 273–285, verwendet UserDefaults.standard. Falls draftKey nicht zusätzlich die Benutzeridentität enthält, können Entwürfe beim Kontowechsel vermischt werden. |
| 262 | P1 | Prüfungsantworten nur lokal gespeichert: Antworten werden unmittelbar in UserDefaults gespeichert. Gerätewechsel und Neuinstallation benötigen eine klare Wiederherstellungsstrategie. |
| 263 | P1 | Prüfung nach Kontowechsel: Eine geöffnete Prüfung muss sofort auf den neuen Benutzerkontext reagieren. |
| 264 | P1 | Prüfung während App-Absturz: Nach erneutem Start müssen alle bereits eingegebenen Antworten korrekt wiederhergestellt werden. |
| 265 | P1 | Prüfungsabgabe und Aufgabenstatus: submit() führt zwei getrennte Serveraktionen aus. Schlägt die zweite fehl, ist die Prüfung möglicherweise bereits abgegeben, während die zugehörige Aufgabe offen bleibt. |
| 266 | P1 | Doppelte Prüfungsabgabe: Bei instabiler Verbindung muss der Server wiederholte Abgabeversuche sicher behandeln. |
| 267 | P1 | Prüfungstimer bei fehlendem Startdatum: ExamTimer verwendet ersatzweise die aktuelle Renderzeit. Das kann eine irreführende verbleibende Prüfungszeit anzeigen. |
| 268 | P1 | Prüfungszeit nach Gerätezeitänderung: Der Timer muss gegen den serverseitigen Startzeitpunkt abgeglichen werden. |
| 269 | P1 | Karteikarten schnell mehrfach bewerten: Zwei schnelle Eingaben dürfen eine Karte nicht doppelt verschieben. |
| 270 | P1 | Karteikarten während Kontowechsel: Der aktuelle Kartenstapel muss vollständig zurückgesetzt werden. |

Nr. 265: zwei voneinander abhängige Änderungen werden getrennt abgeschickt (Teil-Erfolg möglich).

### 271–280: Apple-Bibliothek, Skriptsuche und Lernplanung

| Nr. | Priorität | Befund |
|---|---|---|
| 271 | P1 | Bibliothekssuche ist zunächst eine lokale Titelsuche: LibraryPage.swift filtert Titel und andere Metadaten. Eine vollständige PDF-Inhaltssuche muss gesondert geprüft werden. |
| 272 | P1 | Suche mit schnellem Tippen: Die 300-ms-Verzögerung verwendet Task-Abbruch. Schnelle Eingaben dürfen keine veralteten Ergebnisse anzeigen. |
| 273 | P1 | Bibliothek nach Kontowechsel: Die SwiftUI-Ansicht muss ihre Dateiliste beim Wechsel des aktiven Containers zurücksetzen. |
| 274 | P1 | Globale Sortierung und Filter: LibraryPage.swift verwendet statische Zustandsvariablen. Diese sind nicht automatisch pro Benutzer oder Fenster isoliert. |
| 275 | P1 | Skriptsuche meldet Fehler nicht: DocumentView.swift, Zeilen 324–326, unterdrückt Fehler bei /api/related. |
| 276 | P1 | Skriptvorschläge werden zwischengespeichert: Bei Änderungen der Skripte muss der Seiten-Cache ungültig werden. |
| 277 | P1 | Skriptvorschlag während Dokumentwechsel: Alte Suchantworten dürfen nicht für ein anderes Dokument angezeigt werden. |
| 278 | P1 | Aufgaben überspringen ohne Fehlerkontrolle: PlanView.swift, Zeilen 121–126, verwendet try? und löst anschließend einen Reload aus. |
| 279 | P1 | Stundenplan-Konflikte werden still leer: TimetableView.swift, Zeile 41, behandelt einen fehlgeschlagenen Konfliktabruf als leere Konfliktliste. |
| 280 | P1 | Automatische Stundenplan-Neuverteilung: Auch hier wird ein Fehler teilweise still ignoriert. Nutzer benötigen eine eindeutige Rückmeldung. |

Wichtigste Kandidaten: 261 (Isolation der Prüfungsantworten – zuerst prüfen, ob draftKey die Benutzer-ID enthält, bevor ein Isolationsfehler gemeldet wird), 265 (widersprüchlicher Zustand bei Teilabgabe), 279 (leere Konfliktliste ≠ gescheiterte Prüfung). Auftrag Runde 9: Punkte 251–280 mit Tests bestätigen (DashboardView, ExamsPage, LibraryPage, DocumentView, PlanView, TimetableView, SettingsPage); Datenisolation bei Apple-ID- und Hochschulwechsel, Prüfungsentwürfe, Teilabgaben, Prüfungstimer, doppelte Karteikartenbewertungen, statische Zustände, veraltete Suchergebnisse, verschluckte API-Fehler, Stundenplankonflikte, App-Unterbrechungen; prüfen, ob Probleme schon durch Tests abgesichert oder behoben sind; Go/No-Go-Liste.

---

## Apple-Audit Runde 10 (Nr. 281–330)

### 281–290: Dateiimport und Ordnerverwaltung

| Nr. | Befund |
|---|---|
| 281 | Neue Ordner: LibraryDialogs.swift:92 ignoriert API-Fehler bei der Erstellung. |
| 282 | Ordner umbenennen: Ein fehlgeschlagenes PATCH wird nicht gemeldet. |
| 283 | Ordnerfarbe ändern: Fehlgeschlagene Speicherung wird still ignoriert. |
| 284 | Ordner löschen: Fehler beim DELETE können verborgen bleiben. |
| 285 | Fotoimport: Nicht lesbare Fotos werden beim Import übersprungen, ohne sie einzeln auszuweisen. |
| 286 | Fotoimport: Der Code bezeichnet importierte Bilder pauschal als JPEG. Andere Quellformate müssen überprüft werden. |
| 287 | Dateiauswahl: Data(contentsOf:) lädt ausgewählte Dateien vollständig in den Speicher. |
| 288 | Import mehrerer Dateien: Ein Teilerfolg muss mit genauer Anzahl erfolgreicher und fehlgeschlagener Dateien gemeldet werden. |
| 289 | Importabbruch: Bereits importierte Dateien und noch laufende Uploads müssen einen definierten Zustand haben. |
| 290 | Gleichzeitiger Import: Doppelte Dateinamen und parallele Importvorgänge benötigen Kollisionstests. |

### 291–300: SwiftUI-Navigation und globale Suche

| Nr. | Befund |
|---|---|
| 291 | ShellState.swift:41–43: attach() startet eine asynchrone Aktualisierung. Schneller Serverwechsel benötigt Schutz vor veralteten Antworten. |
| 292 | ShellState.swift:47–49: Anzeigenamen werden asynchron geladen. Ein alter Name darf nach Kontowechsel nicht erscheinen. |
| 293 | Hintergrundstatus: Fehler beim Abruf von /api/bg können die Überwachung beenden, ohne den endgültigen Jobstatus zu kennen. |
| 294 | Hintergrundabfrage: Die Polling-Schleife muss bei App-Wechsel oder Abmeldung beendet werden. |
| 295 | Hintergrundabfrage: Mehrfach gestartete Polling-Schleifen dürfen nicht gleichzeitig denselben Job überwachen. |
| 296 | Globale Suche: Bei einem Netzwerkfehler bleiben möglicherweise vorherige Treffer sichtbar. |
| 297 | Globale Suche: Nach Kontowechsel müssen bisherige Suchtreffer sofort entfernt werden. |
| 298 | Suchergebnisse: Dateitreffer müssen auch bei zwischenzeitlich gelöschten Dokumenten korrekt behandelt werden. |
| 299 | Navigation: Ein API-Wechsel während eines geöffneten Dialogs darf keine Aktion im falschen Konto auslösen. |
| 300 | Navigation: Gleichzeitige Modals, Alerts und Hintergrund-Reloads benötigen Stabilitätstests. |

### 301–310: Module und Lernplanung

| Nr. | Befund |
|---|---|
| 301 | ModulesPage.swift: Wenn der Modulabruf scheitert, können zuvor geladene Moduldaten sichtbar bleiben. |
| 302 | Moduldetail: Ein Wechsel der Modul-ID während eines laufenden Abrufs darf keine falschen Inhalte anzeigen. |
| 303 | Modulwochen: Sortierung und Gruppierung müssen auch bei fehlenden Wochennummern korrekt sein. |
| 304 | Moduldateien: Gleiche Dateien aus mehreren Kursen dürfen nicht versehentlich doppelt gezählt werden. |
| 305 | Modulzuordnung: Ein Fehler beim Speichern darf keine scheinbar erfolgreiche Änderung anzeigen. |
| 306 | Lernpaket abschließen: PlanActions.swift:81–89 ändert Aufgaben nacheinander und ignoriert einzelne Fehler. Ein Paket kann teilweise abgeschlossen werden. |
| 307 | Lernpaket überspringen: Fehler beim POST werden unterdrückt. |
| 308 | Lernpaket verschieben: Fehler beim PATCH werden unterdrückt. |
| 309 | Lernpaket löschen: Fehler beim DELETE werden unterdrückt. |
| 310 | Lernpaket während gleichzeitiger Bearbeitung: Der Zustand muss bei parallelen Änderungen konsistent bleiben. |

### 311–320: Stundenplan und Hochschuldienste

| Nr. | Befund |
|---|---|
| 311 | TimetableShared.swift:48: Wenn ein Termin nicht gefunden wird, muss zwischen „gelöscht“ und „Abruf fehlgeschlagen“ unterschieden werden. |
| 312 | Veranstaltungsmaterialien: Fehler beim Laden werden als leere Materialliste dargestellt. |
| 313 | Veranstaltung löschen: Ein fehlgeschlagenes DELETE wird nicht gemeldet. |
| 314 | Anwesenheitsstatus: Fehler beim POST werden teilweise still ignoriert. |
| 315 | Anwesenheitsstatus: Bei einem Fehler darf keine automatische Lernzeit-Neuverteilung ausgelöst werden. |
| 316 | Wiederkehrende Veranstaltungen: Änderungen müssen korrekt zwischen Einzeltermin und ganzer Serie unterscheiden. |
| 317 | Stundenplan-Editor: Fehlende Module beim Laden dürfen nicht zu falschen Modulzuordnungen führen. |
| 318 | Stundenplan-Editor: Speichern mit veralteten Termindaten benötigt Konfliktprüfung. |
| 319 | Notenabruf: ServicesPage.swift muss Fehler bei einem teilweise abgeschlossenen Hochschulabgleich anzeigen. |
| 320 | Hochschulbescheinigungen: Große PDF-Dokumente werden als vollständige Datenantwort geladen. Speicherverbrauch prüfen. |

### 321–330: WebView, Offline-Cache und Datenschutz

| Nr. | Befund |
|---|---|
| 321 | UFWebFallback.swift: Der Web-Fallback setzt ein PIN-Cookie. Bei externen Servern müssen Host- und Transportbedingungen strikt geprüft werden. |
| 322 | Web-Fallback: Es wird eine eigene WKWebView erstellt. Cookie-Isolation zwischen Konten und Fenstern muss geprüft werden. |
| 323 | Web-Fallback: Navigationsweiterleitungen zu fremden Domains benötigen klare Einschränkungen. |
| 324 | Web-Fallback: Eine geänderte Serveradresse darf nicht dazu führen, dass die alte WebView weiter authentifiziert bleibt. |
| 325 | RemoteData.swift: Beim Offline-Fallback werden gespeicherte API-Antworten angezeigt. Veraltete Daten müssen deutlich gekennzeichnet werden. |
| 326 | Offline-Cache: Ein beschädigter Cache darf nicht als gültiger Datenstand gelten. |
| 327 | Offline-Cache: Bei Konto- oder Hochschulwechsel muss die Cache-Isolation überprüft werden. |
| 328 | Offline-Cache: Ein voller Gerätespeicher kann Cache-Schreibfehler auslösen; die App muss trotzdem weiterarbeiten. |
| 329 | Offline-Cache: Veraltete Informationen zu Terminen, Noten oder Fristen dürfen nicht ohne Zeitangabe als aktuell erscheinen. |
| 330 | Web-Fallback und native Oberfläche: Unterschiedliche Berechtigungen dürfen keine Funktionen freigeben, die im nativen Modus gesperrt sind. |

Konkreteste Codeprobleme: 281–284, 306–309, 313–314 (API-Fehler mit try? ignoriert → Oberfläche suggeriert Erfolg). Wichtige Sicherheits-/Isolationstests: 291–299, 321–324. Auftrag: LibraryDialogs, ShellState, ModulesPage, PlanActions, TimetableShared, ServicesPage, UFWebFallback, RemoteData; versteckte API-Fehler, teilweise abgeschlossene Lernpakete, veraltete Daten nach Konto-/Serverwechsel, Race Conditions, WebKit-Cookies/Weiterleitungen/Kontotrennung, Offline-Cache-Kennzeichnung, Speicher bei großen Dateien.

---

## Apple-Audit Runde 11 (Nr. 331–380)

### 331–340: Apple Pencil und Handschrift

| Nr. | Befund |
|---|---|
| 331 | StrokeConverter.swift:114–115: Wenn gespeicherte PencilKit-Daten nicht dekodierbar sind, greift der Konverter auf andere Darstellungswege zurück. Prüfen, ob alle Striche erhalten bleiben. |
| 332 | Die Anzahl gespeicherter Strich-IDs muss mit der tatsächlichen Anzahl von PencilKit-Strichen übereinstimmen. |
| 333 | Ungültige oder veränderte Strichsignaturen werden erkannt. Testen, ob beschädigte Striche sichtbar gemeldet werden. |
| 334 | Gleichzeitige Pencil-Eingaben und das Neuladen einer Canvas dürfen keine doppelten Striche erzeugen. |
| 335 | Bereits auf einem anderen Gerät gelöschte Striche dürfen nicht unbeabsichtigt wiederhergestellt werden. |
| 336 | Strichbreiten und Druckinformationen müssen nach Speichern und erneutem Öffnen erhalten bleiben. |
| 337 | Markertransparenz muss bei Konvertierung und erneutem Laden unverändert bleiben. |
| 338 | Extrem kurze Striche und einzelne Punkte dürfen bei der Konvertierung nicht verschwinden. |
| 339 | Wiederholtes Konvertieren zwischen PencilKit und dem eigenen JSON-Format darf keine sichtbare Qualitätsverschlechterung verursachen. |
| 340 | Striche mit ungewöhnlichen Koordinaten oder sehr vielen Punkten benötigen Belastungstests. |

### 341–350: Notiz-Journale und Wiederherstellung

| Nr. | Befund |
|---|---|
| 341 | LocalJournal.swift:100: Eine beschädigte meta.json wird protokolliert. Testen, ob die übrigen Notizseiten korrekt wiederhergestellt werden. |
| 342 | LocalJournal.swift:108: Beschädigte Bestätigungsdaten (acks.json) müssen einen sicheren erneuten Synchronisationsversuch ermöglichen. |
| 343 | Einzelne beschädigte Seitendateien dürfen nicht dazu führen, dass das gesamte Dokument unbrauchbar wird. |
| 344 | Unterbrochene Schreibvorgänge müssen mit alten und neuen Dateiversionen getestet werden. |
| 345 | Wenn das Schreiben einer Seite erfolgreich ist, aber das Schreiben der Metadaten fehlschlägt, muss die Wiederherstellung konsistent bleiben. |
| 346 | Nicht lesbare Journale müssen eine sichtbare Wiederherstellungsoption anbieten, statt Änderungen still zu verwerfen. |
| 347 | Sehr viele lokale Seitenänderungen benötigen Speicherplatz- und Ladezeittests. |
| 348 | Journal-Dateinamen mit Unicode-Zeichen müssen nach Kodierung und Dekodierung unverändert bleiben. |
| 349 | Ein fehlgeschlagener Dateischreibvorgang darf niemals den Status „Gespeichert“ erzeugen. |
| 350 | Journalbereinigung darf keine Änderungen entfernen, die noch nicht erfolgreich bestätigt wurden. |

### 351–360: Synchronisierung und Konfliktbehandlung

| Nr. | Befund |
|---|---|
| 351 | Gleichzeitiges Bearbeiten derselben Seite auf zwei Geräten: Beide Änderungen müssen erhalten bleiben oder als Konflikt erscheinen. |
| 352 | Löschen auf Gerät A, Bearbeiten auf Gerät B: Die Merge-Regeln müssen verhindern, dass Änderungen unbemerkt verschwinden. |
| 353 | Änderungen während eines Uploads müssen nach dessen Abschluss erneut synchronisiert werden. |
| 354 | SyncEngine.swift unterscheidet 401, 403 und 409. Testen, ob nach erneuter Anmeldung korrekt weitergearbeitet wird. |
| 355 | Bei HTTP-500-Fehlern dürfen Wiederholungen weder unbegrenzt parallel laufen noch den Akku übermäßig belasten. |
| 356 | Wiederholungsversuche müssen nach dem Schließen eines Dokuments zuverlässig gestoppt werden. |
| 357 | Eine abgebrochene Synchronisierung darf bereits lokal gespeicherte Änderungen nicht zurücksetzen. |
| 358 | Bei einem ungelösten Konflikt muss die Oberfläche klar anzeigen, welche Änderungen betroffen sind. |
| 359 | Wiederholte Konflikte dürfen keine doppelten Anmerkungsobjekte erzeugen. |
| 360 | Wenn der Server eine erfolgreiche Speicherung meldet, aber die lokale Bestätigung nicht geschrieben werden kann, muss der nächste Start sicher reagieren. |

### 361–370: Universität Hildesheim auf dem iPad

| Nr. | Befund |
|---|---|
| 361 | HildesheimConnection.swift:226–231: Mehrfach gestartete Synchronisierungen müssen korrekt zusammengeführt oder verhindert werden. |
| 362 | Hochschulabgleich während Abmeldung: Alle laufenden Aufgaben müssen vollständig beendet werden. |
| 363 | Hochschulwechsel während Learnweb-Download: Die Daten dürfen nicht im falschen Hochschulcontainer landen. |
| 364 | Abgelaufener Learnweb-Token: Der Status muss zuverlässig auf erneute Anmeldung wechseln. |
| 365 | Learnweb funktioniert, LSF nicht: Der Teilerfolg muss sichtbar bleiben. |
| 366 | LSF funktioniert, Learnweb nicht: Vorhandene Kursunterlagen dürfen nicht verschwinden. |
| 367 | Fehlerhafte oder unterbrochene CAS-Anmeldung: Der Nutzer muss erneut starten können, ohne App-Neustart. |
| 368 | Automatischer Notenabruf: Das vorgesehene Intervall muss bei manuellen und automatischen Abrufen korrekt berücksichtigt werden. |
| 369 | HildesheimConnection.swift:188–195: Beim Abmelden werden Schlüsselbunddaten und WebKit-Daten entfernt. Teilfehler benötigen eine sichere Behandlung. |
| 370 | Erneute Anmeldung nach Abmeldung: Alte Sitzungscookies dürfen nicht wiederverwendet werden. |

### 371–380: Hochschulwechsel, Diagnose und Hintergrundaufgaben

| Nr. | Befund |
|---|---|
| 371 | UniversitySettings.swift: Hochschulwechsel bei geöffnetem PDF muss den richtigen Dokumentcontainer aktivieren. |
| 372 | Hochschulwechsel während eines laufenden Downloads darf keine Datei falsch zuordnen. |
| 373 | Hochschuldaten löschen: Die Oberfläche muss tatsächliche Löschfehler anzeigen. |
| 374 | Datenlöschung bei laufendem Abgleich: Die vorhandene Sperre muss auch gegen unmittelbar danach gestartete Tasks schützen. |
| 375 | Mehrfaches Tippen auf „Hochschule wechseln“ darf keine konkurrierenden Containerwechsel auslösen. |
| 376 | Diagnostics.swift:24–28: Nicht lesbare Journalverzeichnisse werden bei der Diagnose übersprungen. Das kann Schäden in der Zusammenfassung verbergen. |
| 377 | Diagnose während laufender Schreibvorgänge muss einen konsistenten oder ausdrücklich vorläufigen Zustand melden. |
| 378 | Die Speichergrößenberechnung muss auch bei sehr vielen PDF-Dateien die Oberfläche reaktionsfähig lassen. |
| 379 | Diagnoseberichte dürfen keine Hochschulpasswörter, Sitzungstokens oder privaten Notizinhalte enthalten. |
| 380 | Hintergrundabgleich: Prüfen, ob für gewünschte Hintergrundfunktionen BGTaskScheduler korrekt konfiguriert ist. |

Auftrag Runde 11: StrokeConverter, LocalJournal, BlobStore, AnnotationMerge, SyncEngine, HildesheimConnection, UniversitySettings, Diagnostics; Tests für PencilKit-Roundtrips ohne Strichverlust, beschädigte Journale, fehlgeschlagene Dateischreibvorgänge, gleichzeitige Änderungen auf zwei Geräten, Löschen/Bearbeiten derselben Seite, HTTP 401/403/409/500 während der Synchronisierung, Hochschulwechsel während Downloads, teilweise erfolgreiche Learnweb-/LSF-Abgleiche, Konto- und Hochschuldatenlöschung, iPadOS-Hintergrundverarbeitung; nur bestätigte Fehler als Bugs; Liste bestätigter Bugs, behobener Probleme, offener Tests und echter Release-Blocker.

---

## Apple-Audit Runde 12 (Nr. 381–420)

### 381–390: Stud.IP-Stundenplan auf Apple-Geräten

| Nr. | Prüfbefund |
|---|---|
| 381 | StudIPScheduleStore.swift:49: Kursveranstaltungen werden mit page[limit]=200 angefordert. Prüfen, ob bei mehr als 200 Einträgen weitere Seiten abgerufen werden. (Laut Runde 13 durch StudIPScheduleStoreTests bereits abgedeckt – kein bestätigter Bug.) |
| 382 | StudIPScheduleStore.swift:35: Einträge ohne ID werden verworfen. Prüfen, ob der Import solche Verluste sichtbar meldet. |
| 383 | StudIPScheduleStore.swift:37: Als abgesagt markierte Termine werden ausgeschlossen. Prüfen, ob die Absage trotzdem im Stundenplan erkennbar bleibt. |
| 384 | StudIPScheduleStore.swift:177–178: Beim Aktualisieren werden vorhandene Kursveranstaltungen gelöscht und ersetzt. Prüfen, was bei unvollständigen Serverantworten passiert. |
| 385 | StudIPScheduleStore.swift:189: Die Tabelle der persönlichen Stundenplaneinträge wird vor dem Neuaufbau geleert. Prüfen, ob ein leerer, aber technisch erfolgreicher Abruf alte Termine unbeabsichtigt entfernt. |
| 386 | StudIPScheduleStore.swift:203: Auch Zyklusdaten werden vor dem Neuaufbau gelöscht. Prüfen, ob ein Teilerfolg als vollständiger Abgleich interpretiert werden kann. |
| 387 | StudIPScheduleStore.swift:239: Nicht lesbare gespeicherte Zyklusdaten werden übersprungen. Diagnose und Wiederherstellung prüfen. |
| 388 | StudIPScheduleImport.swift:162–163: Die Serienerkennung verwendet bestimmte Felder und bei Einzelterminen das Startdatum. Prüfen, ob zwei verschiedene Veranstaltungen dieselbe Kennung erhalten können. |
| 389 | StudIPScheduleImport.swift:181–188: Beim Neuverknüpfen eines Termins werden alte Zuordnungen entfernt. Prüfen, ob manuelle Änderungen an der bisherigen Serie erhalten bleiben. |
| 390 | StudIPScheduleImport.swift:194–204: Absagen werden anhand gespeicherter EXDATE-Werte aktualisiert. Prüfen, ob eine manuell gesetzte Absage unangetastet bleibt. |

### 391–400: PDF-Seiten, Papierkorb und Vorlagen

| Nr. | Prüfbefund |
|---|---|
| 391 | PageOrder.swift:148–171: Wiederherstellung einer gelöschten Seite benötigt Tests, wenn dieselbe Seite inzwischen durch eine Synchronisierung zurückgekehrt ist. |
| 392 | PageOrder.swift:164: Gespeicherte Papierkorb-Objekte werden beim Wiederherstellen übernommen. Prüfen, ob inzwischen neuere Anmerkungen überschrieben werden können. |
| 393 | PageOrder.swift:159: Die ursprüngliche Seitenposition wird wiederverwendet. Bei gleichzeitig geänderter Seitenreihenfolge auf einem zweiten Gerät kann die Position unerwartet sein. |
| 394 | PageOrder.swift:103–115: Der Papierkorb speichert gelöschte Seiten im Dokumentzustand. Große Mengen gelöschter Seiten können diesen aufblähen. |
| 395 | PageOrder.swift:48: Die Erzeugung neuer Seitenschlüssel muss bei extrem schnellen parallelen Einfügungen auf Kollisionen getestet werden. |
| 396 | PageOrder.swift:217–226: Die Vorlagengeometrie erzeugt Linien in einer Schleife. Extrem große Seitenabmessungen benötigen Obergrenzen. |
| 397 | PageOrder.swift:232–233: Bei sehr kleinen Cornell-Seiten kann die Trennlinie außerhalb des sinnvoll nutzbaren Bereichs liegen. |
| 398 | PageOrder.swift:234–240: Millimeter- und Punktraster benötigen Tests bei nicht standardisierten Seitengrößen. |
| 399 | PageOrder.swift:62–64: Zusätzliche Seitendrehungen müssen auch bei ungewöhnlichen Rotationswerten korrekt behandelt werden. |
| 400 | Beim Wiederherstellen einer Seite muss die Apple-Pencil-Zeichnung mit den restaurierten Anmerkungsobjekten konsistent bleiben. |

### 401–410: Lösungspakete und Weitergabe von Notizen

| Nr. | Prüfbefund |
|---|---|
| 401 | SolutionBuilder.swift:110–115: Nicht mehr vorhandene Seitenschlüssel werden bei der Auswahl übersprungen. Prüfen, ob der Nutzer über ausgelassene Seiten informiert wird. |
| 402 | SolutionBuilder.swift:114: Die Reihenfolge richtet sich nach pageOrder, nicht nach der Reihenfolge der Auswahl. Das muss im Dialog erkennbar sein. |
| 403 | SolutionBuilder.swift:126: Ungültige PDF-Seiten werden abgelehnt. Prüfen, ob eine verständliche Fehlermeldung mit der betroffenen Seite erscheint. |
| 404 | SolutionBuilder.swift:132–135: Ungültige Maße eigener Leerseiten werden teilweise durch Standardmaße ersetzt. Prüfen, ob dadurch die Position von Notizen verändert wird. |
| 405 | SolutionBuilder.swift:138–139: Eingefügte Bild- oder PDF-Seiten werden nicht unterstützt. Die Apple-Oberfläche muss das vor dem Teilen erklären. |
| 406 | SolutionBuilder.swift:143–144: Ein Lösungspaket benötigt mindestens ein eigenes Notizobjekt. Prüfen, ob ausschließlich handschriftliche PencilKit-Daten in jedem Format korrekt als Inhalt erkannt werden. |
| 407 | SolutionBuilder.swift:147–149: Fehlende Bilder werden in missingImages erfasst. Prüfen, ob das Teilen bei unvollständigem Inhalt eine ausdrückliche Bestätigung verlangt. |
| 408 | SolutionBuilder.swift:150–151: Titel und Anzeigename werden gekürzt. Prüfen, ob dadurch missverständliche oder identische Namen entstehen. |
| 409 | SolutionBuilder.swift:152–156: Erstellungszeitpunkt und Kennung werden in das Paket übernommen. Prüfen, welche Metadaten beim Teilen sichtbar sind. |
| 410 | SolutionBuilder.swift:156: Die fertigen Inhalte werden validiert. Zusätzliche Tests sollten Grenzwerte und manipulierte Objekte abdecken. |

### 411–420: Nativer API-Client und Datenübertragung

| Nr. | Prüfbefund |
|---|---|
| 411 | APIClient.swift:86–89: Relative API-Pfade werden gegen die Basis-URL aufgelöst. Prüfen, ob unerwartete absolute URLs oder Pfade außerhalb der vorgesehenen API akzeptiert werden. |
| 412 | APIClient.swift:117–135: Multipart-Uploads werden vollständig im Arbeitsspeicher zusammengesetzt. Große PDF-Dateien können hohe Speicherspitzen verursachen. |
| 413 | APIClient.swift:125: Dateinamen werden für Multipart-Header bereinigt. Zusätzliche Unicode- und Sonderzeichenfälle testen. |
| 414 | APIClient.swift:126–127: Feldname und MIME-Typ werden direkt in Multipart-Header eingesetzt. Sicherstellen, dass sie ausschließlich aus vertrauenswürdigen beziehungsweise validierten Werten stammen. |
| 415 | APIClient.swift:135: Uploads verwenden den normalen Transport. Bei Netzunterbrechung muss ein Wiederholungsversuch doppelte Dokumente vermeiden. |
| 416 | APIClient.swift:139: Eine erfolgreiche Uploadantwort wird immer als JSON geparst. Eine leere erfolgreiche Antwort könnte einen Parsingfehler auslösen. |
| 417 | APIClient.swift:145–147: API-Fehlertexte werden auf 400 Byte begrenzt. Prüfen, ob dadurch wichtige Fehlermeldungen verloren gehen. |
| 418 | APIClient.swift:156–158: Fehlt bei einem Anmerkungsabruf die Versionsnummer, wird Version 0 angenommen. Prüfen, ob eine fehlerhafte Antwort dadurch als gültiger Stand erscheint. |
| 419 | APIClient.swift:166–167: Fehlt nach erfolgreichem Speichern die Versionsnummer, wird baseVersion + 1 angenommen. Das muss mit der tatsächlichen Serverversion übereinstimmen. |
| 420 | APIClient.swift:171–173: Bei HTTP 409 werden fehlende Anmerkungsdaten durch ein leeres Dokument ersetzt. Prüfen, ob eine unvollständige Konfliktantwort zu einem falschen Merge führen kann. |

Wichtigste Kandidaten laut Prüfer: 384–386 (Datenverlust bei unvollständigem Stundenplanabgleich), 392 (Überschreibung neuerer Anmerkungen beim Wiederherstellen), 412 (Arbeitsspeicher bei großen Uploads), 418–420 (fehlende Versionsangaben bei der Synchronisierung).

---

## Apple-Tiefenaudit Runde 13 (Nr. 421–440) – Prüfstand f8e7c1aa

Vorbemerkung des Prüfers: StudIPScheduleStoreTests.swift testet bereits mehrseitige API-Antworten, teilweise fehlgeschlagene Abgleiche, Sommer-/Winterzeit, manuelle Terminänderungen und die Zuordnung von Ausfällen. Nr. 381 und der pauschale Verdacht „jeder Teilfehler löscht alte Daten“ gelten daher nicht als bestätigte Bugs.

### 421–430: Engere Datenintegritätsprüfungen

| Nr. | Befund und genauer Test |
|---|---|
| 421 | Ungültige persönliche Stud.IP-Einträge: StudIPScheduleStore.swift:188–195 leert die Tabelle und überspringt anschließend Einträge mit fehlenden Pflichtfeldern. Test: Server liefert HTTP 200, aber ausschließlich fehlerhafte Einträge. Bleiben die bisherigen Termine erhalten? |
| 422 | Ungültige Zyklusdaten: StudIPScheduleStore.swift:201–208 ersetzt die Zyklustabelle und ignoriert nicht interpretierbare Einträge. Test: syntaktisch gültige, aber strukturell unvollständige Antwort. |
| 423 | Leere erfolgreiche Hochschulantwort: Unterscheiden zwischen „wirklich keine Termine“ und „Antwort unerwartet leer“ – vor einem vollständigen Ersetzen lokaler Daten. |
| 424 | Teilweise erfolgreiche Pagination: erste Seite ok, Folgeseite fehlgeschlagen → als unvollständiger Abruf behandeln. |
| 425 | Kursbezogene Löschung: StudIPScheduleStore.swift:177–178 ersetzt die Termine eines Kurses. Prüfen, ob ungültige Einträge bei erfolgreichem Abruf einen vollständigen Kursverlust auslösen können. |
| 426 | Doppelte Stud.IP-IDs: zwei Termine mit derselben ID überschreiben einander? |
| 427 | Abbruch während Datenbankaktualisierung: Transaktion vorhanden; testen, ob bei einem Fehler alle Änderungen zurückgerollt werden. |
| 428 | Alte und neue Semester: wiederverwendete Veranstaltungskennungen → falsche Semesterzuordnung? |
| 429 | Veraltete Ausfälle: nachträglich korrigierte Hochschulmeldung entfernt nur den zugehörigen automatischen Ausfall? |
| 430 | Fehlerstatus nach Teilerfolg: UI darf einen teilweise erfolgreichen Import nicht als vollständig darstellen. |

Stärkster Verdacht 421/422: HTTP 200 ist kein inhaltlich gültiger Datensatz – zuerst Test mit beschädigten, aber formal gültigen Antworten.

### 431–440: Synchronisations- und Merge-Risiken

| Nr. | Befund |
|---|---|
| 431 | AnnotationMerge.swift:84–87 bevorzugt bei zwei unterschiedlichen Änderungen den lokalen Stand und zählt einen Konflikt. Testen, ob die verworfene Serverversion wiederherstellbar bleibt. |
| 432 | AnnotationMerge.swift:18–20 verwendet ohne Objekt-ID den gesamten JSON-Inhalt als Identität; kleine Änderung = neues Objekt. |
| 433 | AnnotationMerge.swift:68–72 speichert Objekte nach ID im Dictionary; doppelte IDs fallen zusammen. |
| 434 | AnnotationMerge.swift:80–100 übernimmt zunächst die Serverreihenfolge; Ebenenreihenfolge bei überlappenden Zeichnungen prüfen. |
| 435 | AnnotationMerge.swift:123–133: bei konkurrierenden Seitenänderungen grundsätzlich Serverreihenfolge, nur neue lokale Seiten angehängt – lokale Umordnung kann verloren gehen (Produktentscheidung, darf nicht unbemerkt verwerfen). |
| 436 | Gleichzeitiges Löschen und Verschieben: pageOrder-Zusammenführung gegen Wiederauftauchen gelöschter Seiten testen. |
| 437 | Widerspruch zwischen Seitenliste und Seiteninhalt nach Merge: Reparatur darf nie fremde oder alte Inhalte übernehmen. |
| 438 | mergedDrawing() bevorzugt unter bestimmten Bedingungen die lokale Zeichnung; Strichsignaturen nach Merge prüfen. |
| 439 | SyncEngine.swift:703–711 protokolliert fehlgeschlagene ACK-Schreibvorgänge; Neustart danach korrekt mit Serverstand abgleichen? |
| 440 | SyncEngine.swift:686–690 ignoriert Fehler beim Entfernen einer alten Vergleichsbasis; nach Absturz fälschlich wiederverwendet? |

Vorhandene Tests (SyncEngineTests.swift): 1.000 und 5.000 Striche, Änderungen während Upload, Wiederherstellung nach simuliertem Absturz, parallele Schreib-/Sync-Anforderungen, höchstens ein Upload gleichzeitig. Nicht bewiesen: Verhalten auf echtem iPad unter Speicherdruck, mit beschädigten Dateien, bei Stromverlust.

Ergebnis der vertieften Codeprüfung (Prüfer): (1) StudIPScheduleStore.swift 188–208: ungültige, formal erfolgreiche Antwort kann bisherige Daten ersetzen → vor dem Löschen vollständig validieren, bei ungültigen Datensätzen Stand behalten und Teilfehler melden. (2) AnnotationMerge.swift 68–82: doppelte IDs fallen zusammen → vor dem Merge erkennen. (3) AnnotationMerge.swift 123–133: konkurrierende Seitenumordnung nicht vollständig zusammengeführt → Reihenfolgekonflikt anzeigen oder Drei-Wege-Regel für Seitenpositionen. (4) SyncEngine.swift 430–445: gezielter Test für Fehler zwischen Serverbestätigung und dauerhaftem Schreiben von acks.json. Reihenfolge: zuerst Regressionstests für diese vier Fälle, dann nur bestätigte Fehler beheben.

Auftrag Tiefentest (Wortlaut, gekürzt): A. Stud.IP-Stundenplan: HTTP 200 mit ungültigen persönlichen Einträgen; HTTP 200 mit beschädigten Zyklusdaten; leere und teilweise geladene Antworten; Fehler auf späterer Pagination-Seite; Abbruch während der SQLite-Transaktion; Semesterwechsel und doppelte Kennungen. B. AnnotationMerge: gleichzeitiges Ändern desselben Objekts; Objekte ohne ID und mit doppelten IDs; unterschiedliche Ebenenreihenfolgen; gleichzeitiges Löschen und Verschieben von Seiten; gleichzeitige Umordnung; PencilKit-Daten nach Drei-Wege-Merge. C. SyncEngine: fehlgeschlagenes ACK-Schreiben; beschädigte/veraltete Basisdatei; Neustart zwischen Serverbestätigung und Journalaktualisierung; wiederholte 409-Konflikte; Verbindungsabbruch nach erfolgreicher serverseitiger Speicherung. Je Test: erwartetes/tatsächliches Verhalten, Reproduzierbarkeit, Datei/Zeile, Schweregrad, Fix, Regressionstest. Keine bestätigten Bugs ohne fehlgeschlagenen Test oder eindeutigen Codebeweis.

---

## Apple Nr. 501–520: PDF-Anzeige, eingebettete Bilder, Anmeldung, Lösungsvorschau

| Nr. | Fundstelle | Ergebnis |
|---|---|---|
| 501 | PageObjects.swift:238–241 | Cache-Fehlerkandidat: Die Anzeigesignatur enthält nur die Schlüssel der Bilder, nicht deren Inhalt. Wird ein Bild unter demselben Schlüssel ersetzt, kann die Anzeige unverändert bleiben. |
| 502 | PageObjects.swift:241–257 | Bei unveränderter Signatur werden die Unteransichten nicht neu aufgebaut. Prüfen, ob ein zuvor fehlendes Bild später sichtbar wird, wenn sein Schlüssel bereits existierte. |
| 503 | DisplayLayout.swift:53 | Ein ungültiger PDF-Seitenindex wird direkt an PDFDocument.page(at:) übergeben; Index außerhalb des Bereichs kann eine Exception auslösen. |
| 504 | DisplayLayout.swift:46–53 | Ein beschädigter pageOrder-Eintrag wird übersprungen. Prüfen, ob die angezeigte Seitenzahl von der gespeicherten Struktur abweicht. |
| 505 | DisplayLayout.swift:47 | Doppelte Seitenschlüssel werden übersprungen. Als Dokumentfehler melden statt Seite unbemerkt ausblenden. |
| 506 | DisplayLayout.swift:58–63 | Breite/Höhe eingefügter Leerseiten ohne Plausibilitätsprüfung an PDFKit. Negative, unendliche, extrem große Werte testen. |
| 507 | DisplayLayout.swift:48,57 | Jeder unbekannte Seitentyp wird wie eine Leerseite behandelt. |
| 508 | DisplayLayout.swift:73 | Rotationen werden auf 90-Grad-Schritte abgerundet; nicht normierte Werte beim Import prüfen. |
| 509 | DisplayLayout.swift:29–33 | Größenberechnung nach mehrfacher Drehung und Umordnung prüfen. |
| 510 | SolutionLayer.swift:22–25 | Mehrere fremde Lösungsseiten mit demselben PDF-Index überschreiben sich im Dictionary; solche Pakete vorher ablehnen? |
| 511 | AccountStore.swift:74–76 | Bei Neuinstallation werden Schlüsselbund-Löschfehler nicht geprüft, bevor der Installationsmerker gesetzt wird. |
| 512 | AccountStore.swift:139–147 | Speichern der Apple-Nutzerkennung nicht auf Erfolg geprüft; Anmeldung könnte nur im Arbeitsspeicher erfolgreich sein. |
| 513 | AccountStore.swift:144–146 | Nutzerkennung, Name und E-Mail einzeln gespeichert; Absturz dazwischen → unvollständige Kontodaten. |
| 514 | AccountStore.swift:183–188 | Beim Abmelden werden Schlüsselbund-Löschfehler ignoriert; Konto nach Neustart wieder da? |
| 515 | AccountStore.swift:235–239 | Kontolöschablauf akzeptiert asynchrone Schritte ohne Fehlerergebnis; Erfolg kann trotz internem Fehler angezeigt werden (ergänzt Nr. 477: Erfolg erst, wenn alle Schritte abgeschlossen oder ausdrücklich als offen gemeldet). |
| 516 | SolutionLayer.swift:59–62 | Bildgrößenprüfung nutzt Multiplikationsergebnis auch bei Integer-Overflow. |
| 517 | SolutionLayer.swift:67–75 | Bilder nach Headerprüfung als UIImage; manipulierte Bilder mit zulässigem Header → Speicherverbrauch prüfen. |
| 518 | SolutionLayer.swift:82–90 | Vorschaugröße aus übergebener Breite; null, negativ, unendlich, extrem groß abfangen. |
| 519 | PageObjects.swift:143–146 | Extrem lange Texte → aufwendiges Textlayout; Begrenzung im Renderer fehlt. |
| 520 | PageObjects.swift:238–257 | Kompletter Objektinhalt wird wiederholt in JSON umgewandelt (Anzeigesignatur); Reaktionszeit bei umfangreichen Seiten. |

Hinweis des Prüfers: Bereits vorhandene Schutzmaßnahmen (Bildgrößenlimits, getrennte Datenspeicherung nach Konto und Hochschule) sprechen gegen frühere Vermutungen.

---

## Apple Nr. 521–570: natives Backend (Platzhalter), Router, Datenbank, Einstellungen – Prüfstand 91eac52c

### 521–535: Lernkalender, Aufgaben, Lernpakete (PendingStudyEndpoints.swift, PendingTimetableEndpoints.swift)

| Nr. | Befund | Einstufung |
|---|---|---|
| 521 | GET /api/calendar erzeugt Kalendertage aus Einstellungen, aber noch ohne echte Lernaufgaben. | Funktionslücke |
| 522 | GET /api/calendar/feasibility gibt open_minutes: 0 zurück. | Funktionslücke |
| 523 | Machbarkeit verwendet feste 28 Tage statt der Verteilung offener Aufgaben. | Logiklücke |
| 524 | POST /api/calendar/generate meldet immer created: 0. | Funktionslücke |
| 525 | POST /api/calendar/suggest liefert immer eine leere Liste. | Funktionslücke |
| 526 | POST /api/calendar/apply meldet immer moved: 0. | Funktionslücke |
| 527 | GET /api/tasks/open gibt immer eine leere Liste. | Funktionslücke |
| 528 | POST /api/tasks/skip bestätigt, ohne eine Aufgabe zu verändern. | Irreführende Erfolgsantwort |
| 529 | PATCH /api/tasks/{id} bestätigt mit JSON null, ohne zu bearbeiten. | Irreführende Erfolgsantwort |
| 530 | DELETE /api/tasks/{id} liefert Erfolg, ohne zu löschen. | Irreführende Erfolgsantwort |
| 531 | POST /api/tasks/{id}/status validiert, findet aber grundsätzlich keine Aufgabe. | Funktionslücke |
| 532 | POST /api/packages lehnt das Anlegen ausdrücklich ab. | Funktionslücke |
| 533 | PATCH /api/packages/{id} kann ohne Datumsänderung Erfolg melden, obwohl nichts geändert wird. | Irreführende Erfolgsantwort |
| 534 | DELETE /api/packages/{id} bestätigt, ohne zu löschen. | Irreführende Erfolgsantwort |
| 535 | POST /api/timetable/reslot liefert nur die übergebenen Termine zurück. | Funktionslücke |

Wichtig: 528–530, 533–534 – eine nicht implementierte Funktion darf keinen erfolgreichen Schreib- oder Löschvorgang vortäuschen (Regel G6 „kein Erfolg ohne Wirkung“).

### 536–550: Dashboard, Suche, Noten, Karteikarten (PendingOverviewEndpoints, PendingLibraryEndpoints, PendingServicesEndpoints)

| Nr. | Befund | Einstufung |
|---|---|---|
| 536 | /api/dashboard liefert eine leere Modulliste, obwohl Module lokal gespeichert sein können. | Funktionslücke |
| 537 | Wochenübersicht meldet done: 0 und total: 0. | Funktionslücke |
| 538 | Dashboard-Rückstand (backlog) fest 0. | Funktionslücke |
| 539 | Bevorstehende Lernaufgaben (upcoming) leer. | Funktionslücke |
| 540 | Wochenansicht: alle täglichen Lernminuten 0. | Funktionslücke |
| 541 | /api/bg liefert festen Hintergrundstatus, nicht den tatsächlichen Hochschulabgleich. | Statuslücke |
| 542 | /api/search liefert unabhängig vom Suchbegriff leere Ergebnisse. | Funktionslücke |
| 543 | /api/files/{id}/pagetext nicht implementiert. | Funktionslücke |
| 544 | /api/related liefert keine verwandten Dokumente. | Funktionslücke |
| 545 | /api/grades/sync als nicht verfügbar implementiert. | Funktionslücke |
| 546 | /api/qis/documents/{id} stellt keine QIS-Dokumente bereit. | Funktionslücke |
| 547 | /api/flashcards gibt eine leere Liste zurück. | Funktionslücke |
| 548 | /api/flashcards/{id}/review führt keine Lernbewertung durch. | Funktionslücke |
| 549 | /api/flashcards/{id} bestätigt das Löschen, ohne zu entfernen. | Irreführende Erfolgsantwort |
| 550 | /api/services gibt für alle Hochschuldienste configured: false, unabhängig von vorhandenen WebKit-Sitzungen. | Integrationsrisiko |

Einige Funktionen sind bewusst für spätere Versionen vorgesehen – keine pauschalen V1-Blocker; kritisch nur, wenn die Oberfläche sie als funktionsfähig anbietet.

### 551–560: Router, Datenbank, Fehlerbehandlung (LocalRouter.swift, SQLiteDatabase.swift, LocalBackendHost.swift)

| Nr. | Befund | Einstufung |
|---|---|---|
| 551 | LocalRouter.swift:124–127: Doppelte Routen werden protokolliert, aber registriert. | Konfliktrisiko |
| 552 | LocalRouter.swift:139–151: Bei gleich spezifischen Routen entscheidet die Registrierungsreihenfolge. | Regressionstest |
| 553 | LocalRouter.swift:157–162: 405 bei falscher Methode – auch bei dynamischen und statischen Routen? | Router-Test |
| 554 | LocalRouter.swift:164–168: Integer-Pfadparameter nur auf Int-Konvertierbarkeit geprüft; negative/extrem große IDs. | Eingabeprüfung |
| 555 | LocalRouter.swift:175–178: Interne SQLite-Fehlermeldungen gehen an die API-Antwort. | Datenschutzrisiko |
| 556 | SQLiteDatabase.swift:279–280: Abfrage kann alle Zeilen in den Speicher laden. | Belastungstest |
| 557 | SQLiteDatabase.swift:244–249: BLOB-Länge in Int32; Größenprüfung darüber. | Grenzwertprüfung |
| 558 | SQLiteDatabase.swift:413–437: Fehler beim Rollback nach fehlgeschlagenem COMMIT ignoriert. | Wiederherstellungstest |
| 559 | LocalBackendHost.swift:99–107: Fehler beim Setzen des Dateischutzes ignoriert. | Sicherheitsprüfung |
| 560 | LocalBackendHost.swift:58–71: Nach fehlgeschlagenem Datenbankstart Startversuch zurückgesetzt; wiederholte teure Initialisierungen. | Belastungstest |

Positiv: Datenbank über Actor serialisiert, Transaktionen ohne await.

### 561–570: Einstellungen und Kontoverwaltung (SettingsPage.swift)

| Nr. | Befund | Einstufung |
|---|---|---|
| 561 | 64–71: API-Fehler beim lokalen Laden mit try? unterdrückt. | Fehlerbehandlung |
| 562 | 69–71: Fehlgeschlagener Modulabruf → leere Modulliste („keine Module“). | UX-Fehlerkandidat |
| 563 | 69–71: Dasselbe beim Kursabruf. | Fehlerbehandlung |
| 564 | 60–85: Mehrere asynchrone Ladevorgänge können sich bei schnellem Server-/Kontowechsel überholen. | Race-Condition-Kandidat |
| 565 | 75–85: Nach Fehler bleiben zuvor geladene Serverdaten sichtbar – als veraltet kennzeichnen? | Aktualitätsrisiko |
| 566 | 214–220: Nach Speichern wird optional die Navigation neu geladen; schneller zweiter Speichervorgang. | Race-Condition-Test |
| 567 | 531–533: Darstellungseinstellungen über globale AppStorage-Schlüssel; welche geräteweit, welche kontospezifisch? | Kontotrennung |
| 568 | 554–562: Lokale Eingabewerte beim Erscheinen übernommen; späterer Datenwechsel? | UI-Test |
| 569 | 839–846: Semester speichern ohne Prüfung ungültiger Datumsbereiche. | Validierung |
| 570 | 566–579: Stud.IP-Zugangskarte mit Text für den eigenen PC-Server – nur im richtigen Servermodus zeigen. | UX-Test |

Zuerst beheben laut Prüfer: 528–530, 533–534, 549 (keine Erfolgsantworten ohne Wirkung); 564; 555; 559; 536–550 je Funktionslücke entscheiden (V1 fertigstellen oder klar als nicht verfügbar kennzeichnen).

---

## Windows/Android Nr. 571–590 (Prüfstand 91eac52c) – PC-Sitzung

| Nr. | Plattform | Befund | Bewertung |
|---|---|---|---|
| 571 | Android | SharedFixtureTest.kt:45: Seitenfeld stimmt bei mindestens einem Merge-Test nicht überein. | Bestätigter Testfehler |
| 572 | Android | AnnotationMerge.kt berücksichtigt pkdrawing-v2 nicht ausdrücklich. | Ursache von 571 (laut Runde 653 inzwischen vorhanden) |
| 573 | Android | Kotlin-Merge übernimmt Zeichnung nur bei vollständig gleicher Objektliste; teilweise gültige v2-Zeichnung kann verloren gehen. | Datenverlustkandidat |
| 574 | Android | Kotlin unterstützt nur Seiten-Merge, nicht die ganze Dokumentstruktur mit pageOrder. | Funktionslücke |
| 575 | Android | mergeObjects() fasst Objekte mit doppelter ID zusammen. | Codebefund |
| 576 | Android | Bei gleichzeitiger Änderung gewinnt lokal; Serverversion nicht erhalten. | Konfliktstrategie |
| 577 | Android | Kanonische Zahlenumwandlung über Double; große Ganzzahlen verlieren Präzision. | Präzisionstest |
| 578 | Android | Es fehlt eine Android-App mit Anmeldung, PDF-Anzeige und Offline-Datenbank. | Android-Release-Blocker |
| 579 | Android | Workflow testet nur Kotlin/JVM, keinen Android-Build/Emulator. | Testabdeckung |
| 580 | Android | Fixtures testen keine geräteübergreifende Synchronisierung mit Netzunterbrechung. | Testlücke |
| 581 | Windows | tests/test_desktop.py:67: Elternprozessüberwachung löst unter Linux-CI nicht aus. | Bestätigter Testfehler |
| 582 | Windows | app/desktop.py: beendeter, nicht abgeholter Kindprozess unter Unix gilt als vorhanden. | Ursachenhypothese |
| 583 | Windows | main.rs: Startdatei nur über Zeitstempel geprüft, nicht gegen die PID des Backend-Prozesses. | Race-Condition-Kandidat |
| 584 | Windows | main.rs: Backend-URL aus backend.json ohne Beschränkung auf http://127.0.0.1. | Sicherheitsprüfung |
| 585 | Windows | main.rs: wartet bis 90 s, prüft nicht, ob der Prozess beendet wurde. | Startverhalten |
| 586 | Windows | app/desktop.py: freier Port ermittelt, erst später geöffnet (Race). | Race-Condition-Kandidat |
| 587 | Windows | start.js: im Entwicklungsmodus Weiterleitung bei jeder HTTP-Antwort. | Codebefund |
| 588 | Windows | tauri.conf.json 0.3.0 vs. package.json 0.2.0. | Bestätigte Versionsabweichung |
| 589 | Windows | Installer-Workflow nur manuell; kein nachgewiesener Build. | Release-Prüfung |
| 590 | Windows | Zustandsdatei vor dem tatsächlichen Start des HTTP-Servers geschrieben. | Startfehler-Test |

## Windows/Android Nr. 653–660 (Prüfstand d649773a)

| Nr. | Plattform | Fundstelle und Problem | Bewertung |
|---|---|---|---|
| 653 | Android | AnnotationMerge.kt:109–112: beide pkdrawing-v2 → lokal ohne strokeSigs-Vergleich gewählt; neuere Serverzeichnung kann übergangen werden. | Datenverlustkandidat |
| 654 | Android | AnnotationMerge.kt:117–120: für pkdrawing-v2 genügt strokeSigs als Array; Passung zu den Strichen ungeprüft. | Validierungslücke |
| 655 | Android | AnnotationMerge.kt:38–40: Objekte ohne ID erhalten Kennung aus dem Inhalt; Inhaltsänderung = neues Objekt. | Konfliktrisiko |
| 656 | Android | AnnotationMerge.kt:44–45: associateBy behält bei doppelter ID nur den letzten Eintrag. | Datenintegrität |
| 657 | Android | AnnotationMerge.kt:82–83: Seite gelöscht vs. verändert → Seite bleibt, Löschwunsch nicht dokumentiert. | Konfliktstrategie |
| 658 | Windows | windows.yml:37: Move-Item erwartet Chromium-Verzeichnis an fester Stelle. | Build-Risiko |
| 659 | Windows | windows.yml:69: Windows-Icons aus Datei unter apps/apple/. | Plattformkopplung |
| 660 | Windows | windows.yml:70–79: Installer wird gebaut, aber nicht testweise installiert. | Testlücke |

## Android Nr. 661–669 (Prüfstand c29d1c53)

| Nr. | Fundstelle und Problem | Bewertung |
|---|---|---|
| 661 | DocumentScreen.kt:110–125: doc, dirty, bitmap, pageIndex beim Laden eines neuen Dokuments nicht gemeinsam zurückgesetzt. | Zustandsrisiko |
| 662 | DocumentScreen.kt:117–124: Scheitert das Laden der Annotationen, bleibt der Renderer offen; kein erneuter Versuch. | Fehlerbehandlung |
| 663 | DocumentScreen.kt:144–146: schnelles Tippen auf „Nächste Seite“ startet mehrere Speicher-/Rendervorgänge ohne Sperre. | Race-Condition-Risiko |
| 664 | DocumentScreen.kt:154–155: Division durch pageSizePt.second ohne Prüfung. | Grenzfall |
| 665 | DocumentScreen.kt:196–199: Strichbreite/Transparenz nicht begrenzt. | Validierungslücke |
| 666 | Repo.kt:60–69: vorhandenes PDF nur nach Existenz/Größe akzeptiert. | Datenintegritätsrisiko |
| 667 | Repo.kt:64–69: Download nicht als PDF geprüft, bevor er in den Cache geht. | Fehlerbehandlung |
| 668 | Ink.kt:20–23: Skalierungsfaktor 0 → ungültige Koordinaten. | Grenzfallfehler |
| 669 | Ink.kt:48–52: Farbwerte unerwarteter Länge ungeprüft als ARGB. | Darstellungsfehler |

## Android Nr. 670–681

| Nr. | Fundstelle und Problem | Bewertung |
|---|---|---|
| 670 | DocumentScreen.kt:158–159: „Nur Stift“ – Fingerberührung ignoriert, aber nicht konsumiert. | Bedienungsrisiko |
| 671 | DocumentScreen.kt:179–183: Strich nur mit ≥ 2 Punkten; einzelner Stifttipp erzeugt keinen Punkt. | Konkreter Funktionsfehler |
| 672 | DocumentScreen.kt:188–199: nur Objekte vom Typ stroke werden gezeichnet. | Funktionslücke |
| 673 | CalendarScreen.kt:67–71: Checkbox während Statusänderung bedienbar. | Race-Condition-Risiko |
| 674 | CalendarScreen.kt:42: Fehlermeldung beim Wochenwechsel nicht zurückgesetzt. | UI-Fehler |
| 675 | HomeScreen.kt:47–49: nach „Abgleich starten“ kein automatisches Neuladen. | Aktualisierungsproblem |
| 676 | HomeScreen.kt:40: Abmeldung wartet auf repo.logout(). | UX-/Netzwerkrisiko |
| 677 | LibraryScreen.kt:29–31: Liste nur beim Laden/Reload aktualisiert. | Aktualisierungsproblem |
| 678 | TimetableScreen.kt:52: Termine mit Status „verschoben“ vollständig ausgeblendet. | Darstellungsfehler, falls kein Ersatztermin geliefert wird |
| 679 | SyncApi.kt:60–61: ungültige Einträge in changes stillschweigend verworfen. | Datenintegritätsrisiko |
| 680 | SyncApi.kt:69–75: fehlerhafte ID-Zuordnungen ohne Fehlermeldung übersprungen. | Validierungslücke |
| 681 | ApiClient.kt:85–86: HTTP 300–399 gelten als Erfolg, obwohl Weiterleitungen deaktiviert sind. | Konkreter Protokollfehler |

Abschließende Einordnung des Prüfers: Die 681 Punkte sind keine 681 bestätigten Bugs; darunter echte Codefehler, Risiken, Testlücken und Überschneidungen. Nächste Phase auf P0/P1 beschränken: Abstürze, Datenverlust, Sicherheitslücken, nachweislich nicht funktionierende Funktionen. Noch nicht ausreichend geprüft: Windows-Installation/-Deinstallation, mehrere Instanzen, Backend-Abstürze; echte Android-Gerätetests; Synchronisierung bei gleichzeitigen Änderungen und Verbindungsabbrüchen; Sitzungsverwaltung/Rechteprüfung; große PDFs, Tausende Dokumente.
