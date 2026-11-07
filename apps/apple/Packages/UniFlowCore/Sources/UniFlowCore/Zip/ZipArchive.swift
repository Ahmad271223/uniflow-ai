import Foundation

/// ZIP-Dateien lesen, sicher entpacken und packen (Wunsch des Inhabers 07.11.2026: Uebungs-ZIPs aus Stud.IP/Moodle in
/// StudiNow oeffnen und bearbeiten). Ohne Fremdbibliothek: Zentralverzeichnis lesen (auch ZIP64), Eintraege
/// ungepackt (Methode 0) oder mit raw DEFLATE (Methode 8, `SolutionDeflate`, auf iOS das Compression-Framework).
///
/// Sicherheit beim Entpacken:
/// - Zip-Slip: jeder Name geht durch `safePath` (kein "..", kein absoluter Pfad, kein Laufwerk, keine Steuerzeichen);
///   unsichere Eintraege und symbolische Links werden uebersprungen und gezaehlt, nie ausserhalb des Ziels geschrieben.
/// - ZIP-Bomben: hoechstens `Limits.maxEntries` Eintraege, die angegebenen Groessen zusammen hoechstens
///   `maxTotalBytes`, je Eintrag `maxEntryBytes`; beim Entpacken entsteht nie mehr als die angegebene Groesse
///   (`SolutionDeflate.inflate(limit:)`), danach wird die CRC-32 geprueft.
/// - Verschluesselte ZIPs (Bit 0 oder AES, Methode 99) ergeben `Failure.encrypted` mit klarer Meldung.
public enum ZipArchive {
    public struct Limits: Sendable, Equatable {
        public var maxEntries: Int
        public var maxTotalBytes: Int
        public var maxEntryBytes: Int
        /// Ordnertiefe eines Eintrags
        public var maxDepth: Int

        public init(maxEntries: Int, maxTotalBytes: Int, maxEntryBytes: Int, maxDepth: Int = 32) {
            self.maxEntries = maxEntries
            self.maxTotalBytes = maxTotalBytes
            self.maxEntryBytes = maxEntryBytes
            self.maxDepth = maxDepth
        }

        /// Fuer Uebungs-ZIPs reichlich: 5000 Dateien, zusammen 1 GB, je Datei 300 MB
        public static let standard = Limits(maxEntries: 5000, maxTotalBytes: 1 << 30, maxEntryBytes: 300 << 20)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notZip
        case corrupt
        case encrypted
        case tooManyEntries(Int)
        case tooLarge
        case unsupported(String)
        case unsafePath(String)

        public var errorDescription: String? {
            switch self {
            case .notZip: return "Die Datei ist keine ZIP-Datei."
            case .corrupt: return "Die ZIP-Datei ist beschädigt oder unvollständig."
            case .encrypted:
                return "Diese ZIP-Datei ist mit einem Passwort verschlüsselt. StudiNow kann verschlüsselte ZIP-Dateien nicht öffnen – mit „Öffnen in …“ geht es in einer anderen App."
            case .tooManyEntries(let n):
                return "Die ZIP-Datei enthält zu viele Einträge (\(n)). StudiNow entpackt höchstens \(Limits.standard.maxEntries)."
            case .tooLarge:
                return "Die ZIP-Datei wäre entpackt zu groß (Schutz vor ZIP-Bomben, höchstens 1 GB)."
            case .unsupported(let what): return "Dieses ZIP-Format wird nicht unterstützt (\(what))."
            case .unsafePath(let p): return "Unsicherer Dateiname in der ZIP-Datei: \(p)"
            }
        }
    }

    /// Ein Eintrag des Zentralverzeichnisses
    public struct Entry: Sendable, Equatable {
        /// Name wie in der ZIP-Datei (UTF-8 oder CP437)
        public let rawName: String
        /// Bereinigter relativer Pfad ohne "/" am Ende; nil = unsicher (Zip-Slip), wird nicht entpackt
        public let path: String?
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let method: UInt16
        public let encrypted: Bool
        public let crc32: UInt32
        public let compressedSize: Int
        public let size: Int
        let localHeaderOffset: Int
    }

    /// Ergebnis von `extract`
    public struct Summary: Sendable, Equatable {
        public var files = 0
        public var folders = 0
        public var bytes = 0
        /// unsichere Pfade und symbolische Links (nicht entpackt)
        public var unsafe: [String] = []
        /// Eintraege, die sich nicht lesen liessen (unbekanntes Packverfahren, CRC falsch)
        public var unreadable: [String] = []
        public init() {}
    }

    // MARK: Erkennen

    public static func isZipName(_ name: String) -> Bool { name.lowercased().hasSuffix(".zip") }

    /// Beginnt wie eine ZIP-Datei (lokaler Kopf oder leeres Archiv)
    public static func looksLikeZip(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x50, 0x4b, 0x05, 0x06])
    }

    // MARK: Pfade

    /// Relativer, sicherer Pfad aus einem Eintragsnamen; nil, wenn er aus dem Ziel heraus fuehren koennte ("..",
    /// absolut, Laufwerk "C:"), Steuerzeichen enthaelt oder leer ist. "\" gilt als Trenner (Windows-ZIPs), "." und
    /// leere Teile fallen weg.
    public static func safePath(_ raw: String, maxDepth: Int = 32) -> String? {
        let name = raw.replacingOccurrences(of: "\\", with: "/")
        guard !name.hasPrefix("/"), !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        var parts: [String] = []
        for p in name.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(p)
            if s == "." { continue }
            if s == ".." { return nil }
            if s.count > 255 { return nil }
            parts.append(s.precomposedStringWithCanonicalMapping)
        }
        guard let first = parts.first, parts.count <= maxDepth else { return nil }
        // Laufwerksbuchstabe ("C:") am Anfang
        if first.count == 2, first.hasSuffix(":") { return nil }
        return parts.joined(separator: "/")
    }

    /// Ordner, die Packprogramme nebenbei anlegen (macOS-Ressourcen, Finder-Dateien) und die niemand bearbeiten will
    public static func isJunk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.first == "__MACOSX" || parts.last == ".DS_Store" || parts.last == "Thumbs.db"
    }

    // MARK: Lesen

    /// Alle Eintraege; wirft bei kaputtem Archiv, Verschluesselung und ueberschrittenen Grenzen (vor dem Entpacken)
    public static func entries(_ data: Data, limits: Limits = .standard) throws -> [Entry] {
        let b = [UInt8](data)
        guard b.count >= 22 else { throw looksLikeZip(data) ? Failure.corrupt : Failure.notZip }
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65535)
        while i >= stop {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw looksLikeZip(data) ? Failure.corrupt : Failure.notZip }
        var count = Int(u16(b, eocd + 10))
        var cdSize = Int(u32(b, eocd + 12))
        var cdOffset = Int(u32(b, eocd + 16))
        // ZIP64: Locator 20 Byte vor dem Ende-Satz
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let loc = eocd - 20
            guard loc >= 0, u32(b, loc) == 0x0706_4b50 else { throw Failure.corrupt }
            let rec = u64(b, loc + 8)
            guard rec >= 0, rec + 56 <= b.count, u32(b, rec) == 0x0606_4b50 else { throw Failure.corrupt }
            count = u64(b, rec + 32)
            cdSize = u64(b, rec + 40)
            cdOffset = u64(b, rec + 48)
        }
        guard count >= 0 else { throw Failure.corrupt }
        guard count <= limits.maxEntries else { throw Failure.tooManyEntries(count) }
        guard cdOffset >= 0, cdSize >= 0, cdOffset <= b.count, cdSize <= b.count - cdOffset else { throw Failure.corrupt }
        var out: [Entry] = []
        out.reserveCapacity(count)
        var total = 0
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4b50 else { throw Failure.corrupt }
            let madeBy = u16(b, p + 4)
            let flags = u16(b, p + 8)
            let method = u16(b, p + 10)
            let crc = u32(b, p + 16)
            var csize = Int(u32(b, p + 20)), usize = Int(u32(b, p + 24))
            let nlen = Int(u16(b, p + 28)), xlen = Int(u16(b, p + 30)), clen = Int(u16(b, p + 32))
            let external = u32(b, p + 38)
            var offset = Int(u32(b, p + 42))
            guard p + 46 + nlen + xlen + clen <= b.count else { throw Failure.corrupt }
            let nameBytes = Array(b[(p + 46)..<(p + 46 + nlen)])
            // ZIP64-Zusatzfeld (0x0001): nur die Werte, die im Kopf 0xFFFFFFFF sind, in dieser Reihenfolge
            if usize == 0xFFFF_FFFF || csize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                var x = p + 46 + nlen
                let xend = x + xlen
                var found = false
                while x + 4 <= xend {
                    let id = u16(b, x), len = Int(u16(b, x + 2))
                    guard x + 4 + len <= xend else { break }
                    if id == 0x0001 {
                        var q = x + 4
                        if usize == 0xFFFF_FFFF { guard q + 8 <= x + 4 + len else { throw Failure.corrupt }; usize = u64(b, q); q += 8 }
                        if csize == 0xFFFF_FFFF { guard q + 8 <= x + 4 + len else { throw Failure.corrupt }; csize = u64(b, q); q += 8 }
                        if offset == 0xFFFF_FFFF { guard q + 8 <= x + 4 + len else { throw Failure.corrupt }; offset = u64(b, q); q += 8 }
                        found = true
                        break
                    }
                    x += 4 + len
                }
                guard found else { throw Failure.corrupt }
            }
            guard usize >= 0, csize >= 0, offset >= 0 else { throw Failure.corrupt }
            let utf8 = flags & 0x0800 != 0
            let raw = utf8 ? String(decoding: nameBytes, as: UTF8.self) : decodeLegacyName(nameBytes)
            let isDir = raw.hasSuffix("/") || raw.hasSuffix("\\")
            // Unix (made by 3): Dateityp in den oberen 16 Bit der externen Attribute; 0o120000 = symbolischer Link
            let isLink = (madeBy >> 8) == 3 && (external >> 16) & 0o170000 == 0o120000
            let encrypted = flags & 0x0001 != 0 || method == 99
            let entry = Entry(rawName: raw, path: safePath(raw, maxDepth: limits.maxDepth), isDirectory: isDir, isSymlink: isLink,
                              method: method, encrypted: encrypted, crc32: crc, compressedSize: csize, size: usize,
                              localHeaderOffset: offset)
            if encrypted && !isDir { throw Failure.encrypted }
            if !isDir {
                guard usize <= limits.maxEntryBytes else { throw Failure.tooLarge }
                total += usize
                guard total <= limits.maxTotalBytes else { throw Failure.tooLarge }
            }
            out.append(entry)
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    /// Inhalt eines Eintrags; prueft Groesse und CRC-32
    public static func read(_ e: Entry, from data: Data) throws -> Data {
        if e.encrypted { throw Failure.encrypted }
        let h = e.localHeaderOffset
        guard h >= 0, h + 30 <= data.count else { throw Failure.corrupt }
        let head = [UInt8](data[data.startIndex + h ..< data.startIndex + h + 30])
        guard u32(head, 0) == 0x0403_4b50 else { throw Failure.corrupt }
        let nlen = Int(u16(head, 26)), xlen = Int(u16(head, 28))
        let start = h + 30 + nlen + xlen
        guard start <= data.count, e.compressedSize <= data.count - start else { throw Failure.corrupt }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        let out: Data
        switch e.method {
        case 0:
            guard raw.count == e.size else { throw Failure.corrupt }
            out = raw
        case 8:
            do {
                out = try SolutionDeflate.inflate(raw, limit: e.size)
            } catch SolutionError.tooLarge {
                throw Failure.tooLarge
            } catch {
                throw Failure.corrupt
            }
            guard out.count == e.size else { throw Failure.corrupt }
        case 9: throw Failure.unsupported("Deflate64")
        case 12: throw Failure.unsupported("BZIP2")
        case 14: throw Failure.unsupported("LZMA")
        default: throw Failure.unsupported("Methode \(e.method)")
        }
        guard crc32(out) == e.crc32 else { throw Failure.corrupt }
        return out
    }

    /// Alles nach `directory` entpacken (der Ordner wird angelegt). Unsichere Pfade, Links und macOS-Beiwerk
    /// (`isJunk`) werden uebersprungen; ein Eintrag, der sich nicht lesen laesst, steht in `unreadable`.
    @discardableResult
    public static func extract(_ data: Data, to directory: URL, limits: Limits = .standard) throws -> Summary {
        let list = try entries(data, limits: limits)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory
        var s = Summary()
        var made = Set<String>()
        func ensureDir(_ rel: String) throws -> Bool {
            if rel.isEmpty || made.contains(rel) { return true }
            let url = try inside(base, rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                guard isDir.boolValue else { return false }                    // Datei gleichen Namens: Eintrag auslassen
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                s.folders += 1
            }
            made.insert(rel)
            return true
        }
        for e in list {
            guard let path = e.path, !e.isSymlink else { s.unsafe.append(e.rawName); continue }
            if isJunk(path) { continue }
            if e.isDirectory {
                if try !ensureDir(path) { s.unreadable.append(e.rawName) }
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            var ok = true
            var acc = ""
            for part in parent.split(separator: "/") {
                acc = acc.isEmpty ? String(part) : acc + "/" + part
                if try !ensureDir(acc) { ok = false; break }
            }
            guard ok else { s.unreadable.append(e.rawName); continue }
            let content: Data
            do {
                content = try read(e, from: data)
            } catch Failure.tooLarge {
                throw Failure.tooLarge
            } catch {
                s.unreadable.append(e.rawName)
                continue
            }
            let url = try inside(base, path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { s.unreadable.append(e.rawName); continue }
            try content.write(to: url, options: .atomic)
            s.files += 1
            s.bytes += content.count
        }
        return s
    }

    /// URL von `rel` (schon `safePath`) unter `base`; wirft, wenn ein vorhandener Teil des Wegs ein symbolischer
    /// Link ist (er koennte aus dem Ziel heraus zeigen) oder der Pfad nicht sicher ist
    static func inside(_ base: URL, _ rel: String) throws -> URL {
        guard let safe = safePath(rel) else { throw Failure.unsafePath(rel) }
        let fm = FileManager.default
        var url = base
        for part in safe.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
            if let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw Failure.unsafePath(rel)
            }
        }
        return url
    }

    // MARK: Packen

    /// Eintrag zum Packen: `data == nil` ist ein Ordner
    public struct Item: Sendable {
        public var path: String
        public var data: Data?
        public var modified: Date
        public init(path: String, data: Data?, modified: Date = Date()) {
            self.path = path
            self.data = data
            self.modified = modified
        }
    }

    /// ZIP aus Eintraegen (UTF-8-Namen, DEFLATE wenn kleiner, sonst ungepackt). Kein ZIP64: hoechstens 65535
    /// Eintraege und zusammen unter 4 GB.
    public static func pack(_ items: [Item]) throws -> Data {
        guard items.count < 0xFFFF else { throw Failure.tooManyEntries(items.count) }
        var out = Data()
        var central = Data()
        for it in items {
            guard let safe = safePath(it.path) else { throw Failure.unsafePath(it.path) }
            let isDir = it.data == nil
            let name = Data((isDir ? safe + "/" : safe).utf8)
            guard name.count <= 0xFFFF else { throw Failure.unsafePath(it.path) }
            let plain = it.data ?? Data()
            let crc = crc32(plain)
            var method: UInt16 = 0
            var body = plain
            if !isDir, plain.count > 64, let packed = try? SolutionDeflate.deflate(plain), packed.count < plain.count {
                method = 8
                body = packed
            }
            let offset = out.count
            guard offset < 0xFFFF_FFFF, plain.count < 0xFFFF_FFFF, body.count < 0xFFFF_FFFF else { throw Failure.tooLarge }
            let (time, date) = dosTime(it.modified)
            // lokaler Kopf
            put32(&out, 0x0403_4b50); put16(&out, 20); put16(&out, 0x0800); put16(&out, method)
            put16(&out, time); put16(&out, date); put32(&out, crc)
            put32(&out, UInt32(body.count)); put32(&out, UInt32(plain.count))
            put16(&out, UInt16(name.count)); put16(&out, 0)
            out.append(name)
            out.append(body)
            // Zentralverzeichnis (made by Unix 2.0: Rechte 644 bzw. 755 fuer Ordner)
            put32(&central, 0x0201_4b50); put16(&central, 0x0314); put16(&central, 20); put16(&central, 0x0800)
            put16(&central, method); put16(&central, time); put16(&central, date); put32(&central, crc)
            put32(&central, UInt32(body.count)); put32(&central, UInt32(plain.count))
            put16(&central, UInt16(name.count)); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
            put32(&central, isDir ? (UInt32(0o040755) << 16) | 0x10 : UInt32(0o100644) << 16)
            put32(&central, UInt32(offset))
            central.append(name)
        }
        let cdOffset = out.count
        guard cdOffset < 0xFFFF_FFFF, central.count < 0xFFFF_FFFF else { throw Failure.tooLarge }
        out.append(central)
        put32(&out, 0x0605_4b50); put16(&out, 0); put16(&out, 0)
        put16(&out, UInt16(items.count)); put16(&out, UInt16(items.count))
        put32(&out, UInt32(central.count)); put32(&out, UInt32(cdOffset)); put16(&out, 0)
        return out
    }

    /// Ordnerinhalt packen (Unterordner, auch leere; versteckte Dateien und Links nicht), Namen sortiert.
    /// `replacing`: relativer Pfad -> anderer Inhalt (z. B. PDF mit Notizen statt des Originals)
    public static func pack(directory: URL, replacing: [String: Data] = [:]) throws -> Data {
        try pack(items(in: directory, replacing: replacing))
    }

    static func items(in directory: URL, replacing: [String: Data] = [:]) throws -> [Item] {
        let fm = FileManager.default
        var out: [Item] = []
        func walk(_ dir: URL, _ rel: String) throws {
            let names = try fm.contentsOfDirectory(atPath: dir.path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for n in names where !n.hasPrefix(".") {
                let url = dir.appendingPathComponent(n)
                let path = rel.isEmpty ? n : rel + "/" + n
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let type = attrs[.type] as? FileAttributeType
                let modified = attrs[.modificationDate] as? Date ?? Date()
                if type == .typeSymbolicLink { continue }
                if type == .typeDirectory {
                    out.append(Item(path: path, data: nil, modified: modified))
                    try walk(url, path)
                } else {
                    out.append(Item(path: path, data: try replacing[path] ?? Data(contentsOf: url), modified: modified))
                }
            }
        }
        try walk(directory, "")
        return out
    }

    // MARK: Hilfen

    /// CRC-32 (IEEE, wie zlib)
    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Obere Haelfte von Codepage 437 (Namen ohne UTF-8-Kennzeichen, z. B. aus dem Windows-Explorer: "ü" = 0x81)
    static let cp437High: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    /// Name ohne UTF-8-Kennzeichen: gueltiges UTF-8 (macOS, viele Packer) bleibt, sonst CP437
    static func decodeLegacyName(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes.map { $0 < 0x80 ? Character(Unicode.Scalar($0)) : cp437High[Int($0) - 0x80] })
    }

    static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980), 1980), 2107)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    private static func put16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    private static func put32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8(v >> 24))
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    /// 64-Bit-Wert als Int; zu gross ergibt -1 (gilt als kaputt)
    private static func u64(_ b: [UInt8], _ i: Int) -> Int {
        let lo = UInt64(u32(b, i)), hi = UInt64(u32(b, i + 4))
        let v = hi << 32 | lo
        return v > UInt64(Int.max) ? -1 : Int(v)
    }
}
