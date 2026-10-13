import AVFoundation
import ImageIO
import XCTest
@testable import LivingFrameCore

final class LivePhotoExporterCropTests: XCTestCase {
    func testLivePhotoExportUsesNonzeroCropForVideoAndCoverDimensions() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-photo-crop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var composition = Composition(
            name: "crop export",
            canvas: CanvasSpec(width: 32, height: 20),
            duration: 0.1,
            fps: 1
        )
        composition.cropRect = CGRect(x: 8, y: 5, width: 16, height: 10)

        let output = try await LivePhotoExporter().export(composition, to: outputURL)
        defer { try? FileManager.default.removeItem(at: output.videoURL) }

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output.coverData as CFData, nil))
        let cover = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cover.width, 16)
        XCTAssertEqual(cover.height, 10)

        let asset = AVURLAsset(url: output.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(abs(size.width), 16, accuracy: 1)
        XCTAssertEqual(abs(size.height), 10, accuracy: 1)
    }
}
