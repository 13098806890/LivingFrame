import XCTest

final class LivingFrameUITests: XCTestCase {
    private struct AuditProfile {
        let name: String
        let language: String
        let locale: String
        let appearance: String
        let contentSizeCategory: String?
    }

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false

        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for title in ["允许", "Allow", "好", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    @MainActor
    func testSmokeVisualAudit() throws {
        try runAudit([Self.simplifiedChinese])
    }

    @MainActor
    func testStandardVisualAudit() throws {
        try runAudit([Self.simplifiedChinese, Self.english, Self.arabic])
    }

    @MainActor
    func testDarkAppearanceVisualAudit() throws {
        try runAudit([Self.darkEnglish])
    }

    @MainActor
    func testAccessibilityTextVisualAudit() throws {
        try runAudit([Self.accessibilityEnglish])
    }

    /// 使用 App 自己的编辑、存储和导出能力走一条完整用户链路。
    /// 测试素材由 Debug-only 启动参数生成，因此不依赖照片权限和宿主机相册状态。
    @MainActor
    func testFunctionalWorkflowAudit() throws {
        let profile = Self.functionalEnglish
        launch(profile, extraArguments: ["-UIAuditSeedProject"])

        let projectTitle = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "UI Audit Project")
        ).firstMatch
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 30), "Seeded editor did not appear")
        waitForUIToSettle()
        attachScreenshot(named: "functional--01-seeded-editor")

        tapButton(["Play", "播放"])
        attachScreenshot(named: "functional--02-playing")
        tapButton(["Pause", "暂停"])

        tapButton(["Full-screen preview", "全屏预览"])
        XCTAssertTrue(
            matchingButton(["Close full-screen preview", "关闭全屏预览"]).waitForExistence(timeout: 10),
            "Full-screen preview did not appear"
        )
        attachScreenshot(named: "functional--03-fullscreen-preview")
        tapButton(["Close full-screen preview", "关闭全屏预览"])

        tapButton(["Canvas", "画布"])
        XCTAssertTrue(matchingButton(["Transparent background", "透明背景"]).waitForExistence(timeout: 10))
        attachScreenshot(named: "functional--04-canvas-tool")
        tapButton(["Transparent background", "透明背景"])
        waitForUIToSettle()
        attachScreenshot(named: "functional--05-transparent-canvas")
        tapNavigationButton(["Done", "完成"])

        tapButton(["Text", "文字"])
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 10), "Text editor did not appear")
        textField.tap()
        textField.typeText(" Verified")
        attachScreenshot(named: "functional--06-text-edited")
        if matchingButton(["Dismiss Keyboard", "收起键盘"]).exists {
            tapButton(["Dismiss Keyboard", "收起键盘"])
        }
        tapNavigationButton(["Done", "完成"])

        tapButton(["Sticker", "贴纸"])
        let firework = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "烟花")
        ).firstMatch
        XCTAssertTrue(firework.waitForExistence(timeout: 10), "Sticker picker did not appear")
        attachScreenshot(named: "functional--07-sticker-picker")
        firework.tap()
        waitForUIToSettle()
        attachScreenshot(named: "functional--08-sticker-added")

        tapButton(["Save Work", "保存作品"])
        waitUntilButtonEnabled(["Save Work", "保存作品"], timeout: 20)
        tapTab(index: 2)
        XCTAssertTrue(
            app.staticTexts["UI Audit Project"].waitForExistence(timeout: 20),
            "Saved work did not appear in Works"
        )
        attachScreenshot(named: "functional--09-saved-work")

        tapButton(["Edit", "编辑"])
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 20), "Saved work did not reopen")
        attachScreenshot(named: "functional--10-reopened-editor")

        tapButton(["Export", "导出"])
        XCTAssertTrue(matchingNavigationButton(["Export", "导出"]).waitForExistence(timeout: 10))
        attachScreenshot(named: "functional--11-export-options")
        tapNavigationButton(["Export", "导出"])
        XCTAssertTrue(
            matchingStaticText(["Exported Successfully", "导出成功"]).waitForExistence(timeout: 60),
            "GIF export did not complete"
        )
        attachScreenshot(named: "functional--12-export-success")
        tapNavigationButton(["Cancel", "取消"])

        tapTab(index: 3)
        let coralTheme = matchingButton(["珊瑚海"])
        XCTAssertTrue(coralTheme.waitForExistence(timeout: 10), "Theme controls did not appear")
        coralTheme.tap()
        waitForUIToSettle()
        attachScreenshot(named: "functional--13-theme-changed")

        let preserveQuality = matchingSwitch([
            "Preserve original frame rate and resolution",
            "保留原始帧率和分辨率"
        ])
        scrollToElement(preserveQuality)
        if preserveQuality.value as? String != "1" {
            preserveQuality.tap()
        }
        attachScreenshot(named: "functional--14-settings-changed")
        attachAccessibilityHierarchy(named: "functional-before-relaunch")

        app.terminate()
        launch(profile, extraArguments: ["-UIAuditSeedProject"])
        tapTab(index: 3)
        let persistedQuality = matchingSwitch([
            "Preserve original frame rate and resolution",
            "保留原始帧率和分辨率"
        ])
        scrollToElement(persistedQuality)
        XCTAssertEqual(persistedQuality.value as? String, "1", "Setting did not survive relaunch")
        attachScreenshot(named: "functional--15-settings-persisted")
        attachAccessibilityHierarchy(named: "functional")
        app.terminate()
    }

    @MainActor
    private func runAudit(_ profiles: [AuditProfile]) throws {
        for profile in profiles {
            try XCTContext.runActivity(named: profile.name) { _ in
                launch(profile)
                try captureMainTabs(profileName: profile.name)
                app.terminate()
            }
        }
    }

    private static let simplifiedChinese = AuditProfile(
        name: "zh-Hans-light-standard",
        language: "zh-Hans",
        locale: "zh_CN",
        appearance: "Light",
        contentSizeCategory: nil
    )

    private static let english = AuditProfile(
        name: "en-light-standard",
        language: "en",
        locale: "en_US",
        appearance: "Light",
        contentSizeCategory: nil
    )

    private static let arabic = AuditProfile(
        name: "ar-light-standard",
        language: "ar",
        locale: "ar_SA",
        appearance: "Light",
        contentSizeCategory: nil
    )

    private static let darkEnglish = AuditProfile(
        name: "en-dark-standard",
        language: "en",
        locale: "en_US",
        appearance: "Dark",
        contentSizeCategory: nil
    )

    private static let accessibilityEnglish = AuditProfile(
        name: "en-light-accessibility-xxxl",
        language: "en",
        locale: "en_US",
        appearance: "Light",
        contentSizeCategory: nil
    )

    private static let functionalEnglish = AuditProfile(
        name: "en-light-functional",
        language: "en",
        locale: "en_US",
        appearance: "Light",
        contentSizeCategory: nil
    )

    private func launch(_ profile: AuditProfile, extraArguments: [String] = []) {
        app.launchArguments = [
            "-AppleLanguages", "(\(profile.language))",
            "-AppleLocale", profile.locale,
            "-AppleInterfaceStyle", profile.appearance
        ] + extraArguments
        if let category = profile.contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }

        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "App did not reach the foreground for \(profile.name)"
        )
    }

    private func captureMainTabs(profileName: String) throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Main tab bar did not appear")
        XCTAssertGreaterThanOrEqual(tabBar.buttons.count, 4, "Expected four main tabs")

        let blockedTabs = (0..<4).filter { !tabBar.buttons.element(boundBy: $0).isHittable }
        if !blockedTabs.isEmpty {
            attachScreenshot(named: "\(profileName)--navigation-blocked")
            attachAccessibilityHierarchy(named: profileName)
            XCTFail("Main tabs are not hittable at indexes \(blockedTabs)")
            return
        }

        let screens = ["library", "editor", "works", "settings"]
        for (index, screen) in screens.enumerated() {
            let button = tabBar.buttons.element(boundBy: index)
            XCTAssertTrue(button.exists, "Missing main tab at index \(index)")
            button.tap()
            waitForUIToSettle()
            attachScreenshot(named: "\(profileName)--\(screen)--top")

            if screen == "settings", app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
                app.scrollViews.firstMatch.swipeUp()
                waitForUIToSettle()
                attachScreenshot(named: "\(profileName)--settings--bottom")
            }
        }

        attachAccessibilityHierarchy(named: profileName)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachAccessibilityHierarchy(named profileName: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(profileName)--accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func waitForUIToSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func matchingButton(_ labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func matchingNavigationButton(_ labels: [String]) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func matchingStaticText(_ labels: [String]) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func matchingSwitch(_ labels: [String]) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    @discardableResult
    private func tapButton(_ labels: [String], timeout: TimeInterval = 10) -> XCUIElement {
        let element = matchingButton(labels)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing button: \(labels)")
        XCTAssertTrue(element.isHittable, "Button is not hittable: \(labels)")
        element.tap()
        return element
    }

    @discardableResult
    private func tapNavigationButton(_ labels: [String], timeout: TimeInterval = 10) -> XCUIElement {
        let element = matchingNavigationButton(labels)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing navigation button: \(labels)")
        XCTAssertTrue(element.isHittable, "Navigation button is not hittable: \(labels)")
        element.tap()
        return element
    }

    private func waitUntilButtonEnabled(_ labels: [String], timeout: TimeInterval) {
        let element = matchingButton(labels)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing button: \(labels)")
        let enabled = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func tapTab(index: Int) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Main tab bar did not appear")
        let tab = tabBar.buttons.element(boundBy: index)
        XCTAssertTrue(tab.exists && tab.isHittable, "Main tab at index \(index) is unavailable")
        tab.tap()
        waitForUIToSettle()
    }

    private func scrollToElement(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Expected settings control is missing")
        let scrollView = app.scrollViews.firstMatch
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<5 {
            let isComfortablyVisible = element.isHittable && element.frame.maxY < tabBarTop - 24
            if isComfortablyVisible { break }
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            element.isHittable && element.frame.maxY < tabBarTop,
            "Could not scroll settings control above the tab bar"
        )
    }
}
