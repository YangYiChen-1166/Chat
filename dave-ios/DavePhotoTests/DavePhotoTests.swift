import XCTest
@testable import DavePhoto

final class DavePhotoTests: XCTestCase {
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

