import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Welche Seiten mit Bild zur KI gehen: Seiten mit Abbildungen, Tabellen, Formeln oder Scans (Text + Bild), reine
/// Textseiten nur als Text. Die Regel ist rein (auch unter Linux pruefbar); die Messwerte liest `DocIndexPages` mit
/// CoreGraphics aus der PDF (Bild-XObjects, Pfadbefehle im Inhaltsstrom, Buchstaben, Mathezeichen).
public enum DocIndexPageRule {
    public enum Kind: String, Sendable { case text, figure }

    public struct Probe: Equatable, Sendable {
        public var letters: Int
        public var images: Int
        public var pathOps: Int
        public var mathSymbols: Int
        public var contentBytes: Int

        public init(letters: Int, images: Int, pathOps: Int, mathSymbols: Int, contentBytes: Int = 0) {
            self.letters = letters; self.images = images; self.pathOps = pathOps; self.mathSymbols = mathSymbols; self.contentBytes = contentBytes
        }

        public var kind: Kind { DocIndexPageRule.decide(self) }
    }

    /// ab so vielen Pfadbefehlen (Linien, Kurven, Rechtecke) gilt die Seite als Diagramm oder Tabelle
    public static let minPathOps = 40
    /// ab so vielen Mathezeichen (inkl. "=") als Formelseite
    public static let minMathSymbols = 6
    static let mathSet = Set("∑∫√≤≥≠∂∞→←⇒⇔∈∉⊂⊆∪∩∀∃λαβγδεθμπσφωΩ±×÷·⋅=")

    /// Mathezeichen und Gleichheitszeichen im Text
    public static func mathSymbols(in text: String) -> Int { text.reduce(0) { $0 + (mathSet.contains($1) ? 1 : 0) } }

    /// Bild dabei, wenn die Seite ein eingebettetes Bild hat, fast keinen Text (Scan, Folie als Bild), viele Pfadbefehle
    /// (Diagramm, Tabelle) oder viele Mathezeichen (Formeln, deren Textebene oft unvollstaendig ist)
    public static func decide(_ p: Probe) -> Kind {
        if p.images > 0 || p.letters < DocIndexFingerprint.minimumLetters || p.pathOps >= minPathOps || p.mathSymbols >= minMathSymbols {
            return .figure
        }
        return .text
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
/// Messwerte und Bild einer PDF-Seite mit CoreGraphics (iPad, Mac): ohne UIKit, nicht auf dem Hauptthread.
public enum DocIndexPages {
    /// Breite des Bilds fuer die KI in Pixeln (etwa 1200, Vorgabe des Inhabers)
    public static let imageWidth = 1200
    /// Breite fuer "Neu erklaeren lassen" (volle Aufloesung)
    public static let fullImageWidth = 2000
    public static let jpegQuality = 0.72

    static func document(_ url: URL) -> CGPDFDocument? {
        guard let doc = CGPDFDocument(url as CFURL), !doc.isEncrypted || doc.isUnlocked else { return nil }
        return doc
    }

    /// Messwerte der Seite (1-basiert) mit dem Text ihrer Textebene; nil, wenn sich die PDF nicht lesen laesst
    public static func probe(pdf url: URL, page: Int, text: String) -> DocIndexPageRule.Probe? {
        guard let doc = document(url), page >= 1, page <= doc.numberOfPages, let p = doc.page(at: page) else { return nil }
        let content = contentData(p)
        return DocIndexPageRule.Probe(letters: DocIndexFingerprint.letters(text), images: imageCount(p), pathOps: pathOps(content),
                                      mathSymbols: DocIndexPageRule.mathSymbols(in: text), contentBytes: content.count)
    }

    /// Inhaltsstrom der Seite (entpackt; `Contents` als Strom oder Liste von Stroemen)
    static func contentData(_ page: CGPDFPage) -> Data {
        guard let dict = page.dictionary else { return Data() }
        var out = Data()
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dict, "Contents", &stream), let s = stream {
            out.append(streamData(s))
        } else {
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Contents", &array), let a = array {
                for i in 0..<CGPDFArrayGetCount(a) {
                    var s: CGPDFStreamRef?
                    if CGPDFArrayGetStream(a, i, &s), let s { out.append(streamData(s)) }
                }
            }
        }
        return out
    }

    static func streamData(_ stream: CGPDFStreamRef) -> Data {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return Data() }
        return data as Data
    }

    /// Pfadbefehle im Inhaltsstrom (m l c v y re): Linien, Kurven, Rechtecke. Zeichenketten (`(...)` mit Klammern und
    /// Escapes, `<...>` hex) und Kommentare werden uebersprungen: Glyphen einer Textzeile sind keine Pfadbefehle.
    public static func pathOps(_ content: Data) -> Int {
        let ops: Set<String> = ["m", "l", "c", "v", "y", "re"]
        var count = 0, token = [UInt8]()
        func flush() {
            if !token.isEmpty, let t = String(bytes: token, encoding: .ascii), ops.contains(t) { count += 1 }
            token.removeAll(keepingCapacity: true)
        }
        let bytes = [UInt8](content)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x28:                                                   // ( Zeichenkette bis zur passenden )
                flush()
                var depth = 1
                i += 1
                while i < bytes.count, depth > 0 {
                    switch bytes[i] {
                    case 0x5C: i += 1                                    // \ Escape: naechstes Byte ueberspringen
                    case 0x28: depth += 1
                    case 0x29: depth -= 1
                    default: break
                    }
                    i += 1
                }
                continue
            case 0x3C:                                                   // < hex bis >, << Woerterbuch bleibt Trenner
                flush()
                if i + 1 < bytes.count, bytes[i + 1] == 0x3C { i += 2; continue }
                while i < bytes.count, bytes[i] != 0x3E { i += 1 }
            case 0x25:                                                   // % Kommentar bis Zeilenende
                flush()
                while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
            case 0x20, 0x0A, 0x0D, 0x09, 0x0C, 0x00: flush()
            case 0x5B, 0x5D, 0x29, 0x3E, 0x2F, 0x7B, 0x7D: flush()     // [ ] ) > / { } trennen ebenfalls
            default: token.append(b)
            }
            i += 1
        }
        flush()
        return count
    }

    /// Bild-XObjects der Seite (auch in Formular-XObjects bis Tiefe 2)
    static func imageCount(_ page: CGPDFPage) -> Int {
        guard let dict = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let r = resources else { return 0 }
        return imageCount(resources: r, depth: 0)
    }

    private final class Counter { var images = 0; var forms: [CGPDFDictionaryRef] = [] }

    static func imageCount(resources: CGPDFDictionaryRef, depth: Int) -> Int {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let x = xobjects else { return 0 }
        let counter = Counter()
        CGPDFDictionaryApplyBlock(x, { _, value, info in
            let counter = Unmanaged<Counter>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let s = stream, let d = CGPDFStreamGetDictionary(s) else { return true }
            var name: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(d, "Subtype", &name), let n = name {
                let sub = String(cString: n)
                if sub == "Image" { counter.images += 1 } else if sub == "Form" { counter.forms.append(d) }
            }
            return true
        }, Unmanaged.passUnretained(counter).toOpaque())
        var total = counter.images
        if depth < 2 {
            for f in counter.forms {
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(f, "Resources", &inner), let r = inner { total += imageCount(resources: r, depth: depth + 1) }
            }
        }
        return total
    }

    /// Seite als JPEG mit `width` Pixeln Breite (weisser Grund, Drehung beachtet); nil, wenn sie sich nicht rendern laesst
    public static func renderJPEG(pdf url: URL, page: Int, width: Int = imageWidth, quality: Double = jpegQuality) -> Data? {
        guard let doc = document(url), page >= 1, page <= doc.numberOfPages, let p = doc.page(at: page) else { return nil }
        let box = p.getBoxRect(.cropBox)
        let rotated = p.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let factor = CGFloat(width) / size.width
        let w = max(1, Int((size.width * factor).rounded())), h = max(1, Int((size.height * factor).rounded()))
        guard h <= 8000, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: factor, y: factor)
        ctx.concatenate(p.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(p)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Seitenzahl der PDF; nil, wenn sie sich nicht lesen laesst
    public static func pageCount(pdf url: URL) -> Int? { document(url)?.numberOfPages }
}
#endif
