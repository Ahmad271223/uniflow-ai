import Foundation

/// Eine angemeldete IMAP-Verbindung: Befehle nacheinander (Marke A1, A2, …), Antworten mit Literalen, Anmeldung mit
/// AUTHENTICATE PLAIN (SASL-IR) bzw. LOGIN. Das Passwort steht nur in genau einer Anfrage an den Mail-Rechner der
/// Hochschule, nie in einem Protokoll oder einer Fehlermeldung.
public actor IMAPSession {
    /// Antwort eines Befehls
    public struct Reply: Sendable {
        /// unmarkierte Antworten ohne "* ", zerlegt (nil, wenn nicht zerlegbar, z. B. Freitext)
        public var untagged: [[IMAPValue]] = []
        /// unmarkierte Antworten als Text (Statuszeilen)
        public var lines: [String] = []
        /// Code der abschliessenden Zeile ("APPENDUID 1 5")
        public var code: String?
        public var text = ""
    }

    let reader: MailReader
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: String?
    public private(set) var closed = false
    private var counter = 0
    /// Zahl der Anmeldeversuche (Tests: nie mehr als einer je Verbindung)
    public private(set) var loginAttempts = 0

    init(reader: MailReader) { self.reader = reader }

    /// Verbinden und Begruessung lesen
    public static func connect(_ opener: MailStreamOpener, site: IMAPMailSite) async throws -> IMAPSession {
        let s = try await opener.open(host: site.imapHost, port: site.imapPort, tls: true)
        let session = IMAPSession(reader: MailReader(s))
        try await session.greeting()
        return session
    }

    private func greeting() async throws {
        let line = String(decoding: try await reader.line(), as: UTF8.self)
        guard line.hasPrefix("* ") else { throw IMAPError.protocolError("Begrüßung") }
        let st = IMAP.status(String(line.dropFirst(2)))
        if st.status == "BYE" { throw IMAPError.protocolError(st.text) }
        guard st.status == "OK" || st.status == "PREAUTH" else { throw IMAPError.protocolError("Begrüßung") }
        if let code = st.code, code.uppercased().hasPrefix("CAPABILITY") {
            capabilities = IMAP.capabilities(code.split(separator: " ").map(String.init))
        }
    }

    public func has(_ cap: String) -> Bool { capabilities.contains(cap.uppercased()) }

    /// Eine vollstaendige Antwort (Zeile samt Literalen)
    private func response() async throws -> Data {
        var out = Data()
        while true {
            let line = try await reader.line()
            out.append(line)
            guard line.last == 0x7D, let open = line.lastIndex(of: 0x7B) else { break }
            var digits = line[(open + 1)..<(line.count - 1)]
            if digits.last == 0x2B { digits = digits.dropLast() }
            guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(String(decoding: digits, as: UTF8.self)) else { break }
            out.append(contentsOf: [0x0D, 0x0A])
            out.append(try await reader.bytes(n))
        }
        return out
    }

    private func nextTag() -> String {
        counter += 1
        return "A\(counter)"
    }

    /// Schreibt die Argumente; Literale mit LITERAL+ ohne Warten, sonst nach "+"
    private func send(_ tag: String, _ args: [IMAPArg]) async throws {
        var line = Data(tag.utf8)
        let plus = has("LITERAL+")
        for a in args {
            line.append(0x20)
            switch a {
            case .raw(let s): line.append(Data(s.utf8))
            case .string(let s):
                if let q = IMAP.quoted(s) { line.append(Data(q.utf8)) } else {
                    try await literal(Data(s.utf8), into: &line, plus: plus)
                }
            case .literal(let d): try await literal(d, into: &line, plus: plus)
            }
        }
        line.append(contentsOf: [0x0D, 0x0A])
        try await reader.write(line)
    }

    private func literal(_ d: Data, into line: inout Data, plus: Bool) async throws {
        line.append(Data("{\(d.count)\(plus ? "+" : "")}\r\n".utf8))
        if !plus {
            try await reader.write(line)
            line = Data()
            try await continuation()
        }
        line.append(d)
    }

    /// Auf "+ …" warten (unmarkierte Antworten dazwischen ueberspringen)
    private func continuation() async throws {
        while true {
            let r = try await response()
            if r.first == 0x2B { return }
            if r.starts(with: Data("* BYE".utf8)) { closed = true; throw IMAPError.protocolError("BYE") }
            if !r.starts(with: Data("* ".utf8)) { throw IMAPError.rejected(String(decoding: r, as: UTF8.self)) }
        }
    }

    /// Befehl ausfuehren; NO/BAD -> `IMAPError.rejected`
    @discardableResult
    public func run(_ args: [IMAPArg]) async throws -> Reply {
        guard !closed else { throw MailStreamError.closed }
        let tag = nextTag()
        do {
            try await send(tag, args)
            return try await collect(tag)
        } catch let e as MailStreamError {
            closed = true
            throw e
        }
    }

    @discardableResult
    public func run(_ words: String...) async throws -> Reply { try await run(words.map { IMAPArg.raw($0) }) }

    private func collect(_ tag: String) async throws -> Reply {
        var reply = Reply()
        let prefix = Data((tag + " ").utf8)
        while true {
            let r = try await response()
            if r.starts(with: prefix) {
                let st = IMAP.status(String(decoding: r.dropFirst(prefix.count), as: UTF8.self))
                reply.code = st.code
                reply.text = st.text
                if let c = st.code, c.uppercased().hasPrefix("CAPABILITY") { capabilities = IMAP.capabilities(c.split(separator: " ").map(String.init)) }
                guard st.status == "OK" else { throw IMAPError.rejected(st.text) }
                return reply
            }
            guard r.starts(with: Data("* ".utf8)) else { continue }            // "+" ohne Literal: uebergehen
            let body = Data(r.dropFirst(2))
            let text = String(decoding: body.prefix(2000), as: UTF8.self)
            let first = text.prefix { $0 != " " }.uppercased()
            if ["OK", "NO", "BAD", "BYE", "PREAUTH"].contains(first) {
                reply.lines.append(text)
                if first == "BYE" { closed = true }
                continue
            }
            if first == "CAPABILITY" {
                capabilities = IMAP.capabilities(text.split(separator: " ").map(String.init))
                continue
            }
            if let t = try? IMAP.tokens(body) { reply.untagged.append(t) }
        }
    }

    // MARK: Anmeldung

    /// Genau ein Anmeldeversuch je Verbindung; abgelehnt -> `IMAPError.authenticationFailed`
    public func login(user: String, password: String) async throws {
        guard loginAttempts == 0 else { throw IMAPError.authenticationFailed("") }
        loginAttempts += 1
        if capabilities.isEmpty { try await run("CAPABILITY") }
        do {
            if has("AUTH=PLAIN") {
                var raw = Data([0])
                raw.append(Data(user.utf8))
                raw.append(0)
                raw.append(Data(password.utf8))
                let token = raw.base64EncodedString()
                if has("SASL-IR") {
                    try await run([.raw("AUTHENTICATE"), .raw("PLAIN"), .raw(token)])
                } else {
                    let tag = nextTag()
                    try await reader.write(tag + " AUTHENTICATE PLAIN\r\n")
                    try await continuation()
                    try await reader.write(token + "\r\n")
                    _ = try await collect(tag)
                }
            } else if !has("LOGINDISABLED") {
                try await run([.raw("LOGIN"), .string(user), .string(password)])
            } else {
                throw IMAPError.unsupported("keine erlaubte Anmeldung")
            }
        } catch IMAPError.rejected(let text) {
            throw IMAPError.authenticationFailed(Self.clean(text))
        }
        // Faehigkeiten nach der Anmeldung (Exchange nennt dann ggf. mehr)
        if !capabilities.contains("UIDPLUS") { try? await run("CAPABILITY") }
    }

    /// Fehlertext des Servers ohne Steuerzeichen, gekuerzt (nie Zugangsdaten: die stehen nicht in Antworten)
    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 }.prefix(200)))
    }

    // MARK: Ordner

    public func select(_ mailbox: String) async throws {
        if selected == mailbox { return }
        selected = nil
        try await run([.raw("SELECT"), .string(mailbox)])
        selected = mailbox
    }

    /// Ordner verlassen, ohne geloeschte zu entfernen (UNSELECT; sonst EXAMINE eines anderen geht nicht ohne Risiko)
    public func unselect() async {
        guard selected != nil else { return }
        if has("UNSELECT") { _ = try? await run("UNSELECT") }
        selected = nil
    }

    public func logout() async {
        guard !closed else { return }
        _ = try? await run("LOGOUT")
        closed = true
        reader.stream.close()
    }

    public func abandon() {
        closed = true
        reader.stream.close()
    }
}
