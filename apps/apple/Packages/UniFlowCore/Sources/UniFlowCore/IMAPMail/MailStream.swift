import Foundation
#if canImport(Network)
import Network
#endif

// Verbindung zu einem Mail-Rechner (IMAP, SMTP) als Byte-Strom. Echt: Network.framework (`NWConnection` mit TLS) fuer
// Verbindungen, die gleich verschluesselt beginnen (IMAP 993); fuer SMTP mit STARTTLS (587) `URLSessionStreamTask`
// von Foundation, weil `NWConnection` eine laufende Verbindung nicht nachtraeglich auf TLS heben kann. Beide nur zu den
// Rechnern der eigenen Hochschule (`IMAPMailSite.hosts`), nie unverschluesselt angemeldet. Tests: Nachbildung des
// Servers im Arbeitsspeicher (UniFlowCoreTests/IMAPFakeServer.swift), nie ein Netz.

public enum MailStreamError: Error, Equatable, CustomStringConvertible {
    case notAllowed(String)
    case closed
    case timeout
    case offline(String)
    case tooLarge

    public var description: String {
        switch self {
        case .notAllowed(let h): return "Verbindung zu \(h) abgelehnt (nicht der Mail-Rechner der Hochschule)."
        case .closed: return "Die Verbindung zum Mail-Rechner wurde getrennt."
        case .timeout: return "Der Mail-Rechner antwortet nicht."
        case .offline(let s): return "Keine Verbindung zum Mail-Rechner (\(s))."
        case .tooLarge: return "Antwort des Mail-Rechners zu groß."
        }
    }
}

/// Byte-Strom zu einem Mail-Rechner
public protocol MailStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Naechste Bytes (mindestens eines); getrennt -> `MailStreamError.closed`
    func read() async throws -> Data
    /// STARTTLS: ab jetzt verschluesselt (nach "220 Ready to start TLS")
    func startTLS() async throws
    func close()
}

/// Oeffnet Verbindungen (echt oder Nachbildung)
public protocol MailStreamOpener: Sendable {
    /// `tls`: gleich verschluesselt (sonst unverschluesselt, und der Aufrufer muss sofort STARTTLS verlangen)
    func open(host: String, port: UInt16, tls: Bool) async throws -> MailStream
}

/// Puffer ueber einem Strom: Zeilen (CRLF) und genau n Bytes (IMAP-Literale)
public final class MailReader: @unchecked Sendable {
    public let stream: MailStream
    private var buffer = Data()
    /// laengste erlaubte Zeile bzw. laengstes Literal
    public var maxLine = 1 << 20
    public var maxLiteral = 60 << 20

    public init(_ stream: MailStream) { self.stream = stream }

    private func fill() async throws {
        let d = try await stream.read()
        if d.isEmpty { throw MailStreamError.closed }
        buffer.append(d)
    }

    /// Eine Zeile ohne CRLF (ein einzelnes LF zaehlt auch als Zeilenende)
    public func line() async throws -> Data {
        var scanned = 0
        while true {
            if let lf = buffer[buffer.startIndex.advanced(by: scanned)...].firstIndex(of: 0x0A) {
                var end = lf
                if end > buffer.startIndex, buffer[end - 1] == 0x0D { end -= 1 }
                let out = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[(lf + 1)...])
                return out
            }
            scanned = buffer.count
            if buffer.count > maxLine { throw MailStreamError.tooLarge }
            try await fill()
        }
    }

    public func bytes(_ n: Int) async throws -> Data {
        guard n >= 0, n <= maxLiteral else { throw MailStreamError.tooLarge }
        while buffer.count < n { try await fill() }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    public func write(_ s: String) async throws { try await stream.write(Data(s.utf8)) }
    public func write(_ d: Data) async throws { try await stream.write(d) }
}

/// Echte Verbindungen nur zu den Rechnern der Hochschule
public struct SystemMailStreamOpener: MailStreamOpener {
    public let allowedHosts: Set<String>
    public var timeout: TimeInterval

    public init(allowedHosts: Set<String>, timeout: TimeInterval = 45) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.timeout = timeout
    }

    public init(site: IMAPMailSite) { self.init(allowedHosts: site.hosts) }

    public func open(host: String, port: UInt16, tls: Bool) async throws -> MailStream {
        let h = host.lowercased()
        guard allowedHosts.contains(h) else { throw MailStreamError.notAllowed(h) }
        #if canImport(Network)
        if tls {
            let s = NWMailStream(host: h, port: port, timeout: timeout)
            try await s.start()
            return s
        }
        return StreamTaskMailStream(host: h, port: port, timeout: timeout)
        #else
        throw MailStreamError.offline("auf diesem System nicht verfügbar")
        #endif
    }
}

#if canImport(Network)
/// Wartet hoechstens `seconds` auf `op`
func mailTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MailStreamError.timeout
        }
        defer { g.cancelAll() }
        guard let first = try await g.next() else { throw MailStreamError.timeout }
        return first
    }
}

/// Einmal erfuellbare Fortsetzung (Rueckrufe von Network.framework koennen mehrfach kommen)
final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock()
        let k = c
        c = nil
        lock.unlock()
        k?.resume(with: r)
    }
}

/// TLS-Verbindung mit Network.framework (TLS 1.2 oder neuer, Zertifikat und Rechnername prueft das System)
final class NWMailStream: MailStream, @unchecked Sendable {
    let connection: NWConnection
    let timeout: TimeInterval
    private let queue = DispatchQueue(label: "studinow.mail.nw")

    init(host: String, port: UInt16, timeout: TimeInterval) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.enableKeepalive = true
        let params = NWParameters(tls: tls, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .imaps, using: params)
        self.timeout = timeout
    }

    func start() async throws {
        let conn = connection, q = queue
        try await mailTimeout(timeout) {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = OnceContinuation(k)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(.success(()))
                    case .failed(let e): once.resume(.failure(MailStreamError.offline(e.localizedDescription)))
                    case .waiting(let e): once.resume(.failure(MailStreamError.offline(e.localizedDescription)))
                    case .cancelled: once.resume(.failure(MailStreamError.closed))
                    default: break
                    }
                }
                conn.start(queue: q)
            }
        }
    }

    func write(_ data: Data) async throws {
        let conn = connection
        try await mailTimeout(timeout) {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { e in
                    k.resume(with: e.map { .failure(MailStreamError.offline($0.localizedDescription)) } ?? .success(()))
                })
            }
        }
    }

    func read() async throws -> Data {
        let conn = connection
        return try await mailTimeout(timeout) {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, e in
                    if let data, !data.isEmpty { k.resume(returning: data) } else if let e { k.resume(throwing: MailStreamError.offline(e.localizedDescription)) } else if complete {
                        k.resume(throwing: MailStreamError.closed)
                    } else {
                        k.resume(returning: Data())
                    }
                }
            }
        }
    }

    func startTLS() async throws { throw MailStreamError.offline("STARTTLS hier nicht möglich") }

    func close() { connection.cancel() }
}

/// Verbindung, die unverschluesselt beginnt und mit STARTTLS verschluesselt wird (`URLSessionStreamTask`). Vor
/// `startTLS` geht nur der Austausch bis "STARTTLS" darueber, nie Zugangsdaten (`SMTPClient`).
final class StreamTaskMailStream: MailStream, @unchecked Sendable {
    let session: URLSession
    let task: URLSessionStreamTask
    let timeout: TimeInterval

    init(host: String, port: UInt16, timeout: TimeInterval) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
        task = session.streamTask(withHostName: host, port: Int(port))
        self.timeout = timeout
        task.resume()
    }

    func write(_ data: Data) async throws {
        let t = task, to = timeout
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            t.write(data, timeout: to) { e in k.resume(with: e.map { .failure(MailStreamError.offline($0.localizedDescription)) } ?? .success(())) }
        }
    }

    func read() async throws -> Data {
        let t = task, to = timeout
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            t.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: to) { data, eof, e in
                if let data, !data.isEmpty { k.resume(returning: data) } else if let e {
                    let ns = e as NSError
                    k.resume(throwing: ns.code == NSURLErrorTimedOut ? MailStreamError.timeout : MailStreamError.offline(ns.localizedDescription))
                } else if eof {
                    k.resume(throwing: MailStreamError.closed)
                } else {
                    k.resume(returning: Data())
                }
            }
        }
    }

    func startTLS() async throws { task.startSecureConnection() }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }
}
#endif
