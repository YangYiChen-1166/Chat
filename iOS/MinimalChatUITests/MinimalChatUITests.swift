import XCTest

final class MinimalChatUITests: XCTestCase {
    private let root = URL(string: "https://minimal-chat-api.yangyichen1166.workers.dev")!

    private func request(_ path: String, method: String = "GET", body: [String: String]? = nil, token: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: path, relativeTo: root)!)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UITestAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture request failed: \(path)"])
        }
        return value
    }

    @MainActor func testLoginAndSendMessageToFriend() async throws {
        continueAfterFailure = false
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let aliceName = "uitesta_\(suffix)", bobName = "uitestb_\(suffix)"
        let password = "UITest-\(UUID().uuidString)"
        let alice = try await request("/register", method: "POST", body: ["username": aliceName, "password": password])
        let bob = try await request("/register", method: "POST", body: ["username": bobName, "password": password])
        let aliceUser = try XCTUnwrap(alice["user"] as? [String: String])
        let bobUser = try XCTUnwrap(bob["user"] as? [String: String])
        let aliceID = try XCTUnwrap(aliceUser["id"]), bobID = try XCTUnwrap(bobUser["id"])
        let aliceToken = try XCTUnwrap(alice["token"] as? String), bobToken = try XCTUnwrap(bob["token"] as? String)
        print("UI_TEST_USER_IDS \(aliceID) \(bobID)")
        _ = try await request("/friends/request", method: "POST", body: ["username": bobName], token: aliceToken)
        _ = try await request("/friends/\(aliceID)/accept", method: "POST", body: [:], token: bobToken)

        let app = XCUIApplication()
        app.launch()
        let username = app.textFields["loginUsername"]
        XCTAssertTrue(username.waitForExistence(timeout: 45))
        username.tap(); username.typeText(aliceName)
        let passwordField = app.secureTextFields["loginPassword"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap(); passwordField.typeText(password)
        let login = app.buttons["登录"]
        XCTAssertTrue(login.waitForExistence(timeout: 10)); login.tap()
        let friend = app.staticTexts[bobName]
        XCTAssertTrue(friend.waitForExistence(timeout: 60), "Friend should appear after login")
        friend.tap()
        let input = app.descendants(matching: .any).matching(identifier: "messageInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        let message = "hello-\(suffix)"
        input.tap(); input.typeText(message)
        let send = app.buttons["sendMessage"]
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 60), "Sent message should appear in the conversation")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); capture.name = "Chat after sending"; capture.lifetime = .keepAlways; add(capture)
        let received = try await request("/messages/\(aliceID)", token: bobToken)
        let messages = try XCTUnwrap(received["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["body"] as? String) == message && ($0["sender_id"] as? String) == aliceID }, "Recipient must receive the text sent by the UI")
    }
}

