import Foundation
import XCTest
@testable import LivingFrameCore

final class BackgroundStoreRetentionTests: XCTestCase {
    func testPruningKeepsTwentyNewestAndAnyReferencedOlderMedia() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let media = (0..<25).map { index in
            BackgroundMediaItem(
                id: "user-\(index)",
                name: "user-\(index)",
                frameCount: 1,
                duration: 0,
                width: 100,
                height: 100,
                createdAt: baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        let idsToPrune = BackgroundStore.userMediaIDsToPrune(
            from: media,
            keepingMostRecent: 20,
            preserving: ["user-2"]
        )

        XCTAssertEqual(idsToPrune, Set(["user-0", "user-1", "user-3", "user-4"]))
    }

    func testPruningUsesCreationDateRatherThanInputOrder() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let older = BackgroundMediaItem(
            id: "user-old",
            name: "user-old",
            frameCount: 1,
            duration: 0,
            width: 100,
            height: 100,
            createdAt: baseDate
        )
        let newest = BackgroundMediaItem(
            id: "user-new",
            name: "user-new",
            frameCount: 1,
            duration: 0,
            width: 100,
            height: 100,
            createdAt: baseDate.addingTimeInterval(1)
        )

        let idsToPrune = BackgroundStore.userMediaIDsToPrune(
            from: [newest, older],
            keepingMostRecent: 1,
            preserving: []
        )

        XCTAssertEqual(idsToPrune, ["user-old"])
    }
}
