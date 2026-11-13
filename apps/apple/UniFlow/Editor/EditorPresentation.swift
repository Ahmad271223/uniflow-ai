import PDFKit
import UIKit

// Praesentationsansicht (11.11.2026, docs/EDITOR-VERBESSERUNGEN-2026-11-10.md): das Dokument ohne Leisten und Palette,
// jede Seite ganz im Bild, fuer Beamer oder zweiten Bildschirm (Mac: Fenster dorthin ziehen und Vollbild; iPad:
// Bildschirm spiegeln oder mit Stage Manager erweitern). Pfeiltasten, Leertaste, Bild auf/ab und Praesentations-
// Klicker blaettern seitenweise; Esc beendet.

extension PDFEditorController {
    func presentationModeChanged() {
        if presentationMode {
            if magnifier != nil { setMagnifier(false) }
            if objects.isActive { finishObjectTools() }
            showToolPicker(false)                           // feste Leiste weg
            fitPage()
        } else {
            let page = pdfView.currentPage
            restoreZoomLimits()
            showToolPicker(pickerAllowed)
            fitWidth()
            // zurueck auf Seitenbreite: dieselbe Seite oben zeigen (sonst stand die Ansicht mitten in ihrem leeren Teil)
            if Self.isMac, let page { DispatchQueue.main.async { [weak self] in self?.pdfView.go(to: page) } }
        }
    }

    /// Ganze Seite einpassen (Breite und Hoehe), Seite oben ausgerichtet
    func fitPage() {
        guard freezeMode == .off, let page = pdfView.currentPage else { return }
        let size = PageRenderer.size(of: page)
        let box = pdfView.bounds.inset(by: pdfView.safeAreaInsets)
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return }
        let s = Self.pageFitScale(page: size, in: box.size)
        if s < pdfView.minScaleFactor { pdfView.minScaleFactor = s }
        pdfView.scaleFactor = s
        pdfView.go(to: page)
    }

    /// Faktor, mit dem eine ganze Seite in die Flaeche passt (etwas Rand)
    nonisolated static func pageFitScale(page: CGSize, in box: CGSize) -> CGFloat {
        guard page.width > 0, page.height > 0 else { return 1 }
        return min(box.width / page.width, box.height / page.height) * 0.98
    }

    /// Tastenbefehl in der Praesentation: alles Blaettern geht seitenweise
    nonisolated static func presentationCommand(_ c: EditorNavigation.Command) -> EditorNavigation.Command {
        switch c {
        case .lineDown, .screenDown: return .right
        case .lineUp, .screenUp: return .left
        default: return c
        }
    }
}
