import SwiftUI
import UniFlowCore

/// Formelblatt auf der Modulseite (Auftrag des Inhabers 22.11.2026): mit Pro AI zum passenden Modul einmal fuer feste
/// Credits kaufen (zuerst „Grundlagen digitaler Systeme“, 3 Credits), danach jederzeit öffnen. Daten vom Geraet
/// (`/api/modules/{id}/formelblatt`, im Kern `FormelblattShop`); ohne Angebot zeigt die Stelle nichts.
enum Formelblatt {
    static let folderName = "Formelblätter"
    static let note = "Vorlage zum Abschreiben: In die Kurzklausur darf nur ein handbeschriebenes Blatt."
    static let savedNote = "Liegt in der Bibliothek im Ordner „Formelblätter“ dieses Moduls."
    static let newVersion = "Es gibt eine neue Fassung. Laden kostet nichts."
    static let open = "Öffnen"
    static let load = "Laden"
    static let loadNew = "Neue Fassung laden"

    static func buyButton(_ credits: Int) -> String { "Für \(credits) Credits kaufen" }
    static func facts(pages: Int?, credits: Int) -> String {
        [pages.map { $0 == 1 ? "1 Seite" : "\($0) Seiten" }, "einmalig \(credits) Credits"].compactMap { $0 }.joined(separator: " · ")
    }
    static func confirmTitle(_ credits: Int) -> String { "Formelblatt für \(credits) Credits kaufen?" }
    static let confirmText = "Die Credits werden einmal abgebucht. Gekauft bleibt gekauft, auch auf deinen anderen Geräten und für neue Fassungen."
    static func bought(_ credits: Int) -> String { credits > 0 ? "Gekauft für \(credits) Credits. Das Formelblatt liegt jetzt im Modul." : "Das Formelblatt liegt jetzt im Modul." }
}

struct FormelblattCard: View {
    let moduleID: Int

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufStudoraAccount) private var account
    @State private var items: [JSONValue] = []
    @State private var busy: String?
    @State private var confirm: JSONValue?
    @State private var error: String?
    @State private var shop = false

    var body: some View {
        // VStack statt Group (22.11.2026, am iPad gesehen): an einer leeren Group laufen .task und .alert nie, das
        // Angebot wurde also nie geladen und die Karte blieb unsichtbar. Der leere VStack ist 0 pt hoch.
        VStack(spacing: 0) {
            if items.isEmpty {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            } else {
                ForEach(Row.rows(items, key: "id")) { row in card(row.value) }
            }
        }
        .task(id: "\(moduleID)|\(router.reloadToken)") { await load() }
        .alert(Formelblatt.confirmTitle(confirm?.i("credits") ?? 0), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Abbrechen", role: .cancel) { confirm = nil }
            Button(Formelblatt.buyButton(confirm?.i("credits") ?? 0)) {
                if let it = confirm { Task { await get(it) } }
                confirm = nil
            }
        } message: {
            Text(Formelblatt.confirmText)
        }
        .ufCreditShop(isPresented: $shop)
    }

    private func card(_ it: JSONValue) -> some View {
        let credits = it.i("credits") ?? 0
        let fileID = it.s("file_id")
        let owned = it["owned"]?.bool == true
        let current = it["current"]?.bool != false
        return UFCard {
            UFCardHead(it.s("title") ?? "Formelblatt", icon: "file", wrap: true) { EmptyView() }
            if let d = it.s("description"), !d.isEmpty {
                Text(d).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            }
            Text(Formelblatt.facts(pages: it.i("pages"), credits: credits)).ufFont(12.8, 600).foregroundStyle(UF.muted).padding(.top, 4)
            if let error {
                Text(error).ufFont(13.6, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    .accessibilityIdentifier("formelblatt.error")
            }
            HStack(spacing: 8) {
                if let fileID {
                    UFButton(Formelblatt.open, icon: "file", kind: .primary, size: .small) { router.go(.doc(fileID)) }
                        .accessibilityIdentifier("formelblatt.open")
                    if !current {
                        UFButton(Formelblatt.loadNew, icon: "refresh", kind: .ghost, size: .small) { Task { await get(it) } }
                            .disabled(busy != nil)
                    }
                } else if owned {
                    UFButton(Formelblatt.load, icon: "refresh", kind: .primary, size: .small) { Task { await get(it) } }
                        .disabled(busy != nil).accessibilityIdentifier("formelblatt.load")
                } else {
                    UFButton(Formelblatt.buyButton(credits), icon: "sparkles", kind: .primary, size: .small) { confirm = it }
                        .disabled(busy != nil).accessibilityIdentifier("formelblatt.buy")
                }
                if busy == it.s("id") { ProgressView().controlSize(.small) }
            }
            .padding(.top, 10)
            Text(fileID != nil && !current ? Formelblatt.newVersion : fileID != nil ? Formelblatt.savedNote : Formelblatt.note)
                .ufFont(12.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
        .padding(.bottom, 14.4)
        .accessibilityIdentifier("formelblatt.card")
    }

    private func load() async {
        guard let api = session.api, api.isLocal else { return }
        do {
            let list = try await api.value("/api/modules/\(moduleID)/formelblatt").list("items")
            StiftSpur.log("Formelblatt: Modul \(moduleID), Angebote \(list.count)")
            if list != items { items = list }
        } catch {
            StiftSpur.log("Formelblatt: Modul \(moduleID), Fehler \(error.localizedDescription)")
        }
    }

    private func get(_ it: JSONValue) async {
        guard let api = session.api, let id = it.s("id") else { return }
        busy = id
        defer { busy = nil }
        do {
            let v = try await api.value("/api/modules/\(moduleID)/formelblatt/\(id)/get", method: "POST", body: .object([:]))
            error = nil
            await account?.refreshCredits()
            toast.show(Formelblatt.bought(v.i("credits_charged") ?? 0), seconds: 4)
            await load()
            if let fid = v.s("file_id") { router.go(.doc(fid)) }
        } catch let e as APIError {
            if e.code == "credits_exhausted" { shop = true }
            error = e.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
