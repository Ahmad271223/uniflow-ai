import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Neues aus develop (Build 38, 13.11.2026) auf dem iPhone: der neue Einstieg (Willkommen, Rundgang, Hochschule, Fragen,
/// Tarif), "Mit KI verbessern" in der Uni-Mail und die Erledigt-Haken im Moduldetail. Jede Seite passt auf alle
/// iPhone-Groessen (nichts ragt ueber den Rand) und wird fotografiert. Nur erfundene Inhalte, kein Netz.
@MainActor
final class IPhoneIntroTests: IPhoneLearnTestCase {

    private struct SetupShot: View {
        @State var model: IntroSetupModel
        var body: some View { IntroSetupLayout(model: $model, onAnswer: { _ in }, onSkipAll: {}, onFinish: {}) }
    }

    private struct PlanShot: View {
        @State private var selected: UFPlan = .free
        var body: some View {
            IntroPlanLayout(trialDays: 7, proAIOffered: true, plans: [.free, .plus, .proAI], selected: $selected,
                            price: IntroShotsAppTests.price, onPrimary: {}, onCompare: {}, onRestore: {}, onLegal: { _ in })
        }
    }

    func testIntroPagesFitThePhone() throws {
        let pages: [(String, String, AnyView)] = [
            ("willkommen", "", AnyView(IntroWelcomeLayout(onSignIn: { _ in }))),
            ("rundgang-uni", "", AnyView(IntroTourLayout(page: .uni, onNext: {}, onSkip: {}))),
            ("rundgang-lernplan", "", AnyView(IntroTourLayout(page: .plan, onBack: {}, onNext: {}, onSkip: {}))),
            ("rundgang-notizen", "", AnyView(IntroTourLayout(page: .notes, onBack: {}, onNext: {}, onSkip: {}))),
            ("rundgang-pruefungen", "", AnyView(IntroTourLayout(page: .exams, onBack: {}, onNext: {}, onSkip: {}))),
            ("hochschule", "", AnyView(UniversityPickerView { _ in })),
            ("fragen-name", "", AnyView(SetupShot(model: IntroShotsAppTests.sampleSetup(step: .name)))),
            ("fragen-faecher", "Analysis I", AnyView(SetupShot(model: IntroShotsAppTests.sampleSetup(step: .modules)))),
            ("fragen-pruefungen", "", AnyView(SetupShot(model: IntroShotsAppTests.sampleSetup(step: .exams)))),
            ("fragen-fertig", "", AnyView(SetupShot(model: IntroShotsAppTests.sampleSetup(step: .ready)))),
            ("tarif", "", AnyView(PlanShot())),
        ]
        for (name, marker, view) in pages {
            let env = try hostPhone(view, api: remote(Canned()))
            XCTAssertTrue(env.wait(timeout: 5) { !self.texts(env).isEmpty && (marker.isEmpty || self.shows(env, marker)) }, "\(name): \(dump(env))")
            env.pump(0.4)
            assertFitsOnAllPhones(env, "einstieg-\(name)")
            shoot(env, "iphone-einstieg-\(name)")
        }
    }

    /// Das Bild des Rundgangs wird am iPhone als Ganzes verkleinert (es ist fuer 560 pt gezeichnet)
    func testTourArtScalesOnlyWhenNarrow() {
        XCTAssertEqual(IntroArtFit<EmptyView>.scale(width: 342), 342 / 560, accuracy: 0.001)
        XCTAssertEqual(IntroArtFit<EmptyView>.scale(width: 560), 1)
        XCTAssertEqual(IntroArtFit<EmptyView>.scale(width: 900), 1, "iPad: nie vergroessern")
    }

    /// Die Kopfzeile des Einstiegs ist eine Zeile, keine halbe Seite. Foto des Inhabers 14.11.2026: im Schritt
    /// „Ich richte deinen Lernplan ein …“ (ohne „Später“) war die obere Hälfte leer, die Sprechblase oben
    /// abgeschnitten – der Platzhalter neben dem Fortschritt war beliebig hoch.
    func testSetupStepsUseTheWholePage() throws {
        for size in [IPhoneLearnTestCase.phoneSmall, IPhoneLearnTestCase.phone, IPhoneLearnTestCase.phoneMax] {
            for step in [IntroSetupModel.Step.name, .modules, .exams, .ready] {
                let env = try hostPhone(SetupShot(model: IntroShotsAppTests.sampleSetup(step: step)), api: remote(Canned()), size: size)
                XCTAssertTrue(env.wait { !self.texts(env).isEmpty }, dump(env))
                env.pump(0.4)
                let steps = try XCTUnwrap(elements(env).first { ($0.accessibilityLabel ?? "").hasPrefix("Schritt ") },
                                          "Fortschritt fehlt: \(dump(env))")
                // eine Zeile unter der Statusleiste, nicht die halbe Seite (vorher reichte sie bis zur Mitte)
                let top = env.window.safeAreaInsets.top
                XCTAssertLessThan(frame(steps).maxY, top + 80, "Kopfzeile ist eine Zeile (\(step), \(Int(size.width)) pt)")
                // der erste Inhalt steht direkt darunter und ist vollständig sichtbar (nichts oben abgeschnitten)
                let others = elements(env).filter { $0 !== steps && !($0.accessibilityLabel ?? "").isEmpty }
                    .map { frame($0) }.filter { $0.height > 1 && $0.width > 1 }
                let first = try XCTUnwrap(others.min { $0.minY < $1.minY }, dump(env))
                XCTAssertLessThan(first.minY, frame(steps).maxY + 70, "oben bleibt keine halbe Seite leer (\(step), \(Int(size.width)) pt)")
                XCTAssertGreaterThan(first.minY, -1, "nichts ragt oben aus dem Bild (\(step))")
                if step == .ready { shoot(env, "iphone-einstieg-fertig-\(Int(size.width))") }
            }
        }
    }

    func testUniMailAIButtonAndProposalFitThePhone() throws {
        var taps = 0
        let view = VStack(alignment: .leading, spacing: 12) {
            UniMailAIButton(access: .ready, busy: false, empty: false) { taps += 1 }
            UniMailAIProposal(text: "Sehr geehrter Herr Meier,\nich habe eine Frage zur Übung am Donnerstag. Könnten Sie mir sagen, ob die Abgabe auch digital möglich ist?\nViele Grüße",
                              accept: {}, dismiss: {})
        }
        .padding(16)
        let env = try hostPhone(ScrollView { view }, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Sehr geehrter Herr Meier") }, dump(env))
        assertFitsOnAllPhones(env, "unimail-ki")
        shoot(env, "iphone-unimail-ki")
        _ = taps
    }
}
