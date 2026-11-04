import Foundation

/// Kleiner ZIP-Leser fuer Office-Dateien (docx, pptx sind ZIP-Pakete), ohne Fremdbibliothek: Zentralverzeichnis
/// lesen, Eintraege ungepackt (Methode 0) oder mit raw DEFLATE (Methode 8, `SolutionDeflate.inflate` wie die
/// Loesungspakete ab Formatversion 2) entpacken. Kein ZIP64, keine Verschluesselung (Office-Dateien brauchen beides
/// nicht); ein Eintrag wird hoechstens `limit` Byte gross (Zip-Bomben).
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum Failure: Error { case notZip, corrupt, unsupported, tooLarge }

    let data: Data
    private(set) var entries: [String: Entry] = [:]
    /// Namen in der Reihenfolge des Zentralverzeichnisses
    private(set) var names: [String] = []

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw Failure.notZip }
        // End of central directory: Signatur 0x06054b50, von hinten gesucht (Kommentar bis 65535 Byte)
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65535)
        while i >= stop {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = Int(Self.u16(bytes, eocd + 10))
        let cdSize = Int(Self.u32(bytes, eocd + 12))
        let cdOffset = Int(Self.u32(bytes, eocd + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= bytes.count else { throw Failure.corrupt }
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Self.u32(bytes, p) == 0x0201_4b50 else { throw Failure.corrupt }
            let method = Self.u16(bytes, p + 10)
            let csize = Self.u32(bytes, p + 20), usize = Self.u32(bytes, p + 24)
            let nlen = Int(Self.u16(bytes, p + 28)), xlen = Int(Self.u16(bytes, p + 30)), clen = Int(Self.u16(bytes, p + 32))
            let offset = Self.u32(bytes, p + 42)
            guard p + 46 + nlen <= bytes.count else { throw Failure.corrupt }
            guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            let e = Entry(name: name, method: method, compressedSize: Int(csize), uncompressedSize: Int(usize), localHeaderOffset: Int(offset))
            if entries[name] == nil { names.append(name) }
            entries[name] = e
            p += 46 + nlen + xlen + clen
        }
    }

    /// Inhalt eines Eintrags; nil, wenn es ihn nicht gibt
    func read(_ name: String, limit: Int) throws -> Data? {
        guard let e = entries[name] else { return nil }
        guard e.uncompressedSize <= limit else { throw Failure.tooLarge }
        let bytes = [UInt8](data)
        let h = e.localHeaderOffset
        guard h >= 0, h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4b50 else { throw Failure.corrupt }
        let nlen = Int(Self.u16(bytes, h + 26)), xlen = Int(Self.u16(bytes, h + 28))
        let start = h + 30 + nlen + xlen
        guard start >= 0, start + e.compressedSize <= bytes.count else { throw Failure.corrupt }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0:
            return raw
        case 8:
            do {
                let out = try SolutionDeflate.inflate(raw, limit: limit)
                guard out.count == e.uncompressedSize else { throw Failure.corrupt }
                return out
            } catch SolutionError.tooLarge {
                throw Failure.tooLarge
            } catch {
                throw Failure.corrupt
            }
        default:
            throw Failure.unsupported
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
