import XCTest
@testable import LivingFrameCore

final class ClipExportStateTests: XCTestCase {
    func testExportStateIsInvalidatedWhenClipPresentationChanges() {
        var state = ClipExportState()
        state.markExported(for: 0, cropKey: "full", resolution: .p720)

        XCTAssertTrue(state.isCurrent(for: 0, cropKey: "full", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 1, cropKey: "full", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 0, cropKey: "cropped", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 0, cropKey: "full", resolution: .original))
    }

    func testEffectSnapshotInvalidatesAndRestoresExportState() {
        let clip = SegmentedClip(
            id: "effect-state",
            name: "effect state",
            fps: 1,
            frameCount: 1,
            width: 16,
            height: 16,
            folderURL: URL(fileURLWithPath: "/tmp/effect-state")
        )
        let baseline = ClipGIFEffectSnapshot(clip: clip)
        var state = ClipExportState()
        state.markExported(for: 0, cropKey: "full", effects: baseline)

        XCTAssertTrue(state.isCurrent(for: 0, cropKey: "full", effects: baseline))

        var changed = clip
        changed.edgeStyle = .outline
        XCTAssertFalse(
            state.isCurrent(
                for: 0,
                cropKey: "full",
                effects: ClipGIFEffectSnapshot(clip: changed)
            )
        )

        changed = clip
        changed.edgeLineStyle = .dashed
        XCTAssertNotEqual(ClipGIFEffectSnapshot(clip: changed), baseline)
        changed = clip
        changed.edgeThickness = .thick
        XCTAssertNotEqual(ClipGIFEffectSnapshot(clip: changed), baseline)
        changed = clip
        changed.edgeColorHex = "00FF00"
        XCTAssertNotEqual(ClipGIFEffectSnapshot(clip: changed), baseline)
        changed = clip
        changed.stickerStyle = .comic
        XCTAssertNotEqual(ClipGIFEffectSnapshot(clip: changed), baseline)

        changed = clip
        changed.edgeColorHex = "ffffff"
        XCTAssertEqual(ClipGIFEffectSnapshot(clip: changed), baseline)
        XCTAssertTrue(
            state.isCurrent(
                for: 0,
                cropKey: "full",
                effects: ClipGIFEffectSnapshot(clip: changed)
            )
        )
    }
}
