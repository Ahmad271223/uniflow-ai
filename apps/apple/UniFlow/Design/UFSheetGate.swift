import SwiftUI

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

struct UFSheetFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: onDismiss) { UFSheetGate(content: sheetContent) }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFSheetItem<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(item: $item, onDismiss: onDismiss) { i in UFSheetGate { sheetContent(i) } }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFCoverFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) { UFSheetGate(content: sheetContent) }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFCoverItem<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item, onDismiss: onDismiss) { i in UFSheetGate { sheetContent(i) } }
            .environment(\.ufSheetEnvironment, true)
    }
}

struct UFPopoverFlag<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let attachmentAnchor: PopoverAttachmentAnchor
    let arrowEdge: Edge?
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) { UFSheetGate(content: sheetContent) }
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
