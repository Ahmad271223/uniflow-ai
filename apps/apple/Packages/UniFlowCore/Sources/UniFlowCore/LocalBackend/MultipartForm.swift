import Foundation

/// multipart/form-data wie `Form(...)`/`File(...)` in FastAPI: Textfelder und Dateien eines Formulars
/// (APIClient.form in der App, FormData im Web).
public struct MultipartForm: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let field: String
        public let filename: String
        public let contentType: String?
        public let data: Data
    }

    /// Textfelder; bei Wiederholung gilt wie bei Starlette der letzte Wert
    public private(set) var fields: [String: String] = [:]
    public private(set) var files: [File] = []

    public func file(_ field: String) -> File? { files.last { $0.field == field } }

    /// Fehler im Aufbau des Formulars (400 wie Starlette bei kaputtem multipart)
    static func malformed(_ why: String) -> LocalHTTPError {
        LocalHTTPError(status: 400, message: "Formular nicht lesbar: \(why)")
    }

    /// Zerlegt den Inhalt anhand der Grenze aus `Content-Type: multipart/form-data; boundary=...`.
    public static func parse(_ body: Data, contentType: String) throws -> MultipartForm {
        let params = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard params.first?.lowercased() == "multipart/form-data" else { throw malformed("kein multipart/form-data") }
        guard let b = params.dropFirst().compactMap({ p -> String? in
            let kv = p.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].lowercased() == "boundary" else { return nil }
            return unquote(String(kv[1]))
        }).first, !b.isEmpty else { throw malformed("Grenze fehlt") }

        let bytes = [UInt8](body)
        let delimiter = Array("--\(b)".utf8)
        var form = MultipartForm()
        guard var pos = find(delimiter, in: bytes, from: 0) else { throw malformed("Grenze nicht gefunden") }
        while true {
            pos += delimiter.count
            // "--" nach der Grenze: Ende des Formulars
            if pos + 1 < bytes.count, bytes[pos] == 0x2D, bytes[pos + 1] == 0x2D { break }
            pos = skipLineBreak(bytes, pos)
            guard let headerEnd = find([0x0D, 0x0A, 0x0D, 0x0A], in: bytes, from: pos) ?? find([0x0A, 0x0A], in: bytes, from: pos) else {
                throw malformed("Kopf eines Teils unvollstaendig")
            }
            let crlf = bytes[headerEnd] == 0x0D
            let head = String(decoding: bytes[pos..<headerEnd], as: UTF8.self)
            let dataStart = headerEnd + (crlf ? 4 : 2)
            guard let next = find(delimiter, in: bytes, from: dataStart) else { throw malformed("Ende eines Teils fehlt") }
            // der Zeilenumbruch vor der naechsten Grenze gehoert nicht zum Inhalt
            var dataEnd = next
            if dataEnd >= dataStart + 2, bytes[dataEnd - 2] == 0x0D, bytes[dataEnd - 1] == 0x0A { dataEnd -= 2 }
            else if dataEnd >= dataStart + 1, bytes[dataEnd - 1] == 0x0A { dataEnd -= 1 }
            try form.add(head: head, data: Data(bytes[dataStart..<dataEnd]))
            pos = next
        }
        return form
    }

    private mutating func add(head: String, data: Data) throws {
        var disposition: [String: String] = [:]
        var type: String?
        for line in head.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if name == "content-disposition" { disposition = MultipartForm.dispositionParams(value) }
            if name == "content-type" { type = value }
        }
        guard let field = disposition["name"] else { throw MultipartForm.malformed("Feldname fehlt") }
        if let filename = disposition["filename"] {
            files.append(File(field: field, filename: filename, contentType: type, data: data))
        } else {
            fields[field] = String(decoding: data, as: UTF8.self)
        }
    }

    /// `form-data; name="kind"; filename="a.pdf"` -> ["name": "kind", "filename": "a.pdf"]
    static func dispositionParams(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        // erster Teil ist "form-data"
        guard let semi = value.firstIndex(of: ";") else { return out }
        var i = value.index(after: semi)
        while i < value.endIndex {
            while i < value.endIndex, value[i] == " " || value[i] == ";" { i = value.index(after: i) }
            guard let eq = value[i...].firstIndex(of: "=") else { break }
            let key = value[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var j = value.index(after: eq)
            var v = ""
            if j < value.endIndex, value[j] == "\"" {
                j = value.index(after: j)
                while j < value.endIndex, value[j] != "\"" {
                    if value[j] == "\\", value.index(after: j) < value.endIndex { j = value.index(after: j) }
                    v.append(value[j])
                    j = value.index(after: j)
                }
                if j < value.endIndex { j = value.index(after: j) }
            } else {
                while j < value.endIndex, value[j] != ";" { v.append(value[j]); j = value.index(after: j) }
                v = v.trimmingCharacters(in: .whitespaces)
            }
            out[key] = v
            i = j
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }

    private static func skipLineBreak(_ b: [UInt8], _ p: Int) -> Int {
        if p + 1 < b.count, b[p] == 0x0D, b[p + 1] == 0x0A { return p + 2 }
        if p < b.count, b[p] == 0x0A { return p + 1 }
        return p
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, start <= hay.count - needle.count else { return nil }
        let first = needle[0]
        var i = start
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var k = 1
                while k < needle.count && hay[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

/// Inhalt eines Formulars wie FormData im Web (`APIClient.form` in der App), Gegenstueck zu `MultipartForm.parse`.
/// Feldname, Dateiname und Typ stehen in Kopfzeilen; dort duerfen weder Anfuehrungszeichen, Backslash noch
/// Steuerzeichen (Zeilenumbruch) stehen, sonst liessen sich weitere Kopfzeilen oder Felder einschleusen bzw. ginge ein
/// Zeichen verloren (der Backslash leitet in Anfuehrungszeichen eine Maskierung ein). Sie werden zu "_"; andere
/// Unicode-Zeichen (Umlaute, Emoji, Semikolon) bleiben, wie Browser sie senden (UTF-8).
public enum MultipartBody {
    public struct File: Sendable {
        public var field: String
        public var name: String
        public var mime: String
        public var data: Data

        public init(field: String, name: String, mime: String, data: Data) {
            self.field = field
            self.name = name
            self.mime = mime
            self.data = data
        }
    }

    /// Text fuer einen Kopf-Parameter in Anfuehrungszeichen (Feld- oder Dateiname)
    public static func headerValue(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            u == "\"" || u == "\\" || u.value < 0x20 || u.value == 0x7F ? "_" : u
        }))
    }

    /// Inhaltstyp `typ/untertyp` aus erlaubten Zeichen (RFC 6838), sonst `application/octet-stream`
    public static func mimeType(_ s: String) -> String {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        func ok(_ p: Substring) -> Bool {
            !p.isEmpty && p.count <= 127 && p.unicodeScalars.allSatisfy { u in
                (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || "!#$&^_.+-".unicodeScalars.contains(u)
            }
        }
        guard parts.count == 2, ok(parts[0]), ok(parts[1]) else { return "application/octet-stream" }
        return s
    }

    /// Textfelder (nach Namen sortiert) und hoechstens eine Datei, Grenze `boundary`
    public static func build(fields: [String: String], file: File?, boundary: String) -> Data {
        let crlf = "\r\n"
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data(("--" + boundary + crlf + "Content-Disposition: form-data; name=\"" + headerValue(k) + "\"" + crlf + crlf + v + crlf).utf8))
        }
        if let file {
            body.append(Data(("--" + boundary + crlf + "Content-Disposition: form-data; name=\"" + headerValue(file.field) + "\"; filename=\""
                              + headerValue(file.name) + "\"" + crlf + "Content-Type: " + mimeType(file.mime) + crlf + crlf).utf8))
            body.append(file.data)
            body.append(Data(crlf.utf8))
        }
        body.append(Data(("--" + boundary + "--" + crlf).utf8))
        return body
    }
}
