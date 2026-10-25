# Entwurf: Anfrage an das Stud.IP-Team der LUH (ZQS/elsa)

Nur ein Entwurf – abschicken musst du ihn selbst (an: elearning@uni-hannover.de). Vorher Namen, Studiengang und
gewünschte Angaben ergänzen; nichts davon wurde bisher verschickt.

---

**Betreff:** Studentische Lern-App: Nutzung der Stud.IP-JSON:API und OAuth2-Client

Guten Tag,

ich studiere im 1. Semester an der LUH und entwickle für mich eine Lern-App für das iPad („UniFlow“). Sie lädt
meine eigenen Kursunterlagen aus Stud.IP auf mein Gerät, damit ich sie dort mit dem Apple Pencil bearbeiten kann.

So funktioniert es derzeit:
- Ich melde mich in der App auf der normalen Stud.IP-Seite der LUH (WebSSO) an. Die App speichert das
  Sitzungs-Cookie im Schlüsselbund des iPads; Benutzername und Passwort nur, wenn ich „Auf diesem iPad merken“
  einschalte (ebenfalls nur im Schlüsselbund dieses Geräts, nie auf einem Server), damit sie beim nächsten Mal im
  Formular stehen. Abschicken muss ich das Formular immer selbst.
- Danach ruft die App über die JSON:API nur lesend meine Kurse, den Ordnerbaum und die Dateien ab
  (`users/me`, `users/{id}/courses`, `courses/{id}/folders`, `folders/{id}/file-refs`, `file-refs/{id}/content`).
- Die Abrufe laufen nacheinander mit Pause, beim Öffnen der App höchstens alle 30 Minuten; ein Durchgang für
  meine 14 Kurse sind etwa 120 Anfragen, Dateien werden nur bei Änderungen erneut geladen.
- Die Dateien bleiben auf meinem Gerät und werden nicht weitergegeben.

Dazu habe ich drei Fragen:
1. Ist diese Nutzung der JSON:API mit dem eigenen Konto aus Ihrer Sicht in Ordnung? Gibt es Vorgaben zur
   Häufigkeit oder Menge der Abrufe, die ich einhalten soll?
2. Die Stud.IP-Dokumentation beschreibt OAuth2 mit PKCE für Apps. Wäre es möglich, für die App einen OAuth2-Client
   einzurichten (öffentlicher Client mit PKCE, Scope `api`, Weiterleitung z. B. `de.uniflow.ai:/oauth/callback`)?
   Dann müsste die App die Anmeldung nicht mehr in einer eingebetteten Webansicht anzeigen.
3. Falls ich die App später auch anderen Studierenden der LUH anbieten möchte: Was müsste ich dafür beachten bzw.
   mit wem sollte ich das abstimmen (z. B. Datenschutz)?

Gern stelle ich die App oder den Quelltext vor.

Viele Grüße
[Name], [Studiengang]

---

Hintergrund und Quellen: `docs/IPAD-STUDIP-SYNC.md`, Abschnitte 7 und 8.
