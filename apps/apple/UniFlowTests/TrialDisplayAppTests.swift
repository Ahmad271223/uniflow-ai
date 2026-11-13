import XCTest
import UniFlowCore
@testable import UniFlow

/// Entscheidung des Inhabers vom 09.11.2026 (Audit Paket 44, Produktentscheidung 1): ueberall dieselbe, massgebliche
/// Probe. Gilt die Probe des StudiNow-Kontos (Vorrang wie beim Freischalten, `UFPlanPrecedence`), zeigen Einstellungen,
/// Seitenleiste (Kontokarte), Probe-Karte (TrialBanner) und Tarifseite bzw. Entscheidungs-Bildschirm (PlanPickerView)
/// deren Resttage und Ende; sonst die der iPad-Probe. Vorher zeigte die Seitenleiste mit laufender Konto-Probe die Tage
/// der iPad-Probe und die Einstellungen nur "StudiNow Pro AI".
@MainActor
final class TrialDisplayAppTests: XCTestCase {
    private func date(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso), iso) }

    /// was die Stellen der App zeigen
    private struct Shown: Equatable {
        var settings: String
        var sidebar: String
        var banner: UFTrialBannerContent?
        var planPage: String?
    }

    private func shown(_ e: Entitlements, service: StudoraAccount.PlanStatus?) -> Shown {
        Shown(settings: e.statusLabel,
              sidebar: UFSidebarProfile.make(e).planLabel,
              banner: TrialBanner.content(ent: e, service: service),
              planPage: e.runningTrial.map { PlanPickerView.trialStatus($0, proAI: true).title })
    }

    /// iPad-Probe: Beginn 07.11. 12:00 -> am 09.11. 12:00 noch 5 Tage, Ende 14.11.
    private func entitlementsWithDeviceTrial(now: Date) throws -> Entitlements {
        let e = Entitlements(observe: false)
        e.useLocalTrial(startedAt: try date("2026-11-07T12:00:00Z"), now: now)
        XCTAssertEqual(e.localTrial?.daysLeft, 5)
        return e
    }

    func testAccountTrialWinsEverywhere() throws {
        let now = try date("2026-11-09T12:00:00Z")
        let e = try entitlementsWithDeviceTrial(now: now)
        // Probe des Kontos: noch 2 Tage, Ende 11.11. 10:00
        let account = StudoraAccount.PlanStatus(plan: "pro_ai", trialActive: true, trialDaysLeft: 2, trialPlan: "pro_ai",
                                                trialEndsAt: try date("2026-11-11T10:00:00Z"))
        e.useServiceStatus(account)
        XCTAssertEqual(e.plan, .proAI, "Freischaltung unveraendert")
        XCTAssertEqual(shown(e, service: account),
                       Shown(settings: "Probe: noch 2 Tage alles frei", sidebar: "Probe · noch 2 Tage",
                             banner: .running(daysLeft: 2, source: .service),
                             planPage: "Probe aktiv: alle Funktionen von StudiNow Pro AI bis 11.11.2026 (noch 2 Tage)"))
        XCTAssertEqual(e.shownTrial, UFShownTrial(source: .service, daysLeft: 2, endsAt: try date("2026-11-11T10:00:00Z")))
        // Konto-Probe ohne gemeldetes Ende: Resttage trotzdem die des Kontos, kein Datum der iPad-Probe
        e.useServiceStatus(StudoraAccount.PlanStatus(plan: "pro_ai", trialActive: true, trialDaysLeft: 2, trialPlan: "pro_ai"))
        XCTAssertEqual(e.runningTrial.map { PlanPickerView.trialStatus($0, proAI: true).title },
                       "Probe aktiv: alle Funktionen von StudiNow Pro AI (noch 2 Tage)")
        XCTAssertEqual(UFSidebarProfile.make(e).planLabel, "Probe · noch 2 Tage")
    }

    func testOnlyDeviceTrialShowsItsDaysEverywhere() throws {
        let now = try date("2026-11-09T12:00:00Z")
        let e = try entitlementsWithDeviceTrial(now: now)
        let expected = Shown(settings: "Probe: noch 5 Tage alles frei", sidebar: "Probe · noch 5 Tage",
                             banner: .running(daysLeft: 5, source: .device),
                             planPage: "Probe aktiv: alle Funktionen von StudiNow Pro AI bis 14.11.2026 (noch 5 Tage)")
        XCTAssertEqual(shown(e, service: nil), expected, "ohne Konto")
        // Konto ohne Probe (nie gewaehrt): iPad-Probe
        let plain = StudoraAccount.PlanStatus(plan: "free")
        e.useServiceStatus(plain)
        XCTAssertEqual(shown(e, service: plain), expected, "Konto ohne Probe")
    }

    func testExpiredAccountTrialFallsBackToTheDeviceTrial() throws {
        let now = try date("2026-11-09T12:00:00Z")
        let e = try entitlementsWithDeviceTrial(now: now)
        let expected = Shown(settings: "Probe: noch 5 Tage alles frei", sidebar: "Probe · noch 5 Tage",
                             banner: .running(daysLeft: 5, source: .device),
                             planPage: "Probe aktiv: alle Funktionen von StudiNow Pro AI bis 14.11.2026 (noch 5 Tage)")
        for over in [StudoraAccount.PlanStatus(plan: "free", needsPlanChoice: true), StudoraAccount.PlanStatus(plan: "free")] {
            e.useServiceStatus(over)
            XCTAssertEqual(e.plan, .proAI, "die iPad-Probe schaltet frei")
            XCTAssertEqual(shown(e, service: over), expected, "Konto-Probe vorbei: \(over)")
        }
        // beide vorbei: kein Probe-Text, der Hinweis nach der Probe des Kontos bleibt
        e.refreshLocalTrial(now: try date("2026-11-15T12:00:00Z"))
        let over = StudoraAccount.PlanStatus(plan: "free", needsPlanChoice: true)
        e.useServiceStatus(over)
        XCTAssertEqual(shown(e, service: over), Shown(settings: "StudiNow Free", sidebar: "Free", banner: .over(source: .service), planPage: nil))
    }

    /// Kauf: die iPad-Probe gilt nicht mehr (wie `UFPlanPrecedence`), die Probe des Kontos schon
    func testPrecedenceWithPurchase() throws {
        let local = UFLocalTrial.state(startedAt: try date("2026-11-07T12:00:00Z"), now: try date("2026-11-09T12:00:00Z"))
        XCTAssertNil(UFShownTrial.make(service: nil, serviceDaysLeft: 0, serviceEndsAt: nil, local: local, purchased: .plus))
        XCTAssertEqual(UFShownTrial.make(service: .proAI, serviceDaysLeft: 2, serviceEndsAt: nil, local: local, purchased: .plus),
                       UFShownTrial(source: .service, daysLeft: 2, endsAt: nil))
        XCTAssertEqual(UFShownTrial.make(service: .proAI, serviceDaysLeft: 2, serviceEndsAt: nil, local: local, purchased: .free)?.daysLeft, 2)
        // 13.11.2026: Pro AI gekauft (auf diesem iPad oder laut Dienst) deckt die Probe ab -> keine Probe mehr anzeigen
        XCTAssertNil(UFShownTrial.make(service: .proAI, serviceDaysLeft: 2, serviceEndsAt: nil, local: local, purchased: .proAI))
        XCTAssertNil(UFShownTrial.make(service: .proAI, serviceDaysLeft: 2, serviceEndsAt: nil, local: local, purchased: .free,
                                       servicePaid: .proAI))
        XCTAssertNil(UFShownTrial.make(service: nil, serviceDaysLeft: 0, serviceEndsAt: nil, local: local, purchased: .free,
                                       servicePaid: .proAI), "auch die iPad-Probe nicht")
        XCTAssertEqual(UFShownTrial.make(service: .proAI, serviceDaysLeft: 2, serviceEndsAt: nil, local: local, purchased: .free,
                                         servicePaid: .plus)?.daysLeft, 2, "Plus deckt die Probe nicht ab: sie bringt noch die KI")
        // Seitenleiste mit Plus und laufender Konto-Probe: Probe, der Knopf fuehrt ueber den Kauf hinaus
        let p = UFSidebarProfile.make(plan: .proAI, purchased: .plus, trialDaysLeft: 2)
        XCTAssertEqual(p.planLabel, "Probe · noch 2 Tage")
        XCTAssertEqual(p.upgrade, .proAI)
        // Tarifseite: Konto-Probe nennt das Konto als Weg zur KI, mit Kauf gilt danach wieder der Kauf
        let s = PlanPickerView.trialStatus(UFShownTrial(source: .service, daysLeft: 2, endsAt: nil), proAI: true, after: .plus)
        XCTAssertTrue(s.note.contains("über dein StudiNow-Konto"), s.note)
        XCTAssertTrue(s.note.contains("Danach gilt wieder StudiNow Plus"), s.note)
        XCTAssertFalse(s.note.contains("Anmelden mit Apple"), s.note)
    }

    /// Ende der Probe aus dem Dienst (`trial.ends_at`, Python `isoformat()`)
    func testServiceDate() throws {
        let end = try date("2026-11-11T10:00:00Z")
        XCTAssertEqual(StudoraAccount.serviceDate("2026-11-11T10:00:00.123456+00:00"), end)
        XCTAssertEqual(StudoraAccount.serviceDate("2026-11-11T10:00:00+00:00"), end)
        XCTAssertEqual(StudoraAccount.serviceDate("2026-11-11T11:00:00+01:00"), end)
        XCTAssertEqual(StudoraAccount.serviceDate("2026-11-11T10:00:00"), end, "ohne Zone: UTC")
        XCTAssertEqual(StudoraAccount.serviceDate("2026-11-11T10:00:00Z"), end)
        XCTAssertNil(StudoraAccount.serviceDate(nil))
        XCTAssertNil(StudoraAccount.serviceDate(""))
        XCTAssertNil(StudoraAccount.serviceDate("bald"))
    }
}
