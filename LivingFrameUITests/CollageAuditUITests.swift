import XCTest

/// 针对编辑页“拼接”工具的独立审计用例。
/// 覆盖用户可见入口、控制面板，以及仅由显式启动参数启用的确定性测试夹具。
final class CollageAuditUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCollageEditorEntryAndControls() throws {
        launchSeededProject()

        let collage = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Collage", "拼接"])
        ).firstMatch
        XCTAssertTrue(collage.waitForExistence(timeout: 10), "Collage tool is not discoverable")
        XCTAssertTrue(collage.isHittable, "Collage tool is not hittable")
        collage.tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--01-editor-opened")

        let collageNavigationBar = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", ["拼接编辑器", "Collage editor"], ["拼接编辑器", "Collage editor"])
        ).firstMatch
        XCTAssertTrue(collageNavigationBar.waitForExistence(timeout: 10), "Collage editor did not open")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label IN %@", ["添加素材", "Add asset"]))
                .firstMatch.waitForExistence(timeout: 10),
            "Add asset action is missing"
        )
        XCTAssertEqual(
            collageSources.count,
            1,
            "Opening collage from the seeded project did not restore its existing background"
        )

        let done = collageNavigationBar.buttons.matching(
            NSPredicate(format: "label IN %@", ["完成", "Done"])
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Collage completion action is missing")
        done.tap()
        XCTAssertFalse(
            collageNavigationBar.waitForExistence(timeout: 5),
            "Collage editor did not dismiss"
        )
        collage.tap()
        XCTAssertTrue(collageNavigationBar.waitForExistence(timeout: 10), "Collage editor did not reopen")
        XCTAssertEqual(
            collageSources.count,
            1,
            "Reopening collage in the same editor session lost its existing material"
        )

        let addDivider = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["添加分割线", "Add divider"])
        ).firstMatch
        XCTAssertTrue(addDivider.waitForExistence(timeout: 10), "Add divider action is missing")
        XCTAssertTrue(addDivider.isEnabled, "Add divider action is unexpectedly disabled")
        addDivider.tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--02-divider-added")

        let canvas = element(identifier: "collage-canvas-preview")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "Collage canvas is not accessible")
        let initialLayoutValue = canvas.value as? String
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.25))
            .press(
                forDuration: 0.15,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.25))
            )
        waitForUIToSettle()
        XCTAssertNotEqual(
            canvas.value as? String,
            initialLayoutValue,
            "Dragging the divider did not update the shared layout offset"
        )

        let angle = app.sliders["collage-divider-angle-0"]
        XCTAssertTrue(angle.waitForExistence(timeout: 10), "Divider angle control is missing")
        XCTAssertTrue(angle.isEnabled, "Divider angle control is unexpectedly disabled")
        let angleValue = app.staticTexts["collage-divider-angle-value-0"]
        XCTAssertTrue(angleValue.waitForExistence(timeout: 10), "Divider angle value is missing")
        XCTAssertEqual(angleValue.label, "90°", "New divider did not keep the expected initial angle")
        attachScreenshot(named: "collage--02b-divider-moved-and-angle-exposed")

        let addAsset = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["添加素材", "Add asset"])
        ).firstMatch
        addAsset.tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--03-asset-picker-opened")
        XCTAssertTrue(
            app.navigationBars.matching(
                NSPredicate(format: "identifier IN %@ OR label IN %@", ["拼接素材", "Collage media"], ["拼接素材", "Collage media"])
            ).firstMatch.waitForExistence(timeout: 10),
            "Collage asset picker did not open"
        )

        // 当前背景素材卡片以 SwiftUI 手势承载点击，未暴露稳定的素材 ID；
        // 这里点击第一张卡片的可视内容，并用“添加(1)”验证选择状态。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.78)).tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--04-asset-selected")
        let addSelectedAsset = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "添加")
        ).firstMatch
        XCTAssertTrue(addSelectedAsset.waitForExistence(timeout: 10), "Selected asset add action is missing")
        XCTAssertTrue(addSelectedAsset.isEnabled, "Selected asset did not enable the add action")
        addSelectedAsset.tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--05-asset-added")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Collage media"))
                .firstMatch.waitForExistence(timeout: 10),
            "Collage editor did not return after adding an asset"
        )
        // 新素材默认保持“未分配”，必须先点击画布区域，再显式点击“添加到这里”。
        // 这一步验证拼接的核心闭环：素材选择 → 区域选择 → 填充区域。
        // 默认 90° 分割线下，seed 素材占右侧区域；点击左侧空区域，
        // 保持刚加入的未分配素材为当前素材，再通过显式按钮完成填充。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.50)).tap()
        waitForUIToSettle()
        let addToRegion = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["点击添加", "Add here"])
        ).firstMatch
        XCTAssertTrue(addToRegion.waitForExistence(timeout: 10), "Partition add action is missing")
        addToRegion.tap()
        waitForUIToSettle()
        attachScreenshot(named: "collage--06-partition-assigned")

        let pickerNavigationBar = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", ["拼接素材", "Collage media"], ["拼接素材", "Collage media"])
        ).firstMatch
        let cancel = pickerNavigationBar.buttons.matching(
            NSPredicate(format: "label IN %@", ["取消", "Cancel"])
        ).firstMatch
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        }
        app.terminate()
    }

    @MainActor
    func testExistingCollageKeepsEachMaterialCropIndependent() throws {
        launchSeededProject()

        let collage = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Collage", "拼接"])
        ).firstMatch
        XCTAssertTrue(collage.waitForExistence(timeout: 10))
        collage.tap()
        waitForUIToSettle()

        XCTAssertTrue(collageSources.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(collageSources.count, 1, "Existing collage material was not restored")
        let originalValue = collageSources.element(boundBy: 0).value as? String

        let duplicate = app.buttons["创建此素材的独立实例"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10), "Duplicate material action is missing")
        duplicate.tap()
        waitForUIToSettle()
        XCTAssertEqual(collageSources.count, 2, "Duplicated material did not create an independent instance")

        let canvas = element(identifier: "collage-canvas-preview")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "Collage canvas is not accessible")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50))
            .press(
                forDuration: 0.15,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.56))
            )
        waitForUIToSettle()
        XCTAssertEqual(
            collageSources.element(boundBy: 0).value as? String,
            originalValue,
            "Moving the active material changed the original material settings"
        )
        XCTAssertFalse(
            (collageSources.element(boundBy: 1).value as? String)?.contains("偏移 0.0,0.0") == true,
            "The duplicated active material did not keep its own crop offset"
        )

        let cropScale = app.sliders["collage-crop-scale"]
        XCTAssertTrue(cropScale.waitForExistence(timeout: 10), "Crop scale control is missing")
        XCTAssertTrue(cropScale.isEnabled, "Crop scale control is unexpectedly disabled")

        let rotate = app.buttons["collage-rotate-active"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10), "Rotate action is missing")
        rotate.tap()
        waitForUIToSettle()

        XCTAssertEqual(
            collageSources.element(boundBy: 0).value as? String,
            originalValue,
            "Rotating the active material changed the original material settings"
        )
        XCTAssertTrue(
            (collageSources.element(boundBy: 1).value as? String)?.contains("90") == true,
            "The duplicated active material did not keep its own rotation state"
        )
        attachScreenshot(named: "collage--independent-material-rotation")
        app.terminate()
    }

    @MainActor
    func testStaticAndAnimatedCollageExposeCorrectPlaybackControls() throws {
        launchSeededProject(extraArguments: ["-UIAuditSeedAnimatedCollage"])

        let collage = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Collage", "拼接"])
        ).firstMatch
        XCTAssertTrue(collage.waitForExistence(timeout: 10))
        collage.tap()
        waitForUIToSettle()

        XCTAssertTrue(collageSources.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(collageSources.count, 2, "Animated collage seed did not create two materials")
        let staticSource = collageSources.element(boundBy: 0)
        let animatedSource = collageSources.element(boundBy: 1)
        XCTAssertTrue(
            (staticSource.value as? String)?.contains("静态素材") == true,
            "First seeded collage source is not identified as static"
        )
        XCTAssertTrue(
            (animatedSource.value as? String)?.contains("动态素材") == true,
            "Second seeded collage source is not identified as animated"
        )

        staticSource.tap()
        waitForUIToSettle()
        XCTAssertFalse(
            element(identifier: "element-playback-controls").exists,
            "Static collage material unexpectedly shows looping controls"
        )

        animatedSource.tap()
        waitForUIToSettle()
        XCTAssertTrue(
            element(identifier: "element-playback-controls").waitForExistence(timeout: 10),
            "Animated collage material does not expose playback range controls"
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label IN %@", ["编辑起始帧和结束帧", "Edit start and end frames"])
            ).firstMatch.waitForExistence(timeout: 10),
            "Animated collage material is missing its source range editor"
        )
        attachScreenshot(named: "collage--static-and-animated-playback-controls")
        app.terminate()
    }

    private var collageSources: XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "collage-source-")
        )
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }

    private func launchSeededProject(extraArguments: [String] = []) {
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Light",
            "-UIAuditSeedProject"
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI Audit Project"))
                .firstMatch.waitForExistence(timeout: 30)
        )
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForUIToSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }
}
