import Foundation

/// Senden ueber SMTP (RFC 5321, Einreichung 587 mit STARTTLS, AUTH PLAIN/LOGIN). Genau ein Versuch, nur nach dem Knopf
/// "Senden" und dessen Rueckfrage. Vor STARTTLS gehen keine Zugangsdaten und kein Inhalt ueber die Leitung; bietet der
/// Server kein STARTTLS an, bricht es ab. Lehnt der Server einen Empfaenger ab, geht nichts hinaus (vor DATA).
public enum SMTPError: Error, Equatable, CustomStringConvertible {
    case noTLS
    case authenticationFailed(String)
    case rejected(String)
    /// Verbindung riss nach dem Absenden ab, bevor der Server bestaetigt hat: Ergebnis unklar (nie erneut senden)
    case unknownOutcome

    public var description: String {
        switch self {
        case .noTLS: return "Der Mail-Rechner bietet keine verschlüsselte Verbindung an; es wurde nichts gesendet."
        case .authenticationFailed(let s): return "Anmeldung beim Senden abgelehnt" + (s.isEmpty ? "." : ": \(s)")
        case .rejected(let s): return "Der Mail-Rechner hat das Senden abgelehnt" + (s.isEmpty ? "." : ": \(s)")
        case .unknownOutcome: return "Die Verbindung brach beim Senden ab. Ob die E-Mail hinausging, ist unklar – bitte in „Gesendet“ bzw. beim Empfänger nachsehen, bevor du sie noch einmal sendest."
        }
    }
}

public struct SMTPClient: Sendable {
    public let site: IMAPMailSite
    public let opener: MailStreamOpener
    /// Name im EHLO (kein Rechnername des Geraets)
    public var heloName = "studinow.app"

    public init(site: IMAPMailSite, opener: MailStreamOpener) {
        self.site = site
        self.opener = opener
    }

    struct Reply {
        let code: Int
        let lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    static func reply(_ r: MailReader) async throws -> Reply {
        var lines: [String] = []
        while true {
            let l = String(decoding: try await r.line(), as: UTF8.self)
            guard l.count >= 3, let code = Int(l.prefix(3)) else { throw SMTPError.rejected("unverständliche Antwort") }
            lines.append(l.count > 4 ? String(l.dropFirst(4)) : "")
            if l.count < 4 || l[l.index(l.startIndex, offsetBy: 3)] != "-" { return Reply(code: code, lines: lines) }
            if lines.count > 200 { throw SMTPError.rejected("Antwort zu lang") }
        }
    }

    static func command(_ r: MailReader, _ line: String) async throws -> Reply {
        try await r.write(line + "\r\n")
        return try await reply(r)
    }

    /// Punkte am Zeilenanfang verdoppeln, Ende mit "."
    public static func dotStuffed(_ d: Data) -> Data {
        var out = Data(), atLineStart = true
        out.reserveCapacity(d.count + 64)
        for b in d {
            if atLineStart, b == 0x2E { out.append(0x2E) }
            out.append(b)
            atLineStart = b == 0x0A
        }
        if !(out.suffix(2) == Data([0x0D, 0x0A])) { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: [0x2E, 0x0D, 0x0A])
        return out
    }

    static func clean(_ s: String) -> String { IMAPSession.clean(s) }

    /// Nachricht senden; `from`: Umschlag-Absender, `recipients`: alle (An, Cc, Bcc)
    public func send(user: String, password: String, from: String, recipients: [String], message: Data) async throws {
        guard !recipients.isEmpty else { throw SMTPError.rejected("kein Empfänger") }
        let stream = try await opener.open(host: site.smtpHost, port: site.smtpPort, tls: site.smtpSecurity == .tls)
        let r = MailReader(stream)
        defer { stream.close() }
        guard try await Self.reply(r).code == 220 else { throw SMTPError.rejected("Begrüßung") }
        var ehlo = try await Self.command(r, "EHLO \(heloName)")
        guard ehlo.code == 250 else { throw SMTPError.rejected(Self.clean(ehlo.text)) }
        if site.smtpSecurity == .startTLS {
            guard ehlo.lines.contains(where: { $0.uppercased().hasPrefix("STARTTLS") }) else { throw SMTPError.noTLS }
            guard try await Self.command(r, "STARTTLS").code == 220 else { throw SMTPError.noTLS }
            try await stream.startTLS()
            ehlo = try await Self.command(r, "EHLO \(heloName)")
            guard ehlo.code == 250 else { throw SMTPError.rejected(Self.clean(ehlo.text)) }
        }
        let auth = ehlo.lines.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased().split(separator: " ").map(String.init) ?? []
        if auth.contains("PLAIN") {
            var raw = Data([0])
            raw.append(Data(user.utf8))
            raw.append(0)
            raw.append(Data(password.utf8))
            let a = try await Self.command(r, "AUTH PLAIN " + raw.base64EncodedString())
            guard a.code == 235 else { throw SMTPError.authenticationFailed(Self.clean(a.text)) }
        } else if auth.contains("LOGIN") {
            guard try await Self.command(r, "AUTH LOGIN").code == 334 else { throw SMTPError.authenticationFailed("") }
            guard try await Self.command(r, Data(user.utf8).base64EncodedString()).code == 334 else { throw SMTPError.authenticationFailed("") }
            let a = try await Self.command(r, Data(password.utf8).base64EncodedString())
            guard a.code == 235 else { throw SMTPError.authenticationFailed(Self.clean(a.text)) }
        } else {
            throw SMTPError.authenticationFailed("keine erlaubte Anmeldung")
        }
        let utf8 = !MailCompose.isASCII(from) || recipients.contains { !MailCompose.isASCII($0) }
        let mf = try await Self.command(r, "MAIL FROM:<\(MailCompose.clean(from))>" + (utf8 ? " SMTPUTF8" : ""))
        guard mf.code == 250 else { throw SMTPError.rejected(Self.clean(mf.text)) }
        for rcpt in recipients {
            let x = try await Self.command(r, "RCPT TO:<\(MailCompose.clean(rcpt))>")
            guard x.code == 250 || x.code == 251 else {
                _ = try? await Self.command(r, "RSET")
                throw SMTPError.rejected("\(rcpt): \(Self.clean(x.text))")
            }
        }
        guard try await Self.command(r, "DATA").code == 354 else { throw SMTPError.rejected("DATA") }
        // ab hier kann die Nachricht beim Server angekommen sein: jeder Abbruch heisst "unklar", nie ein zweiter Versuch
        let done: Reply
        do {
            try await r.write(Self.dotStuffed(message))
            done = try await Self.reply(r)
        } catch {
            throw SMTPError.unknownOutcome
        }
        guard done.code == 250 else { throw SMTPError.rejected(Self.clean(done.text)) }
        _ = try? await Self.command(r, "QUIT")
    }
}
