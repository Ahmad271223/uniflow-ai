# Datenschutzerklärung StudiNow

**Entwurf, Stand 03.11.2026 (26.10.2026). Keine Rechtsberatung – vor der Veröffentlichung anwaltlich prüfen.**

Diese Erklärung gilt für die StudiNow-Apps (iPad und Mac, Android, Windows), die Web-Oberfläche und den
gehosteten StudiNow-Dienst unter `https://studinow.app`. Sie ist so aufgebaut, wie StudiNow arbeitet: Vieles bleibt auf deinem
Gerät; nur mit einem StudiNow-Konto verarbeiten wir Daten auf unseren Servern, und auch dann nur das, was du
eingeschaltet hast.

## 1. Das Wichtigste in Kürze

- **Ohne StudiNow-Konto** bleiben alle Daten auf deinem Gerät (Abschnitt 3). Wir erhalten nichts – außer dem, was du
  auf dem iPad bewusst mit anderen teilst: Community-Beiträge, gemeinsame Wochentests und Einträge der Bibliothek liegen
  verschlüsselt in Apples iCloud (Abschnitt 8b).
- **Mit StudiNow-Konto** speichern wir deine E-Mail-Adresse, dein Passwort nur als Hash, deine Hochschule, Sitzungen
  und Tarif (Abschnitt 5). Den Abgleich mit deiner Hochschule, den Abgleich zwischen deinen Geräten und die Community
  schaltest du einzeln ein (Abschnitte 6–8).
- **Deine Hochschul-Zugangsdaten** gibst du nur bei den Systemen deiner Hochschule ein. Wenn du sie merken lässt,
  liegen sie verschlüsselt auf deinem Gerät oder – für den automatischen Abgleich – verschlüsselt in deinem Konto.
  Für den Abgleich durch den Dienst stimmst du vorher ausdrücklich zu: Der Dienst meldet sich dann um 8 und 15 Uhr
  von seiner Adresse bei deiner Hochschule an und lädt neue Unterlagen in dein Konto. Du kannst die Zugangsdaten
  jederzeit löschen; die Zustimmung endet damit, deine Unterlagen bleiben.
- **Kein Tracking, keine Werbung, kein Verkauf von Daten, keine Analyse-Werkzeuge Dritter.** StudiNow wertet deine
  Inhalte nicht selbst automatisiert aus. KI gibt es nur, wenn du **dein eigenes ChatGPT** verbindest (Abschnitt 8a):
  dann gehen Texte, die du für eine KI-Funktion auswählst, direkt von deinem Gerät an OpenAI.

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
  selbst speichert weder Benutzername noch Passwort und meldet sich nie von selbst an. Einzige Ausnahme: Die iPad-App
  merkt sich auf dem Gerät deinen Hochschul-Benutzernamen (nie das Passwort), damit er beim nächsten Anmelden schon
  eingetragen ist; Abmelden löscht ihn. Nach der Anmeldung behält die
  App nur die Sitzung (Cookies) der Hochschule, bei der Universität Hildesheim zusätzlich den Learnweb-Schlüssel, bis
  du dich abmeldest oder die Hochschule sie beendet. Nur wenn du es am PC ausdrücklich einträgst, liegen die
  Zugangsdaten für den Abgleich ohne Nachfrage in der Datei `.env` im Datenordner der App – jederzeit löschbar.

Der PC-Modus (eigener Server auf deinem Rechner, Ordner `data/`) ist ebenfalls rein lokal; im eigenen WLAN schützt
eine PIN den Zugriff. Diese Daten verlassen dein Gerät nur, wenn du den Geräteabgleich (Abschnitt 7) einschaltest.
Wir speichern auf deinem Gerät nur, was für die Funktion nötig ist oder was du selbst einstellst (§ 25 Abs. 2 TDDDG).

Für **Version 1 der iPad-App** gelten dieser Abschnitt, Abschnitt 4 (Hochschule) und – nur wenn du die Funktionen
nutzt – die Abschnitte 8a (KI über dein ChatGPT) und 8b (Community, gemeinsame Wochentests und Bibliothek über Apple
iCloud). Sie läuft ohne StudiNow-Dienst. „Mit Apple anmelden“ und das Abo laufen allein über Apple (Abschnitt 9); an uns
wird dabei nichts übertragen, deine Apple-Kennung bleibt auf dem iPad.

## 4. Systeme deiner Hochschule

StudiNow liest für dich aus den Systemen deiner Hochschule – Leibniz Universität Hannover: Stud.IP, WebSSO und
QIS; Universität Hildesheim: Learnweb, LSF und CAS-Anmeldung. Die App (oder bei eingeschaltetem Abgleich unser
Dienst in deinem Auftrag) meldet sich dort mit **deinen** Zugangsdaten an und ruft Kurse, Dateien, Termine,
Fristen, Ankündigungen und – nur wenn du „Noten abrufen“ wählst – deinen Notenspiegel und Bescheinigungen ab. Es
wird ausschließlich gelesen; StudiNow schreibt nichts in die Hochschulsysteme.

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
| Tarif (Free/Plus) und Rolle | Funktionen freischalten, Moderation | wie das Konto |

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (Vertrag über die Nutzung von StudiNow); für die Schutzmaßnahmen gegen
Missbrauch Art. 6 Abs. 1 lit. f DSGVO (unser Interesse an einem sicheren Dienst). Ohne diese Daten können wir kein
Konto führen. Du kannst StudiNow auch ohne Konto nutzen (Abschnitt 3).

## 6. Hochschul-Zugangsdaten im Konto und automatischer Abgleich

Nur wenn du es in den Einstellungen einrichtest, speichern wir deine Hochschul-Zugangsdaten (Benutzername und
Passwort, bei Hildesheim zusätzlich ein Learnweb-Token) in deinem Konto, damit unser Dienst zweimal täglich (08:00
und 15:00 Uhr) die Liste neuer Dateien, Termine, Fristen und Ankündigungen für dich abruft, auch wenn kein Gerät läuft.
**Die Dateien selbst (Skripte, Folien, Übungsblätter) speichert der Dienst nicht.** Öffnest du eine Datei auf einem
Gerät, holt der Dienst sie in diesem Moment mit deiner Hochschulsitzung und reicht sie an dein Gerät durch; auf
unseren Servern bleibt nur ein kurzlebiger Zwischenspeicher im Arbeitsspeicher (höchstens 15 Minuten), der
Fingerabdruck der Datei (SHA-256, für die Community) und der Seitentext für die Suche – keine Kopie der Datei.

- Die Zugangsdaten sind mit AES-256-GCM verschlüsselt; der Schlüssel wird je Konto aus einem Dienst-Geheimnis
  abgeleitet, das getrennt von der Datenbank aufbewahrt wird. Niemand kann sie in der Datenbank lesen.
- Für den Abruf hält der Dienst in deinem Kontoordner eine Browsersitzung bei deiner Hochschule (Cookies), damit er
  sich nicht bei jedem Abruf neu anmelden muss. Mitarbeitende greifen darauf nicht zu; die Protokolle des Abgleichs
  enthalten keine Passwörter und keine Dateiinhalte.
- Du kannst die Zugangsdaten jederzeit in den Einstellungen löschen; der automatische Abgleich endet dann sofort.

Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO auf deine ausdrückliche Einrichtung hin. Bitte prüfe, ob die
Nutzungsregeln deiner Hochschule den Abruf durch eine App mit deinen Zugangsdaten erlauben (Abschnitt 4 der
Nutzungsbedingungen).

## 7. Deine Inhalte im Dienst und Abgleich zwischen Geräten

Mit Konto speichert der Dienst in einem eigenen, von anderen Konten getrennten Datenbereich: die abgerufenen Kurse,
die Dateiliste (Name, Ordner, Datum, Größe, Fingerabdruck, Seitentext – nicht die Dateien, siehe Abschnitt 6),
Termine, Fristen, Ankündigungen und – nur auf deinen Abruf hin – Noten und Bescheinigungen; mit dem
Geräteabgleich (Plus) außerdem Notizen, Lesezeichen, Stundenplan, Lernkalender, Aufgaben, Karteikarten und
Einstellungen, damit iPad, Android, Windows und Web denselben Stand zeigen. Übertragung nur verschlüsselt (TLS).
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
- **Windows-App:** Für die Community meldest du dich in der Windows-App mit deinem StudiNow-Konto an. Dein
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

## 8b. iPad: Community, gemeinsame Wochentests und Bibliothek über Apple iCloud (CloudKit)

Ergänzt am 04.11.2026. Die iPad-App (Version 1, ohne StudiNow-Dienst und ohne StudiNow-Konto) speichert alles, was du
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

## 9. Käufe und Abos

Das Abo StudiNow Plus kaufst du über den App Store (Apple) bzw. Google Play. Vertrags- und Zahlungsabwicklung,
Rechnungen, Rückerstattungen und Kündigung laufen über Apple bzw. Google nach deren Datenschutzbestimmungen. Wir
erhalten keine Zahlungsdaten, sondern nur die Information, dass und wie lange ein Abo besteht (Transaktions- und
Produktkennung), um Plus freizuschalten. Diese Information speichern wir, solange das Konto besteht. Rechtsgrundlage:
Art. 6 Abs. 1 lit. b DSGVO.

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

Der Dienst läuft bei [[Hoster]], Serverstandort [[Serverstandort]], auf Grundlage eines Vertrags zur
Auftragsverarbeitung nach Art. 28 DSGVO. E-Mails zum Konto (Passwort zurücksetzen, Bestätigungen) versendet
[[Mail-Anbieter]] in unserem Auftrag. Weitere Auftragsverarbeiter gibt es nicht.

## 12. Empfänger und Übermittlung in Drittländer

- **Apple** (App Store, „Mit Apple anmelden“, Abo) und **Google** (Google Play, „Mit Google anmelden“, Abo) sind
  eigene Verantwortliche. Sitz in den USA; für die Übermittlung gelten die EU-Standardvertragsklauseln bzw. die
  Zertifizierung nach dem EU-US Data Privacy Framework der jeweiligen Anbieter.
- **Apple als Betreiber von iCloud/CloudKit** speichert für uns die Community-Beiträge, gemeinsamen Wochentests und
  Einträge der Bibliothek der iPad-App (Abschnitt 8b), verschlüsselt und nur mit der CloudKit-Nutzerkennung; die
  Datenbank stellt Apple im Rahmen des Apple Developer Program bereit (Rechenzentren auch in den USA, EU-US Data
  Privacy Framework bzw. Standardvertragsklauseln).
- **Deine Hochschule** erhält die Verbindungsdaten des Abrufs (Abschnitt 4).
- **OpenAI** (USA) erhält nur dann Daten, wenn du dein ChatGPT verbindest und eine KI-Funktion nutzt (Abschnitt 8a);
  eigener Verantwortlicher, Übermittlung nach dem EU-US Data Privacy Framework bzw. den Standardvertragsklauseln von
  OpenAI.
- Sonst geben wir keine Daten weiter – nicht an Werbenetzwerke, nicht an Analyse-Dienste, nicht an Dritte zum
  Verkauf. Behörden erhalten Daten nur, wenn wir gesetzlich dazu verpflichtet sind.

## 13. Was wir nicht tun

Kein Tracking über Apps oder Websites hinweg, keine Werbung, keine Profilbildung, keine automatisierten
Entscheidungen mit rechtlicher Wirkung (Art. 22 DSGVO), keine Analyse- oder Absturz-SDKs von Dritten, keine
Auswertung deiner Notizen und Dateien durch eigene KI-Systeme von StudiNow. KI nutzt du nur über dein eigenes ChatGPT,
wenn du es selbst verbindest (Abschnitt 8a). Eine KI im StudiNow-Dienst (Tarif Pro AI) ergänzen wir hier, bevor es
sie gibt.

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
