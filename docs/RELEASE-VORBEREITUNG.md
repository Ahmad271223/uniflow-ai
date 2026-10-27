# Release-Vorbereitung (iPad-App, V1)

Stand 26.10.2026 (Abnahme V1). Nichts davon ist veröffentlicht oder bei Apple angelegt. Veröffentlichung,
App-Store-Connect-Einträge und echte In-App-Produkte nur nach ausdrücklicher Freigabe des Inhabers.

V1 läuft **ohne Server**: Daten aus Stud.IP (LUH) bzw. Learnweb/LSF (Uni Hildesheim) holt das iPad selbst, alles liegt
im lokalen Backend des Geräts (`docs/AUFTRAG-APPSTORE-V1.md`, `docs/IPAD-OHNE-PC.md`). Kein KI-Dienst, kein PC, kein
UniFlow-Konto auf einem Server; Abos nur über StoreKit (Free/Plus).

## Umgebungen

| Umgebung | Datenquelle | Xcode-Konfiguration | Netzwerk | Zweck |
| --- | --- | --- | --- | --- |
| Development | lokales Backend; optional eigener PC-Server (`Start-iPad.cmd`, http im WLAN, PIN, Reiter „Entwicklung“) | Debug | zusätzlich `NSAllowsLocalNetworking` und `NSLocalNetworkUsageDescription` (Skriptphase „Nur Debug: lokales Netz“) | Entwicklung |
| Release (TestFlight, App Store) | nur lokales Backend auf dem iPad | Release | nur HTTPS (ATS ohne Ausnahmen) | Nutzer |

Die Info.plist enthält kein `NSAppTransportSecurity` und keinen Text zum lokalen Netz; beides setzt nur der
Debug-Build nach dem Kopieren (project.yml). Geprüft am 26.10.2026 mit `plutil -p` auf die Info.plist eines
Release-Builds für den Simulator (kein ATS-Schlüssel, kein `NSLocalNetworkUsageDescription`) und im App-Test
`AbnahmeV1AppTests.testInfoPlistHasNoArbitraryLoadsAndOnlyDebugAllowsTheLocalNetwork`.

## Kennungen und Versionen

| Feld | Wert | Hinweis |
| --- | --- | --- |
| Bundle-ID | `de.uniflow.ai` | muss im Apple-Konto frei sein; sonst z. B. `de.<nachname>.uniflow` |
| Testziel | `de.uniflow.ai.tests` | |
| Version (Marketing) | `MARKETING_VERSION` in `apps/apple/project.yml` | |
| Build-Nummer | `CURRENT_PROJECT_VERSION`, je Upload +1 | |
| Mindestversion | iPadOS 17 | wegen PDFKit-Overlays (16) und SwiftUI-APIs (17) |
| Abo | `de.uniflow.plus.monthly` (1,99 €, Probewoche) | Abo-Gruppe in App Store Connect, mit der ersten Version einreichen |

## App-Icon und Startbildschirm

- Icon: `apps/apple/UniFlow/Assets.xcassets/AppIcon.appiconset` (1024×1024, ohne Transparenz). Vor dem Upload am
  Mac prüfen: Xcode meldet fehlende oder transparente Icons als Fehler.
- Startbildschirm: `UILaunchScreen` mit Akzentfarbe (in `project.yml`).

## Berechtigungen (Info.plist)

| Schlüssel | Text | Warum |
| --- | --- | --- |
| `NSLocalNetworkUsageDescription` | „UniFlow verbindet sich mit deinem UniFlow-Server im WLAN.“ | **nur Debug** (eigener Server) |
| (keine Kamera, kein Mikrofon, kein Standort) | – | – |

## Mit Apple anmelden freischalten (Pflicht vor dem Archivieren)

Die Fähigkeit *Sign in with Apple* gibt es nur mit dem bezahlten Apple Developer Program. Damit Simulator, CI und
Builds mit kostenloser Apple-ID (Personal Team) weiter funktionieren, ist sie nicht fest eingetragen:

1. `apps/apple/Config/Team.xcconfig.example` nach `apps/apple/Config/Team.xcconfig` kopieren (steht in `.gitignore`).
2. Dort die Team-ID des bezahlten Programms eintragen; `CODE_SIGN_ENTITLEMENTS` zeigt auf
   `UniFlow/UniFlow.entitlements` (`com.apple.developer.applesignin`).
3. `xcodegen generate`.

Die Skriptphase „Release: Team und Mit Apple anmelden prüfen“ (project.yml) bricht einen Release-Build für Geräte ab,
wenn `DEVELOPMENT_TEAM` oder `CODE_SIGN_ENTITLEMENTS` fehlt: sonst entstünde ein Archiv ohne SIWA-Berechtigung, das an
der Pflichtanmeldung hängen bliebe. (Nicht geprüft am 26.10.2026: ohne Team scheitert der Gerätebuild hier schon an
der Signierung, bevor die Skriptphase läuft.)

Beim Löschen des Kontos widerruft V1 keine Apple-Token, weil die App keine speichert (der `authorizationCode` wird
nicht eingelöst). Der Dialog „Konto löschen“ zeigt deshalb den Weg in den iPad-Einstellungen (Name → Anmelden und
Sicherheit → Mit Apple anmelden → UniFlow). Ab V2 mit Server müssen die Token beim Löschen über
`https://appleid.apple.com/auth/revoke` widerrufen werden.

## Datenschutz

- `apps/apple/UniFlow/PrivacyInfo.xcprivacy` (Privacy Manifest, seit 26.10.2026): kein Tracking, keine erhobenen
  Daten, Required-Reason-APIs `UserDefaults` (CA92.1), Dateizeitstempel (C617.1), freier Speicher (E174.1). Liegt im
  App-Bundle (App-Test `testPrivacyManifestIsInTheBundle`).
- App-Store-Datenschutzangaben (Vorschlag, Entscheidung des Inhabers): für das iPad ohne Konto „Keine Daten erfasst“ –
  nichts verlässt das Gerät in Richtung UniFlow; Stud.IP, Learnweb, LSF und Opencast werden direkt von der Hochschule
  geladen, Abos laufen über Apple. Sobald UniFlow-Konten (gehosteter Modus) dazukommen: E-Mail, Notizen,
  Lernfortschritt (mit Nutzer verknüpft, kein Tracking, keine Werbung).
- Datenschutzerklärung, Nutzungsbedingungen (EULA, eigene oder Apples Standard-EULA), Impressum und Support:
  Entwürfe in `docs/release/` (26.10.2026); vor TestFlight anwaltlich prüfen und auf `[[Domain]]` veröffentlichen,
  Platzhalter hängen vom Hosting ab. Die Abo-Seite zeigt bis dahin einen Platzhalter (Richtlinie 3.1.2(a) verlangt
  funktionierende Links); die URLs danach in PlanPickerView, den Einstellungen und App Store Connect eintragen.
- Exportkontrolle: Die App verschlüsselt Lösungspakete selbst (AES-256-GCM, HKDF-SHA256 aus CryptoKit).
  `ITSAppUsesNonExemptEncryption` ist noch nicht gesetzt; die Einstufung trifft der Inhaber in App Store Connect.

## Fehlerprotokollierung

- Status in der App (Abgleich, Editor), keine Notizinhalte und keine Zugangsdaten in Meldungen.
- Abstürze über Xcode Organizer / TestFlight-Feedback, kein Drittanbieter-SDK.

## TestFlight

1. Apple Developer Program (99 €/Jahr) – Freigabe nötig.
2. App-Store-Connect-Eintrag mit Bundle-ID und Abo-Gruppe – Freigabe nötig.
3. Archive in Xcode (Release), Upload, interne Tester (bis 100, ohne Review).
4. Signierung: automatische Signierung in Xcode; in CI erst nach Freigabe mit App-Store-Connect-API-Schlüssel als
   GitHub-Secret (nie im Repository).

## App-Store-Metadaten

Alle Texte und Angaben (Name, Untertitel, Werbetext, Beschreibung, Schlüsselwörter, Altersfreigabe, App-Datenschutz,
Abo-Produkt, Prüfhinweise) stehen in `docs/release/APP-STORE.md`; Datenschutzerklärung, Nutzungsbedingungen,
Impressum-Vorlage und die Seite „Konto löschen“ in `docs/release/` (Stand 26.10.2026, Entwürfe ohne KI-Versprechen,
`tests/test_release_texts.py`). Support-URL und Datenschutz-URL: offen (Hosting, `[[Domain]]`).

Kurzfassung aus der iPad-Abnahme (Entwurf V1, gilt nur, soweit `docs/release/APP-STORE.md` nichts anderes sagt):

- Name: UniFlow – Studium & Notizen; Untertitel: Skripte, Handschrift, Lernplan
- Kategorie: Bildung; zweite Kategorie: Produktivität
- Beschreibung (Kurz): Holt deine Dateien und Termine aus Stud.IP (Leibniz Universität Hannover) bzw. Learnweb und LSF
  (Uni Hildesheim) direkt aufs iPad, ordnet sie nach Modul und Lehrwoche, plant deine Lernwoche um Vorlesungen und
  Übungen und zeigt deinen Stundenplan. Mit Plus schreibst du mit dem Apple Pencil in deine Skripte und teilst eigene
  Lösungen als verschlüsselte Datei. Alles bleibt auf deinem iPad – ohne KI, ohne PC, ohne UniFlow-Server.
- Stichworte: Studium, Notizen, PDF, Apple Pencil, Lernplan, Stud.IP, Learnweb, Stundenplan, Uni
- Support-URL, Datenschutz-URL, EULA: offen (Inhaber)

## Bildschirmfotos (Vorgaben)

| Gerät | Größe | Inhalte |
| --- | --- | --- |
| iPad Pro 13" (Pflicht) | 2064 × 2752 hoch oder 2752 × 2064 quer | 1. Skript mit Handschrift (Plus), 2. Split-Screen Übung + Skript, 3. Lernkalender Woche, 4. Module nach Lehrwoche, 5. Stundenplan mit Fristen und Feiertagen |
| iPad 11" (optional) | 1668 × 2420 | wie oben |

Nur echte App-Inhalte mit erfundenen Daten: keine fremden Logos (Uni-Logos nur mit Erlaubnis), keine echten Noten,
Namen oder Kurse.

## Checkliste vor der Einreichung (einzeln abhaken)

Code und Build (umgesetzt, Stand Abnahme 26.10.2026):

- [x] ATS ohne Ausnahmen im Release, lokales Netz nur Debug (`plutil -p` auf die Info.plist im Archiv wiederholen)
- [x] Privacy Manifest im Bundle
- [x] Debug-Schalter (-UFPlan, -UFNoServer, -UFUniversity, -UFOnboarding, eigener Server, Debug-Konto, Reiter
      „Entwicklung“) im Release gesperrt; Abo nur über StoreKit; „Konto löschen“ vorhanden
- [x] Release-Prüfung Team/SIWA als Skriptphase
- [x] Seitenleiste ohne Platzhalter-Bereiche ohne PC (Tests & Wiederholung; Community nur mit iCloud-Container im Build,
      sonst ehrlicher Hinweis in den Einstellungen; Uni & Noten nur mit Notenspiegel auf dem Gerät)
- [ ] Icon ohne Transparenz, alle Größen generiert (am Mac prüfen)
- [ ] Gerätetest mit Apple Pencil (`MAC-IPAD-CHECKLISTE.md`)
- [ ] StoreKit: nur Testkonfiguration im Build, echte Produkte erst nach Freigabe

Inhaber:

- [ ] Apple Developer Program, `Team.xcconfig`, App-ID `de.uniflow.ai` mit Sign in with Apple
- [ ] App Store Connect: App-Eintrag, Abo-Gruppe mit `de.uniflow.plus.monthly` (1,99 €, Probewoche), zusammen mit der
      ersten Version einreichen
- [ ] Vertrag für kostenpflichtige Apps mit Bank- und Steuerdaten
- [ ] URLs für Datenschutzerklärung, EULA, Impressum und Support (in App und App Store Connect)
- [ ] App-Datenschutzangaben (mit Community: „Andere Nutzerinhalte“, nicht verknüpft, kein Tracking – wie im Privacy
      Manifest), Exportkontrolle (`ITSAppUsesNonExemptEncryption`), Altersfreigabe
- [ ] Community: iCloud-Container `iCloud.de.uniflow.ai`, `UF_CLOUDKIT_CONTAINER` in `Team.xcconfig`, Schema und
      Indizes, Security Role für `Ban` (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 7); ohne Container bleibt der Build
      ehrlich („nicht verfügbar“, kein Menüpunkt)
- [ ] Bildschirmfotos iPad 13" ohne echte Namen und Noten
- [x] Review-Notes: Weg für die Prüfung ohne Uni-Konto – Demo-Inhalte (Entscheidung 27.10.2026; iPad: erster Start
      „Ohne Hochschulkonto ansehen (Demo)“ und Einstellungen → Erweitert, Text in `docs/release/APP-STORE.md`),
      Begründung der Pflichtanmeldung (Datentrennung je Konto und Hochschule), keine Token/kein Serverkonto, Erlaubnisse
      der Hochschulen
- [ ] TestFlight und Einreichung nur nach eigener Freigabe

Hochschulen (schriftliche Freigaben, `docs/IPAD-OHNE-PC.md` §6):

- [ ] LUH: Stud.IP-Zugriff vom Gerät, Opencast samt Download, Name
- [ ] Uni Hildesheim: CAS, Learnweb über das Moodle-Mobile-SSO, LSF, Name

Apple: App-Prüfung und Prüfung der In-App-Käufe.
