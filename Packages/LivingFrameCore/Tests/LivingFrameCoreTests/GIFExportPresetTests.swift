import XCTest
@testable import LivingFrameCore

final class GIFExportPresetTests: XCTestCase {
    func testSharedResolutionOptionsRespectSourceMaximum() {
        XCTAssertEqual(GIFExportPreset.resolutionOptions(maxSourceDimension: 540), [.p360, .original])
        XCTAssertEqual(GIFExportPreset.resolutionOptions(maxSourceDimension: 720), [.p360, .p720])
        XCTAssertEqual(GIFExportPreset.resolutionOptions(maxSourceDimension: 1080), [.p360, .p720, .original])
    }

    func testSharedFPSOptionsRespectSourceMaximum() {
        XCTAssertEqual(GIFExportPreset.fpsOptions(maxSourceFPS: 24), [15, 24])
        XCTAssertEqual(GIFExportPreset.fpsOptions(maxSourceFPS: 30), [15, 30])
        XCTAssertEqual(GIFExportPreset.fpsOptions(maxSourceFPS: 60), [15, 30, 60])
    }

    func testDefaultPresetChoosesLargestEstimatedSizeBelowTenMegabytes() {
        let presets = [
            GIFExportPreset(resolution: .p360, fps: 10, estimatedBytes: 4_000_000),
            GIFExportPreset(resolution: .p720, fps: 15, estimatedBytes: 9_500_000),
            GIFExportPreset(resolution: .original, fps: 20, estimatedBytes: 10_500_000)
        ]

        XCTAssertEqual(GIFExportPreset.defaultPreset(from: presets), presets[1])
    }

    func testOriginalGIFResolutionShowsItsActualSourceDimension() {
        XCTAssertEqual(ExportResolution.original.gifTitle(for: 900), "900p")
        XCTAssertEqual(ExportResolution.original.gifTitle(for: 1080), "1080p")
    }
}
