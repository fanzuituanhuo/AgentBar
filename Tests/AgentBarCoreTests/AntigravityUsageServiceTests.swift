import Foundation
import XCTest
@testable import AgentBarCore

final class AntigravityUsageServiceTests: XCTestCase {
    func testParsesAvailableQuotaWindows() throws {
        let data = Data("""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
                {"name":"Gemini Models","buckets":[
                    {"name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.75,
                     "reset_time":"2026-11-27T05:33:56.125Z"},
                    {"name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1},
                    {"name":"Unavailable limit","window":"weekly","remaining_fraction":0,"disabled":true},
                    {"name":"Amount limit","remaining_amount":40}
                ]}
            ]}}}
            """.utf8)
        let quotas = AntigravityUsageService.parseQuotas(data)
        XCTAssertEqual(quotas.map(\.label), ["Gemini Models · 周额度", "Gemini Models · 5h 窗口"])
        XCTAssertEqual(quotas.map(\.usedPercent), [25, 0])
        XCTAssertNotNil(quotas.first?.resetsAt)

        let cards = SubscriptionAndStatsService.detectLocalSubscriptions(
            sessions: [], antigravityPlan: "Google AI Pro", antigravityQuotas: quotas
        )
        let card = try XCTUnwrap(cards.first { $0.kind == .antigravity })
        XCTAssertEqual(card.planBadge, "Google AI Pro")
        XCTAssertEqual(card.quotas, quotas)
    }

    func testRequiresVersionWithReadOnlyUsageCommand() {
        XCTAssertFalse(AntigravityUsageService.supportsUsage(Data("1.1.10".utf8)))
        XCTAssertFalse(AntigravityUsageService.supportsUsage(Data("unknown".utf8)))
        XCTAssertTrue(AntigravityUsageService.supportsUsage(Data("1.1.11\n".utf8)))
        XCTAssertTrue(AntigravityUsageService.supportsUsage(Data("1.5.12".utf8)))
    }
}
