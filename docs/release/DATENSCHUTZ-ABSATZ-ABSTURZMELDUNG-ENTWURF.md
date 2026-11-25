# Entwurf: Datenschutz-Absatz „Absturzberichte“

Stand 25.11.2026. **Nur ein Entwurf.** Er steht noch nicht in `docs/release/DATENSCHUTZ.md` und nicht auf
studinow.app. Online stellen darf ihn nur der Inhaber, und erst zusammen mit der App-Version, die die Absturzmeldung
enthält. Der Text beschreibt, was der Code im Zweig `app/absturzmeldung` wirklich tut
(`apps/apple/UniFlow/Services/CrashReporting.swift`, `app/crash_reports.py`); ändert sich der Code, muss der Text mit.

Hinweis: Das ist kein Rechtsrat. Vor dem Veröffentlichen bitte prüfen (lassen), vor allem die offene Frage unten.

## Vorschlag für einen neuen Abschnitt 10a (nach „Web-Oberfläche, Cookies und Server-Protokolle“)

> ## 10a. Absturzberichte der Apps (iPhone, iPad, Mac)
>
> Stürzt StudiNow ab oder reagiert die App längere Zeit nicht, schickt sie beim nächsten Start einen kurzen
> Bericht an den StudiNow-Dienst. So sehen wir, in welcher Version und auf welchen Geräten Fehler auftreten, und
> können sie beheben.
>
> **Was im Bericht steht:** die Version der App, die Art des Geräts (iPhone, iPad oder Mac) und sein Modell
> (zum Beispiel „iPad14,3“), die Version des Betriebssystems, ob die App aus dem App Store oder eine Testfassung ist,
> der Zeitpunkt, die Art des Fehlers (Absturz, Hänger oder von iOS beendet, zum Beispiel weil der Speicher voll war)
> und die Stelle im Programm, an der es passiert ist (technische Angaben: Name des Programmteils und eine Zahl).
>
> **Was nicht im Bericht steht:** dein Name, deine E-Mail-Adresse, dein StudiNow-Konto, deine Zugangsdaten der
> Hochschule, Inhalte oder Namen deiner Dokumente, Notizen, Noten oder Nachrichten.
>
> Der Bericht geht ohne Anmeldung an den Dienst und wird dort ohne Bezug zu einem Konto gespeichert. Deine
> IP-Adresse speichern wir nicht beim Bericht; sie wird wie bei jedem Aufruf im Zugriffsprotokoll des Servers
> festgehalten (Abschnitt 10) und für höchstens zwei Tage gezählt, damit niemand den Dienst mit Berichten überflutet.
> Damit wir zählen können, wie viele Geräte an einem Tag betroffen sind, bildet der Dienst aus einer zufälligen
> Kennung der App und dem Tag einen Wert, der jeden Tag ein anderer ist. Die Kennung selbst speichern wir nicht; sie
> ist nicht die Geräte-Kennung deines Kontos, und aus dem Wert lässt sich nicht auf dich oder dein Gerät schließen.
>
> Die Berichte liegen auf unserem Server bei Hetzner in Deutschland und werden nach 90 Tagen gelöscht. Sie gehen an
> niemanden sonst.
>
> **Ausschalten (Widerspruch):** In den Einstellungen unter „Hilfe & Rechtliches“ → „Absturzberichte an StudiNow
> senden“. Danach schickt die App nichts mehr, und noch nicht gesendete Berichte werden auf dem Gerät gelöscht.
>
> Zweck: Fehler finden und beheben, Stabilität der App. Rechtsgrundlage: Art. 6 Abs. 1 lit. f DSGVO (berechtigtes
> Interesse an einer stabilen App); dein Widerspruch nach Art. 21 DSGVO ist über den Schalter jederzeit möglich.
>
> Davon unabhängig erhebt Apple eigene Absturzdaten, wenn du auf deinem Gerät „Mit App-Entwicklern teilen“
> eingeschaltet hast (Einstellungen von iOS → Datenschutz & Sicherheit → Analyse & Verbesserungen). Das ist Apples
> Erfassung; du steuerst sie dort.

## Weitere Stellen, die dann mitgeändert werden müssen

- **Abschnitt 1 „Das Wichtigste in Kürze“:** ein Satz, zum Beispiel: „Stürzt die App ab, schickt sie einen kurzen
  technischen Bericht ohne deinen Namen und ohne dein Konto; das kannst du ausschalten (Abschnitt 10a).“
- **Abschnitt 13 „Was wir nicht tun“:** „keine Analyse- oder Absturz-SDKs von Dritten“ bleibt richtig (die App nutzt
  Apples eigene Schnittstelle MetricKit und unseren eigenen Server). Zur Klarheit ergänzen: „Absturzberichte gehen
  nur an uns (Abschnitt 10a).“
- **`site/datenschutz.html`** bekommt denselben Text wie `DATENSCHUTZ.md` (die Seite wird aus dem Text gepflegt).
- **App Store Connect → App-Datenschutz:** neue Datenart „Diagnose → Absturzdaten“, erfasst: ja, mit der Identität
  verknüpft: nein, Tracking: nein, Zweck: App-Funktionalität. Die Tabelle in `docs/release/APP-STORE.md` und das
  Datenschutz-Manifest der App (`PrivacyInfo.xcprivacy`) sind im Zweig schon angepasst.

## Offene Frage für den Inhaber (bitte entscheiden, am besten mit rechtlichem Rat)

Der Schalter ist im Zweig **von selbst an** (wie beim Datei-Eingang, Entscheidung vom 18.11.2026): Wer nichts tut,
schickt Absturzberichte; Ausschalten gilt als Widerspruch. Dafür spricht: Nur so sagen die Zahlen etwas aus, und der
Bericht enthält nichts über die Person.

Dagegen steht eine deutsche Besonderheit: § 25 TDDDG verlangt eine Einwilligung, wenn eine App Informationen aus dem
Gerät ausliest, die für den Dienst nicht „unbedingt erforderlich“ sind. Ob ein so knapper Absturzbericht darunter
fällt, wird unterschiedlich beurteilt. Der vorsichtige Weg wäre: **beim ersten Start einmal fragen** („Absturzberichte
senden? Ja / Nein“) und erst nach „Ja“ senden. Dann melden deutlich weniger Geräte, die Zahlen bleiben aber als Trend
brauchbar.

Im Code ist das eine Stelle (`CrashReportSetting.onByDefault`); die Frage beim ersten Start wäre zusätzliche Arbeit
(ein Dialog in der Begrüßung). Bei „erst fragen“ ändert sich im Text oben die Rechtsgrundlage auf Einwilligung
(Art. 6 Abs. 1 lit. a DSGVO, § 25 Abs. 1 TDDDG) mit Widerruf über denselben Schalter.
