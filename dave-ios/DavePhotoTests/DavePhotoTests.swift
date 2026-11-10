import XCTest
@testable import DavePhoto

final class DavePhotoTests: XCTestCase {
    @MainActor func testLiveBridgeCanReadStateWithoutChangingAlbum() async throws {
        let bridge = PhotoBridge()
        bridge.start()
        defer { bridge.stop() }
        XCTAssertFalse(bridge.isMockForTests, "The read-only integration check must use the actual WebSocket transport")
        for _ in 0..<30 {
            if bridge.connected { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard bridge.connected else { throw XCTSkip("Live workstation unavailable for read-only integration check") }
        do {
            let state = try await bridge.decode(WorkState.self, "state")
            let targets = try await bridge.decode([PhotoTarget].self, "targets")
            XCTAssertGreaterThanOrEqual(state.libraryGeneration, 0)
            XCTAssertGreaterThanOrEqual(targets.count, 0)
        } catch let problem as BridgeError where problem.message.contains("离线") {
            throw XCTSkip("Desktop workstation is offline")
        }
    }
    @MainActor func testOriginalPhotoIsPreparedForSharingWithoutChangingBytes() async throws {
        let model = Workbench()
        model.bridge.enableMockForTests()
        await model.refresh()
        XCTAssertEqual(model.state?.photos.count, 3)
        model.selected.insert(1)
        await model.prepareShare(allowSmall: true)
        let bundle = try XCTUnwrap(model.shareBundle, model.error ?? "Share data was not prepared")
        defer { model.removeShareFiles(bundle) }
        XCTAssertEqual(bundle.files.count, 1)
        let expected = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXsAAAAASUVORK5CYII="))
        XCTAssertEqual(try Data(contentsOf: bundle.files[0]), expected)
        XCTAssertEqual(bundle.files[0].pathExtension, "png")
        XCTAssertEqual(bundle.files[0].lastPathComponent, "示例照片1.png")
    }

    @MainActor func testSyntheticPreviewCacheCanBeLoadedAndCleared() async throws {
        let model = Workbench()
        model.bridge.enableMockForTests()
        model.clearCache()
        model.notice = nil
        await model.refresh()
        model.beginCaching()
        for _ in 0..<100 {
            if !model.caching { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.caching, "Caching did not finish")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.thumbnails.count, 3)
        XCTAssertGreaterThan(model.cacheSize, 0)
        model.clearCache()
        XCTAssertEqual(model.cacheSize, 0)
    }
}

