import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Einstellungen je Stift und eigene Stifte (Wunsch des Inhabers 14.11.2026). Bilder des Blatts mit
/// `TEST_RUNNER_UF_STIFT_DIR=<Ordner>`.
@MainActor
final class PenSettingsTests: XCTestCase {

    private func freshTools() -> (EditorToolState, UserDefaults) {
        let suite = "uniflow.tests.pen.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return (EditorToolState(defaults: d), d)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
    }

    /// Gespeicherte Staerken, die PencilKit nicht kann (alte Stufen Fineliner 6, Textmarker 6), fallen beim Laden auf
    /// die naechste gueltige; gueltige bleiben; aeltere Einstellungen ohne Deckkraft und eigene Stifte laden
    func testOldStoredWidthsFallToTheNextValidOne() throws {
        let suite = "uniflow.tests.pen.old.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let old = ##"{"tool":"fineliner","lastInk":"fineliner","lastPen":"fineliner","eraser":"object","styles":{"fineliner":{"hex":"#2f7fd1","width":6},"marker":{"hex":"#ffe066","width":6},"pen":{"hex":"#1d2130","width":1}}}"##
        d.set(Data(old.utf8), forKey: "uniflow.toolbar")
        let tools = EditorToolState(defaults: d)
        XCTAssertEqual(tools.style(.fineliner).width, 4, "Fineliner 6 -> 4 (Obergrenze von PencilKit)")
        XCTAssertEqual(tools.style(.marker).width, 7.5, "Textmarker 6 -> 7,5 (Untergrenze)")
        XCTAssertEqual(tools.style(.pen).width, 1, "gueltig: bleibt")
        XCTAssertNil(tools.style(.pen).opacity)
        XCTAssertEqual(tools.style(.pen).alpha, 1)
        XCTAssertTrue(tools.presets.isEmpty)
        XCTAssertEqual((tools.inkingTool(.fineliner)?.width ?? 0), 4, accuracy: 0.001)
    }

    func testFineStepsAndNumbers() {
        typealias T = EditorToolState
        XCTAssertEqual(T.steppedWidth(0.88, up: true, for: .pen), 0.9)
        XCTAssertEqual(T.steppedWidth(0.9, up: true, for: .pen), 1.0, accuracy: 0.001)
        XCTAssertEqual(T.steppedWidth(0.88, up: false, for: .pen), 0.88, "unten bleibt")
        XCTAssertEqual(T.steppedWidth(0.5, up: false, for: .fineliner), 0.45, accuracy: 0.001, "feine Stufen seit 17.11.2026")
        XCTAssertEqual(T.steppedWidth(0.18, up: false, for: .fineliner), 0.18, "unten bleibt")
        XCTAssertEqual(T.steppedWidth(0.5, up: true, for: .fineliner), 0.6, accuracy: 0.001)
        XCTAssertEqual(T.steppedWidth(2, up: true, for: .pen), 2.25)
        XCTAssertEqual(T.steppedWidth(2, up: false, for: .pen), 1.9, accuracy: 0.001)
        XCTAssertEqual(T.steppedWidth(6, up: true, for: .pen), 7)
        XCTAssertEqual(T.steppedWidth(6, up: false, for: .pen), 5.75)
        XCTAssertEqual(T.steppedWidth(4, up: true, for: .fineliner), 4, "oben bleibt")
        XCTAssertEqual(T.sliderRange(.fineliner), 0.18...4)
        XCTAssertEqual(T.sliderRange(.pen).lowerBound, 0.88, accuracy: 0.001)
        XCTAssertEqual(PenSettingsText.width(0.88), "0,88")
        XCTAssertEqual(PenSettingsText.width(2), "2")
        XCTAssertEqual(PenSettingsText.width(2.25), "2,25")
        let (tools, _) = freshTools()
        tools.setWidth(0.1, for: .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.18, "nie unter der Grenze des Fineliners")
        tools.setWidth(0.734, for: .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.73, "stufenlos, zwei Stellen")
    }

    /// Deckkraft geht in die Tinte und bleibt beim Sichern und Neuladen erhalten (Abgleich mit Browser und iPhone)
    func testOpacityGoesIntoTheInkAndSurvivesSaving() throws {
        let (tools, _) = freshTools()
        tools.setOpacity(0.5, for: .fineliner)
        tools.setWidth(0.5, for: .fineliner)
        let ink = try XCTUnwrap(tools.inkingTool(.fineliner))
        var a: CGFloat = 0
        ink.color.getRed(nil, green: nil, blue: nil, alpha: &a)
        XCTAssertEqual(a, 0.5, accuracy: 0.01)
        XCTAssertEqual(ink.width, 0.5, accuracy: 0.001)
        // Strich in dieser Tinte -> Seiten-JSON -> wieder Zeichnung
        let pts = (0..<20).map { PKStrokePoint(location: CGPoint(x: 20 + CGFloat($0) * 4, y: 50), timeOffset: Double($0) * 0.01,
                                               size: CGSize(width: 0.5, height: 0.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let stroke = PKStroke(ink: PKInk(.monoline, color: ink.color), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_900_000_000)))
        let page = StrokeConverter.update(from: PKDrawing(strokes: [stroke]), previous: ["objects": []], state: InkPageState()).page
        let o = try XCTUnwrap(page["objects"]?.array?.first)
        XCTAssertEqual(o["width"]?.double ?? 0, 0.5, accuracy: 0.01, "Staerke im JSON")
        XCTAssertEqual(o["opacity"]?.double ?? 0, 0.5, accuracy: 0.02, "Deckkraft im JSON")
        let back = StrokeConverter.drawing(fromPage: page).0
        let s = try XCTUnwrap(back.strokes.first)
        var b: CGFloat = 0
        s.ink.color.getRed(nil, green: nil, blue: nil, alpha: &b)
        XCTAssertEqual(b, 0.5, accuracy: 0.02)
        XCTAssertEqual(s.path[0].size.width, 0.5, accuracy: 0.02)
        let nativeBack = try PKDrawing(data: PKDrawing(strokes: [stroke]).dataRepresentation())
        print("[Stift] PencilKit-Daten Fineliner zurueck: \(nativeBack.strokes.first?.ink.inkType.rawValue ?? "-"), Version \(nativeBack.requiredContentVersion.rawValue)")
        print("[Stift] Rundweg Fineliner: pkInk \(o["pkInk"]?.string ?? "-"), zurueck \(s.ink.inkType.rawValue), nativ \(page["pkdrawing"] != nil)")
        // Befund 14.11.2026: PencilKits eigenes Speicherformat liefert einen Fineliner-Strich (.monoline) als .pen zurueck
        // (Inhaltsversion 1, `pkInk` im JSON steht richtig). Nicht hier geaendert: alte Notizen sollen aussehen wie bisher;
        // Vorschlag im Bericht. Staerke und Deckkraft bleiben (oben geprueft).
        XCTAssertTrue([PKInk.InkType.monoline, .pen].contains(s.ink.inkType))
        XCTAssertEqual(o["pkInk"]?.string, PKInk.InkType.monoline.rawValue, "Tintenart im JSON")
    }

    func testPresetsAddApplyRemoveAndStayOnTheDevice() {
        let suite = "uniflow.tests.pen.presets.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let tools = EditorToolState(defaults: d)
        tools.setColor("#e5322d", for: .fineliner)
        tools.setWidth(0.5, for: .fineliner)
        let fine = tools.addPreset(from: .fineliner)!
        XCTAssertEqual(tools.addPreset(from: .fineliner)?.id, fine.id, "gleicher Stift nur einmal")
        tools.setWidth(6, for: .pen)
        tools.setOpacity(0.6, for: .pen)
        let thick = tools.addPreset(from: .pen)!
        XCTAssertEqual(tools.presets.count, 2)
        XCTAssertNil(tools.addPreset(from: .eraser), "nur Stifte")
        // anderen Stift nehmen, dann den eigenen
        tools.setWidth(2, for: .fineliner)
        tools.select(.pen)
        tools.applyPreset(fine.id)
        XCTAssertEqual(tools.tool, .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.5)
        XCTAssertTrue(tools.isActive(fine))
        XCTAssertFalse(tools.isActive(thick))
        // nach Neustart da
        let again = EditorToolState(defaults: d)
        XCTAssertEqual(again.presets.map(\.id), [fine.id, thick.id])
        XCTAssertEqual(again.presets[1].style.opacity ?? 0, 0.6, accuracy: 0.001)
        again.removePreset(fine.id)
        XCTAssertEqual(EditorToolState(defaults: d).presets.map(\.id), [thick.id])
        // Grenze
        for i in 0..<20 { again.setWidth(1 + CGFloat(i) * 0.1, for: .pen); again.addPreset(from: .pen) }
        XCTAssertEqual(again.presets.count, EditorToolState.presetLimit)
        // Zuruecksetzen
        again.resetStyle(.pen)
        XCTAssertEqual(again.style(.pen), EditorToolState.defaultStyle(.pen))
    }

    /// Das Blatt im Feld "Farbe und Stärke": oeffnen, duenner bis zur Grenze (Hinweis auf den Fineliner), zum
    /// Fineliner, Deckkraft, Glaettung, merken, zuruecksetzen; Bilder hell und dunkel
    func testSettingsPanelInTheAttributesField() throws {
        // Glaettung "Leicht"/"Aus" ist seit 17.11.2026 abgeschaltet (`PencilTuning.rebuildFromRawPointsAfterLift`): fuer
        // diesen Test ausdruecklich an, danach zurueck
        PencilTuning.rebuildFromRawPointsAfterLift = true
        addTeardownBlock { @MainActor in PencilTuning.rebuildFromRawPointsAfterLift = false }
        let (tools, _) = freshTools()
        tools.select(.pen)
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(UFContent { UFCard { EditorToolAttributes(tools: tools, tool: .pen) }.frame(width: 360) },
                                          size: CGSize(width: 520, height: 900))
        env.pump(0.6)
        func el(_ id: String) -> NSObject? { LockVisibilityAppTests.element(id, in: env.view) }
        XCTAssertTrue(try XCTUnwrap(el("toolbar.penSettings"), env.labels().joined(separator: "\n")).accessibilityActivate())
        env.pump(0.4)
        XCTAssertNotNil(el("pen.settings.preview"))
        XCTAssertTrue(env.labels().contains { $0.contains("fester du aufdrückst") }, "Stift: Druck erklaert")
        for _ in 0..<20 { _ = el("pen.settings.thinner")?.accessibilityActivate(); env.pump(0.05) }
        XCTAssertEqual(tools.style(.pen).width, 0.88, accuracy: 0.001)
        env.pump(0.3)
        XCTAssertTrue(env.labels().contains { $0.contains("Dünner geht der Stift nicht") }, "Hinweis an der Grenze")
        shoot(env, "stift-einstellungen-grenze-hell")
        _ = el("pen.settings.thicker")?.accessibilityActivate()
        env.pump(0.2)
        XCTAssertEqual(tools.style(.pen).width, 0.9, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(el("pen.settings.remember")).accessibilityActivate())
        env.pump(0.2)
        XCTAssertEqual(tools.presets.count, 1)
        XCTAssertTrue(try XCTUnwrap(el("pen.settings.reset")).accessibilityActivate())
        env.pump(0.2)
        XCTAssertEqual(tools.style(.pen), EditorToolState.defaultStyle(.pen))
        // Glaettung als Stufenregler: Werte Aus/Leicht/Normal
        let slider = try XCTUnwrap(LayoutWidthAuditTests.elements(in: env.window).first {
            $0.accessibilityTraits.contains(.adjustable) && $0.accessibilityLabel == PencilSmoothing.title })
        XCTAssertEqual(slider.accessibilityValue, "Normal")
        slider.accessibilityDecrement()
        env.pump(0.2)
        XCTAssertEqual(PencilSmoothing.current, .light, "eine Stufe je Wischen")
        // zum Fineliner
        for _ in 0..<20 { _ = el("pen.settings.thinner")?.accessibilityActivate(); env.pump(0.03) }
        env.pump(0.2)
        XCTAssertTrue(try XCTUnwrap(el("pen.settings.toFineliner")).accessibilityActivate())
        env.pump(0.4)
        XCTAssertEqual(tools.tool, .fineliner)
        XCTAssertTrue(env.labels().contains { $0.contains("immer gleich breit") }, "Fineliner: fein erklaert")
        shoot(env, "stift-einstellungen-fineliner-hell")
        env.window.overrideUserInterfaceStyle = .dark
        env.pump(0.4)
        shoot(env, "stift-einstellungen-fineliner-dunkel")
        env.window.isHidden = true
    }

    /// Eigene Stifte erscheinen in der Werkzeugleiste zwischen den Stiften und dem Lineal; antippen nimmt den Stift,
    /// entfernen nimmt ihn aus der Leiste. Bild der Leiste quer (feste Leiste, volle Breite)
    func testPresetChipsInTheToolbar() throws {
        let (tools, _) = freshTools()
        tools.setColor("#e5322d", for: .fineliner)
        tools.setWidth(0.5, for: .fineliner)
        let fine = try XCTUnwrap(tools.addPreset(from: .fineliner))
        tools.setColor("#2e9e5b", for: .pen)
        tools.setWidth(6, for: .pen)
        let thick = try XCTUnwrap(tools.addPreset(from: .pen))
        tools.resetStyle(.fineliner)
        tools.resetStyle(.pen)
        tools.select(.pen)
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(VStack(spacing: 0) { EditorToolbar(tools: tools, mode: .init(visible: true, inkOnly: false), undo: {}, redo: {}, askAI: nil); Spacer() },
                                          size: CGSize(width: 1180, height: 160))
        env.pump(0.6)
        let chip = try XCTUnwrap(LockVisibilityAppTests.element("toolbar.preset.\(fine.id)", in: env.view), env.labels().joined(separator: "\n"))
        XCTAssertNotNil(LockVisibilityAppTests.element("toolbar.preset.\(thick.id)", in: env.view))
        let pen = try XCTUnwrap(LockVisibilityAppTests.element("toolbar.tool.pen", in: env.view)).accessibilityFrame
        let ruler = try XCTUnwrap(LockVisibilityAppTests.element("toolbar.ruler", in: env.view)).accessibilityFrame
        XCTAssertGreaterThan(chip.accessibilityFrame.minX, pen.maxX, "nach den Stiften")
        XCTAssertLessThan(chip.accessibilityFrame.maxX, ruler.minX + 1, "vor dem Lineal")
        XCTAssertEqual(chip.accessibilityFrame.midY, pen.midY, accuracy: 1, "dieselbe Zeile")
        XCTAssertTrue(chip.accessibilityActivate())
        env.pump(0.3)
        XCTAssertEqual(tools.tool, .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.5)
        XCTAssertEqual(tools.style(.fineliner).hex, "#e5322d")
        shoot(env, "leiste-eigene-stifte")
        tools.removePreset(thick.id)
        env.pump(0.3)
        XCTAssertNil(LockVisibilityAppTests.element("toolbar.preset.\(thick.id)", in: env.view), "entfernt")
        env.window.isHidden = true
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_STIFT_DIR"], !dir.isEmpty else { return }
        let window = env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
