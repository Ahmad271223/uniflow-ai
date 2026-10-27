import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Menues und Dialoge der Bibliothek 1:1 nach views-lib.js: newMenu, notebookDialog, itemMenu (Ordner, Papierkorb,
// Dokument, Verschieben). prompt()/confirm() wie im Web als Systemdialog.

/// Knopf in einem Menue-Dialog (.stack > .btn): ganze Breite, Icon 16
struct UFMenuButton: View {
    let text: String
    let icon: String
    var kind: UFButtonKind = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7.2) { UFIcon(icon, size: 16); Text(text) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle(kind: kind))
    }
}

/// newMenu(path, current): Notizbuch, Whiteboard, Ordner, PDF importieren, Bild importieren
struct LibraryNewDialog: View {
    let lib: JSONValue
    let path: String
    let current: (label: String, path: String)
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var importKind: String?
    @State private var imageSource = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false

    private var seg: [String] { path.isEmpty ? [] : path.components(separatedBy: "/") }
    private var moduleID: Int? { seg.first.flatMap { $0.hasPrefix("m") ? Int($0.dropFirst()) : nil } }
    private var folderID: Int? { seg.last.flatMap { $0.hasPrefix("f") ? Int($0.dropFirst()) : nil } }

    var body: some View {
        UFDialog("Neu" + (current.path.isEmpty ? "" : " in „\(current.label)“")) {
            VStack(spacing: 8) {
                // Notizbuch und Whiteboard gibt es nur zum Schreiben: Plus (Schloss mit Weg zur Abo-Seite)
                UFMenuButton(text: "Notizbuch", icon: "note") { close(); overlay.modal { NotebookDialog(kind: "notebook", lib: lib, moduleID: moduleID, folderID: folderID) } }
                    .ufRequires(NotebookDialog.feature)
                UFMenuButton(text: "Whiteboard", icon: "square") { close(); overlay.modal { NotebookDialog(kind: "whiteboard", lib: lib, moduleID: moduleID, folderID: folderID) } }
                    .ufRequires(NotebookDialog.feature)
                UFMenuButton(text: "Ordner", icon: "folder") { close(); Task { await newFolder() } }
                UFMenuButton(text: "PDF importieren", icon: "file-text") { importKind = "pdf" }
                UFMenuButton(text: "Bild importieren", icon: "image") { imageSource = true }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
        // <input type=file accept="image/*"> bietet in Safari Fotomediathek und Dateien an
        .confirmationDialog("Bild importieren", isPresented: $imageSource) {
            Button("Fotomediathek") { showPhotos = true }
            Button("Datei auswählen") { importKind = "image" }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photos, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var files: [ImportItem] = []
                var unreadable = 0
                for (i, it) in items.enumerated() {
                    // Format aus den Daten (HEIC, PNG, JPEG …), nicht pauschal JPEG; nicht lesbare Fotos werden gezaehlt
                    if let d = try? await it.loadTransferable(type: Data.self), let type = Self.imageType(d) {
                        files.append(ImportItem(name: "Bild \(i + 1).\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg") { d })
                    } else { unreadable += 1 }
                }
                await upload("image", files, unreadable: unreadable)
            }
        }
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                      allowedContentTypes: importKind == "pdf" ? [.pdf] : [.image], allowsMultipleSelection: true) { result in
            let kind = importKind ?? "pdf"
            importKind = nil
            guard case .success(let urls) = result else { return }
            // erst beim Hochladen lesen, eine Datei nach der anderen (vorher lagen alle gewaehlten Dateien zugleich im
            // Speicher, Pruefbericht 412); eine nicht lesbare zaehlt als fehlgeschlagen statt still zu fehlen
            let files = urls.map { url in
                ImportItem(name: url.lastPathComponent,
                           mime: kind == "pdf" ? "application/pdf" : (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png")) {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }
            }
            Task { await upload(kind, files) }
        }
    }

    /// prompt("Name des Ordners:", "Neuer Ordner") -> POST /api/folders; Fehler sichtbar (vorher try?)
    private func newFolder() async {
        guard let name = await overlay.prompt("Name des Ordners:", value: "Neuer Ordner"), !name.isEmpty, let api = session.api else { return }
        if await toast.attempt("Ordner anlegen", {
            _ = try await api.value("/api/folders", method: "POST",
                                    body: ["name": .string(name), "parent_id": folderID.map { .number(Double($0)) } ?? .null,
                                           "module_id": moduleID.map { .number(Double($0)) } ?? .null])
        }) { router.reload() }
    }

    /// Bildformat aus den Daten (Fotomediathek liefert HEIC, PNG oder JPEG); nil, wenn es kein Bild ist
    static func imageType(_ data: Data) -> UTType? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let id = CGImageSourceGetType(src) else { return nil }
        return UTType(id as String)
    }

    /// Meldung nach dem Import: genaue Zahl der importierten und der gescheiterten Dateien (ein Teilerfolg sagt nie
    /// nur "Importiert")
    static func importSummary(ok: Int, failed: [String], unreadable: Int = 0) -> String {
        var parts: [String] = []
        if ok > 0 { parts.append(ok == 1 ? "1 Datei importiert" : "\(ok) Dateien importiert") }
        if !failed.isEmpty { parts.append("\(failed.count) fehlgeschlagen: " + failed.joined(separator: "; ")) }
        if unreadable > 0 { parts.append(unreadable == 1 ? "1 Foto nicht lesbar" : "\(unreadable) Fotos nicht lesbar") }
        return parts.isEmpty ? "Nichts importiert" : parts.joined(separator: " · ")
    }

    /// Datei zum Import: Name, Typ und Inhalt, der erst beim Hochladen gelesen wird
    struct ImportItem {
        let name: String
        let mime: String
        let load: () throws -> Data
    }

    /// je Datei POST /api/notebooks (kind, title ohne Endung, module_id, folder_id, upload), danach die Bilanz
    /// (importiert, fehlgeschlagen, nicht lesbar). Jede Datei ist eine eigene Anfrage: eine gescheiterte aendert an
    /// den schon importierten nichts.
    private func upload(_ kind: String, _ files: [ImportItem], unreadable: Int = 0) async {
        guard let api = session.api, !files.isEmpty || unreadable > 0 else { return }
        close()
        var ok = 0
        var failed: [String] = []
        for item in files {
            var fields = ["kind": kind, "title": (item.name as NSString).deletingPathExtension]
            if let moduleID { fields["module_id"] = "\(moduleID)" }
            if let folderID { fields["folder_id"] = "\(folderID)" }
            do {
                let data = try item.load()
                _ = try await api.form("/api/notebooks", fields: fields, file: ("upload", item.name, item.mime, data))
                ok += 1
            } catch { failed.append("\(item.name) (\(error.localizedDescription))") }
        }
        toast.show(Self.importSummary(ok: ok, failed: failed, unreadable: unreadable), seconds: failed.isEmpty && unreadable == 0 ? 2.6 : 6)
        if ok > 0 { router.reload() }
    }
}

/// notebookDialog(kind, moduleId, folderId): Titel, Vorlage (nur Notizbuch), Format (A6 ... A2 hoch/quer bzw.
/// Whiteboard-Groessen wie formats.js, `PageFormats`), Modul -> Erstellen, danach Dokument oeffnen
struct NotebookDialog: View {
    /// Notizbuecher und Whiteboards sind zum Schreiben da: Plus wie das Schreiben selbst (PDF- und Bild-Import zum
    /// Lesen bleiben Free)
    static let feature = UFFeature.pencilWriting

    let kind: String
    let lib: JSONValue
    let moduleID: Int?
    let folderID: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var title = ""
    @State private var tpl = "lined"
    @State private var module = 0
    /// Format wie im Web: Notizbuch A4, Whiteboard "Mittel (A3 quer)"
    @State private var format = ""
    @State private var orientation = PageFormats.Orientation.portrait

    private var formats: [PageFormats.Format] { kind == "whiteboard" ? PageFormats.whiteboards : PageFormats.paper }

    var body: some View {
        UFDialog(kind == "whiteboard" ? "Neues Whiteboard" : "Neues Notizbuch") {
            UFField("Titel") { UFTextInput(text: $title) }
            if kind == "notebook" {
                UFField("Vorlage") {
                    UFGridLayout(columns: 6, spacing: 6.4) {
                        ForEach(PaperTemplate.choices, id: \.id) { k, n in
                            Button { tpl = k } label: {
                                VStack(spacing: 4.8) {
                                    UFTemplatePreview(template: k).frame(width: 38, height: 48)
                                    Text(n).ufFont(12.8, tpl == k ? 600 : 400)
                                }
                                .foregroundStyle(tpl == k ? UF.accentText : UF.text2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4 + ufB).padding(.horizontal, 4 + ufB)
                                .background(RoundedRectangle(cornerRadius: 999).fill(tpl == k ? UF.accentSoft : UF.surface))
                                .overlay(RoundedRectangle(cornerRadius: 999).strokeBorder(tpl == k ? .clear : UF.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .environment(\.ufFillsCell, false)
                }
            }
            UFField("Format") {
                VStack(alignment: .leading, spacing: 6.4) {
                    UFFlexWrap(gap: 6.4) {
                        ForEach(formats, id: \.key) { f in
                            UFChip(text: f.name, on: format == f.key) { format = f.key }
                                .accessibilityHint(f.hint ?? "")
                        }
                    }
                    if kind == "notebook" {
                        UFSegmented(options: [(PageFormats.Orientation.portrait, "Hoch"), (.landscape, "Quer")], selection: $orientation)
                    } else {
                        Text("Whiteboards sind quer; „Riesig“ braucht viel Arbeitsspeicher.").ufFont(12.8).foregroundStyle(UF.muted)
                    }
                }
            }
            UFField("Modul (optional)") {
                UFSelect(options: [(0, "– keins –")] + lib.list("modules").compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } }, selection: $module, fill: true)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Erstellen", kind: .primary) { Task { await create() } }
        }
        .onAppear {
            if title.isEmpty { title = kind == "whiteboard" ? "Whiteboard" : "Notizen" }
            if format.isEmpty { format = kind == "whiteboard" ? PageFormats.defaultWhiteboard : PageFormats.defaultNotebook }
            module = moduleID ?? 0
        }
    }

    private func create() async {
        guard let api = session.api else { return }
        // Tarif inzwischen ohne Schreiben (z. B. Abo abgelaufen, waehrend der Dialog offen war)
        guard Entitlements.shared.allows(Self.feature) else {
            toast.show("Notizbücher und Whiteboards gibt es mit Plus.")
            return
        }
        var fields = Self.fields(kind: kind, title: title, template: tpl, format: format, orientation: orientation)
        if module != 0 { fields["module_id"] = "\(module)" }
        if let folderID { fields["folder_id"] = "\(folderID)" }
        do {
            let r = try await api.form("/api/notebooks", fields: fields)
            close()
            if let id = r.s("id") { router.go(.doc(id)) }
        } catch { toast.show(error.localizedDescription) }
    }
}

extension NotebookDialog {
    /// Formularfelder fuer POST /api/notebooks wie notebookDialog im Web (`w`/`h` aus `formatSize(fmt, orient)`)
    static func fields(kind: String, title: String, template: String, format: String,
                       orientation: PageFormats.Orientation) -> [String: String] {
        var f = ["kind": kind, "title": title.isEmpty ? "Notizen" : title, "template": template]
        if let s = PageFormats.size(format, orientation) {
            f["w"] = String(s.width)
            f["h"] = String(s.height)
        }
        return f
    }
}

/// .ed-tpl: Vorschau einer Seitenvorlage (liniert, kariert, gepunktet, Millimeter, Cornell)
struct UFTemplatePreview: View {
    let template: String

    var body: some View {
        Canvas { ctx, size in
            let line = Color(hex: 0xd9dde8)
            switch template {
            case "lined", "cornell":
                var y: CGFloat = 7
                while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(line)); y += 8 }
                if template == "cornell" { ctx.fill(Path(CGRect(x: 14, y: 0, width: 1, height: size.height)), with: .color(Color(hex: 0xb9c2d6))) }
            case "grid", "mm":
                let step: CGFloat = template == "grid" ? 8 : 4
                let c = template == "grid" ? line : Color(hex: 0xe6e9f0)
                var x: CGFloat = 0
                while x < size.width { ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(c)); x += step }
                var y: CGFloat = 0
                while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(c)); y += step }
            case "dotted":
                var y: CGFloat = 0.5
                while y < size.height {
                    var x: CGFloat = 0.5
                    while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(Color(hex: 0xc9ced9))); x += 8 }
                    y += 8
                }
            default: break
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0xd9dde8), lineWidth: 1))
    }
}

/// Ordner „X“: Umbenennen (prompt), Farbe (prompt Hex), Ordner loeschen (confirm, Inhalt bleibt)
struct LibraryFolderMenu: View {
    let folder: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        let id = folder.i("id") ?? 0
        UFDialog("Ordner „\(folder.s("name") ?? "")“") {
            VStack(spacing: 8) {
                // Fehler sichtbar (vorher try?: die Seite lud neu, als waere es gelungen)
                UFMenuButton(text: "Umbenennen", icon: "pencil") {
                    close()
                    Task {
                        if let n = await overlay.prompt("Neuer Name:", value: folder.s("name") ?? ""), !n.isEmpty, let api = session.api,
                           await toast.attempt("Umbenennen", { _ = try await api.value("/api/folders/\(id)", method: "PATCH", body: ["name": .string(n)]) }) {
                            router.reload()
                        }
                    }
                }
                UFMenuButton(text: "Farbe", icon: "circle") {
                    close()
                    Task {
                        if let c = await overlay.prompt("Farbe (Hex):", value: folder.s("color") ?? "#4f8ef7"), !c.isEmpty, let api = session.api,
                           await toast.attempt("Farbe speichern", { _ = try await api.value("/api/folders/\(id)", method: "PATCH", body: ["color": .string(c)]) }) {
                            router.reload()
                        }
                    }
                }
                UFMenuButton(text: "Ordner löschen (Inhalt bleibt erhalten)", icon: "trash", kind: .danger) {
                    close()
                    Task {
                        if await overlay.confirm("Ordner löschen? Dokumente bleiben erhalten."), let api = session.api,
                           await toast.attempt("Ordner löschen", { _ = try await api.value("/api/folders/\(id)", method: "DELETE") }) {
                            router.reload()
                        }
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
    }
}

/// Modul-Menue auf der Ordnerkarte. Im Web ohne Zweig (TypeError, s. Bestandsaufnahme E.3); nativ: Öffnen und Bearbeiten.
struct LibraryModuleMenu: View {
    let module: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog(module.s("name") ?? "Modul") {
            VStack(spacing: 8) {
                UFMenuButton(text: "Öffnen", icon: "folder") { close(); router.go(.files(path: "m\(module.i("id") ?? 0)")) }
                UFMenuButton(text: "Modul bearbeiten", icon: "settings") {
                    close()
                    Task {
                        guard let id = module.i("id"), let api = session.api else { return }
                        await toast.attempt("Modul laden") {
                            let d = try await api.value("/api/modules/\(id)")
                            if let m = d["module"] { overlay.modal { ModuleEditDialog(m: m) } }
                        }
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
    }
}

/// Papierkorb: Wiederherstellen / Endgueltig loeschen (ohne Rueckfrage wie im Web), Fehler als Toast
struct LibraryTrashMenu: View {
    let id: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Papierkorb") {
            VStack(spacing: 8) {
                UFMenuButton(text: "Wiederherstellen", icon: "rotate") { run(["restore": true]) }
                UFMenuButton(text: "Endgültig löschen", icon: "trash", kind: .danger) { run(["delete_forever": true]) }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
    }

    private func run(_ body: JSONValue) {
        close()
        Task {
            do {
                if let api = session.api {
                    _ = try await api.value("/api/library/files/\(id)", method: "PATCH", body: body)
                    // endgueltig geloescht: auch Zwischenspeicher, Journal und Vorschauen dieses Dokuments auf dem Geraet
                    if body["delete_forever"] == true { AppPaths.removeDocumentCopies(fileID: id, namespace: api.namespace) }
                }
            } catch { toast.show(error.localizedDescription, seconds: 4) }
            router.reload()
        }
    }
}

/// Dokument-Menue: Öffnen, Favorit, Umbenennen, In Ordner verschieben, Duplizieren, Original herunterladen, Papierkorb
struct LibraryDocMenu: View {
    let f: JSONValue
    let lib: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        let id = f.s("id") ?? ""
        let own = f.s("course_id") == "__user__"
        let fav = f.i("favorite") == 1
        UFDialog(f.s("title") ?? "") {
            VStack(spacing: 8) {
                UFMenuButton(text: "Öffnen", icon: "book") { close(); router.go(.doc(id)) }
                UFMenuButton(text: fav ? "Aus Favoriten entfernen" : "Zu Favoriten", icon: "star") {
                    close()
                    Task { await patch("Favorit ändern") { try await $0.value("/api/files/\(id)/favorite", method: "POST", body: ["favorite": .bool(!fav)]) } }
                }
                UFMenuButton(text: "Umbenennen", icon: "pencil") {
                    close()
                    Task {
                        if let n = await overlay.prompt("Neuer Titel:", value: f.s("title") ?? ""), !n.isEmpty {
                            await patch("Umbenennen") { try await $0.value("/api/library/files/\(id)", method: "PATCH", body: ["title": .string(n)]) }
                        }
                    }
                }
                UFMenuButton(text: "In Ordner verschieben", icon: "move") { close(); overlay.modal { LibraryMoveDialog(id: id, lib: lib) } }
                UFMenuButton(text: "Duplizieren", icon: "copy") {
                    close()
                    Task { await patch("Duplizieren") { try await $0.value("/api/library/files/\(id)", method: "PATCH", body: ["duplicate": true]) } }
                }
                if f.s("kind") == "pdf" && f.s("downloaded_at") != nil {
                    UFMenuButton(text: "Original herunterladen", icon: "download") { close(); Task { await download(id) } }
                }
                UFMenuButton(text: "In den Papierkorb", icon: "trash", kind: .danger) {
                    close()
                    Task {
                        let ok = await overlay.confirm(own ? "In den Papierkorb legen?"
                                                       : "In den Papierkorb legen? Das Stud.IP-Original bleibt auf dem Server und kann wiederhergestellt werden.")
                        if ok { await patch("In den Papierkorb legen") { try await $0.value("/api/library/files/\(id)", method: "PATCH", body: ["trash": true]) } }
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
    }

    /// Aenderung am Dokument mit sichtbarem Fehler; neu laden nur, wenn sie gelang (vorher try? und immer neu laden)
    private func patch(_ what: String, _ call: (APIClient) async throws -> JSONValue) async {
        guard let api = session.api else { return }
        if await toast.attempt(what, { _ = try await call(api) }) { router.reload() }
    }

    /// <a download>: auf dem iPad ueber das Teilen-Menue (Sichern in Dateien). Der Name kommt ungeprueft aus
    /// Stud.IP/Learnweb: bereinigt in einem eigenen Ordner des Containers (`AppTemp`), Fehler mit Meldung
    private func download(_ id: String) async {
        guard let api = session.api, let (data, http) = try? await api.data("/api/files/\(id)/content"), (200..<300).contains(http.statusCode) else {
            toast.show("Download fehlgeschlagen")
            return
        }
        do {
            let url = try AppTemp.file("download", name: f.s("name") ?? "\(id).pdf")
            try data.write(to: url, options: .atomic)
            UFShare.present([url])
        } catch {
            toast.show("Datei ließ sich nicht ablegen: \(error.localizedDescription)", seconds: 5)
        }
    }
}

/// Modal "Verschieben nach": (kein Ordner …) oder "Modul › Ordner"
struct LibraryMoveDialog: View {
    let id: String
    let lib: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var folder = 0

    var body: some View {
        let modules = lib.list("modules")
        UFDialog("Verschieben nach") {
            UFSelect(options: [(0, "(kein Ordner – Stammebene / Modulordner)")] + lib.list("folders").compactMap { fo in
                fo.i("id").map { fid in
                    let mod = fo.i("module_id").flatMap { mid in modules.first { $0.i("id") == mid }?.s("name") }
                    return (fid, (mod.map { $0 + " › " } ?? "") + (fo.s("name") ?? ""))
                }
            }, selection: $folder, fill: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Verschieben", kind: .primary) {
                Task {
                    guard let api = session.api else { return }
                    // Fehler sichtbar, der Dialog bleibt dann offen (vorher try?, schliessen, neu laden)
                    if await toast.attempt("Verschieben", {
                        _ = try await api.value("/api/library/files/\(id)", method: "PATCH", body: ["folder_id": folder == 0 ? .null : .number(Double(folder))])
                    }) {
                        close()
                        router.reload()
                    }
                }
            }
        }
    }
}

/// Teilen-Menue von iPadOS (Download/Export)
@MainActor
enum UFShare {
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        vc.popoverPresentationController?.permittedArrowDirections = []
        top.present(vc, animated: true)
    }
}
