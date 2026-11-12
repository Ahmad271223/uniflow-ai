import Foundation
import UniFlowCore

// Wohin mit Dateien von aussen (Meldung des Inhabers 11.11.2026): vorher ging beim Import nur "In welches Modul?".
// Jetzt dieselben Orte wie in "Dokumente & Notizen" (`GET /api/library`): ohne Ordner, ein Modul, jeder eigene Ordner
// (auch Unterordner, auch in einem Modul) oder "Neuer Ordner …" (Name eingeben, direkt dort ablegen,
// `POST /api/folders`). Gilt fuer "Teilen"/"Öffnen in", Ablegen in der Bibliothek (PDF, ZIP, Bilder), "Neu" -> "PDF
// importieren" und "Bild importieren" (Fotomediathek, Dateien), "PDF importieren" in der Dokumentleiste und Ablage ->
// "Importieren …" (seit 12.11.2026 alle gleich); "In Ordner verschieben" bietet dieselben Ordner und "Neuer Ordner …".

/// Ziel eines Imports
enum ImportTarget: Hashable {
    /// ohne Ordner: "Eigene Dokumente" auf der obersten Ebene
    case loose
    /// Modul: das Backend legt das Dokument in den Ordner "Eigene Notizen" des Moduls
    case module(Int)
    /// eigener Ordner (auch Unterordner, auch in einem Modul)
    case folder(Int)
    /// "Neuer Ordner …": wird vor dem Import angelegt
    case newFolder

    /// Felder fuer `POST /api/notebooks`: ein Ordner traegt sein Modul selbst, darum nur `folder_id`
    var fields: (moduleID: Int?, folderID: Int?) {
        switch self {
        case .module(let m): return (m, nil)
        case .folder(let f): return (nil, f)
        case .loose, .newFolder: return (nil, nil)
        }
    }

    /// Ziel zum offenen Pfad der Bibliothek ("m1", "m1/vorlesung", "m1/f5/f9", "f3/f7"); Kursordner und Wurzel: ohne
    /// Ordner
    static func from(path: String?) -> ImportTarget {
        if let f = LibraryPage.dropFolder(path) { return .folder(f) }
        if let m = LibraryPage.dropModule(path) { return .module(m) }
        return .loose
    }
}

/// Orte der Bibliothek als Auswahl, Pfade und Namen
enum ImportPlaces {
    static let looseLabel = "Ohne Ordner (Eigene Dokumente)"
    static let newFolderLabel = "Neuer Ordner …"
    static let topLevelLabel = "Oberste Ebene"
    /// tiefer als die Ordnertiefe des Kerns (12) wird nicht gesucht; schuetzt auch vor Kreisen in kaputten Daten
    static let maxDepth = 13

    private static func folders(_ lib: JSONValue) -> [JSONValue] { lib.list("folders") }

    private static func folder(_ id: Int, in lib: JSONValue) -> JSONValue? { folders(lib).first { $0.i("id") == id } }

    /// Kette der Ordner von oben bis `id` (einschliesslich); leer, wenn es ihn nicht gibt
    static func chain(_ id: Int, in lib: JSONValue) -> [JSONValue] {
        var out: [JSONValue] = []
        var next: Int? = id
        var seen = Set<Int>()
        while let n = next, out.count < maxDepth, seen.insert(n).inserted, let f = folder(n, in: lib) {
            out.insert(f, at: 0)
            next = f.i("parent_id")
        }
        return out
    }

    /// Modul eines Ordners (das des obersten Ordners der Kette, sonst irgendeines darin)
    static func module(ofFolder id: Int, in lib: JSONValue) -> Int? {
        let c = chain(id, in: lib)
        return c.first?.i("module_id") ?? c.compactMap { $0.i("module_id") }.first
    }

    private static func moduleName(_ id: Int, in lib: JSONValue) -> String? {
        lib.list("modules").first { $0.i("id") == id }?.s("name")
    }

    /// Name fuer Auswahl und Meldung: "Analysis", "Analysis › Übungen › Blatt 1", "Privat › Sommer"
    static func label(_ target: ImportTarget, in lib: JSONValue) -> String {
        switch target {
        case .loose: return looseLabel
        case .newFolder: return newFolderLabel
        case .module(let m): return moduleName(m, in: lib) ?? "Modul"
        case .folder(let f):
            let c = chain(f, in: lib)
            guard !c.isEmpty else { return "Ordner" }
            let head = c.first?.i("module_id").flatMap { moduleName($0, in: lib) }
            return ([head].compactMap { $0 } + c.map { $0.s("name") ?? "Ordner" }).joined(separator: " › ")
        }
    }

    /// Unterordner eines Ordners bzw. die obersten Ordner eines Moduls (`module`) oder ohne Modul (beides nil), nach
    /// Name wie `/api/library`
    private static func children(of parent: Int?, module: Int?, in lib: JSONValue) -> [JSONValue] {
        folders(lib).filter { f in
            if let parent { return f.i("parent_id") == parent }
            return f["parent_id"]?.isNull != false && f.i("module_id") == module
        }
    }

    /// Ordner unter `parent` der Tiefe nach (Ordner, dann seine Unterordner)
    private static func tree(_ start: [JSONValue], in lib: JSONValue, depth: Int = 0) -> [Int] {
        guard depth < maxDepth else { return [] }
        return start.compactMap { $0.i("id") }.flatMap { id in [id] + tree(children(of: id, module: nil, in: lib), in: lib, depth: depth + 1) }
    }

    /// Alle Orte in der Reihenfolge der Bibliothek: je Modul das Modul und seine Ordner, dann die eigenen Ordner ohne
    /// Modul
    static func places(_ lib: JSONValue) -> [ImportTarget] {
        let modules = lib.list("modules").compactMap { $0.i("id") }
        var out: [ImportTarget] = []
        for m in modules {
            out.append(.module(m))
            out += tree(children(of: nil, module: m, in: lib), in: lib).map(ImportTarget.folder)
        }
        out += tree(children(of: nil, module: nil, in: lib), in: lib).map(ImportTarget.folder)
        return out
    }

    /// Auswahl "Wohin?": ohne Ordner, alle Orte, "Neuer Ordner …"
    static func options(_ lib: JSONValue) -> [(value: ImportTarget, label: String)] {
        ([.loose] + places(lib) + [.newFolder]).map { ($0, label($0, in: lib)) }
    }

    /// Auswahl "Anlegen in" fuer den neuen Ordner: oberste Ebene und alle Orte
    static func parents(_ lib: JSONValue) -> [(value: ImportTarget, label: String)] {
        [(ImportTarget.loose, topLevelLabel)] + places(lib).map { ($0, label($0, in: lib)) }
    }

    /// Gibt es den Ort (noch)? Sonst faellt die Auswahl auf "ohne Ordner" zurueck
    static func contains(_ target: ImportTarget, in lib: JSONValue) -> Bool {
        target == .loose || target == .newFolder || places(lib).contains(target)
    }

    /// Pfad in der Bibliothek (`#/files?path=`), nil fuer die oberste Ebene
    static func path(_ target: ImportTarget, in lib: JSONValue) -> String? {
        switch target {
        case .loose, .newFolder: return nil
        case .module(let m): return "m\(m)"
        case .folder(let f):
            let c = chain(f, in: lib)
            guard !c.isEmpty else { return nil }
            let head = c.first?.i("module_id").map { ["m\($0)"] } ?? []
            return (head + c.compactMap { $0.i("id").map { "f\($0)" } }).joined(separator: "/")
        }
    }

    /// Pfad eines neu angelegten Ordners unter `parent`
    static func path(newFolder id: Int, under parent: ImportTarget, in lib: JSONValue) -> String {
        [path(parent, in: lib), "f\(id)"].compactMap { $0 }.joined(separator: "/")
    }

    /// Anfrage fuer `POST /api/folders` (wie "Neu" -> "Ordner" in der Bibliothek: Unterordner tragen das Modul mit)
    static func newFolderBody(name: String, parent: ImportTarget, in lib: JSONValue) -> JSONValue {
        var parentID: Int?
        var moduleID: Int?
        switch parent {
        case .module(let m): moduleID = m
        case .folder(let f): parentID = f; moduleID = module(ofFolder: f, in: lib)
        case .loose, .newFolder: break
        }
        return ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                "parent_id": parentID.map { .number(Double($0)) } ?? .null,
                "module_id": moduleID.map { .number(Double($0)) } ?? .null]
    }
}
