import SwiftUI
import UIKit
import UniFlowCore

/// Tabelle ("Excel", 26.11.2026) im Objektmodus: Werkzeug "Tabelle" legt beim Antippen eine an und oeffnet die grosse
/// Ansicht (`SheetEditorView`); Doppeltipp auf eine vorhandene oeffnet sie wieder. Anlegen und Bearbeiten ab Pro AI
/// (`UFRichNotes`), ansehen kann sie jeder - auch in geteilten Loesungen.
extension ObjectEditing {
    static let sheetLockedHint = "Tabellen mit Formeln und Diagrammen gibt es mit Pro AI."

    /// Neue Tabelle mit der linken oberen Ecke am Tippunkt
    func newSheet(id: String, on overlay: PageInkView, at p: CGPoint, isDocument: Bool = false) -> JSONValue {
        let page = (width: Double(overlay.geometry.pageSize.width), height: Double(overlay.geometry.pageSize.height))
        var s = Sheet()
        s.isDocument = isDocument
        return SheetObject.object(id: id, x: Double(p.x), y: Double(p.y), sheet: s, page: page)
    }

    /// Die Auswahl ist genau eine Tabelle (Objektleiste: "Tabelle bearbeiten")
    var selectedSheet: (key: String, id: String)? {
        guard let sel = selection, inkSelection == nil, sel.ids.count == 1, let id = sel.ids.first,
              let list = controller?.boundOverlay(forKey: sel.key)?.objectsView.shownObjects,
              let o = list.first(where: { $0["id"]?.string == id }), SheetObject.isSheet(o) else { return nil }
        return (sel.key, id)
    }

    /// Grosse Ansicht oeffnen: zum Bearbeiten mit Pro AI, sonst zum Ansehen (rollen, zoomen, kopieren) - eine lange
    /// Tabelle passt nicht ganz auf die Seite. `title`: Name im Kopf (Tabelle als eigene Datei: der Name des Dokuments).
    func openSheet(key: String, id: String, title: String = "Tabelle") {
        guard let c = controller else { return }
        guard c.presentedViewController == nil else { return }
        let readOnly = !richAllowed
        endTextEditing()
        Task {
            guard let o = await objects(key).first(where: { $0["id"]?.string == id }), let sheet = SheetObject.table(o) else { return }
            guard c.presentedViewController == nil else { return }
            let model = SheetEditorModel(sheet: sheet, title: title, readOnly: readOnly)
            if !readOnly {
                // KI-Hilfe ueber den vorhandenen Weg der KI-Hilfe (Einwilligung und Credits regelt er selbst)
                let api = c.store.api
                model.askAI = { [weak c] body in
                    let r = try await api.value("/api/ai/tutor", method: "POST", body: body)
                    c?.onAIResponse?(r)                      // neuer Credits-Stand fuer die Anzeigen der App
                    return r.s("answer") ?? ""
                }
                model.explainAIError = { [weak c] error in c?.aiErrorText?(error) ?? error.localizedDescription }
            }
            // "Fertig" schliesst die Ansicht selbst - auch wenn das Dokument darunter inzwischen gewechselt hat
            let shown = SheetHostBox()
            let host = UIHostingController(rootView: SheetEditorView(model: model, onSave: { [weak self] s in
                await self?.saveSheet(s, key: key, id: id, original: o) ?? false
            }, onClose: { shown.host?.dismiss(animated: true) }))
            shown.host = host
            host.modalPresentationStyle = .fullScreen
            c.present(host, animated: true)
        }
    }

    /// Tabelle als eigene Datei (Bibliothek: Neu → Tabelle): Das Dokument ist ein Notizbuch, dessen erste Seite eine
    /// Tabelle mit `sheet.doc` traegt - beim Oeffnen erscheint gleich die grosse Ansicht. Ein frisch angelegtes Dokument
    /// (`SheetDocuments.pending`) bekommt die Tabelle hier.
    func openDocumentSheetIfNeeded() {
        guard let c = controller, let key = c.store.pageKey(forPageIndex: 0) else { return }
        let fileID = c.store.file.id, title = c.store.file.displayTitle
        Task {
            let list = await objects(key)
            if let o = list.first(where: { SheetObject.table($0)?.isDocument == true }), let id = o["id"]?.string {
                openSheet(key: key, id: id, title: title)        // ohne Pro AI: zum Ansehen
                return
            }
            guard SheetDocuments.pending.remove(fileID) != nil, richAllowed else { return }
            let pageSize = c.boundOverlay(forKey: key)?.geometry.pageSize ?? CGSize(width: 842, height: 595)
            var s = Sheet(rows: 15, cols: 6)
            s.isDocument = true
            let id = PageOrder.uid()
            var o = SheetObject.object(id: id, x: 24, y: 24, sheet: s, page: (Double(pageSize.width), Double(pageSize.height)))
            // die Tabelle fuellt die Breite der Seite
            o["width"] = .number(Double(max(120, pageSize.width - 48)))
            guard await commit(key, undoable: false, { $0 + [o] }) else { return }
            openSheet(key: key, id: id, title: title)
        }
    }

    /// Tabelle zurueck auf die Seite schreiben (ein Rueckgaengig-Schritt). Ist sie gewachsen, bleibt sie auf der Seite
    /// (`SheetObject.fitted`). Ist das Objekt inzwischen von der Seite verschwunden (geloescht, Abgleich), kommt es
    /// wieder hin (`original`: das Objekt beim Oeffnen). `true`, wenn die Tabelle danach so auf der Seite steht.
    @discardableResult
    func saveSheet(_ sheet: Sheet, key: String, id: String, original: JSONValue? = nil) async -> Bool {
        guard let c = controller, c.writable else { return false }
        let page = c.boundOverlay(forKey: key).map { (width: Double($0.geometry.pageSize.width), height: Double($0.geometry.pageSize.height)) }
        func written(_ o: JSONValue) -> JSONValue {
            let saved = SheetObject.saving(sheet, in: o)
            return page.map { SheetObject.fitted(saved, page: $0) } ?? saved
        }
        await commit(key) { list in
            if list.contains(where: { $0["id"]?.string == id && SheetObject.isSheet($0) }) {
                return list.map { $0["id"]?.string == id && SheetObject.isSheet($0) ? written($0) : $0 }
            }
            guard let original, !list.contains(where: { $0["id"]?.string == id }) else { return list }
            return list + [written(original)]
        }
        // nicht dem Rueckgabewert trauen ("nichts geaendert" ist auch falsch): nachsehen, was auf der Seite steht
        let now = await objects(key).first { $0["id"]?.string == id }
        return now.flatMap(SheetObject.table) == Sheet(json: sheet.json)
    }
}

@MainActor
final class SheetHostBox {
    weak var host: UIViewController?
}

/// Tabellen als eigene Datei
@MainActor
enum SheetDocuments {
    /// Gerade in der Bibliothek angelegt: Beim ersten Oeffnen kommt die Tabelle auf die erste Seite
    static var pending = Set<String>()
    static let defaultTitle = "Tabelle"
}
