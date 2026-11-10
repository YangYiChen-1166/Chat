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
}

