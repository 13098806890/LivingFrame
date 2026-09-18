import Foundation
import XCTest
@testable import LivingFrameCore

final class WorksStoreTests: XCTestCase {
    func testSavedWorkManifestCanBeReloaded() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = WorksStore(rootURL: rootURL)
        let composition = Composition(
            name: "saved-work",
            canvas: CanvasSpec(width: 100, height: 100)
        )
        let work = WorkItem(
            name: composition.name,
            composition: composition,
            posterData: Data([1, 2, 3]),
            format: .gif,
            savedAt: Date(),
            hasManualSave: true
        )

        let manifestURL = try store.save(work)
        let loaded = store.loadWorks()
        let expectedData = try JSONEncoder().encode(work)

        XCTAssertEqual(loaded, [work])
        let savedManifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as? NSDictionary)
        let expectedManifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: expectedData
        ) as? NSDictionary)
        XCTAssertEqual(savedManifest, expectedManifest)
    }

    func testLoadKeepsValidWorksAndSkipsCorruptManifest() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = WorksStore(rootURL: rootURL)
        let composition = Composition(
            name: "valid-work",
            canvas: CanvasSpec(width: 100, height: 100)
        )
        let validWork = WorkItem(
            name: composition.name,
            composition: composition,
            posterData: Data(),
            format: .gif,
            hasManualSave: true
        )
        try store.save(validWork)

        let corruptDirectory = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptDirectory.appendingPathComponent("work.json"))

        XCTAssertEqual(store.loadWorks(), [validWork])
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorksStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
