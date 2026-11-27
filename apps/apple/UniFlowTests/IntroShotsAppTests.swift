import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Bilder des neuen Einstiegs (Inhaber 13.11.2026) fuer Entwurf und Abnahme: mit UF_SCREENSHOT_DIR
/// (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) je Seite hell und dunkel, grosses iPad quer (13") und kleines hoch (11").
/// Nur erfundene Inhalte, keine Anfrage ans Netz. Preise wie im App Store (Plus 1,99 € im Monat, Pro AI 39,99 € im Jahr).
@MainActor
final class IntroShotsAppTests: XCTestCase {

    private static let big = CGSize(width: 1376, height: 1032)
    private static let small = CGSize(width: 834, height: 1194)
    private static let smallLandscape = CGSize(width: 1194, height: 834)

    static func sampleSetup(step: IntroSetupModel.Step) -> IntroSetupModel {
        var m = IntroSetupModel()
        m.name = "Ahmad"
        m.modules = [
            IntroSetupModule(moduleID: 1, name: "Analysis I", color: "#4f5bd5", planned: true, exam: "2027-02-08", examFromUni: true),
            IntroSetupModule(moduleID: 2, name: "Technische Mechanik", color: "#0ea5e9", planned: true, exam: "2027-02-18"),
            IntroSetupModule(moduleID: 3, name: "Programmieren", color: "#16a34a", planned: true),
            IntroSetupModule(moduleID: 4, name: "Lerngruppe Analysis I", color: "#f59e0b", planned: false),
        ]
        m.step = step
        return m
    }

    static func price(_ o: UFOffer) -> IntroPlanPrice? {
        switch o {
        case .plusMonthly: return IntroPlanPrice(display: "1,99 €", per: "/Monat", summary: "1,99 €/Monat, verlängert sich monatlich, jederzeit zum Laufzeitende kündbar",
                                                 button: "StudiNow Plus für 1,99 €/Monat")
        case .proAIMonthly: return IntroPlanPrice(display: "3,99 €", per: "/Monat", summary: "3,99 €/Monat, verlängert sich monatlich, jederzeit zum Laufzeitende kündbar",
                                                  button: "StudiNow Pro AI für 3,99 €/Monat")
        case .proAIYearly: return IntroPlanPrice(display: "39,99 €", per: "/Jahr", summary: "39,99 €/Jahr, verlängert sich jährlich, jederzeit zum Laufzeitende kündbar",
                                                 button: "StudiNow Pro AI für 39,99 €/Jahr", savings: o.savings)
        case .plusFiveYears: return IntroPlanPrice(display: "39,99 €", per: "einmalig", summary: UFOfferText.onceSummary(price: "39,99 €", years: 5),
                                                   button: UFOfferText.onceButton(price: "39,99 €", years: 5), savings: o.savings)
        }
    }

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pages: [(String, AnyView)] = [
            ("1-willkommen", AnyView(IntroWelcomeLayout(onSignIn: { _ in }))),
            ("2-rundgang", AnyView(IntroTourLayout(page: .uni, onNext: {}, onSkip: {}))),
            ("2c-rundgang-lernplan", AnyView(IntroTourLayout(page: .plan, onBack: {}, onNext: {}, onSkip: {}))),
            ("2d-rundgang-notizen", AnyView(IntroTourLayout(page: .notes, onBack: {}, onNext: {}, onSkip: {}))),
            ("2e-hochschule", AnyView(UniversityPickerView { _ in })),
            ("3a-fragen-name", AnyView(IntroSetupShot(model: Self.sampleSetup(step: .name)))),
            ("3a2-fragen-faecher", AnyView(IntroSetupShot(model: Self.sampleSetup(step: .modules)))),
            ("2b-rundgang-pruefungen", AnyView(IntroTourLayout(page: .exams, onBack: {}, onNext: {}, onSkip: {}))),
            ("3-fragen-pruefungen", AnyView(IntroSetupShot(model: Self.sampleSetup(step: .exams)))),
            ("3b-fragen-fertig", AnyView(IntroSetupShot(model: Self.sampleSetup(step: .ready)))),
            ("4-tarif", AnyView(IntroPlanShot())),
        ]
        for (name, view) in pages {
            try shoot(view, name: name + "-gross", size: Self.big, dir: dir)
            try shoot(view, name: name + "-klein", size: Self.small, dir: dir)
            try shoot(view, name: name + "-klein-quer", size: Self.smallLandscape, dir: dir)
        }
    }

    /// Viele Module (24.11.2026, Bild des Inhabers vom iPad): die Liste "Wann sind deine anderen Prüfungen?" muss sich
    /// im breiten Layout scrollen lassen, sonst sind die unteren Module und "Weiter" nicht erreichbar. Mit
    /// UF_SCREENSHOT_DIR entsteht dazu das Bild "3-fragen-pruefungen-viele".
    func testExamListScrollsWithManyModulesOnTheIPad() throws {
        var m = Self.sampleSetup(step: .exams)
        m.modules = (1...14).map { IntroSetupModule(moduleID: $0, name: "Modul \($0) mit einem längeren Namen", color: "#4f5bd5", planned: true) }
        let view = AnyView(IntroSetupShot(model: m))
        let frame = CGRect(origin: .zero, size: Self.smallLandscape)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        func scrollViews(_ v: UIView) -> [UIScrollView] { ((v as? UIScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        let all = scrollViews(hosting.view)
        let scrollable = all.filter { $0.contentSize.height > $0.bounds.height + 1 }
        XCTAssertFalse(scrollable.isEmpty, "die Antworten lassen sich scrollen: \(all.map { "\($0.contentSize.height)/\($0.bounds.height)" })")
        XCTAssertTrue(all.allSatisfy { $0.frame.maxY <= hosting.view.bounds.height + 1 }, "kein Scrollbereich ragt aus dem Bild")
        if let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try shoot(view, name: "3-fragen-pruefungen-viele", size: Self.smallLandscape, dir: dir)
        }
    }

    private struct IntroSetupShot: View {
        @State var model: IntroSetupModel
        var body: some View { IntroSetupLayout(model: $model, onAnswer: { _ in }, onSkipAll: {}, onFinish: {}) }
    }

    private struct IntroPlanShot: View {
        @State private var selected: UFOffer?
        var body: some View {
            IntroPlanLayout(trialDays: 7, proAIOffered: true, offers: UFOffer.allCases, selected: $selected,
                            price: IntroShotsAppTests.price, onPrimary: {}, onCompare: {}, onRestore: {}, onLegal: { _ in })
        }
    }

    private func shoot(_ view: AnyView, name: String, size: CGSize, dir: URL) throws {
        let frame = CGRect(origin: .zero, size: size)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            window.overrideUserInterfaceStyle = style
            RunLoop.main.run(until: Date().addingTimeInterval(1.6))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format).pngData { _ in
                _ = hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            try png.write(to: dir.appendingPathComponent("\(name)-\(tone).png"))
        }
    }
}
