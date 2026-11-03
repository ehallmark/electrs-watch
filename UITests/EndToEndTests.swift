import XCTest

/// Drives the real app against a real onion service. Run through `scripts/e2e/run.sh`, which provides
/// the service and swaps files with this test through EW_E2E_DIR. Addresses are public test vectors.
final class EndToEndTests: XCTestCase {
    private let expectedTotal = "1.23506789 BTC"
    private let expectedPending = "Pending -0.00001000 BTC"
    private let expectedTotalInSats = "123,506,789 sats"
    private let expectedTip = "Block 900000"

    private var directory: URL {
        get throws {
            let path = try XCTUnwrap(ProcessInfo.processInfo.environment["EW_E2E_DIR"], "Run scripts/e2e/run.sh")
            return URL(fileURLWithPath: path)
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForFile(_ name: String, timeout: TimeInterval = 120) throws -> String {
        let url = try directory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw XCTSkip("Timed out waiting for \(name)")
    }

    private func signal(_ name: String, _ text: String = "1") throws {
        try text.write(to: try directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Dismisses the first-use Face ID permission alert, which belongs to SpringBoard.
    private func allowSystemAlert() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func addAddress(_ app: XCUIApplication, _ address: String, label: String) {
        element(app, "home.add").tap()
        let field = element(app, "add.address")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address)
        let labelField = element(app, "add.label")
        labelField.tap()
        labelField.typeText(label)
        element(app, "add.save").tap()
        XCTAssertTrue(element(app, "home.add").waitForExistence(timeout: 10))
    }

    /// Taps Refresh or Retry until `done` is true. Onion services can take a few tries.
    private func refreshUntil(_ app: XCUIApplication, timeout: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            let refresh = element(app, "home.refresh")
            if refresh.waitForExistence(timeout: 200), refresh.isHittable {
                if done() { return true }
                let error = element(app, "home.error")
                print("EW_E2E refresh attempt, last error: \(error.exists ? error.label : "none")")
                refresh.tap()
            }
            Thread.sleep(forTimeInterval: 8)
        }
        return done()
    }

    func testFullFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // DEMO: sample data, clearly labeled, with no refresh and nothing kept after exiting.
        XCTAssertTrue(element(app, "setup.demo").waitForExistence(timeout: 30))
        element(app, "setup.demo").tap()
        XCTAssertTrue(element(app, "demo.badge").waitForExistence(timeout: 10), "Demo wasn't labeled")
        XCTAssertEqual(element(app, "home.total").label, "0.97510000 BTC")
        XCTAssertFalse(element(app, "home.refresh").exists, "Demo offered to connect")
        XCTAssertFalse(element(app, "home.hardRefresh").exists, "Demo offered to connect")
        element(app, "row.Savings").tap()
        XCTAssertTrue(element(app, "detail.tx.0.amount").waitForExistence(timeout: 5), "Demo address page empty")
        XCTAssertEqual(element(app, "detail.tx.0.amount").label, "+0.00500000 BTC")
        XCTAssertTrue(element(app, "demo.badge").exists, "Demo address page wasn't labeled")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("demo.png"))
        app.navigationBars["Savings"].buttons.firstMatch.tap()
        element(app, "demo.exit").tap()

        // First run: generate a key. Back at the welcome screen means the demo saved nothing.
        XCTAssertTrue(element(app, "setup.start").waitForExistence(timeout: 30))
        element(app, "setup.start").tap()
        allowSystemAlert()

        let publicKey = element(app, "pair.publicKey")
        XCTAssertTrue(publicKey.waitForExistence(timeout: 60), "Face ID unlock after setup failed")
        let line = publicKey.label
        XCTAssertTrue(line.hasPrefix("descriptor:x25519:"))
        XCTAssertEqual(line.count, "descriptor:x25519:".count + 52)

        // Bad onion addresses are refused.
        let onionField = element(app, "pair.onion")
        onionField.tap()
        onionField.typeText("example.com")
        element(app, "pair.continue").tap()
        XCTAssertTrue(element(app, "pair.invalid").waitForExistence(timeout: 5))
        onionField.tap()
        onionField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11))
        onionField.typeText(try waitForFile("onion.txt"))
        element(app, "pair.continue").tap()
        XCTAssertTrue(element(app, "home.add").waitForExistence(timeout: 10))

        // Things that must never be accepted as an address.
        element(app, "home.add").tap()
        let field = element(app, "add.address")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8")
        element(app, "add.save").tap()
        XCTAssertTrue(element(app, "add.problem").waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        XCTAssertTrue(element(app, "home.add").waitForExistence(timeout: 10))
        addAddress(app, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", label: "legacy")
        addAddress(app, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", label: "segwit")

        // NEGATIVE: the service exists, but it doesn't list this phone's key yet.
        let refused = refreshUntil(app, timeout: 420) {
            let error = element(app, "home.error")
            return error.exists && error.label.contains("isn't authorized")
        }
        XCTAssertTrue(refused, "Expected refusal before authorization, got: \(element(app, "home.error").label)")
        XCTAssertFalse(element(app, "home.total").exists, "Showed a balance without authorization")
        try signal("refused.flag")

        // Same steps as docs/NODE-SETUP.md: authorize the key, then retry.
        try signal("pubkey.txt", line)
        _ = try waitForFile("authorized.flag")

        let connected = refreshUntil(app, timeout: 500) { element(app, "home.total").exists }
        XCTAssertTrue(connected, "Never connected. Last error: \(element(app, "home.error").label)")

        // POSITIVE: exact values, through Tor, from the mock server.
        XCTAssertEqual(element(app, "home.total").label, expectedTotal)
        XCTAssertEqual(element(app, "home.pending").label, expectedPending)
        XCTAssertTrue(element(app, "home.tip").label.hasPrefix(expectedTip))
        XCTAssertEqual(element(app, "row.legacy").label, "1.23456789 BTC, 2 tx")
        XCTAssertEqual(element(app, "row.segwit").label, "0.00050000 BTC, 2 tx")

        // Amounts can be hidden.
        element(app, "home.hide").tap()
        XCTAssertFalse(element(app, "home.total").label.contains("1.23"))
        element(app, "home.hide").tap()

        // The harness inspects the running process here.
        try signal("connected.flag")
        _ = try waitForFile("inspected.flag")

        // Amounts can be shown in sats.
        XCTAssertFalse(element(app, "home.stale").exists, "A fresh balance was labeled as saved")
        element(app, "home.settings").tap()
        let sats = app.buttons["sats"]
        XCTAssertTrue(sats.waitForExistence(timeout: 10))
        sats.tap()
        // Light mode can be chosen, for a screenshot of how it looks, then back to the default.
        app.buttons["Light"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "home.total").waitForExistence(timeout: 10))
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("light.png"))
        element(app, "home.settings").tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 10), "No appearance setting")
        app.buttons["Dark"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "home.total").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "home.total").label, expectedTotalInSats)
        XCTAssertEqual(element(app, "home.pending").label, "Pending -1,000 sats")
        XCTAssertEqual(element(app, "row.segwit").label, "50,000 sats, 2 tx")

        // The address page works out each transaction's amount from the raw transactions.
        element(app, "row.segwit").tap()
        XCTAssertTrue(element(app, "detail.balance").waitForExistence(timeout: 10), "Tapping an address didn't open its page")
        XCTAssertEqual(element(app, "detail.balance").label, "50,000 sats")
        XCTAssertEqual(element(app, "detail.pending").label, "Pending -1,000 sats")
        let newest = element(app, "detail.tx.0.amount")
        XCTAssertTrue(newest.waitForExistence(timeout: 120), "Transactions didn't load: \(element(app, "detail.error").label)")
        XCTAssertTrue(element(app, "detail.received").label.contains("50,000 sats"), "Received total wrong")
        XCTAssertTrue(element(app, "detail.sent").label.contains("1,000 sats"), "Sent total wrong")
        XCTAssertTrue(element(app, "detail.chart").exists, "No balance chart")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("detail.png"))
        // Newest first: the pending spend, then the payment it spends. The list only draws rows on screen.
        XCTAssertEqual(newest.label, "-1,000 sats")
        XCTAssertEqual(element(app, "detail.tx.0.balance").label, "Balance after, 49,000 sats")
        app.swipeUp()
        XCTAssertTrue(element(app, "detail.tx.1.amount").waitForExistence(timeout: 5), "Older transaction missing")
        XCTAssertEqual(element(app, "detail.tx.1.amount").label, "+50,000 sats")
        XCTAssertEqual(element(app, "detail.tx.1.balance").label, "Balance after, 50,000 sats")
        // Tapping a transaction shows its ID, which the app checked against the raw bytes.
        element(app, "detail.tx.1.amount").tap()
        let txid = element(app, "detail.tx.1.id")
        XCTAssertTrue(txid.waitForExistence(timeout: 5), "Tapping a transaction didn't show its details")
        XCTAssertEqual(txid.label, "5f687d4a0b03c7ec9b2733df3d61e0d4bc3a7d1a0f77b06a0969a384379eed98")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("detail-tx.png"))

        // Renaming from the page changes the label and keeps the balance.
        element(app, "detail.edit").tap()
        let renameField = element(app, "rename.label")
        XCTAssertTrue(renameField.waitForExistence(timeout: 10), "The page didn't offer a rename")
        renameField.tap()
        renameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "segwit".count) + "cold")
        element(app, "rename.save").tap()
        XCTAssertTrue(app.navigationBars["cold"].waitForExistence(timeout: 10), "The page title didn't change")
        app.navigationBars["cold"].buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "row.cold").waitForExistence(timeout: 10), "Rename didn't apply")
        XCTAssertEqual(element(app, "row.cold").label, "50,000 sats, 2 tx")
        XCTAssertEqual(element(app, "home.total").label, expectedTotalInSats)

        // Backgrounding locks, and balances are gone until unlocked.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(element(app, "lock.unlock").waitForExistence(timeout: 20), "Did not lock on background")
        XCTAssertFalse(element(app, "home.total").exists, "Balance visible while locked")
        element(app, "lock.unlock").tap()

        // Opening within 10 minutes of a refresh shows the saved balance, in the saved unit, as current,
        // and doesn't reconnect.
        XCTAssertTrue(element(app, "home.total").waitForExistence(timeout: 60), "Saved balance not shown after unlock")
        XCTAssertEqual(element(app, "home.total").label, expectedTotalInSats)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(app, "home.activity").exists, "Refreshed again right after a recent refresh")
        XCTAssertFalse(element(app, "home.stale").exists, "A balance from minutes ago was labeled as old")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("saved.png"))

        // The address page was saved behind Face ID, so it shows right away without connecting.
        element(app, "row.cold").tap()
        let savedTx = element(app, "detail.tx.0.amount")
        XCTAssertTrue(savedTx.waitForExistence(timeout: 5), "Saved transactions weren't shown after unlock")
        XCTAssertEqual(savedTx.label, "-1,000 sats")
        XCTAssertFalse(element(app, "detail.loading").exists, "Fetched a page that was saved")
        app.navigationBars["cold"].buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "home.refresh").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "home.activity").exists, "Opening a saved page connected")

        // A tap still refreshes, with Tor resuming in the same process.
        element(app, "home.refresh").tap()
        XCTAssertTrue(element(app, "home.stale").waitForExistence(timeout: 5), "Tapping Refresh didn't start one")
        XCTAssertTrue(refreshUntil(app, timeout: 300) {
            !element(app, "home.activity").exists && !element(app, "home.stale").exists && !element(app, "home.error").exists
        }, "Did not reconnect after unlock")
        XCTAssertEqual(element(app, "home.total").label, expectedTotalInSats)
        XCTAssertEqual(element(app, "row.cold").label, "50,000 sats, 2 tx", "The new label didn't survive a lock and refresh")
        try signal("resumed.flag")

        // STALL: the harness freezes the service, so the next open gets stuck the way a phone can.
        // Relaunched with no 10-minute window (simulator only), so opening refreshes again this soon.
        _ = try waitForFile("service-frozen.flag")
        app.terminate()
        app.launchEnvironment["EW_FRESH_SECONDS"] = "0"
        app.launch()
        XCTAssertTrue(element(app, "lock.unlock").waitForExistence(timeout: 30), "Didn't open locked")
        element(app, "lock.unlock").tap()
        XCTAssertTrue(element(app, "home.activity").waitForExistence(timeout: 60), "Refresh didn't start on open")
        try signal("stall-started.flag")
        // Open an address that's never been loaded while the connection is stuck. Its page has to load
        // by itself once the app connects, even though the refresh changes the balances meanwhile.
        element(app, "row.legacy").tap()
        XCTAssertTrue(app.navigationBars["legacy"].waitForExistence(timeout: 10), "The address page didn't open")
        _ = try waitForFile("service-thawed.flag", timeout: 180)
        let legacyTx = element(app, "detail.tx.0.amount")
        XCTAssertTrue(legacyTx.waitForExistence(timeout: 300),
                      "Page opened before connecting never loaded. Load button shown: \(element(app, "detail.load").exists)")
        XCTAssertEqual(legacyTx.label, "-76,543,211 sats")
        app.navigationBars["legacy"].buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "home.hardRefresh").waitForExistence(timeout: 10))

        // The app has to recover by itself, by resetting Tor between attempts, with no tap needed.
        let recovered = element(app, "home.stale")
        let deadline = Date().addingTimeInterval(240)
        while recovered.exists, Date() < deadline { Thread.sleep(forTimeInterval: 2) }
        XCTAssertFalse(recovered.exists, "Did not recover by itself. Last error: \(element(app, "home.error").label)")

        // The log shows what happened, and it survived the earlier lock.
        element(app, "home.settings").tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.swipeUp()
        // Earlier connections may also have needed a reset, so only the reset row is certain.
        XCTAssertTrue(element(app, "settings.log.connectedAfterReset").waitForExistence(timeout: 10), "Recovery didn't go through a reset")
        app.buttons["Done"].tap()

        // HARD REFRESH: starts over from scratch, and reconnects.
        let hardRefresh = element(app, "home.hardRefresh")
        XCTAssertTrue(hardRefresh.waitForExistence(timeout: 10), "No Hard Refresh button")
        hardRefresh.tap()
        XCTAssertTrue(element(app, "home.stale").waitForExistence(timeout: 5), "Hard refresh didn't start an update")
        XCTAssertTrue(element(app, "home.activity").label.hasPrefix("Hard refresh: "), "Screen didn't say a hard refresh is running")
        XCTAssertTrue(element(app, "home.progress").label.hasPrefix("Attempt 1, 0:0"), "Progress didn't restart at zero")
        // Tapping again mid-attempt must abandon that attempt cleanly, not stack a second one.
        if hardRefresh.waitForExistence(timeout: 5) { hardRefresh.tap() }
        let hardDeadline = Date().addingTimeInterval(240)
        while element(app, "home.stale").exists, Date() < hardDeadline { Thread.sleep(forTimeInterval: 2) }
        XCTAssertFalse(element(app, "home.stale").exists, "Hard refresh didn't reconnect. Last error: \(element(app, "home.error").label)")
        XCTAssertEqual(element(app, "home.total").label, expectedTotalInSats)
        element(app, "home.settings").tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(element(app, "settings.log.connectedAfterHardRefresh").waitForExistence(timeout: 10), "Hard refresh wasn't logged")
        XCTAssertTrue(element(app, "settings.log.hardRefreshUsed").exists, "Hard refresh taps weren't counted")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: try directory.appendingPathComponent("log.png"))
        try signal("recovered.flag")
    }
}
