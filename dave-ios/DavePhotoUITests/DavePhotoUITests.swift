import XCTest

final class DavePhotoUITests: XCTestCase {
    @MainActor func testBrowseSelectAndPreviewSyntheticPhotos() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--mock-fixture"]
        app.launch()
        let connection = app.staticTexts["示例相册已连接"]
        XCTAssertTrue(connection.waitForExistence(timeout: 60), "The synthetic workstation state should load")
        let browse = app.staticTexts["浏览照片"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        browse.tap()
        let photo = app.staticTexts["示例照片1.jpg"]
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        let select = app.buttons["select-photo-1"]
        XCTAssertTrue(select.waitForExistence(timeout: 10)); select.tap()
        XCTAssertTrue(app.buttons["已选 1"].waitForExistence(timeout: 10))
        let preview = app.buttons["preview-photo-1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); preview.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15), "Native preview sheet should open")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["已选 1"].waitForExistence(timeout: 10))
    }
    @MainActor func testRemoteWindowAndFaceReviewWithSyntheticData() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--mock-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["示例相册已连接"].waitForExistence(timeout: 60))
        let mini = app.buttons["open-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 20)); mini.tap()
        XCTAssertTrue(app.staticTexts["点击画面操作；滑动或使用按钮滚动。"].waitForExistence(timeout: 20))
        let scroll = app.buttons["向下"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 20)); scroll.tap()
        app.buttons["关闭"].tap()
        let browse = app.staticTexts["浏览照片"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20)); browse.tap()
        let selection = app.buttons["select-photo-1"]
        XCTAssertTrue(selection.waitForExistence(timeout: 20)); selection.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let face = app.buttons["open-face"]
        if !face.isHittable { app.swipeUp() }
        XCTAssertTrue(face.waitForExistence(timeout: 20)); face.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "face-person").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20)); picker.tap()
        let person = app.staticTexts["示例人物 · 2 个样本"]
        XCTAssertTrue(person.waitForExistence(timeout: 10)); person.tap()
        let start = app.buttons["start-face"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let facePreview = app.buttons["preview-face-1"]
        XCTAssertTrue(facePreview.waitForExistence(timeout: 20)); facePreview.tap()
        XCTAssertTrue(app.staticTexts["示例人物 · 0.95"].waitForExistence(timeout: 20))
        app.buttons["完成"].tap()
        let review = app.buttons["review-face-1"]
        XCTAssertTrue(review.waitForExistence(timeout: 20)); review.tap()
        let other = app.buttons["归为非目标"]
        XCTAssertTrue(other.waitForExistence(timeout: 10)); other.tap()
        XCTAssertTrue(app.staticTexts["非目标 · 1"].waitForExistence(timeout: 20))
    }
}

