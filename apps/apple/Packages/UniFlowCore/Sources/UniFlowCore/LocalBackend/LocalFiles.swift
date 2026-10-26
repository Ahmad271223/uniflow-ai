import Foundation

/// Werkzeuge fuer Dokumente, die der Kern ohne PDFKit/UIKit nicht hat (unter Linux gibt es beides nicht).
/// app/server.py nutzt dafuer pypdf (Seitenzahl, Seitentexte) und Pillow (Bild als PDF-Seite); die App setzt PDFKit
/// und UIKit ein.
public protocol LocalDocumentTools: Sendable {
    /// Seitenzahl einer PDF; nil, wenn sie sich nicht lesen laesst (Python: `page_count = None`)
    func pdfPageCount(_ data: Data) -> Int?
    /// Bild als einseitige PDF; nil ohne Umwandlung -> das Bild bleibt ein Bild (wie Python ohne Pillow)
    func pdfFromImage(_ data: Data) -> Data?
    /// Text je Seite einer PDF (am PC pypdf `extract_text`, in der App PDFKit), eine nicht lesbare Seite als "";
    /// nil, wenn sich die Datei nicht lesen laesst (Python: `page_texts` liefert [])
    func pdfPageTexts(_ url: URL) -> [String]?
}

extension LocalDocumentTools {
    /// Ohne Werkzeug (Kern unter Linux, Tests): keine Seitentexte, die Skriptsuche nutzt nur gespeicherte
    public func pdfPageTexts(_ url: URL) -> [String]? { nil }
}

/// Ohne Werkzeuge: keine Seitenzahl, Bilder bleiben Bilder.
public struct NoDocumentTools: LocalDocumentTools {
    public init() {}
    public func pdfPageCount(_ data: Data) -> Int? { nil }
    public func pdfFromImage(_ data: Data) -> Data? { nil }
}

/// Dateien des lokalen Backends: Stud.IP-Downloads, eigene Dokumente (PDF- und Bild-Import) und Bilder der Notizen.
///
/// In der Datenbank (`files.local_path`) stehen Pfade **relativ zum App-Container**: dessen absoluter Pfad aendert
/// sich zwischen Installationen und beim Wiederherstellen aus dem Backup. app/server.py speichert absolute Pfade
/// des PCs; ein absoluter Pfad oder einer mit ".." gilt hier als "nicht lokal vorhanden".
public struct LocalFiles: Sendable {
    /// App-Container (in der App `NSHomeDirectory()`, in Tests ein Temp-Ordner)
    public let container: URL
    /// Datenordner relativ zum Container wie `DATA_DIR` in app/config.py, z. B. "Library/Application Support/UniFlow";
    /// leer = der Container selbst. Darin `files/Eigene Dokumente` (Importe) und `assets/<file_id>` (Bilder).
    public let dataDirectory: String
    public let tools: LocalDocumentTools

    public init(container: URL, dataDirectory: String, tools: LocalDocumentTools = NoDocumentTools()) {
        self.container = container.standardizedFileURL
        self.dataDirectory = LocalFiles.clean(dataDirectory) ?? ""
        self.tools = tools
    }

    /// Ordner fuer eigene Dokumente (`DATA_DIR / "files" / "Eigene Dokumente"`), relativ zum Container
    public var ownDocumentsDirectory: String { join(dataDirectory, "files/Eigene Dokumente") }

    /// Ordner fuer Bilder der Notizen (`ASSETS_DIR / file_id`), relativ zum Container
    public func assetsDirectory(fileID: String) -> String { join(dataDirectory, "assets/" + fileID) }

    /// Datei zu einem gespeicherten Pfad; nil bei absolutem Pfad, "..", leeren Teilen oder ausserhalb des Containers.
    public func url(stored path: String) -> URL? {
        guard let rel = LocalFiles.clean(path), !rel.isEmpty else { return nil }
        let url = container.appendingPathComponent(rel)
        // Symlinks duerfen nicht aus dem Container fuehren
        let base = LocalFiles.resolved(container)
        let full = LocalFiles.resolved(url)
        guard full == base || full.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return url
    }

    /// Pfad mit aufgeloesten Symlinks; fuer noch nicht vorhandene Dateien wird die tiefste vorhandene Stelle aufgeloest
    /// und der Rest angehaengt (/var -> /private/var auf Apple-Systemen).
    static func resolved(_ url: URL) -> String {
        var probe = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            rest.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }
        var path = probe.resolvingSymlinksInPath().path
        for r in rest { path += (path.hasSuffix("/") ? "" : "/") + r }
        return path
    }

    /// Gibt es zu dem gespeicherten Pfad eine Datei? (`Path(local_path).exists()` in Python)
    public func exists(stored path: String?) -> Bool {
        guard let path, let url = url(stored: path) else { return false }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    /// Pfad zum Speichern in der Datenbank: relativ zum Container; nil, wenn die Datei nicht darin liegt.
    public func stored(_ url: URL) -> String? {
        let base = LocalFiles.resolved(container)
        let full = LocalFiles.resolved(url)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return LocalFiles.clean(String(full.dropFirst(prefix.count)))
    }

    /// Daten schreiben (Ordner werden angelegt); mit Dateischutz wie die Datenbank (nach dem ersten Entsperren lesbar).
    public func write(_ data: Data, to stored: String) throws -> URL {
        guard let url = url(stored: stored) else { throw LocalHTTPError(status: 400, message: "Ungültiger Pfad") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }

    /// Datei loeschen (fehlt sie, ist das kein Fehler)
    public func remove(stored: String) {
        guard let url = url(stored: stored) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

    /// Relativer Pfad ohne fuehrenden oder doppelten Schraegstrich; nil bei absolutem Pfad, "." oder "..".
    static func clean(_ path: String) -> String? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.joined(separator: "/")
    }
}

// MARK: - Dateiantworten wie Starlette (FileResponse) und die Middleware file_response_headers

enum LocalFileResponse {
    /// `_INLINE_TYPES` in app/server.py: diese Typen zeigt die App direkt, alles andere wird heruntergeladen
    static let inlineTypes: Set<String> = ["application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp", "text/plain"]

    /// `mimetypes.guess_type(name)[0]` fuer die Endungen, die in Stud.IP- und Learnweb-Kursen vorkommen
    /// (Standardtabelle von Python; die Systemtabellen des PCs koennen weitere Endungen kennen, die aber nie inline
    /// gezeigt werden). Die eine Tabelle des Kerns: Dateiantworten und Learnweb ueber die Sitzung (`Learnweb.guessMime`,
    /// davon haengt `file_kind` "image" ab, z. B. bei .bmp, .tif, .heic).
    static let types: [String: String] = [
        "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpe": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/vnd.microsoft.icon",
        "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic", "heif": "image/heif", "avif": "image/avif",
        "txt": "text/plain", "text": "text/plain", "c": "text/plain", "h": "text/plain",
        "bat": "text/plain", "pl": "text/plain", "ksh": "text/plain", "srt": "text/plain", "csv": "text/csv",
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "md": "text/markdown", "markdown": "text/markdown", "rtf": "text/rtf", "tex": "application/x-tex",
        "xml": "text/xml", "json": "application/json", "zip": "application/zip",
        "gz": "application/gzip", "tar": "application/x-tar", "py": "text/x-python", "doc": "application/msword",
        "dot": "application/msword", "xls": "application/vnd.ms-excel", "ppt": "application/vnd.ms-powerpoint",
        "pps": "application/vnd.ms-powerpoint", "pot": "application/vnd.ms-powerpoint",
        "eps": "application/postscript", "ps": "application/postscript",
        "avi": "video/x-msvideo", "mpg": "video/mpeg", "mpeg": "video/mpeg", "aac": "audio/aac", "opus": "audio/opus",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "mp3": "audio/mpeg", "wav": "audio/x-wav", "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    ]

    /// `mimetypes.guess_type(name)[0]`; nil, wenn die Endung unbekannt ist
    static func guess(_ name: String) -> String? {
        guard let ext = suffix(name)?.dropFirst().lowercased(), !ext.isEmpty else { return nil }
        return types[String(ext)]
    }

    /// `PurePath(name).suffix`: ab dem letzten Punkt des letzten Teils, nicht bei Punkt am Anfang oder Ende
    static func suffix(_ name: String) -> String? {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex, last.index(after: dot) != last.endIndex else { return nil }
        return String(last[dot...])
    }

    /// Antwort wie `FileResponse(path, media_type=..., filename=..., content_disposition_type=...)` mit den Kopfzeilen
    /// der Middleware: `nosniff` immer, Sandbox-CSP fuer alles ausser PDF.
    static func response(_ data: Data, mediaType: String, filename: String?, disposition: String) -> LocalResponse {
        // Starlette haengt bei text/* den Zeichensatz an
        let ctype = mediaType.hasPrefix("text/") && !mediaType.lowercased().contains("charset=") ? mediaType + "; charset=utf-8" : mediaType
        var headers = ["Content-Type": ctype, "Content-Length": String(data.count), "X-Content-Type-Options": "nosniff"]
        if let filename {
            let q = PyText.quote(filename)
            headers["Content-Disposition"] = q != filename ? "\(disposition); filename*=utf-8''\(q)" : "\(disposition); filename=\"\(filename)\""
        }
        if mediaType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() != "application/pdf" {
            headers["Content-Security-Policy"] = "sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'"
        }
        return LocalResponse(status: 200, headers: headers, body: data)
    }
}
