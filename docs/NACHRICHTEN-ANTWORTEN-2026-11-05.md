# Auf Stud.IP-Nachrichten antworten (05.11.2026)

Entscheidung des Inhabers (05.11.2026, wörtlich): „versuch aus studip zu antworten auf die nachrichten ja“. Bisher zeigt
die Seite „Nachrichten“ den Stud.IP-Posteingang nur an (Liste, Suche, Leser, Zähler, „In Stud.IP öffnen“;
`docs/IPAD-STUDIP-SYNC.md`, `MessagesPage.swift`). Neu: im Leser **„Antworten“** und, wenn die Nachricht an mehrere
ging, **„Allen antworten“**. Gesendet wird über Stud.IP unter dem eigenen Namen.

Das Senden ist nach dem Abgeben (`docs/ABGEBEN-STUDIP-2026-11-05.md`) die zweite schreibende Anfrage der App an Stud.IP.
Es nutzt denselben Weg: Sitzungs-Cookie aus dem Schlüsselbund, eigener schreibender Transport
(`URLSessionStudIPWriter`), stille Erneuerung, nie ein Passwort. Gesendet wird nur, wenn der Mensch „Senden“ tippt,
nie im Abgleich und nie still wiederholt.

## 1. Recherche: Nachrichten in der Stud.IP-JSON:API

Gelesen wurden nur öffentliche Dokumentationen, keine Anfrage an die LUH:
- [Stud.IP-Entwicklerdoku JSON:API, Nachrichten](https://docs.gitlab.studip.de/entwicklung/jsonapi/messages/)
- [Stud.IP-Entwicklerdoku JSON:API, Nutzer](https://docs.gitlab.studip.de/entwicklung/jsonapi/users/)
- [Stud.IP-Hilfe „Nachrichten“](https://docs.studip.de/help/6/en/Basis/InteraktionNachrichten)

| Frage | Befund | Sicher? |
| --- | --- | --- |
| Schema | Typ `messages`. Attribute `subject`, `message`, `mkdate`, `priority`, `tags`. Beziehungen `sender` (ein Nutzer) und `recipients` (Nutzer). | Doku |
| Senden | `POST jsonapi.php/v1/messages`, `Content-Type: application/vnd.api+json`. Körper: `{"data":{"type":"messages","attributes":{"subject":…,"message":…,"priority":"normal"},"relationships":{"recipients":{"data":[{"type":"users","id":…}]}}}}`. Darf jeder Stud.IP-Nutzer. | Doku |
| Antwort von Stud.IP | Statuscodes stehen nicht in der Doku. Die App erwartet nach JSON:API **201** mit der neuen Nachricht (`data.id`). Jeder andere 2xx gilt auch als gesendet. | Annahme |
| Posteingang, Ausgang | `GET users/{id}/inbox` (Filter `filter[unread]`), `GET users/{id}/outbox`, nur für den Inhaber. | Doku |
| Einzelne Nachricht | `GET messages/{id}` (nur Inhaber), `DELETE messages/{id}`. Ob das Lesen in Stud.IP als gelesen markiert, steht nicht in der Doku. Die App ruft die Einzelansicht deshalb **nie** auf. | Doku / bewusst nicht genutzt |
| Antworten | In der API gibt es kein eigenes „Antworten“. Eine Antwort ist eine neue Nachricht an den Absender. Stud.IP selbst setzt im Browser „RE: “ vor den Betreff. Die App macht das auch, aber nicht doppelt (bei „RE:“, „Re:“, „AW:“ bleibt der Betreff). Stud.IP-eigene Merkmale wie „beantwortet“ setzt die API vermutlich nicht. | Annahme |
| Text | Ob `message` HTML erwartet oder Text, steht nicht in der Doku. Stud.IP speichert Texte aus dem Browser-Editor als HTML (mit Vorspann `<!--HTML-->`), ältere als Stud.IP-Formatierung. Die App sendet **reinen Text** mit Zeilenumbrüchen. So schlimmstenfalls wirken einzelne Stud.IP-Formatzeichen (`**fett**`, `%%kursiv%%`). Ein Zitat beginnt mit „Am … schrieb …:“, jede Zeile mit „> “. | **unbekannt** |
| Anhänge | Die API nennt keine Anhänge an Nachrichten. Die App sendet keine. | Doku |
| Empfänger | Die Liste des Posteingangs (`include=sender`) nennt den Absender mit `formatted-name`. Ob sie die Beziehung `recipients` mit Kennungen liefert, ist **unbekannt**. Fehlt sie, bietet die App nur „Antworten“ an. Namen weiterer Empfänger: `GET users/{id}` (zeigt nur sichtbare, nicht gesperrte Nutzer). `GET users` mit Suche ist nur für root erlaubt. Eine freie „Neue Nachricht“ mit Empfängersuche geht deshalb nicht und ist nicht gebaut. | Doku / unbekannt |
| Anmeldung | wie beim Abgeben: Sitzungs-Cookie. Die Doku zeigt nur Basic-Auth. | Doku |
| CSRF / Sicherheits-Token | Die Doku schweigt dazu. Die App sendet `X-Requested-With: XMLHttpRequest`. Ein 403 mit „CSRF“ oder „token“ meldet sie eigens und bietet „In Stud.IP antworten“ an. | **unbekannt** |
| Antworten im Browser | Ausweg `dispatch.php/messages/write?answer_to={id}` im angemeldeten In-App-Browser. Der Parameter `answer_to` ist aus der Stud.IP-Oberfläche bekannt, aber nicht dokumentiert. Kennt Stud.IP ihn nicht, öffnet sich ein leeres Schreibfenster. | Annahme |

## 2. Ablauf auf dem iPad

### 2.1 Woher die App die Empfänger kennt

Gespeichert werden weiterhin **keine Namen** (Regel 02.11.2026). Der Abgleich merkt sich je Nachricht nur die **Zahl** der
Empfänger, wenn Stud.IP die Beziehung `recipients` liefert. Das steht in einer eigenen Tabelle `studip_message_meta`, nur
auf dem Gerät und ohne Python-Entsprechung. `GET /api/studip/messages` nennt sie als `recipients` (Zahl oder `null`).

Erst beim Öffnen des Antwortfensters, also auf Knopfdruck, liest die App live aus Stud.IP:
1. `users/me` (eigene Kennung, wird nie angeschrieben),
2. den Posteingang `users/{me}/inbox?page[limit]=50&include=sender`, höchstens 3 Seiten, bis die Nachricht gefunden ist.
   Das ist dieselbe Liste wie beim Abgleich. Sie markiert nichts als gelesen.
3. Nur bei „Allen antworten“: `users/{id}` je weiterem Empfänger, höchstens 20.

Die Namen stehen nur im Fenster und werden nicht gespeichert. Systemnachrichten (Absender `____%system%____` oder ohne
Absender) lassen sich nicht beantworten. Bei ihnen fehlt der Knopf.

### 2.2 Leser

| Teil | Verhalten | Kennung |
| --- | --- | --- |
| Antworten | Primärknopf unter dem Text. Fehlt bei Systemnachrichten (Absender „Stud.IP“). | `messages.reply` |
| Allen antworten | nur wenn der Abgleich 2 bis 21 Empfänger kennt (also 1 bis 20 außer dir) | `messages.replyAll` |
| Beantwortet | „Beantwortet am 05.11.2026, 14:30“ als Abzeichen; darunter „Deine Antwort“ (aufklappbar, eigener Text) | `messages.replied`, `messages.ownReply` |
| Liste | Zeile einer beantworteten Nachricht: kleines Häkchen und „Beantwortet“ in der Bedienungshilfe | — |
| Hinweis | „… StudiNow markiert sie in Stud.IP nicht als gelesen. Antworten gehen über Stud.IP unter deinem Namen.“ | — |

Einen Ordner „Gesendet“ hat die Seite nicht (die Liste kennt nur den Posteingang). Die eigene Antwort steht beim
Original.

### 2.3 Antwortfenster (`MessageReplySheet`)

| Teil | Verhalten | Kennung |
| --- | --- | --- |
| An | Absender vorausgewählt (Name aus Stud.IP). Bei „Allen antworten“ zusätzlich die weiteren Empfänger. Gibt es weitere, wechselt ein Umschalter „Nur Absender / Alle (n)“. Bei mehr als 20 weiteren (Rundnachricht) steht „Rundnachricht an n Personen – die Antwort geht nur an den Absender“. | `reply.to`, `reply.mode` |
| Betreff | „RE: <Betreff>“, änderbar | `reply.subject` |
| Text | mehrzeilig, Pflicht | `reply.text` |
| Original zitieren | Schalter, Standard **aus**. An: das Zitat erscheint grau unter dem Text und wird angehängt. | `reply.quote` |
| Hinweis | „Wird über Stud.IP unter deinem Namen gesendet. Die Empfänger sehen deinen Namen.“ | `reply.notice` |
| Senden | erst aktiv mit Text und Empfänger | `reply.send` |
| Ergebnis | „Gesendet“ mit Empfängern und Zeitpunkt, Knopf „Fertig“ | `reply.sent` |

**Entwurf:** Betreff, Text, Zitat-Schalter und Modus landen bei jeder Änderung als Entwurf in den Einstellungen des
Containers (`uniflow.studip.replyDrafts`, je Nachricht, höchstens 50). Wird das Fenster versehentlich geschlossen
(Wischen, Abbrechen), ist der Text beim nächsten „Antworten“ wieder da: „Entwurf vom 05.11., 14:30 wiederhergestellt“.
Empfängernamen und Zitat stehen nicht im Entwurf. Nach dem Senden oder mit „Entwurf verwerfen“ wird er gelöscht.

**Verlauf:** `uniflow.studip.replies` (höchstens 300, neueste zuerst): Nachricht, Zeitpunkt, Betreff, eigener Text, mit
Zitat ja/nein, Zahl der Empfänger, Kennung der neuen Nachricht. Keine Namen. „Daten dieser Hochschule löschen“ entfernt
beides mit dem Container.

### 2.4 Anmeldung und Fehler

| Fall | Erkennung | Anzeige |
| --- | --- | --- |
| nicht verbunden | keine Stud.IP-Sitzung gespeichert | „Stud.IP ist nicht verbunden“ |
| abgelaufen | 401, Weiterleitung auf die Anmeldung, Anmeldeseite statt JSON | `ensureSession(.userAction)` still erneuern, dann **genau ein** neuer Versuch (Stud.IP hat bei 401 nichts angenommen); sonst „Bitte bei Stud.IP anmelden“ mit `StudIPLoginView`. Der Entwurf bleibt. |
| Sicherheits-Token | 403 mit „csrf/security token“ | „Stud.IP hat das Senden aus der App abgelehnt (Sicherheitsprüfung). Antworte bitte direkt in Stud.IP.“ und Knopf **„In Stud.IP antworten“** |
| verboten | anderer 403 | „Stud.IP hat das Senden abgelehnt (keine Berechtigung) …“ und „In Stud.IP antworten“ |
| abgelehnt | 400, 422 | „Stud.IP hat die Nachricht nicht angenommen (HTTP n) …“ und „In Stud.IP antworten“ |
| nicht gefunden | Nachricht nicht in den ersten 150 des Posteingangs | „Die Nachricht ist in Stud.IP nicht mehr im Posteingang …“ und „In Stud.IP antworten“ |
| Anderes | 5xx, 429, kein Netz | „Stud.IP antwortet mit HTTP n. Die Nachricht wurde vermutlich nicht gesendet …“ bzw. „Keine Verbindung …“; kein stilles Wiederholen (sonst käme sie doppelt an) |

„In Stud.IP antworten“ öffnet `dispatch.php/messages/write?answer_to={id}` über `openURL`. Damit landet die Seite im
angemeldeten In-App-Browser (`UniWebBrowser`).

## 3. Umsetzung

- **Kern** `UniFlowCore/StudIPMessageReply.swift`:
  - `StudIPMessageReply`: Regeln Betreff, Zitat, Körper, Fehlerzuordnung, Suche in der Liste, Links
  - `StudIPClient.replyContext(messageID:)`, `recipientNames(_:)`, `sendMessage(subject:text:recipientIDs:)`
  - `StudIPReplyDraft(s)`, `StudIPReplyRecord`, `StudIPReplyLog`
  - Abgleich: `StudIPExtras.parseMessageMeta`, Tabelle `studip_message_meta`, `recipients` in `messageList`
- **App:**
  - `Services/StudIPMessageSender.swift`: `MessageReplyModel` (Ablauf, Entwurf, Verlauf)
  - `Views/Messages/MessageReplySheet.swift`: Fenster
  - `MessagesPage`: Knöpfe, Abzeichen, eigene Antwort
  - `DebugStub/erststart/routes.json`: Posteingang mit zwei erfundenen Nachrichten und `POST messages`
- **Tests:**
  - Kern `StudIPMessageReplyTests`: Körper und Beziehungen, Kopfzeilen, Betreff, Zitat, Suche über Seiten, Systemnachricht, Fehler, kein zweites POST, Entwurf, Verlauf, Empfängerzahl
  - App `MessageReplyAppTests`: `URLProtocol`-Stub mit Cookie und Körper, Erneuerung mit genau einem zweiten Versuch, CSRF mit Ausweg, Entwurf über Schließen hinweg, Fenster über die Bedienungshilfe, Nachbildung `DebugStubTransport`

## 4. Einmal echt prüfen (Inhaber, mit eigenem Konto)

Am besten mit einer Nachricht, die du dir selbst schickst oder die ein Bekannter dir schickt:

1. Im Browser in Stud.IP eine Nachricht an dich selbst schicken (oder schicken lassen). In der App Stud.IP abgleichen
   (Nachrichten-Seite nach unten ziehen).
2. Die Nachricht öffnen, „Antworten“. Prüfen: Steht der richtige Absender unter „An“? Betreff „RE: …“?
3. Ein paar Zeilen schreiben, das Fenster wegwischen, wieder „Antworten“: Ist der Entwurf da?
4. „Original zitieren“ an, „Senden“. Erwartet: „Gesendet“, im Leser „Beantwortet am …“.
5. Im Browser in Stud.IP unter Nachrichten → Gesendet: Ist die Antwort da? Sehen Zeilenumbrüche und Zitat ordentlich aus?
   Werden Zeichen wie `**` umgedeutet?
6. Kommt statt „Gesendet“ die Meldung „Sicherheitsprüfung“: Stud.IP verlangt ein CSRF-Token (wie beim Abgeben,
   Folgeauftrag). „In Stud.IP antworten“ testen: Öffnet sich das Schreibfenster mit der Antwort?
7. Eine Nachricht an mehrere (z. B. aus einer kleinen Gruppe): Erscheint „Allen antworten“? Falls nie: Die Liste nennt
   keine Empfänger (dann bleibt es bei „Antworten“).

Bitte notieren: Status (201?), Darstellung des Texts (HTML oder Text), CSRF ja/nein, ob „Allen antworten“ erscheint.

## 5. Web und Windows

Lücke, nicht umgesetzt (wie beim Abgeben): Der Dienst ruft Stud.IP nie selbst auf, am PC liest der Abgleich nur. Dort
bleibt „In Stud.IP öffnen“.

## Echter Test (05.11.2026)

Der Inhaber hat auf seinem iPad mit seinem LUH-Konto eine Stud.IP-Nachricht aus der App beantwortet: „schreiben hat
geklappt sehr gut“. Damit ist belegt, dass die JSON:API der LUH schreibende Anfragen (`POST messages`) mit dem
Sitzungs-Cookie annimmt, ohne zusätzliches Sicherheits-Token. Dasselbe Muster nutzt „Abgeben in Stud.IP“
(`docs/ABGEBEN-STUDIP-2026-11-05.md`); dort steht der echte Test noch aus.
