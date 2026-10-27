# Datenschutzerklärung UniFlow

**Entwurf, Stand [[Datum]] (26.10.2026). Keine Rechtsberatung – vor der Veröffentlichung anwaltlich prüfen.**

Diese Erklärung gilt für die UniFlow-Apps (iPad und Mac, Android, Windows), die Web-Oberfläche und den
gehosteten UniFlow-Dienst unter `[[Domain]]`. Sie ist so aufgebaut, wie UniFlow arbeitet: Vieles bleibt auf deinem
Gerät; nur mit einem UniFlow-Konto verarbeiten wir Daten auf unseren Servern, und auch dann nur das, was du
eingeschaltet hast.

## 1. Das Wichtigste in Kürze

- **Ohne UniFlow-Konto** bleiben alle Daten auf deinem Gerät (Abschnitt 3). Wir erhalten nichts.
- **Mit UniFlow-Konto** speichern wir deine E-Mail-Adresse, dein Passwort nur als Hash, deine Hochschule, Sitzungen
  und Tarif (Abschnitt 5). Den Abgleich mit deiner Hochschule, den Abgleich zwischen deinen Geräten und die Community
  schaltest du einzeln ein (Abschnitte 6–8).
- **Deine Hochschul-Zugangsdaten** gibst du nur bei den Systemen deiner Hochschule ein. Wenn du sie merken lässt,
  liegen sie verschlüsselt auf deinem Gerät oder – für den automatischen Abgleich – verschlüsselt in deinem Konto.
  Du kannst sie jederzeit löschen.
- **Kein Tracking, keine Werbung, kein Verkauf von Daten, keine Analyse-Werkzeuge Dritter.** UniFlow nutzt derzeit
  keine KI-Funktionen und wertet deine Inhalte nicht automatisiert aus.

## 2. Verantwortlicher

[[Name]], [[Anschrift]], E-Mail: [[E-Mail]] (siehe Impressum). Einen Datenschutzbeauftragten gibt es nicht, weil die
gesetzlichen Voraussetzungen dafür nicht vorliegen. [[Falls doch benannt: Name und Kontakt.]]

## 3. Was auf deinem Gerät bleibt

Die Apps arbeiten zuerst lokal. Auf dem Gerät gespeichert werden:

- Dateien, Kurse, Termine, Fristen und Ankündigungen aus den Systemen deiner Hochschule, die die App für dich abruft;
- deine Notizen (Handschrift, Text, Formen, Bilder), eigene Dokumente, Lesezeichen, Papierkorb;
- Stundenplan, Lernkalender, Lernpakete, Aufgaben, Karteikarten, Zeitmesser und Einstellungen;
- Hochschul-Zugangsdaten merkt sich – wenn du das beim Anmelden erlaubst – der Passwort-Manager deines Geräts
  (Android: Google Password Manager oder Samsung Pass im Anmeldefenster; iPad: Schlüsselbund von iOS); die App
  selbst speichert weder Benutzername noch Passwort und meldet sich nie von selbst an. Am PC liegen sie für den
  Abgleich in der Datei `.env` bzw. im Datenordner der App. Nach der Anmeldung behält die App nur die Sitzung
  (Cookies) der Hochschule, bis du dich abmeldest.

Der PC-Modus (eigener Server auf deinem Rechner, Ordner `data/`) ist ebenfalls rein lokal; im eigenen WLAN schützt
eine PIN den Zugriff. Diese Daten verlassen dein Gerät nur, wenn du den Geräteabgleich (Abschnitt 7) einschaltest.
Wir speichern auf deinem Gerät nur, was für die Funktion nötig ist oder was du selbst einstellst (§ 25 Abs. 2 TDDDG).

Für **Version 1 der iPad-App** gilt ausschließlich dieser Abschnitt: Sie läuft ohne UniFlow-Dienst. „Mit Apple
anmelden“ und das Abo laufen allein über Apple (Abschnitt 9); an uns wird dabei nichts übertragen.

## 4. Systeme deiner Hochschule

UniFlow liest für dich aus den Systemen deiner Hochschule – Leibniz Universität Hannover: Stud.IP, WebSSO und
QIS; Universität Hildesheim: Learnweb, LSF und CAS-Anmeldung. Die App (oder bei eingeschaltetem Abgleich unser
Dienst in deinem Auftrag) meldet sich dort mit **deinen** Zugangsdaten an und ruft Kurse, Dateien, Termine,
Fristen, Ankündigungen und – nur wenn du „Noten abrufen“ wählst – deinen Notenspiegel und Bescheinigungen ab. Es
wird ausschließlich gelesen; UniFlow schreibt nichts in die Hochschulsysteme.

Für diese Systeme ist deine Hochschule verantwortlich; es gelten ihre Datenschutzhinweise und Nutzungsregeln. Sie
sieht die üblichen Verbindungsdaten (IP-Adresse deines Geräts bzw. unseres Dienstes, Zeitpunkt). UniFlow ist kein
Angebot der Hochschulen und nicht mit ihnen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die
Hochschulsysteme selbst.

## 5. UniFlow-Konto und Anmeldung (gehosteter Dienst)

Wenn du ein UniFlow-Konto anlegst, verarbeiten wir:

| Daten | Zweck | Speicherdauer |
|---|---|---|
| E-Mail-Adresse, Hochschule, Zeitpunkt der Registrierung | Konto führen, Anmeldung, Zuordnung der Hochschule, Mitteilungen zum Konto | bis 30 Tage nach Löschung des Kontos |
| Passwort – nur als Hash (scrypt mit zufälligem Salz), nie im Klartext | Anmeldung | wie das Konto |
| „Mit Apple anmelden“ / „Mit Google anmelden“: Kennung des Anbieters und die von ihm übermittelte E-Mail-Adresse (bei Apple ggf. eine Weiterleitungsadresse) | Anmeldeweg mit dem Konto verknüpfen | wie das Konto |
| Sitzungen: Token nur als Hash, Gerätename (oder Browser-Kennung), Zeitpunkt der Anmeldung und letzten Nutzung | angemeldet bleiben (30 Tage, verlängert sich bei Nutzung), andere Geräte abmelden | bis Abmeldung oder Ablauf |
| Fehlgeschlagene Anmeldeversuche je Konto und Adresse | Schutz vor Passwortraten (Sperre nach 8 Versuchen für 10 Minuten) | 10 Minuten |
| Token für „Passwort vergessen“ (nur als Hash) | Passwort zurücksetzen | 30 Minuten oder bis zur Nutzung |
| Tarif (Free/Plus) und Rolle | Funktionen freischalten, Moderation | wie das Konto |

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (Vertrag über die Nutzung von UniFlow); für die Schutzmaßnahmen gegen
Missbrauch Art. 6 Abs. 1 lit. f DSGVO (unser Interesse an einem sicheren Dienst). Ohne diese Daten können wir kein
Konto führen. Du kannst UniFlow auch ohne Konto nutzen (Abschnitt 3).

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

In der Community kannst du deine Lösung zu einem Übungsblatt mit Studierenden derselben Hochschule teilen, die
dieselbe PDF haben.

- **Was andere sehen:** ein Pseudonym (`Studi-…`, aus deiner Konto-ID abgeleitet, nicht umkehrbar), den von dir
  gewählten Anzeigenamen und Titel, Seitenzahl, Zeitpunkt, Anzahl der Downloads. Nie deine E-Mail oder Konto-ID.
- **Was der Dienst speichert:** das Paket mit deinen Notizen **verschlüsselt** (Schlüssel aus der Original-PDF,
  nur wer dieselbe PDF hat, kann es öffnen; der Dienst kann den Inhalt nicht lesen), den Fingerabdruck der PDF
  (SHA-256), Kopfdaten des Pakets, Status, Downloadzähler; Meldungen (Grund, Hinweis, meldendes Konto – intern),
  deine Sperrliste; bei Verstößen Sperren von Konten.
- **Moderation:** Ab drei Meldungen verschiedener Konten ist eine Lösung verborgen, bis wir entscheiden; wir
  können Lösungen verbergen oder entfernen und Konten für die Community sperren. Zurückgezogene oder entfernte
  Lösungen werden sofort gelöscht; die Kopfdaten bleiben bis zur Löschung des Kontos (Nachvollziehbarkeit bei
  Meldungen).
- Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO (du veröffentlichst bewusst); Moderation und Sperren Art. 6 Abs. 1
  lit. f DSGVO (Schutz der anderen Nutzerinnen und Nutzer, Einhaltung der Regeln). Veröffentlichen ist freiwillig.

## 9. Käufe und Abos

Das Abo UniFlow Plus kaufst du über den App Store (Apple) bzw. Google Play. Vertrags- und Zahlungsabwicklung,
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

Der Dienst läuft bei [[Hosting-Anbieter]], Serverstandort [[Serverstandort]], auf Grundlage eines Vertrags zur
Auftragsverarbeitung nach Art. 28 DSGVO. E-Mails zum Konto (Passwort zurücksetzen, Bestätigungen) versendet
[[Mail-Anbieter]] in unserem Auftrag. Weitere Auftragsverarbeiter gibt es nicht.

## 12. Empfänger und Übermittlung in Drittländer

- **Apple** (App Store, „Mit Apple anmelden“, Abo) und **Google** (Google Play, „Mit Google anmelden“, Abo) sind
  eigene Verantwortliche. Sitz in den USA; für die Übermittlung gelten die EU-Standardvertragsklauseln bzw. die
  Zertifizierung nach dem EU-US Data Privacy Framework der jeweiligen Anbieter.
- **Deine Hochschule** erhält die Verbindungsdaten des Abrufs (Abschnitt 4).
- Sonst geben wir keine Daten weiter – nicht an Werbenetzwerke, nicht an Analyse-Dienste, nicht an Dritte zum
  Verkauf. Behörden erhalten Daten nur, wenn wir gesetzlich dazu verpflichtet sind.

## 13. Was wir nicht tun

Kein Tracking über Apps oder Websites hinweg, keine Werbung, keine Profilbildung, keine automatisierten
Entscheidungen mit rechtlicher Wirkung (Art. 22 DSGVO), keine Analyse- oder Absturz-SDKs von Dritten, keine
Auswertung deiner Notizen und Dateien durch KI-Systeme. Sollten wir später KI-Funktionen anbieten, ergänzen wir
diese Erklärung vorher und du schaltest sie selbst ein.

## 14. Deine Rechte

Du hast das Recht auf Auskunft (Art. 15 DSGVO), Berichtigung (Art. 16), Löschung (Art. 17), Einschränkung der
Verarbeitung (Art. 18), Datenübertragbarkeit (Art. 20) und Widerspruch gegen Verarbeitungen auf Grundlage von
Art. 6 Abs. 1 lit. f DSGVO (Art. 21). Eine erteilte Einwilligung kannst du jederzeit mit Wirkung für die Zukunft
widerrufen. Wende dich dazu an [[E-Mail]]. Außerdem kannst du dich bei einer Datenschutz-Aufsichtsbehörde beschweren,
zum Beispiel bei der für deinen Wohnsitz oder bei der für uns zuständigen Behörde: [[Aufsichtsbehörde, z. B. Die
Landesbeauftragte für den Datenschutz Niedersachsen, Prinzenstraße 5, 30159 Hannover]].

## 15. Konto löschen, Daten mitnehmen

- **Konto löschen** geht in der App (Einstellungen → Konto → Konto löschen, Bestätigung mit Passwort) oder per
  E-Mail an [[E-Mail]]. Das Konto wird sofort gesperrt, alle Sitzungen enden; die Daten werden nach 30 Tagen
  endgültig gelöscht (Frist für versehentliche Löschung). Das Abo kündigst du zusätzlich bei Apple bzw. Google.
- **Daten mitnehmen:** Notizen lassen sich als PDF exportieren; mit dem Geräteabgleich liegen alle Daten auf deinem
  Gerät. Einen Gesamtexport (Art. 20 DSGVO) stellen wir auf Anfrage an [[E-Mail]] bereit.

## 16. Kinder

UniFlow richtet sich an Studierende und nicht an Kinder unter 16 Jahren. Wir erheben wissentlich keine Daten von
Kindern.

## 17. Änderungen

Wir passen diese Erklärung an, wenn sich UniFlow ändert. Die jeweils aktuelle Fassung steht unter
`[[Domain]]/datenschutz`; bei wesentlichen Änderungen informieren wir dich in der App oder per E-Mail.
