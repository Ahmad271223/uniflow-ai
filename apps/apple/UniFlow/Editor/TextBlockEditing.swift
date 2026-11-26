import PDFKit
import UIKit
import UniFlowCore

// Textbloecke "wie Word" im Editor (Auftrag des Inhabers 25.11.2026: "bei einem Blatt, was blanko ist oder liniert,
// soll man abtippen können, Texte sollen immer richtig formatiert sein, mehrere Blöcke, alte Blöcke 3 Sek. antippen,
// dann verschieben, verkleinern usw., dicker, andere Schriftart, bei liniert immer auf den Zeilen"):
// - Tippen: eine Textansicht mit demselben Zeilensatz wie die Anzeige (`TextBlockRender.Layout`) - was man beim
//   Tippen sieht, steht danach genauso auf der Seite, auf linierten Seiten auf den Linien.
// - Formatieren: fett, kursiv, unterstrichen, durchgestrichen, markieren, Farbe, Schriftart, Groesse fuer die Auswahl
//   im Text (ohne Auswahl: fuer das, was als Naechstes getippt wird) oder fuer ganze gewaehlte Bloecke; Ausrichtung
//   und Listen.
// - Langes Druecken auf einen Block greift ihn: ziehen verschiebt, die Anfasser an den Ecken aendern die Breite.

/// Laufendes Bearbeiten eines Texts
struct TextEdit {
    let key: String
    let id: String
    let view: UITextView
    /// noch nicht auf der Seite (kommt mit dem ersten Text bzw. dem ersten Zwischenstand dorthin)
    var isNew: Bool
    let layout: TextBlockRender.Layout
    /// Objekt beim Beginn; Aenderungen am ganzen Block waehrend des Tippens (Ausrichtung) stehen hier
    var object: JSONValue
    /// waehrend des Bearbeitens wurde formatiert: das Objekt wird ein Textblock
    var formatted = false
}

/// Stand fuer die Leiste "Text": gemeinsame Formatierung der Auswahl
struct TextFormat: Equatable {
    var style: TextBlock.Style
    var align: String
    /// es wird gerade getippt (sonst: ganze Bloecke gewaehlt)
    var editing: Bool
    /// der Block sitzt auf den Linien der Seite
    var lined: Bool
    /// die Auswahl besteht aus Haftnotizen/Zetteln: ihr Aussehen (Leiste: Menue "Zettel")
    var note: StickyNote.Choice?
}

extension ObjectEditing {
    /// So lange gedrueckt halten greift einen Textblock. EINE ZEILE ZUM UMSTELLEN (der Inhaber hat 3 Sekunden bestellt).
    static var holdSeconds: TimeInterval = 3
    static let holdHint = "Block gegriffen – ziehen verschiebt ihn, an den Ecken änderst du die Breite."

    // MARK: Anlegen

    /// Vorlage der Seite (liniert, kariert ...); nil bei PDF-Seiten
    func template(forKey key: String) -> String? {
        guard let layout = controller?.store.layout, let i = layout.index(ofKey: key) else { return nil }
        return layout.entry(at: i)?.template
    }

    /// Tarif erlaubt Textbloecke "wie Word" (ab Pro AI, `UFRichNotes`)
    var richAllowed: Bool { controller?.richNotes == true }

    /// Neue Haftnotiz am Tippunkt: mit Pro AI der Zettel aus den Einstellungen des Werkzeugs (Farbe, Aussehen, Papier,
    /// Groesse), sonst die gelbe Haftnotiz wie in 1.0.7
    func newSticky(id: String, on overlay: PageInkView?, at p: CGPoint) -> JSONValue {
        guard richAllowed else { return PageObjectEdit.sticky(id: id, x: Double(p.x), y: Double(p.y)) }
        let page = overlay.map { (width: Double($0.geometry.pageSize.width), height: Double($0.geometry.pageSize.height)) }
        return StickyNote.note(id: id, x: Double(p.x), y: Double(p.y), choice: EditorPalette.stickyChoice, page: page)
    }

    /// Gewaehlte Zettel umgestalten (Farbe, Aussehen, Papier, Groesse); ein Rueckgaengig-Schritt
    func restyleNotes(_ change: @escaping (inout StickyNote.Choice) -> Void) {
        guard richAllowed, editing == nil, let sel = selection else { return }
        inOrder { await $0.commit(sel.key) { StickyNote.restyling($0, ids: sel.ids, change) } }
    }

    /// Neuer Textblock am Tippunkt: auf Seiten mit Linien sitzt er auf der Linie, die Breite reicht bis zum rechten Rand.
    /// Ohne Pro AI: das einfache Textfeld wie in 1.0.7.
    func newBlock(id: String, on overlay: PageInkView, at p: CGPoint) -> JSONValue {
        guard richAllowed else { return PageObjectEdit.text(id: id, x: Double(p.x), y: Double(p.y)) }
        return TextBlock.block(id: id, x: Double(p.x), y: Double(p.y), template: template(forKey: overlay.pageKey),
                        pageWidth: Double(overlay.geometry.pageSize.width))
    }

    // MARK: Langes Druecken greift einen Block

    func installHold() {
        guard let c = controller, hold.view == nil else { return }
        c.pdfView.addGestureRecognizer(hold)
    }

    /// Was sich mit langem Druecken greifen laesst: Textobjekt (Block, Textfeld, Haftnotiz) oder Klappkarte unter dem Punkt
    func textObject(on overlay: PageInkView, at p: CGPoint) -> String? {
        let list = overlay.objectsView.shownObjects
        // Klappkarten liegen ueber allem: sie zuerst
        if let top = TopObjects.hit(list, x: Double(p.x), y: Double(p.y))?["id"]?.string { return top }
        guard let id = PageObjectEdit.hit(list, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight),
              list.first(where: { $0["id"]?.string == id })?["type"]?.string == "text" else { return nil }
        return id
    }

    /// Darf das lange Druecken mit dieser Beruehrung beginnen? Mit einem Objektwerkzeug immer (die Zeichenflaeche nimmt
    /// dann nichts an). Beim Schreiben mit dem Stift nur mit dem Finger, und nur wenn der Finger nicht selbst schreibt -
    /// ein ruhender Stift oder ein schreibender Finger zeichnen, sie greifen keinen Block.
    func holdAccepts(touchType: UITouch.TouchType) -> Bool {
        guard let c = controller, c.writable, c.richNotes, c.correction == nil, c.freezeMode == .off else { return false }
        if isActive { return tool == .select || tool == .text || tool == .sticky }
        return touchType == .direct && c.pencilOnly && !PDFEditorController.isMac
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === pan { panDown = touch.location(in: nil) }
        // im Text, der gerade getippt wird, gehoeren Tipp und Doppeltipp der Textansicht (Schreibmarke setzen, Wort
        // markieren): Vorher beendete jeder Tipp das Tippen, und der Doppeltipp begann es mit dem ALTEN Text neu -
        // das seither Getippte war weg
        if g === tap || g === doubleTap, let view = editing?.view, view.bounds.contains(touch.location(in: view)) { return false }
        guard g === hold else { return true }
        guard holdAccepts(touchType: touch.type) else { return false }
        // im Text, der gerade getippt wird, gehoert das lange Druecken der Textauswahl
        if let view = editing?.view, view.bounds.contains(touch.location(in: view)) { return false }
        return true
    }

    func holdShouldBegin() -> Bool {
        guard grab == nil, !transferring, let (overlay, p) = locate(hold) else { return false }
        // beim Schreiben liegt die Hand oft sekundenlang still auf der Seite: Solange der Stift in dieser Zeit
        // geschrieben hat, greift das Halten nichts (sonst wechselte der Editor mitten im Satz auf "Auswählen")
        if !isActive, overlay.touchTracker.sincePencil < Self.holdSeconds { return false }
        return textObject(on: overlay, at: p) != nil
    }

    @objc func held(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard let (overlay, p) = locate(g), let id = textObject(on: overlay, at: p) else { return }
            grabBlock(id, on: overlay, at: p)
        case .changed:
            guard let gr = grab, case .move = gr.kind, let start = holdStart else { return }
            let now = g.location(in: gr.overlay.content)
            preview(.move(moveOffset(gr, CGPoint(x: now.x - start.x, y: now.y - start.y))))
        case .ended:
            guard holdStart != nil else { return }
            holdStart = nil
            if let gr = grab, case .move = gr.kind { finishGrab() }
        default:
            guard holdStart != nil else { return }
            holdStart = nil
            cancelGrab()
        }
    }

    /// Block auswaehlen (Rahmen mit Anfassern, Leiste "Text") und zum Verschieben greifen. `p`: Punkt der Seite, an dem
    /// der Finger liegt.
    func grabBlock(_ id: String, on overlay: PageInkView, at p: CGPoint) {
        endTextEditing()
        if selection?.ids.contains(id) != true || !isActive || tool != .select {
            controller?.choose(.select)
            select(key: overlay.pageKey, ids: [id], in: overlay.objectsView.shownObjects)
        }
        guard selection?.ids.contains(id) == true, isActive else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        controller?.onHint?(Self.holdHint)
        holdStart = p
        beginGrab(.move, on: overlay)
    }

    // MARK: Text bearbeiten (Tastatur, Diktat oder Scribble mit dem Pencil)

    func beginTextEditing(key: String, id: String, isNew: Bool) {
        // schon dabei: nicht mit dem gespeicherten (aelteren) Text neu beginnen
        if let e = editing, e.id == id, e.key == key { return }
        guard let overlay = controller?.boundOverlay(forKey: key) else { return }
        Task {
            guard let o = await objects(key).first(where: { $0["id"]?.string == id }), o["type"]?.string == "text" else { return }
            endTextEditing()
            startTextEditing(o, key: key, id: id, on: overlay, isNew: isNew)
        }
    }

    /// Neuen Text tippen (Textblock oder Haftnotiz): Das Objekt kommt erst mit dem ersten Text auf die Seite - ein
    /// Rueckgaengig-Schritt, und ein leer gelassenes Feld hinterlaesst nichts.
    func beginNewText(_ o: JSONValue, key: String) {
        guard let c = controller, c.writable, let overlay = c.boundOverlay(forKey: key), let id = o["id"]?.string else { return }
        endTextEditing()
        startTextEditing(o, key: key, id: id, on: overlay, isNew: true)
    }

    private func startTextEditing(_ o: JSONValue, key: String, id: String, on overlay: PageInkView, isNew: Bool) {
        let layout = TextBlockRender.layout(o)
        layout.container.widthTracksTextView = true
        let size = TextBlockRender.size(o)
        let view = UITextView(frame: CGRect(origin: .zero, size: size), textContainer: layout.container)
        view.textContainerInset = TextBlockRender.insets(o)
        view.isScrollEnabled = false
        view.clipsToBounds = false
        // durchsichtig: die Linien der Seite bleiben beim Tippen zu sehen (die Anzeige des Blocks ruht solange)
        view.backgroundColor = StickyNote.isNote(o) ? .clear : (ObjectGeometry.color(o["bg"]) ?? .clear)
        if StickyNote.isNote(o) {
            // Notizzettel: derselbe Zettel liegt beim Tippen unter dem Text und waechst mit
            view.insertSubview(StickyNoteBackdrop(object: o, frame: CGRect(origin: .zero, size: size)), at: 0)
        }
        view.overrideUserInterfaceStyle = .light
        view.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        // ist der Block gewaehlt, zeigt schon der Auswahlrahmen, wo getippt wird
        view.layer.borderWidth = selection?.ids.contains(id) == true || StickyNote.isNote(o) ? 0 : 1 / max(0.5, Self.screenScale(of: overlay))
        view.layer.cornerRadius = 3
        view.layer.anchorPoint = .zero
        view.frame = CGRect(x: ObjectGeometry.coordinate(o["x"], 0), y: ObjectGeometry.coordinate(o["y"], 0), width: size.width, height: size.height)
        view.transform = CGAffineTransform(rotationAngle: CGFloat((o["rotation"]?.double ?? 0) * .pi / 180))
        view.typingAttributes = Self.typingAttributes(at: layout.storage.length, in: layout.storage, object: o)
        view.delegate = self
        view.accessibilityIdentifier = "objects.textEditor"
        overlay.content.addSubview(view)
        overlay.objectsView.setHidden([id], true)
        editing = TextEdit(key: key, id: id, view: view, isNew: isNew, layout: layout, object: o)
        view.becomeFirstResponder()
        view.selectedRange = NSRange(location: layout.storage.length, length: 0)
        view.typingAttributes = Self.typingAttributes(at: layout.storage.length, in: layout.storage, object: o)
        sharpenEditor(view, on: overlay)
        publishFormat(nil)
    }

    /// Die Seite ist vergroessert (Seitenbreite am iPad rund 1,4- bis 2-fach): die Textansicht zeichnet in der Aufloesung
    /// der Anzeige, sonst waere der Text beim Tippen unscharf und spraenge beim Beenden auf scharf
    func sharpenEditor(_ view: UITextView, on overlay: PageInkView) {
        let scale = UIScreen.main.scale * min(8, max(1, Self.screenScale(of: overlay)))
        func walk(_ v: UIView) {
            if abs(v.contentScaleFactor - scale) > 0.01 { v.contentScaleFactor = scale }
            v.layer.sublayers?.forEach { if $0.delegate == nil { $0.contentsScale = scale } }
            v.subviews.forEach(walk)
        }
        walk(view)
    }

    /// Formatierung fuer das naechste getippte Zeichen: wie das Zeichen davor, im leeren Block die Grundformatierung
    static func typingAttributes(at index: Int, in text: NSAttributedString, object o: JSONValue) -> [NSAttributedString.Key: Any] {
        let base = TextBlock.baseStyle(o)
        let style = text.length == 0 ? base : TextBlockRender.style(in: text, at: index - 1, fallback: base)
        return TextBlockRender.attributes(style, paragraph: TextBlockRender.paragraphStyle(o))
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if editing?.view === textView { endTextEditing() }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let e = editing, e.view === textView else { return }
        repairStyles(e)
        fitEditor(e)
        if let overlay = controller?.boundOverlay(forKey: e.key) { sharpenEditor(textView, on: overlay) }
        publishFormat(nil)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let e = editing, e.view === textView else { return }
        // UIKit nimmt fuer das naechste Zeichen die Formatierung davor; fehlt unser Kennzeichen (leerer Text), die Grundformatierung
        if textView.selectedRange.length == 0, textView.typingAttributes[TextBlockRender.styleKey] == nil {
            textView.typingAttributes = Self.typingAttributes(at: textView.selectedRange.location, in: textView.textStorage, object: e.object)
        }
        publishFormat(nil)
    }

    /// Eingabetaste in einer Liste: naechster Punkt bzw. naechste Nummer; auf einem leeren Punkt endet die Liste
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", range.length == 0, let e = editing, e.view === textView else { return true }
        let whole = textView.textStorage.string as NSString
        let paragraph = whole.paragraphRange(for: NSRange(location: range.location, length: 0))
        let lineStart = paragraph.location
        let line = whole.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        // "12. November" ist keine Liste: Nummern zaehlen ab 1 oder als Fortsetzung der Zeile davor
        let previous = lineStart > 0 ? whole.substring(with: whole.paragraphRange(for: NSRange(location: lineStart - 1, length: 0))).trimmingCharacters(in: .newlines) : nil
        guard TextBlock.continuesList(line, previous: previous), let next = TextBlock.listContinuation(after: line) else { return true }
        // die Schreibmarke steht gleich hinter dem Listenzeichen, dahinter steht aber Text: eine gewoehnliche neue
        // Zeile (vorher verschwand das Listenzeichen)
        let rest = whole.substring(with: NSRange(location: range.location, length: NSMaxRange(paragraph) - range.location)).trimmingCharacters(in: .newlines)
        if next.insert == nil, !rest.isEmpty { return true }
        if let insert = next.insert {
            textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: insert, attributes: textView.typingAttributes))
            textView.selectedRange = NSRange(location: range.location + (insert as NSString).length, length: 0)
        } else {
            textView.textStorage.replaceCharacters(in: NSRange(location: lineStart, length: next.endLength), with: "")
            textView.selectedRange = NSRange(location: lineStart, length: 0)
        }
        textViewDidChange(textView)
        return false
    }

    /// Zeichen ohne unser Kennzeichen (eingefuegt aus einer anderen App, Diktat, Autokorrektur) bekommen die Formatierung
    /// des Zeichens davor bzw. die Grundformatierung - man sieht beim Tippen, was gespeichert wird.
    private func repairStyles(_ e: TextEdit) {
        let storage = e.view.textStorage
        guard storage.length > 0 else { return }
        var missing: [NSRange] = []
        storage.enumerateAttribute(TextBlockRender.styleKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if !(value is TextBlockRender.StyleBox) { missing.append(range) }
        }
        guard !missing.isEmpty else { return }
        let para = TextBlockRender.paragraphStyle(e.object), base = TextBlock.baseStyle(e.object)
        let selected = e.view.selectedRange
        storage.beginEditing()
        for r in missing {
            let before = r.location > 0 ? TextBlockRender.style(in: storage, at: r.location - 1, fallback: base) : base
            storage.setAttributes(TextBlockRender.attributes(before, paragraph: para), range: r)
        }
        storage.endEditing()
        e.view.selectedRange = selected
    }

    /// Hoehe der Textansicht nach dem Satz (waechst und schrumpft mit dem Text; auf Linien in ganzen Zeilen)
    func fitEditor(_ e: TextEdit, minHeight: CGFloat? = nil) {
        var h = e.layout.height
        if e.layout.storage.length == 0, e.layout.step == nil { h = ceil(TextBlockRender.font(TextBlock.baseStyle(e.object)).lineHeight) }
        let inset = TextBlockRender.insets(e.object)
        let size = CGSize(width: e.view.bounds.width, height: max(h + inset.top + inset.bottom, minHeight ?? CGFloat(StickyNote.minHeight(e.object))))
        if abs(e.view.bounds.height - size.height) > 0.01 { e.view.bounds = CGRect(origin: .zero, size: size) }
    }

    /// Text auf der Seite halten: Ist der Block beim Tippen unten oder rechts aus der Seite gewachsen, rueckt er so
    /// weit nach oben bzw. links, wie es geht (gedrehte Bloecke bleiben, wo sie sind). Vorher wurde der Text gespeichert,
    /// war aber auf der Seite und im Export nicht zu sehen.
    func keptOnPage(_ o: JSONValue, key: String) -> JSONValue {
        guard let page = controller?.boundOverlay(forKey: key)?.geometry.pageSize, (o["rotation"]?.double ?? 0) == 0,
              let x = o["x"]?.double, let y = o["y"]?.double else { return o }
        let size = TextBlockRender.size(o)
        var out = o
        if x + Double(size.width) > Double(page.width) { out["x"] = .number((max(0, Double(page.width - size.width)) * 100).rounded() / 100) }
        if y + Double(size.height) > Double(page.height) { out["y"] = .number((max(0, Double(page.height - size.height)) * 100).rounded() / 100) }
        return out
    }

    /// Zwischenstand sichern, ohne das Tippen zu beenden (die App geht in den Hintergrund): Beendet iOS sie dort, ist
    /// der Text nicht verloren. Ein neuer Block kommt dabei auf die Seite.
    func saveTextDraft() {
        guard var e = editing else { return }
        let text = NSAttributedString(attributedString: e.view.textStorage)
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let base = TextBlock.baseStyle(e.object)
        let runs = TextBlockRender.runs(from: text, fallback: base)
        let asBlock = TextBlock.isBlock(e.object) || e.formatted || runs.contains { $0.style != base }
        let align = e.object["align"]
        func written(_ o: JSONValue) -> JSONValue {
            var out = o
            if let align { out["align"] = align }
            return asBlock ? TextBlock.saving(runs, in: out) : (PageObjectEdit.set([out], ids: [e.id], "text", .string(text.string)).first ?? out)
        }
        if e.isNew {
            let saved = written(e.object)
            e.isNew = false
            editing = e
            Task { await commit(e.key) { list in list.contains { $0["id"]?.string == e.id } ? list : list + [saved] } }
        } else {
            Task { await commit(e.key) { list in list.map { $0["id"]?.string == e.id && $0["type"]?.string == "text" ? written($0) : $0 } } }
        }
    }

    /// Bearbeiten beenden: Text und Formatierung speichern; ein leeres Feld wird entfernt (sonst bliebe es unsichtbar
    /// auf der Seite)
    func endTextEditing() {
        guard let e = editing else { return }
        editing = nil
        let text = NSAttributedString(attributedString: e.view.textStorage)
        e.view.delegate = nil
        e.view.removeFromSuperview()
        controller?.boundOverlay(forKey: e.key)?.objectsView.setHidden([e.id], false)
        let base = TextBlock.baseStyle(e.object)
        let runs = TextBlockRender.runs(from: text, fallback: base)
        let align = e.object["align"]
        // einfaches Textfeld (Web, Haftnotiz) ohne Formatierung bleibt, was es war
        let asBlock = TextBlock.isBlock(e.object) || e.formatted || runs.contains { $0.style != base }
        publishFormat(nil)
        let empty = text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if e.isNew {
            // neu: erst jetzt auf die Seite, und nur mit Text
            guard !empty else { return }
            var out = e.object
            if let align { out["align"] = align }
            let saved = keptOnPage(asBlock ? TextBlock.saving(runs, in: out) : (PageObjectEdit.set([out], ids: [e.id], "text", .string(text.string)).first ?? out), key: e.key)
            Task { await commit(e.key) { $0 + [saved] } }
            return
        }
        Task {
            if empty {
                if selection?.ids.contains(e.id) == true { clearSelection() }
                await commit(e.key) { PageObjectEdit.delete($0, ids: [e.id]) }
            } else {
                await commit(e.key) { list in
                    list.map { o in
                        guard o["id"]?.string == e.id, o["type"]?.string == "text" else { return o }
                        var out = o
                        if let align { out["align"] = align }
                        return self.keptOnPage(asBlock ? TextBlock.saving(runs, in: out) : (PageObjectEdit.set([out], ids: [e.id], "text", .string(text.string)).first ?? out), key: e.key)
                    }
                }
            }
        }
    }

    // MARK: Formatieren (Leiste "Text")

    /// Formatierung beim Tippen: der markierte Text, sonst das, was als Naechstes getippt wird
    func editingFormat() -> TextFormat? {
        guard let e = editing else { return nil }
        let base = TextBlock.baseStyle(e.object)
        let range = e.view.selectedRange
        let style: TextBlock.Style
        if range.length > 0, NSMaxRange(range) <= e.view.textStorage.length {
            style = TextBlock.commonStyle(TextBlockRender.runs(from: e.view.textStorage.attributedSubstring(from: range), fallback: base), fallback: base)
        } else {
            style = (e.view.typingAttributes[TextBlockRender.styleKey] as? TextBlockRender.StyleBox)?.style
                ?? TextBlockRender.style(in: e.view.textStorage, at: range.location - 1, fallback: base)
        }
        return TextFormat(style: style, align: e.object["align"]?.string ?? "left", editing: true, lined: TextBlock.isSnapped(e.object),
                          note: StickyNote.isSticky(e.object) ? StickyNote.choice(e.object) : nil)
    }

    /// Formatierung gewaehlter Bloecke (nur wenn die Auswahl aus Text besteht)
    func selectionFormat(_ list: [JSONValue]) -> TextFormat? {
        guard let sel = selection, inkSelection == nil else { return nil }
        let chosen = list.filter { ($0["id"]?.string).map(sel.ids.contains) == true }
        guard let first = chosen.first, chosen.count == sel.ids.count, chosen.allSatisfy({ $0["type"]?.string == "text" }) else { return nil }
        let style = TextBlock.commonStyle(chosen.flatMap(TextBlock.runs), fallback: TextBlock.baseStyle(first))
        return TextFormat(style: style, align: first["align"]?.string ?? "left", editing: false, lined: TextBlock.isSnapped(first),
                          note: chosen.allSatisfy(StickyNote.isSticky) ? StickyNote.choice(first) : nil)
    }

    /// Formatierung aendern: beim Tippen die Auswahl im Text (ohne Auswahl das naechste Zeichen), sonst die gewaehlten Bloecke
    func format(_ change: TextBlock.Change) {
        guard richAllowed else { return }
        if let e = editing {
            let view = e.view, range = view.selectedRange
            let para = TextBlockRender.paragraphStyle(e.object), base = TextBlock.baseStyle(e.object)
            if range.length > 0 {
                TextBlockRender.apply(change, to: view.textStorage, range: range, fallback: base, paragraph: para)
                view.selectedRange = range
            } else {
                let current = (view.typingAttributes[TextBlockRender.styleKey] as? TextBlockRender.StyleBox)?.style
                    ?? TextBlockRender.style(in: view.textStorage, at: range.location - 1, fallback: base)
                view.typingAttributes = TextBlockRender.attributes(change.applied(to: current), paragraph: para)
            }
            editing?.formatted = true
            if let now = editing { fitEditor(now) }
            publishFormat(nil)
            return
        }
        guard let sel = selection else { return }
        inOrder { await $0.commit(sel.key) { TextBlock.applying(change, to: $0, ids: sel.ids) } }
    }

    /// Aenderungen an gewaehlten Bloecken nacheinander speichern: Zwei schnell hintereinander gedrueckte Knoepfe (fett,
    /// dann kursiv) laesen sonst beide denselben Stand der Seite, und der zweite ueberschriebe den ersten.
    func inOrder(_ work: @escaping @MainActor (ObjectEditing) async -> Void) {
        let before = formatQueue
        formatQueue = Task { [weak self] in
            await before?.value
            if let self { await work(self) }
        }
    }

    /// Ausrichtung des ganzen Blocks
    func setAlignment(_ align: String) {
        guard richAllowed, TextBlock.alignments.contains(align) else { return }
        if var e = editing {
            e.object["align"] = .string(align)
            e.formatted = true
            editing = e
            let para = TextBlockRender.paragraphStyle(e.object)
            let storage = e.view.textStorage
            storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: storage.length))
            var typing = e.view.typingAttributes
            typing[.paragraphStyle] = para
            e.view.typingAttributes = typing
            publishFormat(nil)
            return
        }
        guard let sel = selection else { return }
        inOrder { await $0.commit(sel.key) { TextBlock.aligning(align, $0, ids: sel.ids) } }
    }

    /// Aufzaehlung bzw. Nummerierung an und aus: beim Tippen die Zeilen der Auswahl, sonst alle Zeilen der Bloecke
    func toggleList(_ kind: TextBlock.ListKind) {
        guard richAllowed else { return }
        if let e = editing {
            let view = e.view
            let typing = view.typingAttributes
            let caret = Self.togglingList(kind, in: view.textStorage, range: view.selectedRange, attributes: typing)
            view.selectedRange = caret
            view.typingAttributes = typing
            editing?.formatted = true
            textViewDidChange(view)
            return
        }
        guard let sel = selection else { return }
        inOrder {
            await $0.commit(sel.key) { list in
                list.map { o in
                    guard let id = o["id"]?.string, sel.ids.contains(id), o["type"]?.string == "text" else { return o }
                    let base = TextBlock.baseStyle(o)
                    // immer ueber den Satz der Bloecke, damit die Abschnitte ihre Formatierung behalten
                    let text = NSMutableAttributedString()
                    let para = TextBlockRender.paragraphStyle(o)
                    for r in TextBlock.runs(o) { text.append(NSAttributedString(string: r.text, attributes: TextBlockRender.attributes(r.style, paragraph: para))) }
                    _ = Self.togglingList(kind, in: text, range: NSRange(location: 0, length: text.length),
                                          attributes: TextBlockRender.attributes(base, paragraph: para))
                    return TextBlock.setting(TextBlockRender.runs(from: text, fallback: base), in: o)
                }
            }
        }
    }

    /// Listenzeichen an den Zeilen des Bereichs setzen oder entfernen (`TextBlock.togglingList`). Ein neues Zeichen
    /// bekommt die Formatierung des ersten Zeichens seiner Zeile (leere Zeile: `attributes`). Rueckgabe: die Schreibmarke
    /// danach (Ende des bearbeiteten Bereichs).
    nonisolated static func togglingList(_ kind: TextBlock.ListKind, in text: NSMutableAttributedString, range: NSRange,
                                         attributes: [NSAttributedString.Key: Any]) -> NSRange {
        let whole = text.string as NSString
        let safe = NSRange(location: min(range.location, whole.length), length: min(range.length, max(0, whole.length - min(range.location, whole.length))))
        var block = whole.paragraphRange(for: safe)
        // der Zeilenumbruch am Ende gehoert nicht zur letzten Zeile
        var tail = 0
        if block.length > 0, whole.character(at: NSMaxRange(block) - 1) == 10 { tail = 1 }
        block.length -= tail
        let lines = whole.substring(with: block).components(separatedBy: "\n")
        let changed = TextBlock.togglingList(kind, lines: lines)
        // von hinten nach vorn, damit die Stellen davor gueltig bleiben
        var starts: [Int] = []
        var at = block.location
        for l in lines { starts.append(at); at += (l as NSString).length + 1 }
        var delta = 0
        text.beginEditing()
        for i in lines.indices.reversed() {
            let oldLength = TextBlock.listPrefix(of: lines[i])?.length ?? 0
            let newLength = TextBlock.listPrefix(of: changed[i])?.length ?? 0
            let rest = (lines[i] as NSString).length - oldLength
            let newPrefix = (changed[i] as NSString).substring(to: (changed[i] as NSString).length - rest)
            guard oldLength > 0 || newLength > 0 else { continue }
            let attrs = rest > 0 ? text.attributes(at: starts[i] + oldLength, effectiveRange: nil) : attributes
            text.replaceCharacters(in: NSRange(location: starts[i], length: oldLength), with: NSAttributedString(string: newPrefix, attributes: attrs))
            delta += (newPrefix as NSString).length - oldLength
        }
        text.endEditing()
        return NSRange(location: NSMaxRange(block) + delta, length: 0)
    }
}
