# Benachrichtigungen wie bei Studo (für Version 1.3 oder 1.4)

Stand 11.11.2026, Zweig `claude/benachrichtigungen-1-3-f2d39e` (von `develop`, nicht gemergt, nichts hochgeladen,
Versionsnummer unverändert). Entscheidung des Inhabers 11.11.2026: kommt erst mit einem späteren Update.

## Was neu ist

| Mitteilung | Text | Schalter (Einstellungen → „Im Hintergrund abgleichen“) |
|---|---|---|
| Neue Note | „Neue Note in *Modul* eingetragen“ | „Neue Noten“ (aus) |
| … mit Notenwert | „… eingetragen: 1,7“ | „Notenwert in der Mitteilung zeigen“ (aus) |
| Stud.IP-Nachricht | „1 neue Nachricht in Stud.IP“ – nie Absender oder Betreff | „Stud.IP-Nachrichten“ (aus, nur LUH) |
| Ankündigung | Titel „Neue Ankündigung in *Kurs*“, darunter die Überschrift | „Ankündigungen“ (aus) |
| Neuanmeldung | keine eigene Mitteilung; klappt sie nicht, kommt wie bisher einmal „Bitte bei … anmelden“ | „Im Hintergrund neu anmelden“ (an) |

- Erst das Einschalten eines Schalters fragt iOS nach der Erlaubnis für Mitteilungen, nie der App-Start.
- Neue Noten: Der Hintergrundlauf vergleicht den gespeicherten Notenspiegel vor und nach dem Abruf. „Angemeldet“
  zählt nicht als Note, „bestanden“ ohne Note schon. Beim allerersten Notenspiegel kommt keine Mitteilung.
  QIS wird im Hintergrund höchstens einmal pro Stunde gefragt.
- Nachrichten und Ankündigungen zählen nur, wenn sie jünger als 14 Tage sind. Mehr als drei Noten oder Ankündigungen
  auf einmal werden zu einer Sammelmitteilung.
- Abgelaufene Anmeldung (Stud.IP, QIS, Uni-Mail): Der Hintergrundlauf meldet sich still neu an, **nur** wenn der
  Nutzer seinen Uni-Zugang gespeichert hat und „Automatisch anmelden“ an ist. Das Passwort liegt nur im Schlüsselbund
  dieses Geräts und geht nie an einen StudiNow-Server. Höchstens ein Versuch je Dienst in 6 Stunden, nach einem
  Fehlschlag erst nach 24 Stunden. Lehnt die Hochschule das Passwort ab, wird es sofort gelöscht und nie wieder gesendet.
  Auf iPad und iPhone nur im langen Hintergrundlauf (der kurze hat nur rund 30 Sekunden), am Mac bei jedem Takt.
- Mac („Designed for iPad“): Solange StudiNow läuft, auch wenn es nicht vorn ist, läuft alle 20 bis 30 Minuten
  derselbe Abgleich mit denselben Mitteilungen. War eben schon ein Lauf, fällt der Takt aus.

Code: `UniFlow/Services/BackgroundNews.swift` (Regeln, Texte, Schalter), `MacBackgroundTicker.swift`,
`BackgroundSync.swift` (Ablauf), `UniAutoLogin.swift`, `StudIPSync.swift`, `QISConnection.swift`,
`UniMailConnection.swift` (Neuanmeldung ohne Fenster), `Views/Settings/BackgroundSyncCard.swift` (Schalter).
Tests: `UniFlowTests/BackgroundNewsAppTests.swift`.

## Was nur am echten Gerät prüfbar ist

1. **Wann iOS den Hintergrundlauf startet**, bestimmt iOS allein (Nutzung, Akku, Netz). Der Simulator startet ihn nie.
   Mitteilungen können also Stunden später kommen als die Note im QIS steht.
2. **Neuanmeldung im Hintergrund ohne Fenster**: Die unsichtbare Anmeldeseite läuft dort ohne sichtbares Fenster. Ob
   iOS das im Hintergrund lange genug zulässt (rund 30 Sekunden im kurzen Lauf), lässt sich nur am iPad/iPhone mit
   gesperrtem Bildschirm prüfen – mit einer echten, abgelaufenen Stud.IP-, QIS- und Uni-Mail-Anmeldung.
3. **Mac**: ob der 20–30-Minuten-Takt auch bei minimiertem Fenster pünktlich bleibt (macOS kann Apps im Hintergrund
   bremsen; die App meldet deshalb eine laufende Aufgabe an) und ob Mitteilungen dort erscheinen.
4. **Echte Daten**: Ob QIS eine neue Note sofort im Notenspiegel zeigt und welche Statuswörter die LUH nutzt
   („bestanden“, „BE“, „NB“ sind abgedeckt), und wie Stud.IP-Ankündigungen den Kurs nennen.
5. Sperrbildschirm mit „Vorschauen: nie“: Dann steht nur „Neues aus deiner Hochschule“ da.

## Vor der Veröffentlichung

- Datenschutzerklärung und App-Store-Text: „Neuanmeldung im Hintergrund mit dem gespeicherten Uni-Zugang (nur auf dem
  Gerät)“ ergänzen.
- Versionsnummer setzt der Inhaber beim Einreichen.
