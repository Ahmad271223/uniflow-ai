import Foundation

/// SHA-1 (FIPS 180-4) und MD5 (RFC 1321) ohne CryptoKit, damit der Kern auch unter Linux baut (wie SolutionSHA256).
/// Nur fuer Kennungen und Pruefsummen, die Moodle bzw. der PC so vorgeben: Datei-ID `lw-<cmid>-<sha1[:8]>`
/// (app/learnweb.py) und die passport-Pruefung der Moodle-SSO-Antwort (md5(wwwroot + passport)).
/// Nicht fuer Sicherheit verwenden.
public enum InsecureHash {
    public static func sha1Hex(_ s: String) -> String { hex(sha1(Data(s.utf8))) }
    public static func md5Hex(_ s: String) -> String { hex(md5(Data(s.utf8))) }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Nachricht + 0x80 + Nullen + Laenge in Bit (64 Bit; gross-endian fuer SHA-1, klein-endian fuer MD5)
    private static func padded(_ data: Data, bigEndian: Bool) -> [UInt8] {
        var m = [UInt8](data)
        let bits = UInt64(m.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in 0..<8 {
            let shift = bigEndian ? UInt64(56 - 8 * i) : UInt64(8 * i)
            m.append(UInt8((bits >> shift) & 0xff))
        }
        return m
    }

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    public static func sha1(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        let m = padded(data, bigEndian: true)
        var w = [UInt32](repeating: 0, count: 80)
        for block in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 {
                let i = block + 4 * t
                w[t] = UInt32(m[i]) << 24 | UInt32(m[i + 1]) << 16 | UInt32(m[i + 2]) << 8 | UInt32(m[i + 3])
            }
            for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> UInt32(24 - 8 * $0)) & 0xff) } }
    }

    private static let md5Shift: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                             5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                             4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                             6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    /// floor(abs(sin(i + 1)) * 2^32)
    private static let md5K: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }

    public static func md5(_ data: Data) -> [UInt8] {
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        let m = padded(data, bigEndian: false)
        var w = [UInt32](repeating: 0, count: 16)
        for block in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 {
                let i = block + 4 * t
                w[t] = UInt32(m[i]) | UInt32(m[i + 1]) << 8 | UInt32(m[i + 2]) << 16 | UInt32(m[i + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ md5K[i] &+ w[g]
                a = d; d = c; c = b
                b = b &+ rotl(f, md5Shift[i])
            }
            a0 &+= a; b0 &+= b; c0 &+= c; d0 &+= d
        }
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8((v >> UInt32(8 * $0)) & 0xff) } }
    }
}
