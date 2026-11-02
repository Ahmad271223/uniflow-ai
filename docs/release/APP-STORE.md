# App Store Connect – Texte und Angaben (iPad, Mac „Designed for iPad“)

**Entwurf, Stand 26.10.2026, Sprache de-DE.** Die Felder stehen in `text`-Blöcken mit Feldnamen;
`tests/test_release_texts.py` prüft Längen und dass kein Text KI-Funktionen verspricht. Zeichen inklusive Leerzeichen.

**Vor dem Einreichen prüfen – Aussagen, die vom Stand der iPad-App abhängen:**

| Aussage im Text | Gilt nur, wenn |
|---|---|
| Universität Hildesheim (Learnweb, LSF) | M10 fertig und am Gerät geprüft; sonst nur die LUH nennen |
| Abgabefristen, Ankündigungen der Lehrenden, Feiertage im Kalender | Port der Fristen/Ankündigungen/Feiertage auf dem iPad fertig (`docs/STAND-MAC-SITZUNG.md`) |
| Skriptsuche zur Aufgabe | M3/M4 (S7) fertig |
| Community: Lösungen vergleichen | V1: nur Teilen als Datei und Ansehen; Online-Community erst mit M15 und Dienst |
| „ohne Tracking“ | bleibt richtig, solange kein Analyse-SDK eingebaut wird |
| Nur Studora Free und Plus | V1 verkauft nur diese beiden (Entscheidung des Inhabers 28.10.2026); Pro Connect und Pro AI erst mit dem Studora-Dienst nennen und einreichen |

## Name, Untertitel, Werbetext

```text name
Studora – Studium & Notizen
```

```text subtitle
Skripte, Handschrift, Lernplan
```

```text promo
Skripte und Übungsblätter aus Stud.IP, Stundenplan und Lernkalender, Handschrift mit dem Apple Pencil – alles auf deinem iPad, ohne Tracking.
```

## Beschreibung (max. 4000 Zeichen)

```text description
Studora bringt dein Studium an einen Ort: die Dateien und Termine aus den Systemen deiner Hochschule, dein Stundenplan, dein Lernkalender und deine handschriftlichen Notizen – auf dem iPad, mit dem Apple Pencil.

FÜR STUDIERENDE DER LEIBNIZ UNIVERSITÄT HANNOVER[[ UND DER UNIVERSITÄT HILDESHEIM]]
Melde dich wie gewohnt bei Stud.IP[[ bzw. Learnweb]] an. Studora holt neue Skripte, Übungsblätter und Folien aus deinen Kursen, ordnet sie nach Modulen und übernimmt deine Vorlesungs- und Übungstermine[[, Abgabefristen und Ankündigungen der Lehrenden]]. Deine Zugangsdaten bleiben bei dir; die App liest nur und schreibt nichts in die Hochschulsysteme.

DOKUMENTE LESEN UND BESCHREIBEN
• Bibliothek mit Modulordnern, Favoriten, zuletzt geöffneten Dokumenten und Papierkorb
• PDFs lesen, zoomen, durchsuchen, Lesezeichen setzen
• Mit Plus: Schreiben mit dem Apple Pencil – Stift, Marker, Radierer, Lasso; Seiten einfügen, drehen und sortieren; Notizen als PDF exportieren
• Mit Plus: Übung und Skript nebeneinander[[, mit Skriptsuche zur Aufgabe]]

STUNDENPLAN UND LERNKALENDER
• Wochenraster mit deinen Vorlesungen und Übungen aus Stud.IP
• Lernkalender mit Lernpaketen je Modul und Lehrwoche in deinen freien Zeitfenstern: Vorlesung nacharbeiten, Übungen, Nachholen, „Woche retten“
[[• Abgabefristen, Quiz-Termine, Feiertage und vorlesungsfreie Zeit auf einen Blick]]
• Aufgaben abhaken, Zeitmesser mit Stoppuhr, Countdown und Pomodoro

GEMEINSAM LERNEN (PLUS)
• Eigene Karteikarten mit Wiederholung
• Lösungen zu Übungsblättern mit anderen vergleichen: als verschlüsselte Datei, die nur öffnen kann, wer dieselbe PDF hat[[; später online unter Pseudonym, mit Melden und Sperren]]

DEINE DATEN
• Alles liegt auf deinem iPad. Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort speichert Studora nicht und überträgt es nie; merken kann es auf Wunsch iOS im Schlüsselbund.

STUDORA FREE UND PLUS
Studora Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Lesen, Stundenplan, Lernkalender, Lernplanung und Lösungen anderer in der Community ansehen. Studora Plus (1,99 € pro Monat, die erste Woche gratis) schaltet das Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten und das Teilen eigener Lösungen frei. Das Abo verlängert sich automatisch um einen Monat, wenn es nicht mindestens 24 Stunden vor Ende des laufenden Zeitraums in den Einstellungen deines Apple-Kontos gekündigt wird. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: [[Domain]]/nutzungsbedingungen
Datenschutz: [[Domain]]/datenschutz

Studora ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Schlüsselwörter (max. 100 Zeichen, durch Komma getrennt)

```text keywords
Studium,Notizen,Apple Pencil,Lernplan,Stud.IP,Learnweb,Stundenplan,Übungsblatt,Hannover,Hildesheim
```

## Neue Funktionen in dieser Version (1.0)

```text whats-new
Erste Version: Dateien und Termine aus Stud.IP, Bibliothek nach Modulen, Stundenplan, Lernkalender mit Lernplanung, Zeitmesser. Mit Studora Plus: Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, Lösungen teilen.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| Kategorie | Bildung; zweite Kategorie: Produktivität |
| Support-URL | `[[Domain]]/support` (Kontakt per E-Mail [[E-Mail]]) |
| Marketing-URL | `[[Domain]]` (optional) |
| Datenschutz-URL | `[[Domain]]/datenschutz` |
| Copyright | © [[Jahr]] [[Name]] |
| Händlerstatus (DSA) | Händler; Name, Anschrift, E-Mail, Telefon wie im Impressum (werden im Store angezeigt) |
| Altersfreigabe | 4+ – Fragebogen: keine Gewalt, keine sexuellen Inhalte, kein Glücksspiel, keine Drogen, kein uneingeschränkter Webzugang (die Anmeldeseiten der Hochschule öffnen nur auf bekannten Adressen), **nutzergenerierte Inhalte: ja** (Community – Melden, Sperren, Moderation, Kontakt sind vorhanden), kein Wettbewerb, keine medizinischen Inhalte |
| Bundle-ID | `de.uniflow.ai` (`docs/RELEASE-VORBEREITUNG.md`) |
| Mit Apple anmelden | Fähigkeit aktiv; Konto löschen in der App (Richtlinie 5.1.1(v)) |

## App-Datenschutz (Nutrition Labels)

**V1 (iPad ohne Studora-Dienst):** „Daten werden nicht erfasst.“ Begründung: Alle Daten bleiben auf dem Gerät; „Mit
Apple anmelden“ und das Abo laufen über Apple, nicht über einen Server des Entwicklers; kein Analyse-SDK.
Hochschul-Passwörter speichert die iPad-App nicht (Entscheidung vom 27.10.2026): Im Anmeldefenster (WKWebView ohne
eigene Skripte) kann sie nur iOS selbst mit Passwort-Autofill im Schlüsselbund bzw. iCloud-Schlüsselbund sichern –
das ist Apples Funktion, nicht eine Erfassung durch den Entwickler. Auf dem Gerät bleiben nur Sitzungs-Cookies und der
Learnweb-Schlüssel; beides verlässt das Gerät nicht. Ältere Testfassungen hatten Zugangsdaten auf Wunsch selbst im
Schlüsselbund abgelegt; die aktuelle Fassung löscht solche Einträge beim ersten Start.

**Ab Anbindung des Studora-Dienstes (Konto, Geräteabgleich, Community):**

| Datentyp | Erfasst | Mit Identität verknüpft | Für Tracking | Zweck |
|---|---|---|---|---|
| Kontaktinformationen → E-Mail-Adresse | ja | ja | nein | App-Funktionalität (Konto) |
| Kennungen → Nutzer-ID | ja | ja | nein | App-Funktionalität |
| Nutzerinhalte → andere Nutzerinhalte (Dokumente, Notizen, Kalender; Community-Pakete verschlüsselt) | ja | ja | nein | App-Funktionalität |
| Käufe → Kaufverlauf (Abo-Status) | ja | ja | nein | App-Funktionalität |
| Standort, Kontakte, Gesundheit, Finanzdaten, Browserverlauf, Nutzungsdaten, Diagnose | nein | – | – | – |

Hochschul-Zugangsdaten, die der Nutzer für den automatischen Abgleich im Konto speichert (nur über Web/PC, nicht in der
iPad-App), sind „Anmeldedaten“ im
Sinne von Apples Definition **nicht** erfasst, wenn sie nur verschlüsselt zur Erbringung der vom Nutzer
eingerichteten Funktion gespeichert werden; [[mit Apple-Dokumentation zum Zeitpunkt der Einreichung abgleichen]].

## In-App-Käufe

Tarife nach `docs/ABO-SYSTEM.md`; Namen, Preise und Produkt-IDs aus `packages/shared-contracts/fixtures/plans/plans.json`.
**V1 verkauft nur Studora Free und Studora Plus** (Entscheidung des Inhabers vom 28.10.2026, `UFPlanCatalog.sellable`
in der App). Studora Free hat kein Produkt. Für V1 legt der Inhaber in App Store Connect **nur das Plus-Produkt** an,
als automatisch verlängerbares Abo in der Abo-Gruppe „Studora“:

| Feld | Wert |
|---|---|
| Produkt-ID | `de.uniflow.plus.monthly` (die Kennung bleibt bei `de.uniflow`, Bundle-ID `de.uniflow.ai`) |
| Abo-Gruppe | Studora |
| Referenzname | Studora Plus (monatlich) |
| Anzeigename (max. 30) | Studora Plus |
| Beschreibung (max. 45) | Stift, Karteikarten, Lösungen teilen |
| Preis | 1,99 € pro Monat (Preisstufe nach App Store Connect) |
| Einführungsangebot | 1 Woche gratis, einmal je Apple-ID |
| Prüf-Screenshot | Tarifseite der App mit den Karten Free und Plus |

**Später, nicht in V1:** Studora Pro Connect (`de.uniflow.proconnect.monthly`, 2,99 €) und Studora Pro AI
(`de.uniflow.proai.monthly`, 3,99 €) kommen erst mit dem Studora-Dienst in dieselbe Gruppe, dann mit Stufen nach Rang
(Pro AI höchste, Plus niedrigste). Werte stehen in `apps/apple/UniFlowTests/UniFlowAlleTarife.storekit`; die
Tarifseite zeigt bis dahin nur den Satz „Pro-Tarife folgen mit dem Studora-Dienst.“ ohne Preis und ohne Kaufknopf.
In V1 prüft die App den Kauf nur auf dem Gerät (StoreKit 2); kein Konto beim Dienst, kein `appAccountToken`.

Pflichttexte auf der Tarifseite in der App: Preis und Laufzeit, automatische Verlängerung, Kündigung in den
Einstellungen, Links zu Nutzungsbedingungen und Datenschutzerklärung, „Käufe wiederherstellen“. Was den
Online-Dienst braucht, steht auf den Karten unter „in Vorbereitung“, nie als enthalten.

## Hinweise für die App-Prüfung (Review Notes)

```text review-notes
Studora ist eine Lern-App für Studierende der Leibniz Universität Hannover. Die Hochschulfunktionen (Dateien, Termine) brauchen ein persönliches Konto der Hochschule, das wir nicht weitergeben dürfen. Zum Prüfen ohne Hochschulkonto: Mit Apple anmelden, einen Tarif wählen, als Hochschule „Leibniz Universität Hannover“ wählen und auf der folgenden Anmeldeseite unten „Ohne Hochschulkonto ansehen (Demo)“ tippen. Das legt ein Demo-Modul mit drei PDFs, Stundenplan, Lernkalender, einer Abgabefrist und einer Ankündigung an (selbst erstellte Demo-Daten, keine Hochschulinhalte); im Demo-Betrieb verbindet sich die App nicht mit der Hochschule und fragt nach keiner Anmeldung. Jederzeit auch unter Einstellungen → Erweitert → „Demo-Inhalte anlegen“; „Entfernen“ (Übersicht oder Einstellungen → Erweitert) nimmt alles wieder weg. Anmeldung mit Apple ist in der App vorhanden, Konto löschen unter Einstellungen → Konto. Das Abo „Studora Plus“ lässt sich in der Sandbox testen; nach dem Ende von Plus bleiben Notizen lesbar. Funktionen, die unseren Online-Dienst brauchen, stehen in der App deutlich als „in Vorbereitung“ und sind nicht freigeschaltet. Die Community in dieser Version teilt Lösungen nur als verschlüsselte Datei zwischen Nutzern mit derselben PDF; lesen, melden und sperren geht in jedem Tarif, teilen ab Plus, dazu eine Kontaktadresse. Keine KI-Funktionen in dieser Version, kein Tracking, keine Werbung.
```

## Bildschirmfotos (iPad Pro 13", 2064 × 2752)

1. Skript mit Handschrift (Apple Pencil) · 2. Übung und Skript nebeneinander · 3. Lernkalender (Woche) · 4. Module
und Bibliothek · 5. Stundenplan[[ mit Fristen und Feiertagen]]. Nur echte App-Inhalte, keine Uni-Logos ohne Erlaubnis,
keine echten Namen oder Noten.
