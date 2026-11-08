# Datenschutzerklärung StudiNow

**Entwurf, Stand 07.11.2026 (26.10.2026). Keine Rechtsberatung – vor der Veröffentlichung anwaltlich prüfen.**

Diese Erklärung gilt für die StudiNow-Apps (iPad und Mac, Android, Windows), die Web-Oberfläche und den
gehosteten StudiNow-Dienst unter `https://studinow.app`. Sie ist so aufgebaut, wie StudiNow arbeitet: Vieles bleibt auf deinem
Gerät; nur mit einem StudiNow-Konto verarbeiten wir Daten auf unseren Servern, und auch dann nur das, was du
eingeschaltet hast.

## 1. Das Wichtigste in Kürze

- **Ohne StudiNow-Konto** (iPad-App) bleiben alle Daten auf deinem Gerät (Abschnitt 3). Wir erhalten nichts – außer
  dem, was du auf dem iPad bewusst mit anderen teilst: Community-Beiträge, gemeinsame Wochentests und Einträge der
  Bibliothek liegen verschlüsselt in Apples iCloud (Abschnitt 8b). Die Web-Oberfläche und die Windows-App brauchen
  seit dem 05.11.2026 immer ein StudiNow-Konto (Abschnitt 5).
- **Mit StudiNow-Konto** speichern wir deine E-Mail-Adresse, dein Passwort nur als Hash, deine Hochschule, Sitzungen
  und Tarif (Abschnitt 5). Den Abgleich mit deiner Hochschule, den Abgleich zwischen deinen Geräten und die Community
  schaltest du einzeln ein (Abschnitte 6–8).
- **Deine Hochschul-Zugangsdaten** gibst du nur bei den Systemen deiner Hochschule ein. Wenn du sie merken lässt,
  liegen sie nur auf deinem Gerät (iPad, PC). **Auf unseren Servern speichern wir Hochschul-Passwörter nie** – auch
  nicht für die Web-Version (seit 06.11.2026; Abschnitt 6). Den Abgleich mit deiner Hochschule erledigt die iPad-App
  oder die Windows-App auf deinem Gerät; in der Web-Version lädst du Unterlagen selbst hoch.
- **Kein Tracking, keine Werbung, kein Verkauf von Daten, keine Analyse-Werkzeuge Dritter.** KI gibt es nur für
  KI-Funktionen, die du nutzt. Es gibt zwei Wege:
  - Du verbindest **dein eigenes ChatGPT** (Abschnitt 8a). Dann gehen die Texte direkt von deinem Gerät an OpenAI.
    Diese Verbindung ist in den Apps noch ausgeschaltet („bald verfügbar“).
  - Du nutzt im Tarif **Pro AI** die **StudiNow-KI** (Abschnitt 8c). Dann gibt der Dienst die einzelne Anfrage an einen
    von zwei Auftragsverarbeitern weiter: OpenAI oder Amazon Web Services (Frankfurt).

## 2. Verantwortlicher

IT solutions by Ahmad Fakih (Einzelunternehmen, Inhaber: Ahmad Fakih), Baldurstraße 5, 30657 Hannover, Deutschland,
E-Mail: support@studinow.app (siehe Impressum). Einen Datenschutzbeauftragten gibt es nicht, weil die
gesetzlichen Voraussetzungen dafür nicht vorliegen.

## 3. Was auf deinem Gerät bleibt

Die Apps arbeiten zuerst lokal. Auf dem Gerät gespeichert werden:

- Dateien, Kurse, Termine, Fristen und Ankündigungen aus den Systemen deiner Hochschule, die die App für dich abruft;
- deine Notizen (Handschrift, Text, Formen, Bilder), eigene Dokumente, Lesezeichen, Papierkorb;
- Stundenplan, Lernkalender, Lernpakete, Aufgaben, Karteikarten, Zeitmesser und Einstellungen;
- iPad: eigene Vorlesungsaufnahmen (Audio) und ihre Mitschrift. Aufgenommen wird nur, wenn du „Aufnehmen“ antippst
  und dem Zugriff auf das Mikrofon zustimmst; die Mitschrift erzeugt die Spracherkennung von iOS ausschließlich auf
  dem Gerät (ohne Apple-Server, nur nach deiner Zustimmung zur Spracherkennung). Aufnahme und Mitschrift verlassen
  das iPad nicht; „Löschen“ entfernt beides. Nur wenn du es ausdrücklich antippst, geht der **Text** eines Teils der
  Mitschrift an dein ChatGPT (Abschnitt 8a) – nie die Audioaufnahme. Ob du eine Vorlesung aufnehmen darfst, klärst du
  mit den Lehrenden;
- Hochschul-Zugangsdaten merkt sich – wenn du das beim Anmelden erlaubst – der Passwort-Manager deines Geräts
  (Android: Google Password Manager oder Samsung Pass im Anmeldefenster; iPad: Passwort-Autofill von iOS mit dem
  Schlüsselbund bzw. iCloud-Schlüsselbund, verantwortlich ist Apple; am PC das von der App geöffnete Browserfenster); die App
  selbst speichert weder Benutzername noch Passwort und meldet sich nie von selbst an. Ausnahme iPad-App: Sie merkt
  sich auf dem Gerät deinen Hochschul-Benutzernamen, damit er beim nächsten Anmelden schon eingetragen ist, und – nur
  wenn du „Passwort auf diesem iPad merken“ eingeschaltet lässt – dein Hochschul-Passwort, um dich nach Ablauf einer
  Sitzung selbst wieder anzumelden („Automatisch anmelden“, Abschnitt 4); Abmelden löscht beides. Nach der Anmeldung behält die
  App nur die Sitzung (Cookies) der Hochschule, bei der Universität Hildesheim zusätzlich den Learnweb-Schlüssel, bis
  du dich abmeldest oder die Hochschule sie beendet. Nur wenn du es am PC ausdrücklich einträgst, liegen die
  Zugangsdaten für den Abgleich ohne Nachfrage in der Datei `.env` im Datenordner der App – jederzeit löschbar.

Der PC-Modus (eigener Server auf deinem Rechner, Ordner `data/`) ist ebenfalls rein lokal; im eigenen WLAN schützt
eine PIN den Zugriff. Diese Daten verlassen dein Gerät nur, wenn du den Geräteabgleich (Abschnitt 7) einschaltest.
Wir speichern auf deinem Gerät nur, was für die Funktion nötig ist oder was du selbst einstellst (§ 25 Abs. 2 TDDDG).

Für die **iPad-App ohne StudiNow-Konto** gelten dieser Abschnitt, Abschnitt 4 (Hochschule) und – nur wenn du die
Funktionen nutzt – Abschnitt 8b (Community, gemeinsame Wochentests und Bibliothek über Apple iCloud). „Mit Apple
anmelden“ beim Start und das Abo laufen dann allein über Apple (Abschnitt 9); an uns wird dabei nichts übertragen,
deine Apple-Kennung bleibt auf dem iPad. Meldest du dich auf dem iPad freiwillig bei deinem **StudiNow-Konto** an
(Einstellungen → Zugang & Darstellung → StudiNow-Konto, z. B. für die StudiNow-KI in Pro AI), gelten zusätzlich die
Abschnitte 5, 7, 8, 8c und 9: Der Sitzungsschlüssel liegt nur im Schlüsselbund dieses iPads, die App gleicht mit
deinem Konto ab und meldet deine App-Store-Käufe an den Dienst. „Abmelden“ beendet das.

## 4. Systeme deiner Hochschule

StudiNow liest für dich aus den Systemen deiner Hochschule. Je nachdem, welche Hochschulen die jeweilige
App-Version anbindet, sind das – Leibniz Universität Hannover: Stud.IP, WebSSO und
QIS; Hochschule Hannover: Moodle, HISinOne (Campusmanagement), QIS und deren Anmeldung (SSO); Universität Hildesheim:
Learnweb, LSF, PLuS (HISinOne) und CAS-Anmeldung. Die App auf deinem Gerät (nie unser Dienst) meldet
sich dort mit **deinen** Zugangsdaten an und ruft Kurse, Dateien, Termine,
Fristen, Ankündigungen und – nur wenn du „Noten abrufen“ wählst – deinen Notenspiegel und Bescheinigungen ab.
Geschrieben wird nur, wenn du es ausdrücklich auslöst: Antwortest du in der App auf eine Nachricht oder gibst du mit
„Jetzt abgeben“ eine Datei ab, sendet StudiNow genau diese Antwort bzw. Datei mit deinem Zugang an das System deiner
Hochschule. Darüber hinaus schreibt StudiNow nichts in die Hochschulsysteme.

**Lehrende (Leibniz Universität Hannover, Stud.IP):** Für deine aktuellen Kurse liest StudiNow Name, Rolle,
E-Mail-Adresse und Sprechstunde der Lehrenden und Tutor/innen, so wie Stud.IP sie dir zeigt; diese Angaben bleiben auf
deinem Gerät bzw. PC (nie im gehosteten Dienst), Daten anderer Studierender liest StudiNow nicht, und eine Nachricht an
Lehrende geht nur hinaus, wenn du sie selbst mit „Senden“ abschickst.

**Uni-Mail und Uni-Kalender (Leibniz Universität Hannover und Universität Hildesheim, nur iPad-App und
Windows-App/PC):** Verbindest du Uni-Mail, meldest du dich selbst auf der SOGo-Seite deiner Hochschule an (LUH:
`kalender.uni-hannover.de`, Uni Hildesheim: `webmail.uni-hildesheim.de`); die App spricht nur mit diesem Rechner deiner
Hochschule, jede Hochschule hat ihre eigene Sitzung. StudiNow speichert die Sitzung (Cookies) im
Schlüsselbund bzw. im Datenordner deines PCs und deinen Kontonamen aus der Adresse von SOGo; dein Passwort nur in der
iPad-App und nur, wenn du es erlaubst („Automatisch anmelden“, unten), am PC nie. Die App ruft deine Ordner,
die Kopfzeilen deiner E-Mails (Absender, Betreff, Datum), die E-Mails, die du öffnest, ihre Anhänge, die du antippst,
und – nur wenn du „Termine übernehmen“ wählst – die Termine deines Uni-Kalenders direkt bei SOGo ab. **E-Mails, Anhänge
und Termine bleiben auf deinem Gerät bzw. PC und in deinem Uni-Postfach; nichts davon geht an Server von StudiNow, auch
nicht im gehosteten Dienst** (dort gibt es Uni-Mail nicht). Auf dem Gerät liegen nur die Kopfzeilen der ersten Seite des
Posteingangs (Anzeige ohne Netz), die übernommenen Termine und geöffnete Anhänge in einem temporären Ordner. Beim
Öffnen einer E-Mail markiert SOGo sie als gelesen. Geschrieben wird nur auf deinen ausdrücklichen Wunsch: Antworten,
Weiterleiten, neue E-Mails und Anhänge legt StudiNow als Entwurf in deinem Postfach an; gesendet wird erst mit
„Senden“ und deiner Bestätigung, genau einmal. „Als ungelesen“, „Markieren“ und „In den Papierkorb“ ändern nur diese
E-Mail (endgültig gelöscht wird nie). Bilder aus dem Internet in E-Mails lädt die App nicht. Auf Wunsch („Bei neuen
Uni-Mails benachrichtigen“, Vorgabe aus) zeigt das iPad eine Mitteilung mit der Zahl neuer E-Mails, ohne Absender und
Betreff. „Abmelden“ löscht Sitzung, Zwischenspeicher und übernommene Termine auf dem Gerät.

**Automatisch anmelden (nur iPad-App, freiwillig):** Unter jeder Anmeldeseite deiner Hochschule steht der Schalter
„Passwort auf diesem iPad merken – du wirst nicht erneut gefragt“ (voreingestellt an, jederzeit abschaltbar). Ist er an,
liest die App beim Absenden des echten Anmeldeformulars deiner Hochschule deinen Benutzernamen und dein Passwort mit und
legt sie nach erfolgreicher Anmeldung **nur auf diesem iPad im Schlüsselbund** ab (nur dieses Gerät, nicht in
iCloud-Schlüsselbund oder Backups, ein Eintrag je Hochschule). Läuft später eine Sitzung ab (Stud.IP, QIS, Uni-Mail,
Learnweb, LSF, PLuS, Moodle, Campusmanagement), meldet sich die App unsichtbar auf genau diesen Anmeldeseiten deiner
Hochschule wieder an und wiederholt den Abruf einmal. Das Passwort geht nur an die Anmeldeseiten deiner Hochschule, nie
an StudiNow-Server oder andere Rechner, und wird nicht protokolliert. Lehnt die Hochschule es ab (z. B. nach einem
Passwortwechsel), fragt die App einmal „Anmeldung nötig“; die neue Anmeldung ersetzt das alte Passwort. „Abmelden“,
„Gespeichertes Passwort löschen“ bzw. der Schalter „Automatisch anmelden“ in den Einstellungen, „Daten dieser Hochschule
löschen“ und „Konto löschen“ entfernen den Eintrag. Rechtsgrundlage: deine Einwilligung (Art. 6 Abs. 1 lit. a DSGVO,
§ 25 Abs. 1 TDDDG), widerrufbar mit dem Schalter.

**Raumfinder (frei in jedem Tarif, ohne Anmeldung):** Suchst du im Raumfinder nach einem Raum, Gebäude oder einer
Einrichtung oder tippst du auf eine Raumangabe (etwa im Stundenplan, Lernkalender oder bei einer Klausur), schickt die App
– bzw. am PC und im Web unser Dienst – nur den Suchtext (z. B. „F102“ oder „1101“) an den öffentlichen Standortfinder der
Leibniz Universität Hannover (`standortfinder.uni-hannover.de`), ohne Zugangsdaten und ohne Bezug zu deiner Person.
Gefundene Orte bleiben 30 Tage im Zwischenspeicher deines Geräts bzw. des Dienstes. Für die Hochschule Hannover und die
Universität Hildesheim gibt es keinen öffentlichen Raumfinder; dort zeigt StudiNow nur die Adresse des Standorts aus
einer festen Liste, ohne Abfrage. **Google Maps und Apple Karten** erhalten von StudiNow nichts von selbst: Erst wenn du
auf „In Google Maps öffnen“, „Route“ oder „In Apple Karten“ tippst, öffnet sich die Karte (App oder Browser) mit dem
Ort bzw. den Koordinaten; ab dann gelten die Datenschutzhinweise von Google bzw. Apple.

Für diese Systeme ist deine Hochschule verantwortlich; es gelten ihre Datenschutzhinweise und Nutzungsregeln. Sie
sieht die üblichen Verbindungsdaten (IP-Adresse deines Geräts bzw. unseres Dienstes, Zeitpunkt). StudiNow ist kein
Angebot der Hochschulen und nicht mit ihnen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die
Hochschulsysteme selbst.

## 5. StudiNow-Konto und Anmeldung (gehosteter Dienst)

Wenn du ein StudiNow-Konto anlegst, verarbeiten wir:

| Daten | Zweck | Speicherdauer |
|---|---|---|
| E-Mail-Adresse, Hochschule, Zeitpunkt der Registrierung | Konto führen, Anmeldung, Zuordnung der Hochschule, Mitteilungen zum Konto | bis 30 Tage nach Löschung des Kontos |
| Passwort – nur als Hash (scrypt mit zufälligem Salz), nie im Klartext | Anmeldung | wie das Konto |
| „Mit Apple anmelden“ / „Mit Google anmelden“: Kennung des Anbieters und die von ihm übermittelte E-Mail-Adresse (bei Apple ggf. eine Weiterleitungsadresse) | Anmeldeweg mit dem Konto verknüpfen | wie das Konto |
| Sitzungen: Token nur als Hash, Gerätename (oder Browser-Kennung), Zeitpunkt der Anmeldung und letzten Nutzung | angemeldet bleiben (30 Tage, verlängert sich bei Nutzung), andere Geräte abmelden | bis Abmeldung oder Ablauf |
| Fehlgeschlagene Anmeldeversuche je Konto und Adresse | Schutz vor Passwortraten (Sperre nach 8 Versuchen für 10 Minuten) | 10 Minuten |
| Token für „Passwort vergessen“ (nur als Hash) | Passwort zurücksetzen | 30 Minuten oder bis zur Nutzung |
| Tarif (Free, Plus, Pro AI) und Rolle | Funktionen freischalten, Moderation | wie das Konto |

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (Vertrag über die Nutzung von StudiNow); für die Schutzmaßnahmen gegen
Missbrauch Art. 6 Abs. 1 lit. f DSGVO (unser Interesse an einem sicheren Dienst). Ohne diese Daten können wir kein
Konto führen. In der iPad-App kannst du StudiNow auch ohne Konto nutzen (Abschnitt 3). Die Web-Oberfläche und die
Windows-App brauchen immer ein StudiNow-Konto; ohne aktives Abo (nach der Probe) kannst du dort deine Daten nur
ansehen und exportieren, gelöscht wird dadurch nichts.

**Windows-App:** Du meldest dich mit E-Mail und Passwort deines StudiNow-Kontos an oder über deinen Browser („Mit
Apple anmelden“, „Mit Google anmelden“, Konto anlegen; die Anmeldung läuft dann auf der Anmeldeseite des Dienstes und
wird mit einem Einmal-Code an die App auf deinem PC übergeben). Dein Passwort geht dabei nur einmal verschlüsselt an den
Dienst und wird auf dem PC nicht gespeichert. Auf dem PC liegen nur ein Sitzungsschlüssel in der
Windows-Anmeldeinformationsverwaltung (du löschst ihn mit „Abmelden“) und der zuletzt abgerufene Abo-Stand (Tarif,
Probe, Ablauf), damit die App bis zu 7 Tage ohne Internet weiter funktioniert. Beim Abruf erfährt der Dienst, dass die
Anfrage von der Windows-App kommt.

**iPad-App:** Das Konto ist auf dem iPad freiwillig. Du meldest dich in den Einstellungen mit Apple an (Apple übergibt
dem Dienst ein Identitäts-Token mit deiner Apple-Kennung und – beim ersten Mal, wenn du zustimmst – deiner E-Mail-Adresse;
der Dienst legt damit ein Konto an oder meldet dich an) oder mit E-Mail und Passwort. Auf dem iPad liegt danach nur ein
Sitzungsschlüssel im Schlüsselbund dieses Geräts (nicht in iCloud); „Abmelden“ und „Konto löschen“ entfernen ihn.

## 6. Keine Hochschul-Zugangsdaten auf unseren Servern

**Deine Hochschul-Passwörter liegen nur auf deinem Gerät, nie auf unseren Servern.** Seit dem 06.11.2026 nimmt der
StudiNow-Dienst Hochschul-Zugangsdaten (Benutzername und Passwort), Learnweb- oder Moodle-Schlüssel und
Hochschul-Sitzungen (Cookies) nicht mehr an – auch nicht für die Web-Version und auch nicht mit deiner Zustimmung.
Der Dienst meldet sich nie bei deiner Hochschule an und gleicht nicht selbst ab.

- Den Abgleich mit deiner Hochschule (Kurse, Dateien, Termine, Noten) macht die **iPad-App** oder die **Windows-App**
  auf deinem Gerät. Wo sie Zugangsdaten oder Sitzungen ablegt, steht in Abschnitt 3.
- In der **Web-Version** lädst du Unterlagen selbst hoch; sie liegen dann wie beschrieben in deinem Konto (Abschnitt 7).
- Hochschul-Zugangsdaten, die Nutzer früher (Entscheidung vom 30.10.2026, mit Zustimmung) im Konto hinterlegt hatten,
  haben wir beim Umstellen des Dienstes gelöscht (in der Datenbankdatei überschrieben); in Sicherungskopien
  verschwinden sie, sobald diese turnusmäßig ersetzt werden.

Bitte prüfe, ob die Nutzungsregeln deiner Hochschule den Abruf durch eine App mit deinen Zugangsdaten erlauben
(Abschnitt 4 der Nutzungsbedingungen).

## 7. Deine Inhalte im Dienst und Abgleich zwischen Geräten

Mit Konto speichert der Dienst in einem eigenen, von anderen Konten getrennten Datenbereich: die abgerufenen Kurse,
die Dateiliste (Name, Ordner, Datum, Größe, Fingerabdruck, Seitentext – nicht die Dateien, siehe Abschnitt 6),
Termine, Fristen, Ankündigungen und – nur auf deinen Abruf hin – Noten und Bescheinigungen; mit dem
Geräteabgleich außerdem Module, Lesezeichen, Stundenplan, Lernkalender, Aufgaben, Karteikarten und Einstellungen,
ab Pro AI auch deine Notizen, damit iPad, Android, Windows und Web denselben Stand zeigen. Übertragung nur verschlüsselt (TLS).
Löschen in der App (Papierkorb, Konto) löscht auch im Dienst; endgültig gelöscht wird mit dem Konto, spätestens
30 Tage nach dessen Löschung. Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

## 8. Community (Plus)

In der Community trittst du der Gruppe eines Kurses oder einer Lerngruppe bei und teilst deine Lösung zu einem
Übungsblatt mit deren Mitgliedern. Mitglieder sehen deine Notizen auch dann, wenn sie die PDF nicht haben.

- **Was andere sehen:** ein Pseudonym (`Studi-…`, aus deiner Konto-ID abgeleitet, nicht umkehrbar), den von dir
  gewählten Anzeigenamen und Titel, Seitenzahl, Zeitpunkt, Anzahl der Downloads. Nie deine E-Mail oder Konto-ID.
- **Was der Dienst speichert:** das Paket mit deinen Notizen **verschlüsselt** (Schlüssel aus der Kurs-Kennung bzw.
  dem Beitrittscode; wer Kurs-Kennung oder Code kennt, kann es öffnen. Lässt du deine Hochschule durch den Dienst
  abgleichen, liegt die Kurs-Kennung beim Dienst, er könnte Pakete dieses Kurses dann technisch lesen; er tut es nicht),
  deine Mitgliedschaften und die Schlüssel deiner Kurse, den Fingerabdruck der PDF
  (SHA-256), Kopfdaten des Pakets, Status, Downloadzähler; Meldungen (Grund, Hinweis, meldendes Konto – intern),
  deine Sperrliste; bei Verstößen Sperren von Konten. Dazu deine **Likes** (welches Konto welche Lösung mag, nach
  außen nur als Anzahl), deine **Kommentare** (Text, Pseudonym, Seite und Stelle auf der Seite, Zeitpunkt) und die
  **Fingerabdrücke der PDFs**, die dein Gerät aus dem Hochschul-Abgleich meldet, damit du Lösungen zu genau diesen
  Dateien findest (keine Dateinamen, keine Inhalte).
- **Windows-App, Abgleich mit dem iPad:** Ist die Windows-App mit deinem Konto verbunden, gleicht sie Notizen,
  Module, Stundenplan-Anpassungen, Lernkalender, Karteikarten und Einstellungen mit deinem Konto im Dienst ab (wie
  in Abschnitt 7 beschrieben). Hochschuldateien selbst lädt jedes Gerät von der Hochschule; zu Notizen speichert der
  Dienst nur Name und Kurs der Datei. Abschalten: Community → StudiNow-Konto → „Mit dem iPad abgleichen“.
- **Windows-App:** Die Windows-App ist immer mit deinem StudiNow-Konto angemeldet (Abschnitt 5). Dein
  StudiNow-Passwort geht dabei einmal verschlüsselt an den Dienst und wird nicht gespeichert; auf dem PC liegt nur ein
  Sitzungsschlüssel, den du mit „Abmelden“ löschst. Die App schickt dem Dienst die Fingerabdrücke (SHA-256) der PDFs
  aus deinem Hochschul-Abgleich, nie die Dateien. Lösungen werden auf deinem PC ver- und entschlüsselt.
- **Fragen und Antworten je Kurs:** Fragen, Antworten und „hilfreich“-Stimmen speichern wir mit deinem Pseudonym,
  Zeitpunkt und einem Kurs-Schlüssel (aus Hochschule und Kurs-ID berechnet, ohne Kursnamen). **Lesezeichen** sind
  privat. **Mitteilungen** (z. B. „hat deine Frage beantwortet“) liegen in deinem Konto; gelesene löschen wir nach
  90 Tagen. Mit dem Konto wird alles gelöscht.
- **Auswertung durch den Betreiber:** Wir sehen intern, welche Konten die meisten Likes bekommen haben (Rangliste mit
  E-Mail-Adresse), um hilfreiche Beiträge zu würdigen und Missbrauch zu erkennen. Andere Nutzer sehen das nie.
- **Moderation:** Ab drei Meldungen verschiedener Konten ist eine Lösung verborgen, bis wir entscheiden; wir
  können Lösungen verbergen oder entfernen und Konten für die Community sperren. Zurückgezogene oder entfernte
  Lösungen werden sofort gelöscht; die Kopfdaten bleiben bis zur Löschung des Kontos (Nachvollziehbarkeit bei
  Meldungen).
- Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (du veröffentlichst bewusst); Moderation und Sperren Art. 6 Abs. 1
  lit. f DSGVO (Schutz der anderen Nutzerinnen und Nutzer, Einhaltung der Regeln). Veröffentlichen ist freiwillig.

## 8a. KI über dein ChatGPT (freiwillig) – Entwurf, vor Veröffentlichung rechtlich prüfen

- **Wann:** nur wenn du in den Einstellungen „ChatGPT verbinden“ wählst, dem Hinweis zustimmst und dich bei OpenAI
  anmeldest. Ohne Verbindung gibt es keine KI; alles andere in StudiNow funktioniert genauso.
- **Was gesendet wird:** erst wenn du eine KI-Funktion antippst (Frage im Editor, Wochentest, Zusammenfassung,
  Bewertung eines Tests): der Text der betroffenen Seite oder deiner Markierung, deine Frage oder Lösung, die Namen von
  Kurs und Datei, passende Stellen aus deinen eigenen Unterlagen (Quellen) und bei Wochentests die Texte der Unterlagen
  der Woche; auf dem iPad auf Wunsch auch der Text eines Teils der Mitschrift einer eigenen Vorlesungsaufnahme
  (Abschnitt 3), nie die Audioaufnahme. Nie gesendet werden Zugangsdaten, Hochschul-Sitzungen, Noten, ganze Dateien
  oder Notizen anderer.
- **Wohin:** direkt von deinem Gerät an OpenAI (OpenAI OpCo, LLC, USA) über die Schnittstelle „Sign in with ChatGPT“.
  Die Anfragen laufen über dein ChatGPT-Abo und zählen gegen dessen Grenzen. **StudiNow sieht weder Anfragen noch
  Antworten** und speichert sie auf keinem Server; Antworten bleiben auf deinem Gerät.
- **Anmeldung:** StudiNow erhält von OpenAI nur deine Kennung, deinen Namen und deine E-Mail-Adresse sowie Zugriffs- und
  Erneuerungs-Token. Sie liegen nur im Schlüsselbund dieses Geräts (Windows: auf diesem PC), nie in deinem
  StudiNow-Konto und nie im Abgleich zwischen Geräten. StudiNow hat keinen Zugriff auf deine ChatGPT-Unterhaltungen.
- **Rechtsgrundlage:** deine Einwilligung (Art. 6 Abs. 1 lit. a DSGVO), die du mit „Trennen“ jederzeit widerrufen
  kannst; dabei werden Token und Profil vom Gerät gelöscht. „Konto löschen“ entfernt die Verbindung ebenfalls.
- **Verantwortlich bei OpenAI:** Für die Verarbeitung bei OpenAI gelten deren Bedingungen und Datenschutzerklärung,
  auch deine Einstellung, ob Inhalte zum Training verwendet werden dürfen. Übermittlung in die USA: siehe Abschnitt 12.
- **Eigenes ChatGPT mit deinem OpenAI-Schlüssel (iPad, seit 07.11.2026):** Statt der Anmeldung bei ChatGPT kannst du
  in den Einstellungen (Erweitert → „Eigenes ChatGPT“) einen eigenen API-Schlüssel eintragen, den du bei
  platform.openai.com selbst anlegst. Der Schlüssel liegt **nur im Schlüsselbund dieses iPads** (nicht übertragbar auf
  andere Geräte), wird nie an StudiNow oder in dein StudiNow-Konto übertragen, nie protokolliert und nur in der
  Anfrage an OpenAI mitgesendet. Die Anfragen gehen **direkt von deinem Gerät an die OpenAI-Schnittstelle**
  (api.openai.com) und werden von OpenAI über dein Konto abgerechnet; es gelten die Bedingungen und die
  Datenschutzerklärung von OpenAI für die API (laut OpenAI werden API-Inhalte standardmäßig nicht zum Training
  verwendet). Gesendet wird, was oben unter „Was gesendet wird“ steht; beim **KI-Lernplan** zusätzlich nur Modultitel,
  Lehrwochen, Dateinamen mit Art und Dauer, Klausurtermine, Daten und freie Minuten – keine Namen, keine Noten, keine
  Seitentexte. Die KI schlägt vor, eingetragen wird erst nach deiner Bestätigung. „Schlüssel löschen“ oder „Konto
  löschen“ entfernt den Schlüssel vom Gerät.

## 8b. iPad: Community, gemeinsame Wochentests und Bibliothek über Apple iCloud (CloudKit)

Ergänzt am 04.11.2026. Die iPad-App (ohne angemeldetes StudiNow-Konto; mit Konto derselben Hochschule läuft die
Community über den Dienst, Abschnitt 8) speichert alles, was du
mit anderen Studierenden teilst, in der **öffentlichen Datenbank von Apple CloudKit** im iCloud-Container von StudiNow
(`iCloud.de.uniflow.ai`). Die Rechenzentren betreibt Apple; für die Inhalte dieser Datenbank sind wir verantwortlich
(Abschnitt 2). Es gibt drei Funktionen:

- **Community (Lösungen, Diskussion, Korrekturen):** Wenn du eine Lösung veröffentlichst (ab Plus), eine Frage, Antwort
  oder einen Kommentar schreibst, etwas likest, einen Korrekturvorschlag machst, etwas meldest oder eine Lerngruppe
  anlegst.
- **Gemeinsame Wochentests:** Wenn du mit deiner KI einen Wochentest erstellst, legt die App den Test für alle mit
  denselben Unterlagen ab (höchstens drei Varianten); wer dieselben Dateien hat, übernimmt ihn, statt neu zu erzeugen.
- **Bibliothek (gemeinsamer Dokument-Index):** Wenn deine KI eine Seite einer Kursdatei einordnet („Seite einordnen“
  oder – nur bei verbundener KI, im WLAN und beim Laden – bis zu drei neue Dateien der laufenden Woche nach einem
  Abgleich), legt die App die Einordnung für alle mit derselben Datei ab. Wer dieselbe Datei hat, sieht sie als „Schon
  erklärt“, ohne eigene KI-Anfrage.

**Welche Daten:**

| Funktion | Gespeichert | Verschlüsselt |
|---|---|---|
| Lösung | Paket mit deinen Notizen (nie die Original-PDF), Fingerabdruck der PDF (SHA-256), Hochschule, Kurs- bzw. Gruppen-Schlüssel (Hashwerte, nie Kurs-ID, Kursname oder Beitrittscode), Sichtbarkeit, Pseudonym (leer bei „anonym“), Titel, Seitenzahl, Lehrwoche, Zeitpunkt | das Paket |
| Frage, Antwort, Kommentar, Korrekturvorschlag | Text, Pseudonym, Seite und Stelle bzw. Korrektur-Tinte; im Klartext nur, zu welcher Lösung oder Community er gehört, Status und Zeitpunkte | Text, Pseudonym, Stelle, Tinte |
| Like | worauf (Kennung der Lösung oder Frage), Zeitpunkt | – |
| Meldung | Grund, dein Hinweis (höchstens 500 Zeichen), Zeitpunkt; sichtbar nur für dich und uns | – |
| Lerngruppe | Gruppen-Schlüssel (Hash aus Hochschule und Code, nie der Code), Name, Hochschule | – |
| Wochentest | Fragen und Musterlösungen, Schlüssel des Tests (Hash), Variante, Status, Zeitpunkt – keine Antworten, keine Ergebnisse, keine Namen | der Test |
| Bibliothek | je Seite Zusammenfassung, Fachbegriffe, Elemente und Aufgaben; Datei-Schlüssel (HMAC des Fingerabdrucks), Seite, Fassung, Zeitpunkt – kein Seitentext, kein Seitenbild, keine Notizen, keine Namen | der Eintrag |

Jeder Datensatz trägt die **CloudKit-Nutzerkennung**: eine zufällige Kennung deines iCloud-Kontos, die Apple nur für
StudiNow vergibt und als Ersteller einträgt. Wir sehen nicht, wer dahinter steht; sie dient dem Zurückziehen eigener
Beiträge, dem Melden, dem Blockieren und der Moderation. Nie gespeichert werden Apple-ID, Name, E-Mail-Adresse,
Matrikelnummer, Kurs-ID, Kursname, Hochschul-Zugangsdaten oder deine Antworten in Tests. Deine eigene Sperrliste liegt
in der privaten Datenbank deines iCloud-Kontos; nur du siehst sie.

**Verschlüsselung und wer was lesen kann:** Inhalte sind mit AES-256-GCM verschlüsselt. Die Schlüssel entstehen auf
deinem Gerät (HKDF-SHA256) aus der Kurs-Kennung bzw. dem Beitrittscode (Community) oder aus den Fingerabdrücken der
Dateien (Wochentests, Bibliothek); sie gehen nie an Apple oder an uns. Lesen kann deshalb nur, wer denselben Kurs bzw.
dieselbe Datei hat. Die Kopfdaten in der Tabelle ohne Verschlüsselung (z. B. Titel, Pseudonym, Lehrwoche,
Seitenzahl, Fingerabdruck) kann jeder abrufen, der den Container kennt. Andere Nutzer sehen Pseudonym, Titel,
Seitenzahl, Lehrwoche, Zeitpunkt und die Zahl der Likes. Wir sehen im CloudKit Dashboard die Datensätze und Meldungen,
aber keine verschlüsselten Inhalte; hätten wir die Kurs-Kennung oder die Datei, könnten wir sie technisch öffnen – wir
tun es nicht. Beim Suchen fragt die App nur mit Schlüsseln (Fingerabdruck, Kurs-, Gruppen- oder Datei-Schlüssel);
Lesen geht ohne iCloud-Konto, Schreiben braucht eines.

**Wo:** in den Rechenzentren von Apple (iCloud). Für dein iCloud-Konto selbst ist Apple eigener Verantwortlicher; eine
Übermittlung in die USA ist möglich (Abschnitt 12).

**Moderation:** Meldungen sehen wir im CloudKit Dashboard. Wir können Lösungen und Kommentare verbergen oder löschen und
eine CloudKit-Nutzerkennung für die Community sperren. Eine automatische Schwelle gibt es auf dem iPad nicht.

**Löschen und Widerruf:**

- **Lösung zurückziehen** („Meine geteilten Lösungen“ → Zurückziehen): das Paket mit deinen Notizen wird sofort
  gelöscht; die Kopfdaten bleiben als „zurückgezogen“ markiert, bis wir sie löschen (auf Anfrage sofort). Wer die
  Lösung schon geladen hat, behält seine Kopie.
- **Eigene Fragen, Antworten und Kommentare** löschst du in der Diskussion, **Likes** nimmst du mit einem zweiten
  Tippen zurück.
- **Wochentests und Bibliothek** enthalten keine persönlichen Inhalte; auf Anfrage löschen wir die Datensätze deiner
  Nutzerkennung.
- **„Konto löschen“ in der App** entfernt alle Daten auf dem iPad, aber nicht von selbst, was du in iCloud
  veröffentlicht hast – darauf weist der Dialog hin. Zieh deine Beiträge vorher zurück oder schreib an
  support@studinow.app; wir löschen dann alle Datensätze deiner Nutzerkennung.

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (du veröffentlichst bzw. nutzt die Funktion bewusst); Moderation und
Sperren Art. 6 Abs. 1 lit. f DSGVO (Schutz der anderen Nutzerinnen und Nutzer). Alle drei Funktionen sind freiwillig;
ohne sie funktioniert StudiNow genauso.

## 8c. StudiNow-KI im Dienst (Tarif Pro AI) – Entwurf, vor Veröffentlichung rechtlich prüfen

- **Wann:** nur wenn du mit deinem StudiNow-Konto (Pro AI oder Probe, bestätigte E-Mail-Adresse) eine KI-Funktion im
  Dienst nutzt, z. B. eine Frage im Editor, eine Erklärung des ganzen Dokuments, Karteikarten oder einen Wochentest.
  Vor der ersten Anfrage zeigen App, Web und Windows einmal den Hinweis „KI-Hilfe: Was wird gesendet?“ (was, an wen)
  und senden erst nach „Zustimmen und fortfahren“; widerrufen kannst du das jederzeit in den Einstellungen
  („KI-Einwilligung widerrufen“), dann wird vor der nächsten Anfrage wieder gefragt.
- **Was gesendet wird:**
  - der Text der betroffenen Seite oder deiner Markierung;
  - deine Frage oder Lösung, wenn du eine schreibst;
  - die Namen von Kurs und Datei;
  - passende Stellen aus deinen Unterlagen und Lerntexte deines Kurses;
  - deine eigenen Notizen zur Seite, wenn du sie mitschickst;
  - bei Wochentests und Karteikarten die Texte der Unterlagen;
  - beim Einordnen einer Seite ohne Text das Bild der Seite.

  Nie gesendet werden dein Name, deine E-Mail-Adresse, Zugangsdaten, Hochschul-Sitzungen und Noten. OpenAI erhält zur
  Missbrauchserkennung eine nicht umkehrbare Kennung deines Kontos, nicht die Konto-ID.
- **Wohin:** Der Dienst gibt jede Anfrage an **einen** von zwei Auftragsverarbeitern weiter. Welcher es ist, hängt von
  der Aufgabe ab (die meisten Aufgaben an ChatGPT, schwere wie Rechnen, Herleiten oder das Prüfen einer Lösung an
  Claude), bei einer Störung auch vom Ersatz:
  - **OpenAI**: ChatGPT-Modelle. Die Verarbeitung findet in den USA statt (siehe Abschnitt 12), bis unser Projekt mit
    Datenresidenz in der EU freigeschaltet ist; dann ändern wir diesen Satz.
  - **Amazon Web Services EMEA SARL** (Luxemburg) über Amazon Bedrock, Region Frankfurt, mit Verarbeitung in der EU:
    Modell „Claude Sonnet“ von Anthropic.
- **Was StudiNow speichert:**
  - je Anfrage Zeitpunkt, Zweck, Modell, Anzahl der Tokens und Kosten (für Credits und Budget);
  - die Antwort 24 Stunden lang, damit eine wiederholte Anfrage nicht doppelt kostet;
  - Antworten ohne eigene Notizen bis zu 30 Tage ohne Bezug zu deinem Konto, damit eine gleiche Anfrage sofort
    beantwortet wird;
  - Erklärungen ganzer Dokumente ohne Namen, für alle mit derselben Datei.
- **Rechtsgrundlage:** Art. 6 Abs. 1 lit. b DSGVO, weil du die KI-Funktion deines Tarifs nutzt. Mit beiden
  Anbietern besteht ein Vertrag zur Auftragsverarbeitung nach Art. 28 DSGVO; sie dürfen die Daten nur für uns
  verarbeiten.

## 9. Käufe und Abos

Die Abos StudiNow Plus und StudiNow Pro AI kaufst du über den App Store (Apple) bzw. Google Play. Vertrags- und
Zahlungsabwicklung, Rechnungen, Rückerstattungen und Kündigung laufen über Apple bzw. Google nach deren
Datenschutzbestimmungen. Wir erhalten keine Zahlungsdaten. Ohne StudiNow-Konto prüft die iPad-App den Kauf nur auf
dem Gerät; an uns geht nichts. Bist du in der App mit deinem StudiNow-Konto angemeldet, schickt sie uns die von Apple
signierte Kaufbestätigung (Transaktions- und Produktkennung, Laufzeit), damit wir den Tarif deinem Konto zuordnen
(z. B. die Credits der StudiNow-KI in Pro AI). Diese Information speichern wir, solange das Konto besteht. Rechtsgrundlage:
Art. 6 Abs. 1 lit. b DSGVO.

**Web und Windows (Entwurf, vor Veröffentlichung rechtlich prüfen):** Dort schließt du ein Abo – sobald wir den
Abschluss eingerichtet haben – über den Zahlungsdienstleister Stripe ab (Stripe Payments Europe, Ltd., Irland; eigener
Verantwortlicher für die Zahlungsabwicklung). Die Windows-App öffnet dafür die Bezahlseite von Stripe in deinem
Browser. Wir übermitteln Stripe deine E-Mail-Adresse, eine Kundenkennung und den gewählten Tarif; Zahlungsdaten gibst
du nur bei Stripe ein, wir erhalten sie nicht. Von Stripe erhalten wir Kunden- und Abo-Kennung, Tarif, Status und
Laufzeit, um das Abo freizuschalten; Kündigen und Wechseln geht im Kundenportal von Stripe. Hast du schon ein Abo über
Apple, bietet die App keinen zweiten Kauf an.

## 10. Web-Oberfläche, Cookies und Server-Protokolle

- **Cookie `uniflow_session`**: hält dich in der Web-Oberfläche angemeldet (HttpOnly, 30 Tage, verlängert sich bei
  Nutzung); technisch notwendig, keine Einwilligung erforderlich. Beim Abmelden wird es gelöscht. Im PC-Modus gibt
  es stattdessen das Cookie `lernapp_pin` für den WLAN-Zugang (1 Jahr).
- **Lokaler Speicher des Browsers**: nur Einstellungen, die du selbst vornimmst (Hell/Dunkel, Seitenleiste,
  zuletzt geöffnete Ansicht). Keine Kennungen für Werbung oder Analyse.
- **Zugriffsprotokolle des Servers**: IP-Adresse, Zeitpunkt, aufgerufene Adresse, Status, Browser-Kennung – zur
  Abwehr von Angriffen und zur Fehlersuche (Art. 6 Abs. 1 lit. f DSGVO), gelöscht nach 14 Tagen.
- **Protokolle des Abgleichs** je Konto: Zeitpunkt, Erfolg, Fehlermeldung ohne Inhalte und Passwörter, bei
  fehlgeschlagener Anmeldung ein Bildschirmfoto der Anmeldeseite deiner Hochschule zur Fehlersuche – gelöscht nach
  90 Tagen. Abgelaufene oder beendete Sitzungen, verbrauchte Reset-Links und Fehlversuchszähler werden täglich
  entfernt.
- **Schriftart und andere Dateien der Oberfläche** liefert unser Server selbst aus; die Web-Oberfläche lädt nichts
  von Dritten (auch keine Schriften von Google), es werden keine Daten an Dritte übertragen.

## 11. Hosting, E-Mail-Versand und Auftragsverarbeiter

Der Dienst läuft bei Hetzner Online GmbH, Industriestr. 25, 91710 Gunzenhausen (Deutschland), Serverstandort Nürnberg, Deutschland (EU), auf Grundlage eines Vertrags zur
Auftragsverarbeitung nach Art. 28 DSGVO. E-Mails zum Konto (Passwort zurücksetzen, Bestätigungen) versendet
STRATO GmbH, Otto-Ostrowski-Straße 7, 10249 Berlin (Deutschland) in unserem Auftrag. Für die StudiNow-KI (Abschnitt 8c) sind **OpenAI** und
**Amazon Web Services EMEA SARL** (Amazon Bedrock, Region Frankfurt) Auftragsverarbeiter, jeweils mit einem Vertrag
nach Art. 28 DSGVO. Weitere Auftragsverarbeiter gibt es nicht.

## 12. Empfänger und Übermittlung in Drittländer

- **Apple** (App Store, „Mit Apple anmelden“, Abo) und **Google** (Google Play, „Mit Google anmelden“, Abo) sind
  eigene Verantwortliche. Sitz in den USA; für die Übermittlung gelten die EU-Standardvertragsklauseln bzw. die
  Zertifizierung nach dem EU-US Data Privacy Framework der jeweiligen Anbieter.
- **Apple als Betreiber von iCloud/CloudKit** speichert für uns die Community-Beiträge, gemeinsamen Wochentests und
  Einträge der Bibliothek der iPad-App (Abschnitt 8b), verschlüsselt und nur mit der CloudKit-Nutzerkennung; die
  Datenbank stellt Apple im Rahmen des Apple Developer Program bereit (Rechenzentren auch in den USA, EU-US Data
  Privacy Framework bzw. Standardvertragsklauseln).
- **Stripe** (Abschnitt 9) erhält beim Abschluss im Web oder unter Windows E-Mail-Adresse, Kundenkennung und Tarif;
  eigener Verantwortlicher für die Zahlung. Eine Übermittlung in die USA durch Stripe stützt sich auf das EU-US Data
  Privacy Framework bzw. die Standardvertragsklauseln von Stripe.
- **Deine Hochschule** erhält die Verbindungsdaten des Abrufs (Abschnitt 4); der Standortfinder der Leibniz Universität
  Hannover nur den Suchtext des Raumfinders (Abschnitt 4).
- **Google bzw. Apple** (Karten) erhalten einen Ort erst, wenn du im Raumfinder auf einen Karten-Link tippst; dann als
  eigene Verantwortliche (Abschnitt 4).
- **OpenAI** (USA) erhält nur dann Daten, wenn du dein ChatGPT verbindest und eine KI-Funktion nutzt (Abschnitt 8a);
  eigener Verantwortlicher, Übermittlung nach dem EU-US Data Privacy Framework bzw. den Standardvertragsklauseln von
  OpenAI.
- **StudiNow-KI (Abschnitt 8c):**
  - Amazon Web Services verarbeitet in der EU (Frankfurt).
  - OpenAI verarbeitet als unser Auftragsverarbeiter in den USA. Die Übermittlung stützt sich auf das EU-US Data
    Privacy Framework bzw. die Standardvertragsklauseln im Vertrag mit OpenAI.
- Sonst geben wir keine Daten weiter – nicht an Werbenetzwerke, nicht an Analyse-Dienste, nicht an Dritte zum
  Verkauf. Behörden erhalten Daten nur, wenn wir gesetzlich dazu verpflichtet sind.

## 13. Was wir nicht tun

Kein Tracking über Apps oder Websites hinweg, keine Werbung, keine Profilbildung, keine automatisierten
Entscheidungen mit rechtlicher Wirkung (Art. 22 DSGVO), keine Analyse- oder Absturz-SDKs von Dritten, keine
Verwendung deiner Notizen und Dateien für Werbung, Profile oder das Training von KI-Modellen. KI verarbeitet deine
Inhalte nur für die KI-Funktionen, die du nutzt: über dein eigenes ChatGPT (Abschnitt 8a) oder die StudiNow-KI im
Tarif Pro AI (Abschnitt 8c).

## 14. Deine Rechte

Du hast das Recht auf Auskunft (Art. 15 DSGVO), Berichtigung (Art. 16), Löschung (Art. 17), Einschränkung der
Verarbeitung (Art. 18), Datenübertragbarkeit (Art. 20) und Widerspruch gegen Verarbeitungen auf Grundlage von
Art. 6 Abs. 1 lit. f DSGVO (Art. 21). Eine erteilte Einwilligung kannst du jederzeit mit Wirkung für die Zukunft
widerrufen. Wende dich dazu an support@studinow.app. Außerdem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren,
zum Beispiel bei der für deinen Wohnsitz oder bei der für uns zuständigen Behörde: Die Landesbeauftragte für den
Datenschutz Niedersachsen, Prinzenstraße 5, 30159 Hannover.

## 15. Konto löschen, Daten mitnehmen

- **Konto löschen** geht in der App (Einstellungen → Konto → Konto löschen, Bestätigung mit Passwort) oder per
  E-Mail an support@studinow.app. Das Konto wird sofort gesperrt, alle Sitzungen enden; die Daten werden nach 30 Tagen
  endgültig gelöscht (Frist für versehentliche Löschung). Das Abo kündigst du zusätzlich bei Apple bzw. Google.
- **iPad ohne StudiNow-Konto:** „Konto löschen“ (Einstellungen → Zugang & Darstellung → Konto) entfernt sofort alle
  Daten auf dem iPad; was du in der Community, als Wochentest oder in der Bibliothek geteilt hast, löschen wir auf
  Anfrage (Abschnitt 8b).
- **Daten mitnehmen:** Im Konto-Menü („Meine Daten exportieren“) lädst du alle Daten deines Kontos als ZIP herunter
  (Auskunft nach Art. 15 und Datenübertragbarkeit nach Art. 20 DSGVO): Konto, Geräte, Käufe, Nutzung, deine Kurse,
  Notizen, Kalender, Lernpakete, Karteikarten, Tests, eigene Dateien und Community-Beiträge. Gespeicherte Passwörter
  und Sitzungen deiner Hochschule stehen aus Sicherheitsgründen nur als „gespeichert“ darin. Notizen lassen sich
  außerdem als PDF exportieren.
- **E-Mail-Adresse bestätigen:** Nach der Registrierung schicken wir einen Link zur Bestätigung. Bis dahin kannst du
  alles nutzen außer dem Veröffentlichen in der Community.

## 16. Kinder

StudiNow richtet sich an Studierende und nicht an Kinder unter 16 Jahren. Wir erheben wissentlich keine Daten von
Kindern.

## 17. Änderungen

Wir passen diese Erklärung an, wenn sich StudiNow ändert. Die jeweils aktuelle Fassung steht unter
`https://studinow.app/datenschutz`; bei wesentlichen Änderungen informieren wir dich in der App oder per E-Mail.
