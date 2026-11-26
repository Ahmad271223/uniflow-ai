import Foundation

// Absturzmeldung (25.11.2026, docs/ABSTURZMELDUNG-2026-11-25.md, Dienst: app/crash_reports.py).
//
// Der Inhaber will sehen, wie viele Abstuerze es je Tag, App-Version und Geraeteart gab. Apple liefert der App ueber
// MetricKit, was auf diesem Geraet passiert ist (Absturz, Haenger, Tageszaehlung "von iOS beendet"). Hier steht der
// plattformunabhaengige Teil: Apples JSON lesen, auf wenige Angaben kuerzen, in einer kleinen Datei sammeln und an
// den Dienst geben. Den Empfang von MetricKit macht die App (UniFlow/Services/CrashReporting.swift).
//
// Was das Geraet verlaesst (und nichts sonst): App-Version und Build, Geraeteart, Modellkennung, Systemversion,
// Quelle (store | test), Zeitpunkt, Art, Signal/Ausnahme-Typ/-Code, Beendigungsgrund von iOS, Name der
// Ausnahme-Klasse, bei Haengern die Dauer, und die oberste Aufrufkette als "Programmdatei + Abstand".
// Bewusst NICHT: der Text einer Ausnahme (`composedMessage`, `arguments`: kann Dateinamen enthalten), Speicherangaben
// (`virtualMemoryRegionInfo`), Kennung der App-Installation bei Apple, Region, Konto, Uni-Zugang, Dokumente.

/// Eine Meldung, wie sie in der Warteschlange liegt und an den Dienst geht
public struct CrashReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case crash, hang, exit }

    /// Eine Zeile der Aufrufkette: Programmdatei, Abstand in der Datei, Kennung der Datei (nur bei der App selbst)
    public struct Frame: Codable, Equatable, Sendable {
        public var b: String
        public var o: Int
        public var u: String?
        public init(b: String, o: Int, u: String? = nil) { self.b = b; self.o = o; self.u = u }
    }

    /// zufaellig, 32 Hex-Zeichen: der Dienst legt dieselbe Meldung nie zweimal ab
    public var id: String
    public var kind: Kind
    public var at: Date
    public var appVersion: String
    public var appBuild: String?
    /// iphone | ipad | mac
    public var deviceClass: String
    /// z. B. "iPad14,3"
    public var deviceModel: String?
    public var osVersion: String?
    /// store | test
    public var channel: String
    public var signal: Int?
    public var exceptionType: Int?
    public var exceptionCode: Int?
    public var termination: String?
    public var exceptionName: String?
    public var hangSeconds: Double?
    /// nur exit: memory_limit | watchdog | cpu_limit | bad_access | illegal_instruction | abnormal
    public var reason: String?
    /// nur exit: Anzahl in den 24 Stunden der Zaehlung
    public var count: Int?
    public var frames: [Frame]

    public init(id: String, kind: Kind, at: Date, appVersion: String, appBuild: String? = nil, deviceClass: String,
                deviceModel: String? = nil, osVersion: String? = nil, channel: String, signal: Int? = nil,
                exceptionType: Int? = nil, exceptionCode: Int? = nil, termination: String? = nil, exceptionName: String? = nil,
                hangSeconds: Double? = nil, reason: String? = nil, count: Int? = nil, frames: [Frame] = []) {
        self.id = id; self.kind = kind; self.at = at; self.appVersion = appVersion; self.appBuild = appBuild
        self.deviceClass = deviceClass; self.deviceModel = deviceModel; self.osVersion = osVersion; self.channel = channel
        self.signal = signal; self.exceptionType = exceptionType; self.exceptionCode = exceptionCode
        self.termination = termination; self.exceptionName = exceptionName; self.hangSeconds = hangSeconds
        self.reason = reason; self.count = count; self.frames = frames
    }

    /// Neue Kennung einer Meldung bzw. einer Installation: UUID ohne Striche, klein
    public static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// Zeitpunkt, wie ihn der Dienst liest: UTC, ganze Sekunden ("2026-11-24T08:15:00Z")
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Die Meldung im Format des Dienstes (app/crash_reports.py `clean`); fehlende Angaben fehlen auch hier
    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "at": .string(Self.timestamp(at)),
                                      "app_version": .string(appVersion), "device_class": .string(deviceClass),
                                      "channel": .string(channel)]
        if let appBuild { o["app_build"] = .string(appBuild) }
        if let deviceModel { o["device_model"] = .string(deviceModel) }
        if let osVersion { o["os_version"] = .string(osVersion) }
        if let signal { o["signal"] = .number(Double(signal)) }
        if let exceptionType { o["exception_type"] = .number(Double(exceptionType)) }
        if let exceptionCode { o["exception_code"] = .number(Double(exceptionCode)) }
        if let termination { o["termination"] = .string(termination) }
        if let exceptionName { o["exception_name"] = .string(exceptionName) }
        if let hangSeconds { o["hang_seconds"] = .number(hangSeconds) }
        if let reason { o["reason"] = .string(reason) }
        if let count { o["count"] = .number(Double(count)) }
        if !frames.isEmpty {
            o["frames"] = .array(frames.map { f in
                var x: [String: JSONValue] = ["b": .string(f.b), "o": .number(Double(f.o))]
                if let u = f.u { x["u"] = .string(u) }
                return .object(x)
            })
        }
        return .object(o)
    }
}

/// Apples MetricKit-JSON (`MXDiagnosticPayload.jsonRepresentation()`, `MXMetricPayload.jsonRepresentation()`) auf
/// `CrashReport` kuerzen. Schluesselnamen aus der MetricKit-Bibliothek von iOS 27.2 (25.11.2026 nachgesehen):
/// crashDiagnostics, hangDiagnostics, diagnosticMetaData, callStackTree, callStacks, threadAttributed,
/// callStackRootFrames, subFrames, binaryName, binaryUUID, offsetIntoBinaryTextSegment, sampleCount, appVersion,
/// appBuildVersion, deviceType, osVersion, isTestFlightApp, signal, exceptionType, exceptionCode, terminationReason,
/// objectiveCexceptionReason, hangDuration, applicationExitMetrics, foregroundExitData, cumulative…ExitCount.
public enum MetricKitReports {
    /// Was die App selbst weiss (Rueckfall, wenn Apples Daten eine Angabe nicht tragen)
    public struct Context: Equatable, Sendable {
        public var appVersion: String
        public var appBuild: String?
        /// iphone | ipad | mac
        public var deviceClass: String
        /// store | test
        public var channel: String
        /// Programmdateien der App selbst: nur ihre Zeilen tragen die Kennung der Datei (zum Zuordnen des Builds)
        public var appBinaries: Set<String>

        public init(appVersion: String, appBuild: String?, deviceClass: String, channel: String, appBinaries: Set<String>) {
            self.appVersion = appVersion; self.appBuild = appBuild; self.deviceClass = deviceClass
            self.channel = channel; self.appBinaries = appBinaries
        }
    }

    /// Hoechstens so viele Zeilen je Aufrufkette; laengere Ketten behalten Anfang und Ende
    public static let maxFrames = 32
    static let keptHead = 20
    /// Platzhalter fuer die ausgelassene Mitte einer langen Kette; `o` traegt die Zahl der ausgelassenen Zeilen
    public static let cutMarker = "(...)"

    /// Gruende der Tageszaehlung von iOS, nur Vordergrund (`MXForegroundExitData`)
    static let exitKeys: [(key: String, reason: String)] = [
        ("cumulativeMemoryResourceLimitExitCount", "memory_limit"),
        ("cumulativeAppWatchdogExitCount", "watchdog"),
        ("cumulativeCPUResourceLimitExitCount", "cpu_limit"),
        ("cumulativeBadAccessExitCount", "bad_access"),
        ("cumulativeIllegalInstructionExitCount", "illegal_instruction"),
        ("cumulativeAbnormalExitCount", "abnormal"),
    ]

    /// Abstuerze und Haenger aus einem Diagnose-Paket. `at`: Zeitstempel des Pakets (Apple nennt keinen je Eintrag).
    public static func diagnostics(json: Data, at: Date, context: Context,
                                   newID: () -> String = CrashReport.newID) -> [CrashReport] {
        guard let root = try? JSONValue.parse(json) else { return [] }
        var out: [CrashReport] = []
        for d in root["crashDiagnostics"]?.array ?? [] {
            let meta = d["diagnosticMetaData"] ?? .null
            var r = base(.crash, meta: meta, appVersion: meta["appVersion"]?.string, at: at, context: context, id: newID())
            r.signal = int(meta["signal"])
            r.exceptionType = int(meta["exceptionType"])
            r.exceptionCode = int(meta["exceptionCode"])
            r.termination = plain(meta["terminationReason"]?.string, limit: 160)
            let reason = meta["objectiveCexceptionReason"] ?? d["objectiveCexceptionReason"] ?? .null
            r.exceptionName = name(reason["exceptionName"]?.string) ?? name(reason["className"]?.string)
            r.frames = frames(d["callStackTree"], context: context)
            out.append(r)
        }
        for d in root["hangDiagnostics"]?.array ?? [] {
            let meta = d["diagnosticMetaData"] ?? .null
            var r = base(.hang, meta: meta, appVersion: meta["appVersion"]?.string, at: at, context: context, id: newID())
            r.hangSeconds = seconds(meta["hangDuration"])
            r.frames = frames(d["callStackTree"], context: context)
            out.append(r)
        }
        return out
    }

    /// Tageszaehlung "von iOS beendet, waehrend die App vorn war" aus einem Messwerte-Paket; je Grund eine Meldung,
    /// Gruende mit 0 fehlen. `at`: Beginn des Zeitraums der Zaehlung.
    public static func exits(json: Data, at: Date, context: Context, newID: () -> String = CrashReport.newID) -> [CrashReport] {
        guard let root = try? JSONValue.parse(json) else { return [] }
        let data = root["applicationExitMetrics"]?["foregroundExitData"] ?? .null
        let meta = root["metaData"] ?? .null
        var out: [CrashReport] = []
        for (key, reason) in exitKeys {
            guard let n = int(data[key]), n > 0 else { continue }
            var r = base(.exit, meta: meta, appVersion: root["appVersion"]?.string ?? meta["appVersion"]?.string,
                         at: at, context: context, id: newID())
            r.reason = reason
            r.count = min(n, 10_000)
            out.append(r)
        }
        return out
    }

    // MARK: Bausteine

    private static func base(_ kind: CrashReport.Kind, meta: JSONValue, appVersion: String?, at: Date, context: Context,
                             id: String) -> CrashReport {
        // Version und Build aus Apples Daten: nach einem Update meldet die neue App den Absturz der alten
        let v = Self.version(appVersion) ?? context.appVersion
        let b = Self.build(meta["appBuildVersion"]?.string) ?? (v == context.appVersion ? context.appBuild : nil)
        let test = meta["isTestFlightApp"]?.bool == true
        return CrashReport(id: id, kind: kind, at: at, appVersion: v, appBuild: b, deviceClass: context.deviceClass,
                           deviceModel: model(meta["deviceType"]?.string), osVersion: plain(meta["osVersion"]?.string, limit: 48),
                           channel: test ? "test" : context.channel)
    }

    /// Die Aufrufkette des Fadens, dem Apple das Ereignis zuschreibt (`threadAttributed`), sonst des ersten. In der
    /// Reihenfolge, in der Apple sie liefert; bei Verzweigungen (Haenger: mehrere Messpunkte) der haeufigste Zweig.
    static func frames(_ tree: JSONValue?, context: Context) -> [CrashReport.Frame] {
        let stacks = tree?["callStacks"]?.array ?? []
        guard let stack = stacks.first(where: { $0["threadAttributed"]?.bool == true }) ?? stacks.first else { return [] }
        var chain: [CrashReport.Frame] = []
        var next = stack["callStackRootFrames"]?.array?.first
        var guardCount = 0
        while let f = next, guardCount < 2_000 {
            guardCount += 1
            if let b = plain(f["binaryName"]?.string, limit: 64), let o = int(f["offsetIntoBinaryTextSegment"]), o >= 0 {
                let u = context.appBinaries.contains(b) ? uuid(f["binaryUUID"]?.string) : nil
                chain.append(CrashReport.Frame(b: b, o: o, u: u))
            }
            let subs = f["subFrames"]?.array ?? []
            next = subs.max { (int($0["sampleCount"]) ?? 0) < (int($1["sampleCount"]) ?? 0) } ?? subs.first
        }
        guard chain.count > maxFrames else { return chain }
        let tail = maxFrames - keptHead - 1
        let skipped = chain.count - keptHead - tail
        return Array(chain.prefix(keptHead)) + [CrashReport.Frame(b: cutMarker, o: skipped)] + Array(chain.suffix(tail))
    }

    /// Zahl aus einer JSON-Zahl oder einem Zahlentext ("11")
    static func int(_ v: JSONValue?) -> Int? {
        if let n = v?.int { return n }
        if let s = v?.string { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Dauer eines Haengers in Sekunden: Apple schreibt "20 sec" (auch "1500 ms", "2 min"); eine blanke Zahl sind Sekunden
    static func seconds(_ v: JSONValue?) -> Double? {
        if let d = v?.double { return d >= 0 && d <= 86_400 ? d : nil }
        guard let s = v?.string?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let number = s.prefix { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(number) else { return nil }
        let unit = s.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let secs: Double
        if unit.hasPrefix("ms") { secs = value / 1000 } else if unit.hasPrefix("min") { secs = value * 60 } else { secs = value }
        return secs >= 0 && secs <= 86_400 ? (secs * 100).rounded() / 100 : nil
    }

    private static let plainSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:;()_+-/")

    /// Kurzer Text nur aus harmlosen Zeichen, wie der Dienst ihn annimmt (`_plain` in app/crash_reports.py)
    static func plain(_ s: String?, limit: Int) -> String? {
        guard let s else { return nil }
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter { plainSet.contains($0) }))
        let t = String(kept.trimmingCharacters(in: .whitespaces).prefix(limit))
        return t.isEmpty ? nil : t
    }

    private static func matches(_ s: String?, _ pattern: String) -> String? {
        guard let s, s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return s
    }

    static func version(_ s: String?) -> String? { matches(s, #"^[0-9][0-9A-Za-z.\-]{0,19}$"#) }
    static func build(_ s: String?) -> String? { matches(s, #"^[0-9A-Za-z.]{1,12}$"#) }
    static func model(_ s: String?) -> String? { matches(s, #"^[A-Za-z][A-Za-z0-9,_\-]{0,31}$"#) }
    static func name(_ s: String?) -> String? { matches(s, #"^[A-Za-z_][A-Za-z0-9_.]{0,79}$"#) }
    static func uuid(_ s: String?) -> String? {
        matches(s, #"^[0-9A-Fa-f]{8}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{12}$"#)?.uppercased()
    }
}

/// Anschluss an `POST /api/diagnose/crashes` (ohne Konto, ohne Sitzung)
public struct CrashReportClient: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// angenommen: die gesendeten Meldungen koennen weg
        case done
        /// abgelehnt (Format): ein zweiter Versuch aendert nichts, die Meldungen koennen weg
        case refused
        /// spaeter noch einmal (kein Netz, Dienst nicht erreichbar, Grenze erreicht)
        case later
    }

    public static let path = "/api/diagnose/crashes"
    public static let version = 1
    /// Meldungen je Anfrage (`MAX_REPORTS` im Dienst)
    public static let batch = 20

    public let base: String
    public let http: ServiceHTTPTransport

    public init(base: String, http: ServiceHTTPTransport) { self.base = base; self.http = http }

    /// Rumpf der Anfrage: Format-Version, Kennung der Installation (nur fuer die Tagesgrenze, siehe Dienst), Meldungen
    public static func body(install: String, reports: [CrashReport]) -> JSONValue {
        .object(["v": .number(Double(version)), "install": .string(install), "reports": .array(reports.map(\.json))])
    }

    public func send(install: String, reports: [CrashReport]) async -> Outcome {
        let url = (base.hasSuffix("/") ? String(base.dropLast()) : base) + Self.path
        let req = AIHTTPRequest(method: "POST", url: url, headers: ["Accept": "application/json", "Content-Type": "application/json"],
                                body: Self.body(install: install, reports: reports).serialized())
        guard let resp = try? await http.send(req) else { return .later }
        switch resp.status {
        case 200: return .done
        case 400, 413, 422: return .refused
        default: return .later
        }
    }
}

/// Warteschlange der Meldungen in einer kleinen Datei. MetricKit liefert, wann es will (meist beim naechsten Start,
/// oft erst am Folgetag) und auch ohne Netz; gesendet wird beim Start und nach jedem Empfang.
public actor CrashReportOutbox {
    /// Hoechstens so viele Meldungen warten; die aeltesten fallen weg
    public static let maxPending = 60
    /// Aeltere Meldungen nimmt der Dienst nicht mehr an (`MAX_AGE_DAYS`)
    public static let maxAge: TimeInterval = 30 * 86_400

    private let file: URL

    public init(file: URL) { self.file = file }

    public func pending() -> [CrashReport] { load() }

    public func add(_ new: [CrashReport], now: Date = Date()) {
        guard !new.isEmpty else { return }
        var all = load()
        let known = Set(all.map(\.id))
        all += new.filter { !known.contains($0.id) }
        save(trimmed(all, now: now))
    }

    /// Alles verwerfen (Schalter aus)
    public func clear() { try? FileManager.default.removeItem(at: file) }

    /// Wartende Meldungen an den Dienst geben, in Paketen; liefert, wie viele die Warteschlange verlassen haben.
    /// Endet beim ersten "spaeter" - der naechste Start versucht es wieder.
    @discardableResult
    public func flush(install: String, client: CrashReportClient, now: Date = Date()) async -> Int {
        var gone = 0
        for _ in 0..<(Self.maxPending / CrashReportClient.batch + 1) {
            let all = trimmed(load(), now: now)
            let part = Array(all.prefix(CrashReportClient.batch))
            guard !part.isEmpty else { break }
            let outcome = await client.send(install: install, reports: part)
            guard outcome != .later else { break }
            let sent = Set(part.map(\.id))
            save(load().filter { !sent.contains($0.id) })       // neu lesen: waehrend des Sendens kann etwas dazugekommen sein
            gone += part.count
        }
        return gone
    }

    private func trimmed(_ all: [CrashReport], now: Date) -> [CrashReport] {
        Array(all.filter { now.timeIntervalSince($0.at) <= Self.maxAge }.suffix(Self.maxPending))
    }

    private func load() -> [CrashReport] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode([CrashReport].self, from: data)) ?? []
    }

    private func save(_ all: [CrashReport]) {
        if all.isEmpty { try? FileManager.default.removeItem(at: file); return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
