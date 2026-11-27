import Foundation
@testable import UniFlowCore

// Nachbildung des Mail-Rechners der GWDG (Exchange IMAP4 auf 993, SMTP 587 mit STARTTLS) im Arbeitsspeicher, fuer
// IMAPMailTests und die App-Tests (GoettingenMailAppTests nutzen eine Kopie in UniFlowTests). Kein Netz. Antworten im
// Aufbau des echten Servers (Begruessung und Faehigkeiten am 27.11.2026 ohne Anmeldung gelesen); Inhalte erfunden.

final class IMAPFake: MailStreamOpener, @unchecked Sendable {
    struct Message {
        var uid: Int
        var flags: Set<String>
        var data: Data
        var internalDate: String
    }

    final class Box {
        let name: String
        var flags: [String]
        var messages: [Message] = []
        var uidNext = 1
        init(name: String, flags: [String] = ["\\HasNoChildren"]) {
            self.name = name
            self.flags = flags
        }
    }

    struct Delivery: Equatable {
        var from: String
        var recipients: [String]
        var data: Data
    }

    private let lock = NSLock()
    var user = "ug-student\\erika.muster"
    var password = "richtig-geheim"
    var capabilities = "IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=NTLM AUTH=GSSAPI SASL-IR UIDPLUS UNSELECT CHILDREN IDLE NAMESPACE LITERAL+"
    var boxes: [Box] = []
    /// alle Befehle (AUTHENTICATE/LOGIN unkenntlich)
    var log: [String] = []
    var logins = 0
    var failedLogins = 0
    var opened: [(host: String, port: UInt16, tls: Bool)] = []
    /// Verbindung nach so vielen Befehlen trennen (einmal)
    var dropAfterCommands: Int?
    // SMTP
    var smtpAdvertisesStartTLS = true
    var smtpRejects: Set<String> = []
    var smtpDropAfterData = false
    var deliveries: [Delivery] = []
    var smtpLog: [String] = []
    var smtpAuthBeforeTLS = false
    /// alles, was ueber die Leitung ging (Pruefung: Passwort nur in genau den Anmelde-Befehlen)
    var wire = Data()

    init() {}

    func box(_ name: String) -> Box? { boxes.first { $0.name == name } }

    func withLock<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try f()
    }

    /// Nachricht ablegen; `latin1`: Bytes in ISO-8859-1 statt UTF-8
    @discardableResult
    func add(_ boxName: String, _ raw: String, flags: Set<String> = [], date: String = "26-Nov-2026 10:42:00 +0100", latin1: Bool = false) -> Int {
        let b = box(boxName)!
        let uid = b.uidNext
        b.uidNext += 1
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let data = latin1 ? (text.data(using: .isoLatin1) ?? Data(text.utf8)) : Data(text.utf8)
        b.messages.append(Message(uid: uid, flags: flags, data: data, internalDate: date))
        return uid
    }

    /// Postfach wie bei Exchange mit deutscher Sprache
    static func goettingen() -> IMAPFake {
        let f = IMAPFake()
        f.boxes = [Box(name: "INBOX", flags: ["\\HasChildren"]), Box(name: "INBOX/Uni"), Box(name: "Entw&APw-rfe"), Box(name: "Gesendete Elemente"),
                   Box(name: "Gel&APY-schte Elemente"), Box(name: "Junk-E-Mail"), Box(name: "Kalender", flags: ["\\HasChildren"]),
                   Box(name: "Kalender/Feiertage"), Box(name: "Kontakte"), Box(name: "Aufgaben"), Box(name: "Postausgang"),
                   Box(name: "Synchronisierungsprobleme", flags: ["\\HasChildren"]), Box(name: "Synchronisierungsprobleme/Konflikte"),
                   Box(name: "Archiv")]
        return f
    }

    func open(host: String, port: UInt16, tls: Bool) async throws -> MailStream {
        withLock { opened.append((host, port, tls)) }
        if port == 993 && tls { return IMAPFakeConnection(self) }
        if port == 587 && !tls { return SMTPFakeConnection(self) }
        throw MailStreamError.offline("Nachbildung: \(host):\(port) tls=\(tls)")
    }
}

/// Eine IMAP-Verbindung zur Nachbildung (Client-Seite)
final class IMAPFakeConnection: MailStream, @unchecked Sendable {
    let server: IMAPFake
    private var out = Data()
    private var input = Data()
    private var pending = Data()
    private var closed = false
    private var authenticated = false
    private var selected: IMAPFake.Box?
    private var commands = 0

    init(_ s: IMAPFake) {
        server = s
        out.append(Data("* OK The Microsoft Exchange IMAP4 service is ready.\r\n".utf8))
    }

    func write(_ data: Data) async throws {
        try server.withLock {
            guard !closed else { throw MailStreamError.closed }
            server.wire.append(data)
            input.append(data)
            try process()
        }
    }

    func read() async throws -> Data {
        try server.withLock {
            if out.isEmpty { throw MailStreamError.closed }
            let d = out
            out = Data()
            return d
        }
    }

    func startTLS() async throws { throw MailStreamError.offline("kein STARTTLS bei IMAP") }
    func close() { server.withLock { closed = true } }

    private func say(_ s: String) { out.append(Data((s + "\r\n").utf8)) }

    /// Eingang zerlegen: Zeilen, Literale ({n} mit "+", {n+} ohne)
    private func process() throws {
        while let lf = input.firstIndex(of: 0x0A) {
            let line = Data(input[input.startIndex...lf])
            input = Data(input[(lf + 1)...])
            pending.append(line)
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
            if let open = text.lastIndex(of: "{"), text.hasSuffix("}") {
                var digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
                let plus = digits.hasSuffix("+")
                if plus { digits = digits.dropLast() }
                if let n = Int(digits) {
                    if !plus { say("+ Ready for additional command text.") }
                    if input.count < n { pendingLiteral = n; return }
                    pending.append(input.prefix(n))
                    input = Data(input.dropFirst(n))
                    continue
                }
            }
            let cmd = pending
            pending = Data()
            try execute(cmd)
            if closed { return }
        }
        if let n = pendingLiteral, input.count >= n {
            pendingLiteral = nil
            pending.append(input.prefix(n))
            input = Data(input.dropFirst(n))
            try process()
        }
    }

    private var pendingLiteral: Int?

    private func fetchItems(_ m: IMAPFake.Message, seq: Int, items: [IMAPValue], box: IMAPFake.Box) -> Data {
        var parts: [Data] = []
        var markSeen = false
        var names: [String] = []
        for it in items { if let l = it.list { names += l.compactMap(\.text) } else if let t = it.text { names.append(t) } }
        // Klammerliste "(UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO)])" kommt als ein Atom mit Klammern
        if names.count == 1, names[0].hasPrefix("(") {
            names = String(names[0].dropFirst().dropLast()).components(separatedBy: " ")
        }
        var joined: [String] = []
        for n in names {
            if let last = joined.last, last.contains("["), !last.contains("]") { joined[joined.count - 1] += " " + n } else { joined.append(n) }
        }
        var msg = m
        for n in joined {
            let u = n.uppercased()
            if u == "UID" { parts.append(Data("UID \(m.uid)".utf8)) }
            if u == "FLAGS" { continue }
            if u == "RFC822.SIZE" { parts.append(Data("RFC822.SIZE \(m.data.count)".utf8)) }
            if u == "INTERNALDATE" { parts.append(Data("INTERNALDATE \"\(m.internalDate)\"".utf8)) }
            if u.hasPrefix("BODY.PEEK[HEADER.FIELDS") || u.hasPrefix("BODY[HEADER.FIELDS") {
                let fields = Set(u.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: " ").map { $0.lowercased() })
                let head = MailMIME.split(m.data).header
                var keep: [String] = [], take = false
                for line in String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n") {
                    if line.first == " " || line.first == "\t" { if take { keep.append(line) }; continue }
                    let name = line.split(separator: ":").first.map { $0.lowercased() } ?? ""
                    take = fields.contains(name)
                    if take { keep.append(line) }
                }
                let lit = Data((keep.joined(separator: "\r\n") + "\r\n\r\n").utf8)
                var d = Data("BODY[HEADER.FIELDS (\(fields.sorted().map { $0.uppercased() }.joined(separator: " ")))] {\(lit.count)}\r\n".utf8)
                d.append(lit)
                parts.append(d)
            }
            if u == "BODY[]" || u == "BODY.PEEK[]" {
                if u == "BODY[]" { markSeen = true }
                var d = Data("BODY[] {\(m.data.count)}\r\n".utf8)
                d.append(m.data)
                parts.append(d)
            }
        }
        if markSeen, let i = box.messages.firstIndex(where: { $0.uid == m.uid }) {
            box.messages[i].flags.insert("\\Seen")
            msg = box.messages[i]
        }
        if joined.contains(where: { $0.uppercased() == "FLAGS" }) {
            parts.insert(Data("FLAGS (\(msg.flags.sorted().joined(separator: " ")))".utf8), at: min(1, parts.count))
        }
        var line = Data("* \(seq) FETCH (".utf8)
        for (i, p) in parts.enumerated() {
            if i > 0 { line.append(0x20) }
            line.append(p)
        }
        line.append(Data(")\r\n".utf8))
        return line
    }

    private func uids(_ set: String, in box: IMAPFake.Box) -> [Int] {
        var out: [Int] = []
        for p in set.split(separator: ",") {
            let r = p.split(separator: ":")
            if r.count == 2, let a = Int(r[0]) {
                let b = r[1] == "*" ? Int.max : (Int(r[1]) ?? a)
                out += box.messages.map(\.uid).filter { $0 >= a && $0 <= b }
            } else if let a = Int(p) {
                out.append(a)
            }
        }
        return out
    }

    private func execute(_ raw: Data) throws {
        commands += 1
        let t = (try? IMAP.tokens(raw)) ?? []
        guard t.count >= 2, let tag = t[0].text, let cmd = t[1].text?.uppercased() else { say("* BAD Command Error."); return }
        let logLine = ["AUTHENTICATE", "LOGIN"].contains(cmd) ? "\(tag) \(cmd) ***" : String(decoding: raw.prefix(300), as: UTF8.self).trimmingCharacters(in: .newlines)
        server.log.append(logLine)
        if let n = server.dropAfterCommands, commands > n {
            server.dropAfterCommands = nil
            closed = true
            out = Data()
            return
        }
        func ok(_ s: String = "\(cmd) completed.") { say("\(tag) OK \(s)") }
        func no(_ s: String) { say("\(tag) NO \(s)") }
        func bad(_ s: String = "Command Argument Error. 11") { say("\(tag) BAD \(s)") }
        let args = Array(t.dropFirst(2))
        switch cmd {
        case "CAPABILITY":
            say("* CAPABILITY \(server.capabilities)")
            ok()
        case "NOOP": ok()
        case "LOGOUT":
            say("* BYE Microsoft Exchange Server IMAP4 server signing off.")
            ok()
            closed = true
        case "AUTHENTICATE":
            guard args.count == 2, args[0].text?.uppercased() == "PLAIN", let ir = args[1].text, let d = Data(base64Encoded: ir) else { bad(); return }
            let p = d.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            server.logins += 1
            if p.count == 3, p[1] == server.user, p[2] == server.password { authenticated = true; ok("AUTHENTICATE completed.") } else {
                server.failedLogins += 1
                no("AUTHENTICATE failed.")
            }
        case "LOGIN":
            server.logins += 1
            if args.count == 2, args[0].text == server.user, args[1].text == server.password { authenticated = true; ok("LOGIN completed.") } else {
                server.failedLogins += 1
                no("LOGIN failed.")
            }
        default:
            guard authenticated else { bad("Command received in Invalid state."); return }
            try authed(tag, cmd, args, ok: ok, no: no, bad: bad)
        }
    }

    private func authed(_ tag: String, _ cmd: String, _ args: [IMAPValue], ok: (String) -> Void, no: (String) -> Void, bad: (String) -> Void) throws {
        switch cmd {
        case "LIST":
            for b in server.boxes { say("* LIST (\(b.flags.joined(separator: " "))) \"/\" \(IMAP.quoted(b.name) ?? b.name)") }
            ok("LIST completed.")
        case "STATUS":
            guard let name = args.first?.text, let b = server.box(name) else { no("The specified folder could not be found in the store."); return }
            say("* STATUS \(IMAP.quoted(b.name) ?? b.name) (UNSEEN \(b.messages.filter { !$0.flags.contains("\\Seen") }.count))")
            ok("STATUS completed.")
        case "SELECT", "EXAMINE":
            guard let name = args.first?.text, let b = server.box(name) else { no("The specified folder could not be found in the store."); return }
            selected = b
            say("* \(b.messages.count) EXISTS")
            say("* 0 RECENT")
            say("* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $MDNSent)")
            say("* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $MDNSent)] Permanent flags")
            say("* OK [UIDVALIDITY 14] UIDVALIDITY value")
            say("* OK [UIDNEXT \(b.uidNext)] The next unique identifier value")
            ok("[READ-WRITE] SELECT completed.")
        case "UNSELECT":
            selected = nil
            ok("UNSELECT completed.")
        case "CLOSE", "EXPUNGE":
            server.log.append("VERBOTEN \(cmd)")
            if let b = selected { b.messages.removeAll { $0.flags.contains("\\Deleted") } }
            ok("\(cmd) completed.")
        case "APPEND":
            guard args.count >= 2, let name = args[0].text, let b = server.box(name), let data = args.last?.data else { no("Folder not found"); return }
            let flags = args.count >= 3 ? Set((args[1].list ?? []).compactMap(\.text)) : []
            let uid = b.uidNext
            b.uidNext += 1
            b.messages.append(.init(uid: uid, flags: flags, data: data, internalDate: "27-Nov-2026 09:00:00 +0100"))
            ok("[APPENDUID 14 \(uid)] APPEND completed.")
        case "UID":
            guard let sub = args.first?.text?.uppercased(), let b = selected else { bad("Command received in Invalid state."); return }
            let rest = Array(args.dropFirst())
            switch sub {
            case "SEARCH":
                let words = rest.compactMap(\.text)
                var hits = b.messages
                if words.first?.uppercased() == "CHARSET" { hits = hits.filter { _ in true } }
                if let i = words.firstIndex(where: { $0.uppercased() == "SUBJECT" }), i + 1 < words.count {
                    let q = words[i + 1].lowercased()
                    let fq = words.firstIndex { $0.uppercased() == "FROM" }.map { words[$0 + 1].lowercased() } ?? q
                    hits = hits.filter { m in
                        let h = MailMIME.headers(MailMIME.split(m.data).header)
                        let s = MailMIME.decodeWords(MailMIME.header(h, "subject") ?? "").lowercased()
                        let f = MailMIME.decodeWords(MailMIME.header(h, "from") ?? "").lowercased()
                        return s.contains(q) || f.contains(fq)
                    }
                }
                say("* SEARCH" + hits.map { " \($0.uid)" }.joined())
                ok("SEARCH completed.")
            case "FETCH":
                guard let set = rest.first?.text else { bad(""); return }
                let want = Set(uids(set, in: b))
                for (i, m) in b.messages.enumerated() where want.contains(m.uid) {
                    out.append(fetchItems(m, seq: i + 1, items: Array(rest.dropFirst()), box: b))
                }
                ok("FETCH completed.")
            case "STORE":
                guard rest.count >= 3, let set = rest[0].text, let mode = rest[1].text?.uppercased(), let list = rest[2].list else { bad(""); return }
                let fl = Set(list.compactMap(\.text))
                for u in uids(set, in: b) {
                    guard let i = b.messages.firstIndex(where: { $0.uid == u }) else { continue }
                    if mode.hasPrefix("+") { b.messages[i].flags.formUnion(fl) } else { b.messages[i].flags.subtract(fl) }
                }
                ok("STORE completed.")
            case "COPY", "MOVE":
                guard sub == "COPY" || server.capabilities.contains("MOVE") else { bad("Command Error. 12"); return }
                guard rest.count >= 2, let set = rest[0].text, let target = rest[1].text, let tb = server.box(target) else { no("Folder not found"); return }
                for u in uids(set, in: b) {
                    guard let m = b.messages.first(where: { $0.uid == u }) else { continue }
                    var c = m
                    c.uid = tb.uidNext
                    c.flags.remove("\\Deleted")
                    tb.uidNext += 1
                    tb.messages.append(c)
                    if sub == "MOVE" { b.messages.removeAll { $0.uid == u } }
                }
                ok("\(sub) completed.")
            case "EXPUNGE":
                guard server.capabilities.contains("UIDPLUS"), let set = rest.first?.text else { bad("Command Error. 12"); return }
                let want = Set(uids(set, in: b))
                b.messages.removeAll { want.contains($0.uid) && $0.flags.contains("\\Deleted") }
                ok("EXPUNGE completed.")
            default: bad("Command Error. 12")
            }
        default: bad("Command Error. 12")
        }
    }
}

/// Eine SMTP-Verbindung zur Nachbildung (587, erst unverschluesselt, dann STARTTLS)
final class SMTPFakeConnection: MailStream, @unchecked Sendable {
    let server: IMAPFake
    private var out = Data()
    private var input = Data()
    private var tls = false
    private var authed = false
    private var authStep = 0
    private var authUser = ""
    private var inData = false
    private var from = ""
    private var rcpts: [String] = []
    private var closed = false

    init(_ s: IMAPFake) {
        server = s
        say("220 MBX19-GWD-05.um.gwdg.de Microsoft ESMTP MAIL Service ready at Fri, 27 Nov 2026 10:00:00 +0100")
    }

    private func say(_ s: String) { out.append(Data((s + "\r\n").utf8)) }

    func write(_ data: Data) async throws {
        server.withLock {
            guard !closed else { return }
            server.wire.append(data)
            input.append(data)
            process()
        }
    }

    func read() async throws -> Data {
        try server.withLock {
            if out.isEmpty { throw MailStreamError.closed }
            let d = out
            out = Data()
            return d
        }
    }

    func startTLS() async throws { server.withLock { tls = true } }
    func close() { server.withLock { closed = true } }

    private func process() {
        if inData {
            guard let r = input.range(of: Data("\r\n.\r\n".utf8)) else { return }
            var body = Data(input[input.startIndex..<r.lowerBound])
            input = Data(input[r.upperBound...])
            inData = false
            body = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n..", with: "\r\n.").utf8)
            if server.smtpDropAfterData { closed = true; return }
            server.deliveries.append(.init(from: from, recipients: rcpts, data: body + Data("\r\n".utf8)))
            say("250 2.6.0 <x@MBX19-GWD-05.um.gwdg.de> [InternalId=1] Queued mail for delivery")
            return
        }
        while let r = input.range(of: Data("\r\n".utf8)) {
            let line = String(decoding: input[input.startIndex..<r.lowerBound], as: UTF8.self)
            input = Data(input[r.upperBound...])
            handle(line)
            if inData { process(); return }
        }
    }

    private func handle(_ line: String) {
        if authStep == 1 {
            authUser = String(decoding: Data(base64Encoded: line) ?? Data(), as: UTF8.self)
            authStep = 2
            say("334 UGFzc3dvcmQ6")
            return
        }
        if authStep == 2 {
            authStep = 0
            let pw = String(decoding: Data(base64Encoded: line) ?? Data(), as: UTF8.self)
            server.smtpLog.append("AUTH-DATA ***")
            if !tls { server.smtpAuthBeforeTLS = true }
            if authUser == server.user, pw == server.password { authed = true; say("235 2.7.0 Authentication successful") } else {
                say("535 5.7.3 Authentication unsuccessful")
            }
            return
        }
        server.smtpLog.append(line.uppercased().hasPrefix("AUTH PLAIN") ? "AUTH PLAIN ***" : line)
        let u = line.uppercased()
        if u.hasPrefix("EHLO") {
            if tls {
                for l in ["250-MBX19-GWD-05.um.gwdg.de Hello [10.250.9.200]", "250-SIZE 367001600", "250-PIPELINING", "250-DSN", "250-ENHANCEDSTATUSCODES",
                          "250-AUTH GSSAPI NTLM LOGIN", "250-8BITMIME", "250-BINARYMIME", "250-CHUNKING", "250 SMTPUTF8"] { say(l) }
            } else {
                say("250-MBX19-GWD-05.um.gwdg.de Hello [10.250.9.200]")
                say("250-SIZE 367001600")
                if server.smtpAdvertisesStartTLS { say("250-STARTTLS") }
                say("250 8BITMIME")
            }
        } else if u == "STARTTLS" {
            say(server.smtpAdvertisesStartTLS ? "220 2.0.0 SMTP server ready" : "502 5.3.3 Command not implemented")
        } else if u == "AUTH LOGIN" {
            if !tls { server.smtpAuthBeforeTLS = true }
            authStep = 1
            say("334 VXNlcm5hbWU6")
        } else if u.hasPrefix("MAIL FROM:") {
            guard authed else { say("530 5.7.57 Client not authenticated to send mail"); return }
            from = String(line.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            rcpts = []
            say("250 2.1.0 Sender OK")
        } else if u.hasPrefix("RCPT TO:") {
            let r = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            if server.smtpRejects.contains(r) { say("550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup") } else {
                rcpts.append(r)
                say("250 2.1.5 Recipient OK")
            }
        } else if u == "DATA" {
            inData = true
            say("354 Start mail input; end with <CRLF>.<CRLF>")
        } else if u == "RSET" {
            rcpts = []
            say("250 2.0.0 Resetting")
        } else if u == "QUIT" {
            say("221 2.0.0 Service closing transmission channel")
            closed = true
        } else {
            say("500 5.3.3 Unrecognized command")
        }
    }
}

/// Erfundene Nachrichten fuer die Nachbildung
enum FakeMails {
    static let lecture = """
    From: =?UTF-8?Q?Prof=2E_Dr=2E_Max_M=C3=BCller?= <max.mueller@uni-goettingen.de>
    To: Erika Muster <erika.muster@stud.uni-goettingen.de>
    Cc: tutor@uni-goettingen.de
    Subject: =?UTF-8?Q?=C3=9Cbungsblatt_3_=E2=80=93_Abgabe_verschoben?=
    Date: Thu, 26 Nov 2026 10:42:00 +0100
    Message-ID: <blatt3@uni-goettingen.de>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="aussen"

    --aussen
    Content-Type: multipart/alternative; boundary="innen"

    --innen
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Liebe Studierende,
    die Abgabe ist am Freitag. Gr=C3=BC=C3=9Fe

    --innen
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    <p>Liebe Studierende,</p><p>die Abgabe ist am <b>Freitag</b>.</p><script>alert(1)</script><img src=3D"https://tracker.example/p.gif">
    --innen--

    --aussen
    Content-Type: application/pdf; name="Blatt3.pdf"
    Content-Disposition: attachment; filename*=UTF-8''%C3%9Cbungsblatt%203.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKJcOkw7zDtsOfCg==
    --aussen--
    """

    static let plain = """
    From: Mensa-Team <mensa@example.org>
    To: erika.muster@stud.uni-goettingen.de
    Subject: Neuer Speiseplan
    Date: Wed, 25 Nov 2026 08:00:00 +0100
    Message-ID: <plan@example.org>
    Content-Type: text/plain; charset=iso-8859-1
    Content-Transfer-Encoding: 8bit

    Gr\u{FC}\u{DF}e aus der Mensa.
    """

    static func group(_ n: Int) -> String {
        """
        From: Lerngruppe \(n) <gruppe\(n)@stud.uni-goettingen.de>
        To: erika.muster@stud.uni-goettingen.de, lena.beispiel@stud.uni-goettingen.de
        Cc: tom.test@stud.uni-goettingen.de
        Reply-To: liste\(n)@stud.uni-goettingen.de
        Subject: Treffen \(n)
        Date: Tue, 24 Nov 2026 18:00:00 +0100
        Message-ID: <treffen\(n)@stud.uni-goettingen.de>
        Content-Type: text/plain; charset=utf-8

        Wir treffen uns um 18 Uhr.
        """
    }
}
