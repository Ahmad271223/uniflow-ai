# KI über das ChatGPT-Abo der Nutzer („Sign in with ChatGPT“) – Plan, Stand 27.10.2026

Vorschlag des Inhabers vom 27.10.2026: Wer ein ChatGPT-Abo hat, verbindet es mit UniFlow. Lernpläne, Analysen der
Unterlagen und Fragen im Editor laufen dann über das ChatGPT des Nutzers; UniFlow zahlt keine KI-Kosten und braucht
keinen KI-Server. Dieses Dokument hält fest, was OpenAI dafür anbietet, wie es in UniFlow eingebaut würde, was der
Inhaber beantragen muss und was offen ist. **Gebaut ist davon noch nichts.**

Warum das die Entscheidung vom 25.10. ändern kann: KI entfiel in V1, weil sie „ohne PC einen kostenpflichtigen Dienst
und einen kleinen eigenen Server“ gebraucht hätte und „der Schlüssel nicht in die App“ darf
(`docs/AUFTRAG-APPSTORE-V1.md`, Abschnitt 6). Mit dem ChatGPT-Abo fallen beide Gründe weg: Die Anfragen bezahlt das
Abo des Nutzers, und in der App liegt kein UniFlow-Schlüssel, sondern nur das Token, das der Nutzer selbst erteilt hat.
Die Entscheidung „KI entfällt in V1“ bleibt bestehen, bis der Inhaber sie ändert; dieser Plan setzt **nach dem
App-Store-Start** an (V1.1), damit V1 nicht wartet.

## 1. Was OpenAI anbietet (Stand der Doku, 27.10.2026)

- **Anmeldung:** OAuth 2.0 Authorization Code mit PKCE und OpenID Connect. Herausgeber `https://auth.openai.com`,
  Endpunkte über `https://auth.openai.com/.well-known/openid-configuration` (Autorisierung
  `/api/accounts/authorize`, Token `/api/accounts/oauth/token`, Schlüssel `/.well-known/jwks.json`). Öffentliche Clients
  (ohne Geheimnis, wie eine iPad-App) und vertrauliche Clients sind vorgesehen. Client-IDs beginnen mit `oaiapp_`.
- **Berechtigungen (Scopes):** `openid`, `profile`, `email` für die Identität; `offline_access` für ein Refresh-Token;
  `resource.invoke` mit `chatgpt.tokens.use.direct` für Anfragen über das Abo. Die Identität allein erlaubt keine
  KI-Anfragen; der Nutzer muss die Nutzung seines Abos ausdrücklich erlauben.
- **Anfragen:** an die öffentliche Responses API (`resource` = `https://api.openai.com/v1`) mit dem Zugriffstoken des
  Nutzers. Welche Modelle verfügbar sind, liefert die Verbindung selbst (Modellliste, Auswahl per `slug`).
- **Was UniFlow erfährt:** nur stabile Kennung, Name, E-Mail und Profilbild; **kein** Zugriff auf die ChatGPT-Chats.
- **Limits:** Die Nutzung zählt gegen die normalen Limits des Abos. Der Nutzer kann je App ein Wochenlimit setzen;
  danach stoppt die Nutzung, es wird nichts nachberechnet. Apps sollen bei einem Limit als wichtigste Aktion „Nutzung
  verwalten“ anbieten (öffnet ChatGPT → Einstellungen → Nutzung).
- **Wer mitmachen darf:** Open-Source-Projekte und private Projekte, die lokal laufen, sofort (ohne Antrag, die
  Client-ID wird beim ersten Anmelden erzeugt). **Kostenpflichtige oder gehostete Apps nur nach Aufnahme über die
  Warteliste**; die Anmeldung allein läuft als begrenzter Versuch mit ausgewählten kommerziellen Partnern.
  **UniFlow ist eine kostenpflichtige App-Store-App und braucht deshalb die Aufnahme.**
- **Abos:** Plus und Pro; laut einem Bericht inzwischen auch Go. Mit dem kostenlosen ChatGPT geht es nicht.

Quellen: [Quickstart](https://developers.openai.com/siwc/quickstart),
[Website-Anbindung](https://developers.openai.com/siwc/website),
[Open-Source-Clients (Cookbook)](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt),
[Client-ID beantragen](https://developers.openai.com/siwc/request-client-id),
[Hilfe: ChatGPT-Abo in anderen Apps](https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites).
Nicht dokumentiert (beim Antrag fragen, Abschnitt 6): Rückleitung für native iPad-/Mac-Apps, genaue Fehlercodes,
Laufzeit der Tokens, Verfügbarkeit in der EU.

## 2. Was die KI in UniFlow tun soll

Die Funktionen gibt es am PC schon (`app/ai.py`, heute über `claude -p`); sie werden für ChatGPT übernommen, nicht neu
erfunden. Jede KI-Funktion ist **ein Zusatz**: Ohne ChatGPT läuft UniFlow genauso wie heute.

| Funktion | Wo | Was an ChatGPT geht | Ergebnis |
|---|---|---|---|
| **Fragen im Editor** | Editor, Seitenleiste „KI“ | markierter Text, Seitentext (bis 9 000 Zeichen), eigene Frage oder Lösung; Kurs und Dateiname | Antwort als Text; Modi wie `ai.TUTOR_MODES`: erklären, einfach erklären, Zusammenfassung, Schritt für Schritt, nur Hinweise, Lösung prüfen, ähnliche Aufgabe, Fachbegriffe, Karteikarten (diese als Entwurf in „Karteikarten“) |
| **Analyse der Unterlagen** | Dokumente, Modul | Dateiname, Kurs, erste Seiten als Text (oder als PDF-Seiten, wenn der Text dünn ist) | Art (Vorlesung, Übung, …), Titel, Lehrwoche, Themen, Schwierigkeit, geschätzte Lernzeit (Felder wie `ai.analyze_file`); überschreibt nie die feste Einordnung aus Ordner und Dateiname (`study.effective_type`), nur Lücken |
| **Lernpläne** | Lernkalender | Liste der offenen Unterlagen mit Analyse, Prüfungstermine, freie Zeitfenster, Einstellungen | **Vorschlag**, den der Nutzer übernimmt oder verwirft; der feste Planer (Free) bleibt die Grundlage. Ergebnis nach JSON-Schema, wird gegen Kalender und Zeitfenster geprüft, nie still übernommen |
| **Wochentests** | Modul, Lernkalender | Unterlagen der Lehrwoche (Text) | Test mit 8 bzw. 12 Fragen und Bewertung der Antworten (wie `ai.generate_test`/`grade_test`) |
| **Abgaben erkennen** (später) | Übersicht | Text von Übungsblättern und Ankündigungen | ergänzt die regelbasierte Erkennung der Mac-Sitzung, nur bei Unsicherheit |

Regeln für alle Funktionen:

- Gesendet wird **nur nach einer Handlung des Nutzers** (Tippen auf „Fragen“, „Analysieren“, „Plan vorschlagen“) und
  nur das Nötige: Text der Seite oder Auswahl, keine ganzen Ordner, keine Zugangsdaten, keine Hochschul-Cookies, keine
  Notizen anderer Nutzer. Was gesendet wird, steht vor dem ersten Senden je Funktion in einem Hinweis.
- Antworten mit fester Form (Analyse, Plan, Test, Karteikarten) kommen als JSON nach einem gemeinsamen Schema und
  werden geprüft; was nicht passt, wird verworfen und als Fehler gezeigt, nie halb übernommen.
- Der Dienst von UniFlow sieht weder Anfragen noch Antworten (Abschnitt 3). Antworten bleiben auf dem Gerät.

## 3. Aufbau

**Anfragen gehen direkt vom Gerät an OpenAI.** Das passt zu den bestehenden Regeln (iPad ohne PC, Dienst speichert
keine Hochschuldateien) und braucht keinen Server. Das Token liegt nur auf dem Gerät (iPad/Mac: Schlüsselbund,
Windows: Windows-Anmeldeinformationen bzw. verschlüsselt im App-Ordner), nie beim Dienst, nie im Abgleich G2.

- **Gemeinsamer Vertrag** `packages/shared-contracts/ai/`: Prompts, Modi und JSON-Schemas als Dateien, dazu Fixtures
  (Eingabe → erwartete Form der Antwort, Prüfung der Antwort, Fehlerfälle). Python, Swift und der Web-Editor lesen
  dieselben Texte, damit alle Plattformen gleich antworten. Erzeugt aus `app/ai.py`, wie die anderen Fixtures.
- **Python** (`app/ai.py`, liefert Windows-App und Web am PC): Auswahl des Anbieters hinter einer Funktion `ask` –
  `claude` (heute, `claude -p`) oder `chatgpt` (Token des Nutzers, Responses API über `urllib`). Die vier Pfade, die im
  Dienst heute 501 melden (`/api/ai/tutor`, `/api/files/{id}/analyze`, `/api/tests/generate`,
  `/api/tests/generate-week`), bleiben im gehosteten Modus aus: dort liefe die Anfrage über den Server, das widerspricht
  „Dienst sieht nichts“.
- **Windows-App** (Tauri mit mitgeliefertem Python): Anmeldung im Systembrowser mit Rückleitung auf `127.0.0.1`
  (wie im Cookbook beschrieben), Token im Backend des Geräts.
- **iPad/Mac** (Swift-Kern): Anmeldung mit `ASWebAuthenticationSession`, PKCE, Rückleitung auf ein eigenes Schema oder
  einen Universal Link (bei OpenAI zu klären), Token im Schlüsselbund, Anfragen mit `URLSession`; ein
  `AIService`-Protokoll im Kern, damit später andere Anbieter dahinter passen.
- **Fehler und Grenzen:** Abo erlaubt keine Nutzung → „In ChatGPT freigeben“; Limit erreicht → „Nutzung verwalten“ als
  Hauptknopf, KI-Knöpfe bis zum nächsten Versuch grau; Token abgelaufen → einmal still erneuern, sonst „ChatGPT neu
  verbinden“; kein Netz → KI-Knöpfe aus, Rest der App unverändert.
- **Einstellungen → KI:** „ChatGPT verbinden“ / „Trennen“, verbundenes Konto (Name, E-Mail), Modellwahl aus der Liste
  der Verbindung, Schalter je Funktion, Link „Nutzung verwalten“.

## 4. Was der Inhaber bei OpenAI beantragen muss

1. **OpenAI-Konto** für UniFlow anlegen (Organisation auf den Namen des Inhabers), Kontakt-E-Mail festlegen.
2. **Interessenformular** ausfüllen: <https://openai.com/form/sign-in-with-chatgpt-interest/>. Ziel: Aufnahme als
   kommerzielle App **mit Nutzung des ChatGPT-Abos** (`chatgpt.tokens.use.direct`), nicht nur Anmeldung.
3. Bereithalten, was dort oder im Gespräch mit OpenAI gefragt wird:

| Angabe | Für UniFlow |
|---|---|
| App, Anbieter | UniFlow, Lern-App für Studierende (LUH Hannover, Uni Hildesheim); Anbieter = Inhaber, Impressum aus `docs/release/` |
| Plattformen | iPadOS/macOS (App Store, nativ), Windows (Desktop-App); später Web |
| Kostenpflichtig? | ja: Free und Plus (1,99 €/Monat, App-Store-Abo). KI selbst wird nicht verkauft, der Nutzer bringt sein Abo mit |
| Wofür die KI | Fragen zu Vorlesungsfolien und Übungsblättern im Editor, Einordnung der Unterlagen, Lernplan-Vorschläge, Wochentests (Abschnitt 2) |
| Benötigte Scopes | `openid profile email offline_access`, `resource.invoke` mit `chatgpt.tokens.use.direct` |
| Client-Art | öffentlicher Client mit PKCE auf dem Gerät (iPad/Mac, Windows); kein UniFlow-Server in der Anfragekette |
| Rückleitungen | iPad/Mac: eigenes Schema `de.uniflow.ai:/oauth/chatgpt` oder Universal Link `https://<Domain>/oauth/chatgpt` (je nachdem, was OpenAI für native Apps erlaubt); Windows: `http://127.0.0.1:<Port>/callback` |
| Daten | gesendet werden nur Text der Seite/Auswahl und Kursnamen, nach Handlung des Nutzers; UniFlow speichert keine Anfragen oder Antworten auf einem Server; Token nur auf dem Gerät |
| Datenschutzerklärung | URL der veröffentlichten Erklärung (Entwurf `docs/release/DATENSCHUTZ.md`, um Abschnitt „KI über ChatGPT“ ergänzen) |
| Erwartete Nutzerzahl | Schätzung des Inhabers (erstes Semester: Studierende an LUH und Hildesheim) |

4. Nach der Aufnahme: Client-ID (`oaiapp_…`) und registrierte Rückleitungen in die Konfiguration eintragen
   (`apps/apple/Config/`, Windows-Konfiguration); **kein Geheimnis in die App** (öffentlicher Client).

Bis zur Aufnahme darf der Inhaber die Anbindung **für sich selbst** am eigenen PC nutzen: private, lokal laufende
Projekte sind ohne Antrag zugelassen. Damit lässt sich Phase 1 testen, ohne dass andere Nutzer sie bekommen.

## 5. Apple, Datenschutz, Recht

- **Apple-Regel 5.1.2:** Weitergabe persönlicher Daten an fremde KI nur nach klarem Hinweis und ausdrücklicher
  Zustimmung. Umsetzung: Zustimmungsdialog beim Verbinden („Seitentext und Fragen gehen an OpenAI, UniFlow speichert
  sie nicht“), einzeln abschaltbar je Funktion, App-Datenschutzangaben in App Store Connect und Privacy Manifest
  ergänzen (Datenkategorien „Andere Nutzerinhalte“, Weitergabe an Dritte).
- **Anmeldung:** ChatGPT wird nur **verbunden**, nicht zur Anmeldung in UniFlow benutzt. Die UniFlow-Anmeldung bleibt
  „Mit Apple anmelden“; damit greift die Regel für fremde Anmeldedienste nicht.
- **Käufe:** UniFlow verkauft keine KI. Das ChatGPT-Abo kauft der Nutzer bei OpenAI; die App wirbt nicht mit Preisen
  von OpenAI und verlinkt keinen Kauf. Ob KI zu Free oder nur zu Plus gehört, entscheidet der Inhaber (Abschnitt 7).
- **Datenschutzerklärung:** Abschnitt „KI über ChatGPT“: Empfänger OpenAI, Zweck, welche Daten, Rechtsgrundlage
  Einwilligung, Widerruf durch Trennen, Verweis auf OpenAIs Datenschutz; Datenübermittlung in die USA.
- **Unterlagen der Hochschule:** Der Nutzer schickt Ausschnitte seiner eigenen Kursunterlagen an seine eigene KI –
  wie beim Kopieren in ChatGPT von Hand. UniFlow schickt nie ganze Dateien unaufgefordert und teilt nichts mit anderen.
  Prüfen lassen, ob die Hochschulen das in ihren Nutzungsbedingungen anders sehen.

## 6. Fragen an OpenAI (mit dem Antrag stellen)

1. Ist Abo-Nutzung (`chatgpt.tokens.use.direct`) für eine kostenpflichtige App-Store-App erlaubt, wenn die KI nicht
   verkauft wird?
2. Welche Rückleitungen sind für native iPad-/Mac-Apps erlaubt (eigenes Schema, Universal Link)? Öffentlicher Client
   ohne Geheimnis auf dem Gerät zulässig?
3. Fehlercodes für „Nutzung nicht freigegeben“, „Limit erreicht“, „neu anmelden“; Laufzeit von Zugriffs- und
   Refresh-Token.
4. Welche Modelle stehen über das Abo zur Verfügung, mit PDF-Eingabe?
5. Verfügbar für Nutzer in Deutschland und der EU? Welche Abos (Plus, Pro, Go)?
6. Dürfen Ausschnitte aus Kursunterlagen gesendet werden; gelten für diese Anfragen dieselben Regeln zur Nutzung für
   Training wie in ChatGPT selbst (Einstellung des Nutzers)?

## 7. Entscheidungen des Inhabers

| Thema | Vorschlag |
|---|---|
| Zeitpunkt | nach dem App-Store-Start (V1.1); V1 bleibt ohne KI |
| Free oder Plus | KI für alle mit ChatGPT-Abo, auch Free (der Nutzer zahlt die KI selbst; Plus bleibt Stift und Community) |
| Ohne ChatGPT-Abo | keine KI; später optional eigener API-Schlüssel des Nutzers oder ein anderer Anbieter hinter derselben Schnittstelle |
| Claude am PC | bleibt als zweiter Anbieter am eigenen PC (`claude -p`); Auswahl in Einstellungen → KI |

## 8. Phasen

| Phase | Inhalt | Wer | Fertig, wenn |
|---|---|---|---|
| 0 | OpenAI-Konto, Interessenformular, Fragen aus Abschnitt 6 | Inhaber | Antwort von OpenAI liegt vor |
| 1 | Vertrag `shared-contracts/ai` (Prompts, Schemas, Fixtures) aus `app/ai.py`; Anbieter `chatgpt` in Python mit Anmeldung über `127.0.0.1`; Fragen im Editor und Analyse am eigenen PC | PC-Sitzung | Tests gegen die Fixtures grün, Inhaber hat am eigenen PC mit seinem Abo gefragt (privates Projekt, ohne Antrag) |
| 2 | Windows-App: „ChatGPT verbinden“, Token sicher auf dem Gerät, alle vier Funktionen, Fehlerfälle | PC-Sitzung | Gerätetest auf einem Windows-Laptop; Client-ID aus Phase 0 nötig für andere Nutzer |
| 3 | iPad/Mac: `AIService` im Kern, `ASWebAuthenticationSession`, Schlüsselbund, Editor-Seitenleiste, Analyse, Plan-Vorschlag, Zustimmungsdialog | Mac-Sitzung | Tests gegen dieselben Fixtures grün, Gerätetest mit Abo |
| 4 | Datenschutzerklärung, App-Datenschutzangaben, Privacy Manifest, App-Prüfung | Inhaber + PC-Sitzung | Update im App Store |

Kosten für UniFlow: keine laufenden KI-Kosten, kein zusätzlicher Server. Aufwand liegt in Phase 1–3.
