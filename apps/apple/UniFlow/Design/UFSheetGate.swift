import SwiftUI
import UIKit

// Blaetter am Mac ("Designed for iPad", Befund 14.11.2026, macOS 26.6, docs/MAC-DURCHLAUF-2026-11-14.md):
// SwiftUI baut den Inhalt eines Blatts dort einmal zu frueh auf, mit leerer Umgebung, noch bevor die Umgebung der
// oeffnenden Ansicht ankommt (`PresentationHostingController.init` liest `bridgedPresentation`). Liest eine Ansicht im
// Blatt dabei ein Umgebungsobjekt (`@EnvironmentObject`: Session, StudIPSync, …) und hat ihr `body` eine Verzweigung
// (`if`, `switch`), stuerzt die App ab: "No ObservableObject of type Session found". Am iPad und iPhone kommt die
// Umgebung vor dem ersten Aufbau an.
//
// Darum oeffnet die App Blaetter nur ueber `ufSheet`, `ufFullScreenCover` und `ufPopover`: Sie setzen ein Kennzeichen
// in die Umgebung der oeffnenden Ansicht, und der Inhalt wird am Mac erst aufgebaut, wenn das Kennzeichen im Blatt
// angekommen ist (dann sind auch alle Umgebungsobjekte da). Am iPad und iPhone wird der Inhalt wie bisher sofort
// aufgebaut. Neue Blaetter nie direkt mit `.sheet` oeffnen (`SheetGateAppTests` prueft die Quellen).

private struct UFSheetEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true, sobald die Umgebung der oeffnenden Ansicht im Blatt angekommen ist (gesetzt von `ufSheet` usw.)
    var ufSheetEnvironment: Bool {
        get { self[UFSheetEnvironmentKey.self] }
        set { self[UFSheetEnvironmentKey.self] = newValue }
    }
}

/// Inhalt eines Blatts: am Mac erst aufbauen, wenn die Umgebung da ist; sonst sofort
struct UFSheetGate<Content: View>: View {
    @Environment(\.ufSheetEnvironment) private var arrived
    let content: () -> Content

    /// Der Inhalt darf aufgebaut werden
    static func open(mac: Bool, arrived: Bool) -> Bool { !mac || arrived }

    var body: some View {
        if UFSheetGate<EmptyView>.open(mac: UFDevice.isMac, arrived: arrived) { content() }
    }
}

// Blatt und Hinweis zugleich (Meldung des Inhabers am Mac, 26.11.2026, Store-Version 1.0.7: "Auf meinem Mac gehen alle
// Buttons nicht"): Steht ein Hinweis (`.alert`, z. B. "Bitte neu anmelden" beim Start) und wird in dem Moment ein Blatt
// faellig (z. B. der einmalige Plus-Hinweis), lehnt UIKit das Blatt ab ("Attempt to present … which is already
// presenting <SwiftUI.PlatformAlertController>"). SwiftUI schliesst daraufhin den Hinweis von selbst, haelt das Blatt
// aber fuer offen und oeffnet bis zum Neustart der App kein weiteres mehr ("Currently, only presenting a single sheet is
// supported") - an iPad, iPhone und Mac gleich (`SheetNachHinweisAppTests`). Auch Zuruecknehmen und neu Verlangen hilft
// dann nicht. Darum haelt `UFSheetHold` ein faelliges Blatt zurueck, solange ein Hinweis steht, und gibt es frei, sobald
// der Hinweis beantwortet ist. Ein Blatt, das schon offen ist, bleibt offen (Rueckfragen aus einem Blatt heraus).

/// Haelt ein faelliges Blatt zurueck, solange ein Hinweis (UIAlertController) ueber einem Fenster der App steht
final class UFSheetHold: ObservableObject {
    /// zaehlt hoch, sobald der Hinweis weg ist: die oeffnende Ansicht fragt dann neu
    @Published private(set) var released = 0
    /// steht gerade ein Hinweis? (in Tests ersetzbar)
    var alertOnScreen: () -> Bool = UFSheetHold.alertOnScreen
    private var opened = false
    private var watching: Task<Void, Never>?

    /// Darf das Blatt jetzt offen sein? `wanted`: die Ansicht verlangt es
    func pass(_ wanted: Bool) -> Bool {
        guard wanted else {
            opened = false
            watching?.cancel()
            watching = nil
            return false
        }
        if opened { return true }
        if alertOnScreen() {
            watch()
            return false
        }
        opened = true
        return true
    }

    /// wartet, bis der Hinweis weg ist, und meldet es dann der Ansicht
    private func watch() {
        guard watching == nil else { return }
        watching = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.alertOnScreen() {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.watching = nil
            self.released += 1
        }
    }

    /// Bindung fuer `.sheet(isPresented:)` usw.: offen erst, wenn kein Hinweis steht
    func flag(_ isPresented: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { self.pass(isPresented.wrappedValue) }, set: { isPresented.wrappedValue = $0 })
    }

    /// Bindung fuer `.sheet(item:)` usw.
    func item<Item>(_ item: Binding<Item?>) -> Binding<Item?> {
        Binding(get: { self.pass(item.wrappedValue != nil) ? item.wrappedValue : nil }, set: { item.wrappedValue = $0 })
    }

    /// Hinweis ueber irgendeinem Fenster der App (auch waehrend er gerade verschwindet: UIKit lehnt bis zum Ende ab);
    /// ebenso der Hinweis zur KI-Einwilligung, den die App selbst ueber allem zeigt (`AIConsentHost`)
    static func alertOnScreen() -> Bool { presented { $0 is UIAlertController || $0 is AIConsentHost } }

    /// Irgendein Blatt, Vollbild-Blatt, Popover oder Hinweis ueber einem Fenster der App. Die umgekehrte Reihenfolge
    /// geht ebenfalls schief: verlangt die Wurzel einen Hinweis, waehrend ein Blatt offen ist, schliesst SwiftUI das
    /// Blatt, und der Hinweis erscheint nie. Von selbst kommende Fragen (`askForLoginIfDue`) warten darum, bis nichts
    /// mehr offen ist.
    static func presentationOnScreen() -> Bool { presented { _ in true } }

    private static func presented(_ match: (UIViewController) -> Bool) -> Bool {
        MainActor.assumeIsolated {
            for scene in UIApplication.shared.connectedScenes {
                guard let windows = (scene as? UIWindowScene)?.windows else { continue }
                for window in windows {
                    var controller = window.rootViewController?.presentedViewController
                    while let c = controller {
                        if match(c) { return true }
                        controller = c.presentedViewController
                    }
                }
            }
            return false
        }
    }
}

struct UFSheetFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent
    @StateObject private var hold = UFSheetHold()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: hold.flag($isPresented), onDismiss: onDismiss) { UFSheetGate(content: sheetContent) }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFSheetItem<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent
    @StateObject private var hold = UFSheetHold()

    func body(content: Content) -> some View {
        content
            .sheet(item: hold.item($item), onDismiss: onDismiss) { i in UFSheetGate { sheetContent(i) } }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFCoverFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent
    @StateObject private var hold = UFSheetHold()

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: hold.flag($isPresented), onDismiss: onDismiss) { UFSheetGate(content: sheetContent) }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFCoverItem<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent
    @StateObject private var hold = UFSheetHold()

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: hold.item($item), onDismiss: onDismiss) { i in UFSheetGate { sheetContent(i) } }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFPopoverFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let attachmentAnchor: PopoverAttachmentAnchor
    let arrowEdge: Edge?
    let sheetContent: () -> SheetContent
    @StateObject private var hold = UFSheetHold()

    func body(content: Content) -> some View {
        content
            .popover(isPresented: hold.flag($isPresented), attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) { UFSheetGate(content: sheetContent) }
            .environment(\.ufSheetEnvironment, true)
    }
}

extension View {
    /// Wie `.sheet(isPresented:onDismiss:content:)`, am Mac ohne den zu fruehen Aufbau des Inhalts (`UFSheetGate`)
    func ufSheet<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(UFSheetFlag(isPresented: isPresented, onDismiss: onDismiss, sheetContent: content))
    }

    /// Wie `.sheet(item:onDismiss:content:)`, am Mac ohne den zu fruehen Aufbau des Inhalts (`UFSheetGate`)
    func ufSheet<Item: Identifiable, C: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                              @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(UFSheetItem(item: item, onDismiss: onDismiss, sheetContent: content))
    }

    /// Wie `.fullScreenCover(isPresented:onDismiss:content:)`, am Mac ohne den zu fruehen Aufbau des Inhalts
    func ufFullScreenCover<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                    @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(UFCoverFlag(isPresented: isPresented, onDismiss: onDismiss, sheetContent: content))
    }

    /// Wie `.fullScreenCover(item:onDismiss:content:)`, am Mac ohne den zu fruehen Aufbau des Inhalts
    func ufFullScreenCover<Item: Identifiable, C: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                        @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(UFCoverItem(item: item, onDismiss: onDismiss, sheetContent: content))
    }

    /// Wie `.popover(isPresented:attachmentAnchor:arrowEdge:content:)`, am Mac ohne den zu fruehen Aufbau des Inhalts
    func ufPopover<C: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge? = nil,
                            @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(UFPopoverFlag(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge, sheetContent: content))
    }
}
