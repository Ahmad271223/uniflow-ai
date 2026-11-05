# Google Play Console – Texte und Angaben (Android, ab V2)

**Entwurf, Stand 26.10.2026, Sprache de-DE.** Felder in `text`-Blöcken mit Feldnamen; `tests/test_release_texts.py`
prüft Längen und dass kein Text KI-Funktionen verspricht. Die Android-App (`apps/android`) ist eine erste Fassung
(Konto, Dokumente, PDF mit Stift, Stundenplan, Lernkalender); Karteikarten, Noten und Community fehlen dort noch.
Die Texte gelten für den Stand, der eingereicht wird – Aussagen in `[[…]]` erst aufnehmen, wenn die Funktion in der
Android-App läuft.

## Store-Eintrag

```text title
StudiNow – Studium & Notizen
```

```text short
Stud.IP und Learnweb auf dem Tablet: Dateien, Stundenplan, Lernkalender, Stift.
```

```text full
StudiNow bringt dein Studium an einen Ort: die Dateien und Termine aus den Systemen deiner Hochschule, dein Stundenplan, dein Lernkalender und deine handschriftlichen Notizen – auf dem Tablet, mit dem Stift.

FÜR STUDIERENDE DER LEIBNIZ UNIVERSITÄT HANNOVER UND DER UNIVERSITÄT HILDESHEIM
Melde dich mit deinem StudiNow-Konto an und verbinde deine Hochschule. StudiNow holt neue Skripte, Übungsblätter und Folien aus deinen Kursen, ordnet sie nach Modulen und übernimmt Vorlesungs- und Übungstermine, Abgabefristen und Ankündigungen der Lehrenden. Die App liest nur und schreibt nichts in die Hochschulsysteme.

DOKUMENTE LESEN UND BESCHREIBEN
• Bibliothek mit Modulordnern und Dokumenten
• PDFs lesen und zoomen
• Mit Plus: Schreiben mit dem Stift (z. B. S Pen) – Stift, Marker, Radierer; Notizen werden mit deinen anderen Geräten abgeglichen

STUNDENPLAN UND LERNKALENDER
• Wochenraster mit deinen Vorlesungen und Übungen
• Lernkalender mit Lernpaketen je Modul und Lehrwoche in deinen freien Zeitfenstern
• Abgabefristen, Feiertage und vorlesungsfreie Zeit auf einen Blick
[[• Eigene Karteikarten mit Wiederholung (Plus)]]
[[• Lösungen zu Übungsblättern mit anderen vergleichen – verschlüsselt, unter Pseudonym, mit Melden und Sperren (Plus)]]

EIN KONTO FÜR ALLE GERÄTE
Mit deinem StudiNow-Konto zeigen Android-Tablet, iPad, Windows und Web denselben Stand: Dokumente, Notizen, Stundenplan und Lernkalender.

DEINE DATEN
• Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort bleibt bei dir: Du meldest dich im Anmeldefenster deiner Hochschule an. Merken übernimmt auf Wunsch der Passwort-Manager deines Geräts, die App speichert es nicht.
• Konto löschen direkt in der App.

STUDINOW FREE UND PLUS
Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Lesen, Stundenplan, Lernkalender und Lernplanung. Zum Start hast du 7 Tage Probe mit allem, ohne Zahlungsdaten. StudiNow Plus (1,99 € pro Monat) schaltet das Schreiben mit dem Stift frei[[, dazu Karteikarten und das Teilen von Lösungen]]. Das Abo verlängert sich automatisch um einen Monat, wenn du es nicht vor Ende des laufenden Zeitraums in Google Play kündigst. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| App-Kategorie | Bildung |
| Tags | Lernen, Produktivität, Notizen |
| Kontaktdaten | E-Mail support@studinow.app, Telefon [[Telefon]], Website `https://studinow.app` (werden öffentlich angezeigt) |
| Datenschutzerklärung | `https://studinow.app/datenschutz` |
| Konto löschen (Pflicht bei Kontoerstellung) | in der App: Einstellungen → Konto → Konto löschen; URL `https://studinow.app/konto-loeschen` |
| Zielgruppe und Inhalte | nur „18 und älter“ (Studierende; keine Kinder-Zielgruppe, damit die Families-Richtlinien nicht greifen) |
| Werbung | enthält keine Werbung |
| App-Zugriff | „Alle Funktionen sind ohne besondere Zugangsdaten verfügbar“ gilt **nicht** – Anleitung hinterlegen: Konto anlegen in der App; Hochschulfunktionen brauchen ein Hochschulkonto; Prüfung mit den Demo-Inhalten (Einstellungen → Erweitert → „Demo-Inhalte anlegen“: Demo-Modul mit PDFs, Stundenplan, Lernkalender, Frist, Ankündigung) |
| Paketname | `de.uniflow.android` (`apps/android/app/build.gradle.kts`) |

## Inhaltseinstufung (IARC-Fragebogen)

Gewalt, sexuelle Inhalte, Sprache, kontrollierte Substanzen, Glücksspiel: jeweils **nein**. „Nutzer können
interagieren oder Inhalte austauschen“: **ja**, sobald die Community in der Android-App ist (Lösungen als
verschlüsselte Pakete, kein Chat), mit Moderation, Melden und Sperren; bis dahin **nein**. „Teilt den Standort“: nein.
„Käufe digitaler Güter“: ja (Abo). Erwartete Einstufung: USK 0 / PEGI 3.

## Datensicherheit (Formular „Data safety“)

| Frage | Antwort |
|---|---|
| Erhebt oder teilt die App Nutzerdaten? | Ja (erhebt), teilt nicht |
| Verschlüsselung bei der Übertragung | Ja (TLS) |
| Löschung anfordern | Ja – in der App und über `https://studinow.app/konto-loeschen` |
| Unabhängige Sicherheitsprüfung | Nein |

| Datentyp | Erhoben | Geteilt | Optional | Zweck |
|---|---|---|---|---|
| Persönliche Daten → E-Mail-Adresse, Nutzer-IDs | ja | nein | nein (Konto nötig) | App-Funktionen, Kontoverwaltung |
| Dateien und Dokumente (Dokumente, Notizen; Community-Pakete verschlüsselt) | ja | nein | ja (Geräteabgleich, Community) | App-Funktionen |
| Kalender (Stundenplan, Lernkalender – nur in der App, kein Gerätekalender) | ja | nein | ja | App-Funktionen |
| Finanzdaten → Kaufverlauf (Abo-Status) | ja | nein | ja | App-Funktionen |
| Standort, Kontakte, Fotos, Audio, Gesundheit, Aktivität, Browserverlauf, Geräte-IDs, Absturzprotokolle, Diagnose | nein | – | – | – |

Hochschul-Zugangsdaten erhebt die Android-App nicht: Die Anmeldung läuft im Anmeldefenster der Hochschule (WebView),
Merken übernimmt der Passwort-Manager des Systems, die App behält nur die Sitzung (Cookies) der Hochschule bis zur
Abmeldung – sie laufen nie über den StudiNow-Dienst. [[Mit der Google-Dokumentation zum Zeitpunkt der Einreichung
abgleichen, ob die Sitzungs-Cookies anzugeben sind.]]

## Abo-Produkt (Play Billing)

| Feld | Wert |
|---|---|
| Produkt-ID | `plus_monthly` |
| Name | StudiNow Plus |
| Beschreibung | Stift, Karteikarten, Lösungen teilen (Abgleich der Notizen zwischen Geräten erst mit Pro AI) |
| Basisplan | `monthly`, 1 Monat, automatisch verlängernd, 1,99 € |
| Angebot | **keins** (Entscheidung 04.11.2026: keine Einführungsangebote; die 7 Tage Probe laufen in der App ohne Kauf, `docs/ABO-SYSTEM.md` 3b). Android ist zurzeit pausiert. |

Pflichttexte auf der Tarifseite in der App wie bei Apple: Preis und Laufzeit, automatische Verlängerung, Kündigung
in Google Play, Links zu Nutzungsbedingungen und Datenschutzerklärung.

## Bildschirmfotos (Tablet, 16:10 oder 16:9)

1. PDF mit Stift-Notizen · 2. Bibliothek nach Modulen · 3. Stundenplan · 4. Lernkalender · 5. Anmeldung mit
StudiNow-Konto. Nur echte App-Inhalte, keine Uni-Logos ohne Erlaubnis, keine echten Namen oder Noten.
