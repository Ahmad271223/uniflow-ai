import Foundation
#if canImport(Compression)
import Compression
#endif

/// Raw DEFLATE (RFC 1951, ohne zlib-Kopf) fuer Loesungspakete ab Formatversion 2 (docs/LOESUNGEN-TEILEN.md 3a).
///
/// - iOS/macOS: `Compression`-Framework mit `COMPRESSION_ZLIB` (das ist raw DEFLATE), als Strom mit fester
///   Puffergroesse, damit beim Entpacken nie mehr als `limit` Byte entstehen (Zip-Bomben).
/// - Linux (CI, `swift test` ohne Compression): eigene kleine Umsetzung, Entpacken vollstaendig nach RFC 1951,
///   Packen nur mit unkomprimierten Bloecken (gueltiges DEFLATE, nur nicht kleiner). Pakete erzeugt die App auf dem
///   iPad; unter Linux laufen nur Tests.
///
/// Gepackte Bytes muessen zwischen Python (zlib), Browser (CompressionStream) und Swift nicht gleich sein; gleich ist
/// der entpackte Klartext.
public enum SolutionDeflate {
    /// Packen. Wirft nur, wenn das System den Strom nicht anlegen kann.
    public static func deflate(_ data: Data) throws -> Data {
        #if canImport(Compression)
        return try process(data, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max)
        #else
        return storedBlocks(data)
        #endif
    }

    /// Entpacken, hoechstens `limit` Byte: mehr ergibt `SolutionError.tooLarge`, kaputte, abgeschnittene oder mit
    /// Zusatzbytes versehene Daten `invalidContent("Kompression")`.
    public static func inflate(_ data: Data, limit: Int) throws -> Data {
        #if canImport(Compression)
        return try process(data, operation: COMPRESSION_STREAM_DECODE, limit: limit)
        #else
        return try inflatePortable(data, limit: limit)
        #endif
    }

    static var corrupt: SolutionError { .invalidContent("Kompression") }

    #if canImport(Compression)
    private static func process(_ input: Data, operation: compression_stream_operation, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw corrupt }
        defer { compression_stream_destroy(stream) }
        let size = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var out = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let empty: UInt8 = 0
            try withUnsafePointer(to: empty) { emptyPtr in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? emptyPtr
                stream.pointee.src_size = raw.count
                while true {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = size
                    let before = stream.pointee.src_size
                    let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { throw corrupt }
                    let produced = size - stream.pointee.dst_size
                    guard produced <= limit - out.count else { throw SolutionError.tooLarge }
                    out.append(buffer, count: produced)
                    if status == COMPRESSION_STATUS_END {
                        // Zusatzbytes nach dem letzten Block: Python, Browser und `inflatePortable` weisen sie ab, das
                        // Compression-Framework verbraucht sie stillschweigend. Unkritisch: das Gepackte ist per
                        // AES-GCM authentifiziert, Zusatzbytes kann nur der Absender selbst einfuegen; Inhalt und
                        // Groesse werden danach ohnehin streng geprueft.
                        guard stream.pointee.src_size == 0 else { throw corrupt }
                        return
                    }
                    // kein Fortschritt (Packen und Entpacken) bzw. abgeschnittene Daten (Entpacken: keine Eingabe mehr,
                    // nichts mehr erzeugt, aber kein Ende): nie endlos warten
                    if produced == 0 && (stream.pointee.src_size == before
                                         || (operation == COMPRESSION_STREAM_DECODE && stream.pointee.src_size == 0)) { throw corrupt }
                }
            }
        }
        return out
    }
    #endif

    /// Unkomprimierte DEFLATE-Bloecke (BTYPE 00), hoechstens 65 535 Byte je Block.
    static func storedBlocks(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 65_535 * 5 + 5)
        var at = 0
        repeat {
            let n = min(65_535, bytes.count - at)
            let last: UInt8 = at + n >= bytes.count ? 1 : 0
            out.append(last)
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += bytes[at..<(at + n)]
            at += n
        } while at < bytes.count
        return Data(out)
    }

    // MARK: Entpacken ohne Compression (RFC 1951, nach dem Muster von zlibs "puff")

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        /// `nil` bei ueberbelegtem Code.
        init?(lengths: ArraySlice<Int>) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
                if left < 0 { return nil }
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (i, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = i
                offs[l] += 1
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        var buf: UInt32 = 0
        var cnt = 0

        mutating func bits(_ n: Int) throws -> Int {
            var val = buf
            while cnt < n {
                guard pos < bytes.count else { throw SolutionDeflate.corrupt }
                val |= UInt32(bytes[pos]) << UInt32(cnt)
                pos += 1
                cnt += 8
            }
            buf = n == 32 ? 0 : val >> UInt32(n)
            cnt -= n
            return Int(val & ((1 << UInt32(n)) - 1))
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let c = h.count[len]
                if code - c < first { return h.symbol[index + (code - first)] }
                index += c
                first += c
                first <<= 1
                code <<= 1
            }
            throw SolutionDeflate.corrupt
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                   4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (Huffman(lengths: l[...])!, Huffman(lengths: [Int](repeating: 5, count: 30)[...])!)
    }()

    /// Plattformunabhaengiges Entpacken (unter Linux im Einsatz, auf dem Mac in den Tests gegen Python geprueft).
    static func inflatePortable(_ data: Data, limit: Int) throws -> Data {
        var r = Reader(bytes: [UInt8](data))
        var out: [UInt8] = []
        var last = 0
        repeat {
            last = try r.bits(1)
            switch try r.bits(2) {
            case 0:
                r.buf = 0
                r.cnt = 0
                guard r.pos + 4 <= r.bytes.count else { throw corrupt }
                let len = Int(r.bytes[r.pos]) | Int(r.bytes[r.pos + 1]) << 8
                let nlen = Int(r.bytes[r.pos + 2]) | Int(r.bytes[r.pos + 3]) << 8
                guard len == ~nlen & 0xFFFF else { throw corrupt }
                r.pos += 4
                guard r.pos + len <= r.bytes.count else { throw corrupt }
                guard len <= limit - out.count else { throw SolutionError.tooLarge }
                out += r.bytes[r.pos..<(r.pos + len)]
                r.pos += len
            case 1:
                try codes(&r, &out, fixed.0, fixed.1, limit: limit)
            case 2:
                let nlen = try r.bits(5) + 257, ndist = try r.bits(5) + 1, ncode = try r.bits(4) + 4
                guard nlen <= 286, ndist <= 30 else { throw corrupt }
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var lengths = [Int](repeating: 0, count: 320)
                for i in 0..<ncode { lengths[order[i]] = try r.bits(3) }
                guard let lencode = Huffman(lengths: lengths[0..<19]) else { throw corrupt }
                var i = 0
                while i < nlen + ndist {
                    let sym = try r.decode(lencode)
                    if sym < 16 {
                        lengths[i] = sym
                        i += 1
                        continue
                    }
                    var value = 0, repeatCount: Int
                    switch sym {
                    case 16:
                        guard i > 0 else { throw corrupt }
                        value = lengths[i - 1]
                        repeatCount = 3 + (try r.bits(2))
                    case 17: repeatCount = 3 + (try r.bits(3))
                    default: repeatCount = 11 + (try r.bits(7))
                    }
                    guard i + repeatCount <= nlen + ndist else { throw corrupt }
                    for _ in 0..<repeatCount {
                        lengths[i] = value
                        i += 1
                    }
                }
                guard lengths[256] != 0,
                      let lit = Huffman(lengths: lengths[0..<nlen]),
                      let dist = Huffman(lengths: lengths[nlen..<(nlen + ndist)]) else { throw corrupt }
                try codes(&r, &out, lit, dist, limit: limit)
            default:
                throw corrupt
            }
        } while last == 0
        guard r.pos == r.bytes.count else { throw corrupt }
        return Data(out)
    }

    private static func codes(_ r: inout Reader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman, limit: Int) throws {
        while true {
            var sym = try r.decode(lit)
            if sym < 256 {
                guard out.count < limit else { throw SolutionError.tooLarge }
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                sym -= 257
                guard sym < 29 else { throw corrupt }
                let len = lengthBase[sym] + (try r.bits(lengthExtra[sym]))
                let ds = try r.decode(dist)
                guard ds < 30 else { throw corrupt }
                let d = distBase[ds] + (try r.bits(distExtra[ds]))
                guard d <= out.count else { throw corrupt }
                guard len <= limit - out.count else { throw SolutionError.tooLarge }
                let start = out.count - d
                for k in 0..<len { out.append(out[start + k]) }
            }
        }
    }
}
