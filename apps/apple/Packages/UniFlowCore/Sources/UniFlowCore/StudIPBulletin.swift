import Foundation

// Schwarzes Brett aus Stud.IP (Auftrag des Inhabers 03.11.2026: "Schwarzes Brett mit einbinden, wenn eine Uni das hat").
// Die LUH betreibt das Plugin "SchwarzesBrettPlugin" (Kleinanzeigen in Themen wie Biete, Suche, Jobs an der Uni ...).
// Die JSON:API kennt das Brett nicht; das Plugin liefert aber je Thema einen RSS-Feed
// (plugins.php/schwarzesbrettplugin/rss/{thema}/{anzahl}) und die Themenliste als Seite (.../category/list).
// Beides verlangt an der LUH die angemeldete Sitzung (ohne Cookie: Umleitung auf dispatch.php/login, geprueft
// 03.11.2026), darum laeuft der Abruf ueber den `StudIPClient` mit dem Sitzungs-Cookie, nur GET, mit denselben Pausen.
//
// Gespeichert werden je Thema die neuesten `perTopic` Anzeigen: Titel, ganzer Text (Absaetze bleiben; `maxText` ist nur eine Notbremse), Link,
// Zeitpunkt. Der Feed nennt keine Autoren, die App speichert keine (nie Personennamen). Nur auf diesem Geraet, nicht
// im Geraete-Abgleich, nicht in der Community, keine Quelle der KI.
//
// Hochschulen: `UniversityProfile.hasBulletinBoard` sagt, ob das Brett erwartet wird (LUH ja, Hildesheim nein). Dazu
// die Laufzeit-Erkennung wie bei den uebrigen Ergaenzungen: fehlt das Plugin (404/403 oder keine Themenliste), merkt
// sich das die App unter `studip_missing_endpoints` ("bulletin") und fragt erst nach `StudIPExtras.retryDays` wieder;
// eine Hochschule ohne Plugin kostet so eine Anfrage je 30 Tage. Mit Plugin: hoechstens alle `minHours` Stunden, dann
// eine Anfrage fuer die Themen und eine je Thema.
//
// Keine Python-Entsprechung: der PC-Server liest Stud.IP nur ueber die JSON:API (app/studip_extras.py), das Brett gibt
// es dort nicht (docs/IPAD-STUDIP-SYNC.md, Abschnitt 11).

public enum StudIPBulletin {
    public static let perTopic = 20
    /// nur Notbremse: der RSS-Text ist die ganze Anzeige und bleibt ganz (Inhaber 03.11.2026: "ganze Nachricht, nie '…'")
    public static let maxText = 50000
    /// Name in `studip_missing_endpoints`
    public static let missingName = "bulletin"
    /// zwischen zwei Abrufen mindestens so viele Stunden (Kleinanzeigen aendern sich langsam)
    public static let minHours = 6
    /// "neu" fuer die Uebersicht: so viele Tage zurueck
    public static let newDays = 7
    static let plugin = "plugins.php/schwarzesbrettplugin"
    static let topicsKey = "studip_bulletin_topics"
    static let fetchedKey = "studip_bulletin_fetched_at"
    /// Kennzeichen der Themenliste in der Seite des Plugins (views/category/list.php: `<ul class="sb-categories">`)
    static let topicsMarker = "sb-categories"

    static let table = """
        CREATE TABLE IF NOT EXISTS studip_bulletin (
            id TEXT PRIMARY KEY,
            topic TEXT NOT NULL,               -- Thema (Titel in Stud.IP)
            title TEXT NOT NULL,
            text TEXT NOT NULL,                -- ganzer Text ohne Formatierung (Absaetze bleiben)
            url TEXT,                          -- Anzeige in Stud.IP
            posted_at TEXT,                    -- YYYY-MM-DDTHH:MM:SS, Ortszeit
            fetched_at TEXT
        )
        """

    /// Thema des Bretts, wie die Themenliste es nennt
    public struct Topic: Sendable, Equatable {
        public let id: String
        public let title: String
        /// Anzahl laut Stud.IP (alle Anzeigen des Themas)
        public let count: Int

        public init(id: String, title: String, count: Int) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    /// Eine Anzeige
    public struct Entry: Sendable, Equatable {
        public let id, topic, title, text, url, postedAt: String

        public init(id: String, topic: String, title: String, text: String, url: String, postedAt: String) {
            self.id = id
            self.topic = topic
            self.title = title
            self.text = text
            self.url = url
            self.postedAt = postedAt
        }

        public var json: JSONValue {
            ["id": .string(id), "topic": .string(topic), "title": .string(title), "text": .string(text),
             "url": url.isEmpty ? .null : .string(url), "posted_at": postedAt.isEmpty ? .null : .string(postedAt)]
        }
    }

    // MARK: Adressen

    static func listPath() -> String { plugin + "/category/list" }
    static func feedPath(_ topicID: String) -> String { plugin + "/rss/\(topicID)/\(perTopic)" }

    /// Startseite des Bretts in Stud.IP (Leser, Karte)
    public static func boardURL(base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return b + "/" + listPath()
    }

    // MARK: Lesen der Themenliste (HTML)

    private static let topicHref = PyRegex(#"/category/(?:view/)?([0-9a-f]{32})(?:[/?#]|$)"#)
    /// erste "(N)" im Linktext; danach kann ein Hinweistext des Themas folgen ("Umfragen (5) Umfragen und Befragungen",
    /// an der LUH 03.11.2026), der nicht zum Titel gehoert
    private static let topicCount = PyRegex(#"\(([\d.  ]+)\)"#)
    private static let anySpace = PyRegex(#"\s+"#)

    /// Themen aus der Seite `category/list`: Links `<a href=".../category/view/{id}" class="category ...">Titel (Anzahl)</a>`
    /// innerhalb `<ul class="sb-categories">`. Ohne diese Liste leer (Plugin fehlt oder andere Fassung).
    public static func parseTopics(html: String) -> [Topic] {
        var out: [Topic] = []
        var seen = Set<String>()
        var inList = false
        var depth = 0
        var current: (id: String, parts: [String])?
        for t in HTMLTokenizer.tokens(html) {
            switch t {
            case .start(let name, let attrs):
                if name == "ul" {
                    if inList { depth += 1 } else if (attrs["class"] ?? "").split(separator: " ").contains(Substring(topicsMarker)) { inList = true; depth = 0 }
                } else if inList, name == "a", current == nil, let href = attrs["href"], let m = topicHref.regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
                          let r = Range(m.range(at: 1), in: href) {
                    current = (String(href[r]), [])
                }
            case .text(let s):
                current?.parts.append(s)
            case .end(let name):
                if name == "ul", inList {
                    if depth == 0 { inList = false } else { depth -= 1 }
                } else if name == "a", let c = current {
                    current = nil
                    var title = PyText.strip(anySpace.sub(c.parts.joined(), " "))
                    var count = 0
                    if let m = topicCount.regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let r = Range(m.range(at: 1), in: title),
                       let whole = Range(m.range, in: title) {
                        count = Int(title[r].filter(\.isNumber)) ?? 0
                        title = PyText.strip(String(title[..<whole.lowerBound]))
                    }
                    if !title.isEmpty, !seen.contains(c.id) {
                        seen.insert(c.id)
                        out.append(Topic(id: c.id, title: title, count: count))
                    }
                }
            case .raw:
                break
            }
        }
        return out
    }

    // MARK: Lesen eines Feeds (RSS 2.0 des Plugins, views/rss/index.php)

    private static let itemRE = PyRegex(#"(?s)<item\b[^>]*>(.*?)</item>"#)
    private static let cdataRE = PyRegex(#"(?s)^\s*<!\[CDATA\[(.*?)\]\]>\s*$"#)

    private static func field(_ item: String, _ name: String) -> String? {
        let re = try? NSRegularExpression(pattern: "(?s)<\(name)\\b[^>]*>(.*?)</\(name)>")
        guard let m = re?.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)), let r = Range(m.range(at: 1), in: item) else { return nil }
        let raw = String(item[r])
        if let c = cdataRE.regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let cr = Range(c.range(at: 1), in: raw) {
            return String(raw[cr])
        }
        return QISParser.decodeEntities(raw)
    }

    /// `pubDate` (RFC 2822, "Mon, 02 Nov 2026 10:15:00 +0100") -> Ortszeit Berlin "YYYY-MM-DDTHH:MM:SS"; nil, wenn unlesbar
    static func localTime(rfc2822 s: String) -> String? {
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        var parts = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        if let first = parts.first, Int(first) == nil { parts.removeFirst() }           // Wochentag
        guard parts.count >= 4, let day = Int(parts[0]), let month = months[PyText.lower(PyText.slice(parts[1], 0, 3))],
              var year = Int(parts[2]), (1...31).contains(day) else { return nil }
        if year < 100 { year += year < 50 ? 2000 : 1900 }
        let hms = parts[3].split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(hms.count), (0...23).contains(hms[0]), (0...59).contains(hms[1]) else { return nil }
        let seconds = hms[0] * 3600 + hms[1] * 60 + (hms.count == 3 ? min(59, hms[2]) : 0)
        var offset = 0
        if parts.count >= 5 {
            let z = parts[4]
            if let sign = z.first, sign == "+" || sign == "-", z.count == 5, let hh = Int(PyText.slice(z, 1, 3)), let mm = Int(PyText.slice(z, 3, 5)) {
                offset = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
            }
            // GMT, UT, UTC, Z und Zonennamen: 0
        }
        let utc = BerlinClock.dayNumber(year: year, month: month, day: day) * 86400 + seconds - offset
        return BerlinClock.localISO(utc: utc)
    }

    /// Anzeigen eines Feeds (Thema `topic`): title, link, description (HTML in CDATA), pubDate, guid. Ohne Titel keine
    /// Anzeige; der Text ist der ganze Text der Anzeige als reiner Text mit Absaetzen, nie gekuerzt ("…").
    public static func parseFeed(xml: String, topic: String) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<String>()
        for m in itemRE.regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let item = String(xml[r])
            let title = PyText.strip(anySpace.sub(QISParser.decodeEntities(field(item, "title") ?? ""), " "))
            guard !title.isEmpty else { continue }
            let link = PyText.strip(field(item, "link") ?? "")
            var guid = PyText.strip(field(item, "guid") ?? "")
            if guid.isEmpty { guid = link.split(separator: "/").last.map(String.init) ?? "" }
            guard !guid.isEmpty, !seen.contains(guid) else { continue }
            seen.insert(guid)
            let body = Announcements.htmlToText(field(item, "description") ?? "")
            let text = StudIPTexts.full(body, maxText)
            let url = link.hasPrefix("https://") || link.hasPrefix("http://") ? link : ""
            out.append(Entry(id: "sb-" + guid, topic: topic, title: PyText.slice(title, 0, Announcements.maxTitle), text: text, url: url,
                             postedAt: localTime(rfc2822: field(item, "pubDate") ?? "") ?? ""))
            if out.count >= perTopic { break }
        }
        return out
    }

    // MARK: Abruf (Geraet)

    public struct Download: Sendable {
        public var topics: [Topic] = []
        /// nil = nicht gelesen (uebersprungen, fehlt, Fehler); der Bestand bleibt
        public var entries: [Entry]?
        public var missing: [String: JSONValue] = [:]
        public var sessionExpired = false
        /// nicht gefragt (zu frueh, als fehlend gemerkt)
        public var skipped = false
        /// Themenliste da, aber kein RSS (in Stud.IP abgeschaltet): nichts gespeichert
        public var feedUnavailable = false
        public init() {}
    }

    static func isFeed(_ r: HTTPReply) -> Bool {
        let ct = r.contentType.lowercased()
        if ct.contains("xml") { return true }
        let head = String(decoding: r.body.prefix(600), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<?xml")
    }

    /// Themen und je Thema die neuesten Anzeigen. Wirft nie: abgelaufene Sitzung steht im Ergebnis, Fehler lassen den
    /// Bestand. `missing`: gespeicherte Liste fehlender Endpunkte; `lastFetchedAt`: letzter Abruf (settings).
    public static func fetch(client: StudIPClient, missing: [String: JSONValue], lastFetchedAt: String?, clock: UniFlowClock) async -> Download {
        var d = Download()
        d.missing = missing
        let today = clock.today
        guard StudIPExtras.shouldAsk(missing, missingName, today: today) else { d.skipped = true; return d }
        if let last = lastFetchedAt, let lastUTC = BerlinClock.utcSeconds(localISO: last), clock.utcSeconds - lastUTC < minHours * 3600 {
            d.skipped = true
            return d
        }
        let page: HTTPReply
        do {
            page = try await client.htmlPage(listPath())
        } catch StudIPError.sessionExpired {
            d.sessionExpired = true
            return d
        } catch {
            return d
        }
        let html = String(decoding: page.body, as: UTF8.self)
        let topics = (200..<300).contains(page.status) && html.contains(topicsMarker) ? parseTopics(html: html) : []
        guard !topics.isEmpty else {
            // kein Plugin (404, 403, Fehlerseite) oder eine Fassung ohne Themenliste: 30 Tage nicht wieder fragen
            d.missing = StudIPExtras.remember(missing, missingName, status: 404, today: today)
            return d
        }
        d.missing = StudIPExtras.remember(missing, missingName, status: 200, today: today)
        d.topics = topics
        var entries: [Entry] = []
        for t in topics {
            let r: HTTPReply
            do {
                r = try await client.htmlPage(feedPath(t.id))
            } catch StudIPError.sessionExpired {
                d.sessionExpired = true
                return d
            } catch {
                return d                                        // Netz weg: Bestand bleibt
            }
            guard (200..<300).contains(r.status), isFeed(r) else {
                if r.contentType.lowercased().contains("text/html") { d.feedUnavailable = true; return d }   // RSS abgeschaltet
                continue                                        // ein Thema ohne Feed: die anderen weiter
            }
            entries += parseFeed(xml: String(decoding: r.body, as: UTF8.self), topic: t.title)
        }
        d.entries = entries
        return d
    }

    // MARK: Speicher

    static func has(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_bulletin'") != nil
    }

    static func setting(_ c: SQLiteConnection, _ key: String) throws -> String? {
        try c.scalar("SELECT value FROM settings WHERE key=?", [.text(key)])?.string
    }

    static func setSetting(_ c: SQLiteConnection, _ key: String, _ value: String) throws {
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    /// Zeitpunkt des letzten Abrufs (settings) fuer `fetch`
    public static func lastFetchedAt(_ c: SQLiteConnection) throws -> String? { try setting(c, fetchedKey) }

    /// Schreibt den Abruf (in einer Transaktion aufrufen): Anzeigen ersetzen (in Stud.IP Verschwundenes faellt weg),
    /// Themen in der Reihenfolge von Stud.IP, Zeitpunkt, fehlende Endpunkte
    public static func store(_ d: Download, in c: SQLiteConnection, clock: UniFlowClock) throws {
        try StudIPExtras.saveMissing(c, d.missing)
        guard let entries = d.entries else { return }
        let now = clock.nowISO
        try c.executeScript(table)
        try c.execute("DELETE FROM studip_bulletin WHERE id NOT IN (\(StudIPExtras.marks(entries.count)))", entries.map { .text($0.id) })
        for e in entries {
            try c.execute("""
                INSERT OR REPLACE INTO studip_bulletin(id, topic, title, text, url, posted_at, fetched_at) VALUES (?,?,?,?,?,?,?)
                """, [.text(e.id), .text(e.topic), .text(e.title), .text(e.text), .text(e.url), .text(e.postedAt), .text(now)])
        }
        let topics: JSONValue = .array(d.topics.map { ["id": .string($0.id), "title": .string($0.title), "total": .number(Double($0.count))] })
        try setSetting(c, topicsKey, topics.jsonString())
        try setSetting(c, fetchedKey, now)
    }

    // MARK: Lesen: Karte und Leser

    /// Erwartet die Hochschule der Datenbank ein Schwarzes Brett?
    public static func expected(_ c: SQLiteConnection) throws -> Bool {
        UniversityProfile.profile(forKey: try setting(c, "university") ?? Migrations.defaultUniversity)?.hasBulletinBoard ?? false
    }

    /// `GET /api/studip/bulletin?topic=`: {available, topics: [{title, count, total}], entries: [...], new_count, fetched_at, url}.
    /// `count` = gespeicherte Anzeigen des Themas (hoechstens `perTopic`), `total` = Anzahl laut Stud.IP. Neueste zuerst.
    public static func overview(_ c: SQLiteConnection, topic: String?, today: Int) throws -> JSONValue {
        let expected = try expected(c)
        let base = UniversityProfile.profile(forKey: try setting(c, "university") ?? Migrations.defaultUniversity)?.studipBase?.absoluteString
        var out: [String: JSONValue] = ["available": .bool(expected), "topics": .array([]), "entries": .array([]), "new_count": .number(0),
                                        "fetched_at": .null, "url": base.map { .string(boardURL(base: $0)) } ?? .null]
        guard expected, try has(c) else { return .object(out) }
        let rows = try c.rows("SELECT id, topic, title, text, url, posted_at FROM studip_bulletin ORDER BY posted_at DESC, id")
        var counts: [String: Int] = [:]
        for r in rows { counts[r["topic"]?.string ?? "", default: 0] += 1 }
        var order: [JSONValue] = []
        var named = Set<String>()
        for t in (try setting(c, topicsKey)).flatMap({ try? JSONValue.parse(Data($0.utf8)) })?.array ?? [] {
            guard let title = t["title"]?.string, let n = counts[title], n > 0 else { continue }
            named.insert(title)
            order.append(["title": .string(title), "count": .number(Double(n)), "total": t["total"] ?? .number(Double(n))])
        }
        for (title, n) in counts.sorted(by: { PyText.less($0.key, $1.key) }) where !named.contains(title) {
            order.append(["title": .string(title), "count": .number(Double(n)), "total": .number(Double(n))])
        }
        let since = BerlinClock.isoDate(today - newDays)
        let wanted = (topic ?? "").isEmpty ? nil : topic
        var entries: [JSONValue] = []
        var fresh = 0
        for r in rows {
            let posted = r["posted_at"]?.string ?? ""
            if !PyText.less(PyText.slice(posted, 0, 10), since), !posted.isEmpty { fresh += 1 }
            if let wanted, r["topic"]?.string != wanted { continue }
            entries.append(["id": r["id"] ?? .null, "topic": r["topic"] ?? .null, "title": r["title"] ?? .null, "text": r["text"] ?? .null,
                            "url": (r["url"]?.string ?? "").isEmpty ? .null : r["url"]!, "posted_at": posted.isEmpty ? .null : .string(posted)])
        }
        out["topics"] = .array(order)
        out["entries"] = .array(entries)
        out["new_count"] = .number(Double(fresh))
        out["fetched_at"] = (try setting(c, fetchedKey)).map(JSONValue.string) ?? .null
        return .object(out)
    }

    /// `GET /api/studip/bulletin/{id}`: eine Anzeige zum Lesen; nil = unbekannt
    public static func item(_ c: SQLiteConnection, id: String) throws -> JSONValue? {
        guard try has(c), let r = try c.rows("SELECT id, topic, title, text, url, posted_at FROM studip_bulletin WHERE id=?", [.text(id)]).first else { return nil }
        let posted = r["posted_at"]?.string ?? ""
        return ["id": r["id"] ?? .null, "topic": r["topic"] ?? .null, "title": r["title"] ?? .null, "text": r["text"] ?? .null,
                "url": (r["url"]?.string ?? "").isEmpty ? .null : r["url"]!, "posted_at": posted.isEmpty ? .null : .string(posted)]
    }
}
