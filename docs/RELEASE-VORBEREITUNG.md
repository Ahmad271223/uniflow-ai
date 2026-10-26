# Release-Vorbereitung (iPad-App)

Stand 25.10.2026. Nichts davon ist veröffentlicht oder bei Apple angelegt. Veröffentlichung, App-Store-Connect-Einträge
und echte In-App-Produkte nur nach ausdrücklicher Freigabe.

## Umgebungen

| Umgebung | Server | Xcode-Konfiguration | Netzwerk | Zweck |
| --- | --- | --- | --- | --- |
| Development | eigener PC (`Start-iPad.cmd`, http im WLAN, PIN) | Debug | http im lokalen Netz erlaubt | Entwicklung, eigene Nutzung |
| Staging | gehosteter Testserver mit HTTPS (noch nicht vorhanden) | Staging (Release-Optimierung) | nur HTTPS | TestFlight, Tests mit Testkonten |
| Production | gehosteter Server mit HTTPS (noch nicht vorhanden) | Release | nur HTTPS | App Store |

Regel: `NSAllowsArbitraryLoads` gibt es nur in Debug. Release und Staging erlauben ausschließlich HTTPS. Die
Server-Adresse kommt in Staging/Production fest aus der Konfiguration, nicht aus einem Eingabefeld.

Offen, weil Hosting noch nicht entschieden ist (siehe `KONTEN-ABOS-PLAN.md`): Staging- und Production-Server.

## Kennungen und Versionen

| Feld | Wert | Hinweis |
| --- | --- | --- |
| Bundle-ID | `de.uniflow.ai` | muss im Apple-Konto frei sein; sonst z. B. `de.<nachname>.uniflow` |
| Testziel | `de.uniflow.ai.tests` | |
| Version (Marketing) | `0.2.0` | `MARKETING_VERSION` in `apps/apple/project.yml` |
| Build-Nummer | `2` | `CURRENT_PROJECT_VERSION`, je Upload +1 |
| Mindestversion | iPadOS 17 | wegen PDFKit-Overlays (16) und SwiftUI-APIs (17) |

## App-Icon und Startbildschirm

- Icon: `apps/apple/UniFlow/Assets.xcassets/AppIcon.appiconset` (1024×1024, ohne Transparenz). Vor dem Upload am
  Mac prüfen: Xcode meldet fehlende oder transparente Icons als Fehler.
- Startbildschirm: `UILaunchScreen` mit Akzentfarbe (in `project.yml`).

## Berechtigungen (Info.plist)

| Schlüssel | Text | Warum |
| --- | --- | --- |
| `NSLocalNetworkUsageDescription` | „UniFlow verbindet sich mit deinem UniFlow-Server im WLAN.“ | nur Development |
| (keine Kamera, kein Mikrofon, kein Standort) | – | Aufnahmen gibt es nur im Web-Editor |

## Mit Apple anmelden freischalten

Die Fähigkeit *Sign in with Apple* gibt es nur mit dem bezahlten Apple Developer Program. Damit Simulator, CI und
Builds mit kostenloser Apple-ID (Personal Team) weiter funktionieren, ist sie nicht fest eingetragen:

1. `apps/apple/Config/Team.xcconfig.example` nach `apps/apple/Config/Team.xcconfig` kopieren (steht in `.gitignore`).
2. Dort die Team-ID des bezahlten Programms eintragen; `CODE_SIGN_ENTITLEMENTS` zeigt auf
   `UniFlow/UniFlow.entitlements` (`com.apple.developer.applesignin`).
3. `xcodegen generate`. Ohne diese Datei meldet der Knopf „Mit Apple anmelden“, dass die Anmeldung in diesem Build
   nicht verfügbar ist; im Debug-Build gibt es „Anmeldung überspringen (Debug)“.

Beim Löschen des Kontos widerruft V1 keine Apple-Token, weil die App keine speichert (der `authorizationCode` wird
nicht eingelöst). Ab V2 mit Server müssen die Token beim Löschen über `https://appleid.apple.com/auth/revoke`
widerrufen werden.

## Datenschutz

- `PrivacyInfo.xcprivacy` (Privacy Manifest): genutzte „Required Reason APIs“ angeben (`UserDefaults`: CA92.1,
  Dateizeitstempel: C617.1). Datei anlegen, sobald am Mac geprüft wird, welche APIs die fertige App tatsächlich nutzt.
- App-Store-Datenschutzangaben: Development speichert alles nur auf dem eigenen PC und Gerät. Mit Konten: E-Mail,
  Notizen, Lernfortschritt (mit Nutzer verknüpft, kein Tracking, keine Werbung).
- Datenschutzerklärung und Impressum: Entwürfe in `docs/release/` (26.10.2026); vor TestFlight anwaltlich prüfen und auf `[[Domain]]` veröffentlichen, Platzhalter hängen vom Hosting ab.

## Fehlerprotokollierung

- Heute: Status in der App, Konsole (`os.Logger` noch nicht eingebaut), Server-Logs unter `logs/`.
- Vor TestFlight: `os.Logger` mit Kategorien (sync, editor, network); keine Notizinhalte und keine Zugangsdaten
  ins Protokoll. Abstürze über Xcode Organizer / TestFlight-Feedback, kein Drittanbieter-SDK.

## TestFlight

1. Apple Developer Program (99 €/Jahr) – Freigabe nötig.
2. App-Store-Connect-Eintrag mit Bundle-ID – Freigabe nötig.
3. Archive in Xcode (Release), Upload, interne Tester (bis 100, ohne Review).
4. Signierung: automatische Signierung in Xcode; in CI erst nach Freigabe mit App-Store-Connect-API-Schlüssel als
   GitHub-Secret (nie im Repository).

## App-Store-Metadaten

Alle Texte und Angaben (Name, Untertitel, Werbetext, Beschreibung, Schlüsselwörter, Altersfreigabe, App-Datenschutz,
Abo-Produkt, Prüfhinweise) stehen in `docs/release/APP-STORE.md`; Datenschutzerklärung, Nutzungsbedingungen,
Impressum-Vorlage und die Seite „Konto löschen“ in `docs/release/` (Stand 26.10.2026, Entwürfe ohne KI-Versprechen,
`tests/test_release_texts.py`). Support-URL und Datenschutz-URL: offen (Hosting, `[[Domain]]`).

## Bildschirmfotos (Vorgaben)

| Gerät | Größe | Inhalte |
| --- | --- | --- |
| iPad Pro 13" (Pflicht) | 2064 × 2752 hoch oder 2752 × 2064 quer | 1. Skript mit Handschrift, 2. Split-Screen Übung + Skript, 3. Lernkalender Woche, 4. Module, 5. Stundenplan mit Fristen und Feiertagen |
| iPad 11" (optional) | 1668 × 2420 | wie oben |

Nur echte App-Inhalte, keine fremden Logos (Uni-Logos nur mit Erlaubnis), keine echten Noten oder Namen.

## Checkliste vor dem ersten Upload

- [ ] `NSAllowsArbitraryLoads` nur in Debug (Release-Build prüfen: `plutil -p` auf die Info.plist im Archiv)
- [ ] Staging/Production-Server mit HTTPS
- [ ] Privacy Manifest
- [ ] Icon ohne Transparenz, alle Größen generiert
- [ ] Gerätetests aus `MAC-IPAD-CHECKLISTE.md` bestanden
- [ ] Keine Testdaten, keine echten Namen/Noten in Bildschirmfotos
- [ ] StoreKit: nur Testkonfiguration im Build, echte Produkte erst nach Freigabe
