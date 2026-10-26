# Store- und Rechtstexte (P10) – Entwürfe, Stand 26.10.2026

Dieser Ordner enthält die Texte, die vor der Veröffentlichung im App Store (iPad, Mac „Designed for iPad“), im Play
Store (Android) und für den gehosteten Dienst gebraucht werden. **Alles sind Entwürfe aus dem tatsächlichen Verhalten
der Software, keine Rechtsberatung.** Vor der Veröffentlichung prüft eine Anwältin oder ein Anwalt die Datenschutz-
erklärung, die Nutzungsbedingungen und das Impressum; die Store-Texte prüft der Inhaber.

| Datei | Inhalt | Wo sie hinkommt |
|---|---|---|
| `DATENSCHUTZ.md` | Datenschutzerklärung für Apps, Web-Oberfläche und Dienst (Art. 13 DSGVO) | öffentliche Seite `[[Domain]]/datenschutz`; URL in App Store Connect und Play Console |
| `NUTZUNGSBEDINGUNGEN.md` | Nutzungsbedingungen inkl. Tarife, Abo, Hochschulsysteme, Community-Regeln | öffentliche Seite `[[Domain]]/nutzungsbedingungen`; Link auf der Tarifseite in der App (Pflicht bei Abos) |
| `IMPRESSUM.md` | Impressum-Vorlage nach § 5 DDG (zwei Varianten) | `[[Domain]]/impressum`; Händlerangaben im App Store (DSA) |
| `KONTO-LOESCHEN.md` | Öffentliche Seite „Konto löschen“ (Pflicht im Play Store, nützlich für Apple) | `[[Domain]]/konto-loeschen` |
| `APP-STORE.md` | App Store Connect: Name, Untertitel, Werbetext, Beschreibung, Schlüsselwörter, Altersfreigabe, App-Datenschutz, Abo-Produkt, Hinweise für die Prüfung | App Store Connect (de-DE) |
| `PLAY-STORE.md` | Play Console: Titel, Kurz- und Vollbeschreibung, Datensicherheit, Inhaltseinstufung, Zielgruppe, Abo-Produkt | Play Console (de-DE) |

Regeln für alle Texte (Entscheidung des Inhabers vom 25.10.2026):

- **Keine KI-Versprechen.** V1 enthält keine generativen Funktionen; die Texte nennen weder „KI“ noch „automatisch
  erstellte Tests“ noch Zusammenfassungen. Wenn KI-Funktionen später kommen, werden Store-Texte und
  Datenschutzerklärung zuerst ergänzt (`tests/test_release_texts.py` prüft die Store-Texte darauf).
- **Nur, was wirklich funktioniert.** Uni & Noten auf dem iPad und die Online-Community gelten erst als Funktion,
  wenn sie am Gerät laufen („bald“ ist kein Store-Text). Fristen, Termine und Noten sind Abbilder der
  Hochschulsysteme; verbindlich bleibt immer die Hochschule – das steht in jedem Text.
- **Keine Hochschule als Partner darstellen.** UniFlow ist nicht mit der Leibniz Universität Hannover oder der
  Universität Hildesheim verbunden; keine Uni-Logos in Screenshots ohne Erlaubnis.

## Platzhalter

Alle Platzhalter stehen in doppelten eckigen Klammern und müssen vor der Veröffentlichung ersetzt sein
(`tests/test_release_texts.py` listet sie auf):

`[[Name]]`, `[[Anschrift]]`, `[[E-Mail]]`, `[[Telefon]]`, `[[Domain]]`, `[[Hosting-Anbieter]]`, `[[Serverstandort]]`,
`[[Mail-Anbieter]]`, `[[Datum]]`, `[[USt-IdNr.]]` (nur falls vorhanden), `[[Aufsichtsbehörde]]`, Aufbewahrungsfristen
`[[14 Tage]]` / `[[90 Tage]]` (müssen zur umgesetzten Löschung passen).

## Was vor der Veröffentlichung noch zu tun ist

1. **Hosting entscheiden** (`docs/KONTEN-ABOS-PLAN.md`): Anbieter, Standort (Empfehlung EU), Vertrag zur
   Auftragsverarbeitung (Art. 28 DSGVO). Ohne gehosteten Dienst gilt für V1 (iPad) nur der Abschnitt „Auf deinem
   Gerät“ der Datenschutzerklärung – das ist dort so markiert.
2. **Schriftart selbst ausliefern – erledigt (26.10.2026).** Die Web-Oberfläche liefert „Inter“ aus
   `app/static/fonts/` aus (Inter 4.1, SIL Open Font License, `LICENSE-Inter.txt`); die CSP (`UI_CSP`) erlaubt keine
   fremden Hosts mehr, `tests/test_fonts.py` prüft das. Hintergrund: Laden von Google Fonts überträgt die IP-Adresse
   an Google und ist in Deutschland ohne Einwilligung angreifbar (LG München I, 3 O 17493/20).
3. **Löschfristen umsetzen**, die die Erklärung nennt: HTTP-Zugriffsprotokolle `[[14 Tage]]`, Abgleich-Protokolle
   `[[90 Tage]]` (heute gibt es keine automatische Rotation der `logs/`-Dateien), Konto 30 Tage nach Löschung
   (umgesetzt: `accounts.purge_deleted`).
4. **Mailversand** für „Passwort vergessen“ und Konto-Bestätigung (`accounts.reset_sender`) – Anbieter in die
   Datenschutzerklärung (Abschnitt 11).
5. **Öffentliche Seiten** `/datenschutz`, `/nutzungsbedingungen`, `/impressum`, `/konto-loeschen` aus diesen Dateien
   auf `[[Domain]]` bereitstellen (der Dienst kann sie als statische Seiten ausliefern; noch nicht gebaut).
6. **App Review:** Die Hochschulfunktionen brauchen ein echtes Hochschulkonto, das Apple und Google nicht bekommen
   dürfen. Für die Prüfung braucht die App Beispielinhalte ohne Hochschule (Demo-Kurs mit PDFs, Stundenplan,
   Kalender) – in den Prüfhinweisen beschrieben, in der App noch nicht vorhanden.
7. **Händlerstatus (DSA)** in App Store Connect angeben; Name, Anschrift, E-Mail und Telefon werden dann im Store
   angezeigt. Dieselben Angaben wie im Impressum.
8. **Datenexport** als Gesamtpaket (ZIP mit Notizen, Kalender, Karteikarten) ist in `docs/KONTEN-ABOS-PLAN.md`
   geplant, aber nicht gebaut; die Erklärung nennt heute den Export als PDF und den Geräteabgleich.
9. **Abstimmung mit den Hochschulen** zum automatisierten Abruf mit Studierenden-Zugangsdaten
   (`docs/ANFRAGE-STUDIP-ZUGANG.md`, `docs/ANFRAGE-HILDESHEIM.md`): Ergebnis ggf. in Nutzungsbedingungen Abschnitt 4.
