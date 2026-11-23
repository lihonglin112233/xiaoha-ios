import XCTest
@testable import XiaoHaCore

/// 小组件深链与快照的回归测试。
final class WidgetDeepLinkTests: XCTestCase {

    func testAllLinksProduceValidURLs() {
        for link in WidgetDeepLink.allCases {
            let url = link.url
            XCTAssertNotNil(url, "\(link.rawValue) 应能构造 URL")
            XCTAssertEqual(url?.scheme, "xiaohacar")
        }
    }

    func testParseRoundTrip() throws {
        for link in WidgetDeepLink.allCases {
            let url = try XCTUnwrap(link.url)
            XCTAssertEqual(WidgetDeepLink.parse(url), link, "\(link.rawValue) 解析不一致")
        }
    }

    /// 用户指定的四个按钮必须都能正确映射到车控动作。
    func testRequestedButtonsMapCorrectly() {
        XCTAssertEqual(WidgetDeepLink.parse(URL(string: "xiaohacar://action/engineStart")!),
                       .engineStart)
        XCTAssertEqual(WidgetDeepLink.parse(URL(string: "xiaohacar://action/lock")!), .lock)
        XCTAssertEqual(WidgetDeepLink.parse(URL(string: "xiaohacar://action/unlock")!), .unlock)
        XCTAssertEqual(WidgetDeepLink.parse(URL(string: "xiaohacar://action/windowClose")!), .windowClose)

        XCTAssertEqual(WidgetDeepLink.engineStart.vehicleAction, .engineStart)
        XCTAssertEqual(WidgetDeepLink.lock.vehicleAction, .lock)
        XCTAssertEqual(WidgetDeepLink.unlock.vehicleAction, .unlock)
        XCTAssertEqual(WidgetDeepLink.windowClose.vehicleAction, .windowClose)
    }

    func testRefreshHasNoVehicleAction() {
        XCTAssertNil(WidgetDeepLink.refresh.vehicleAction)
    }

    func testRejectsForeignSchemes() {
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "https://example.com/action/lock")!))
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "otherapp://action/lock")!))
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "xiaohacar://action/unknownAction")!))
    }

    /// 兼容 xiaohacar://lock 这种简写。
    func testShortFormURL() {
        XCTAssertEqual(WidgetDeepLink.parse(URL(string: "xiaohacar://lock")!), .lock)
    }

    /// 快照缺失时必须给出占位而不是崩溃。
    func testSnapshotPlaceholderWhenMissing() {
        let snapshot = WidgetStore.load()
        // 未写入过数据时，车名是默认值，其他为 nil
        XCTAssertFalse(snapshot.vehicleName.isEmpty)
        XCTAssertNil(snapshot.battery)
    }

    /// 小组件四个按钮的文案与图标必须齐全，避免渲染时空白。
    func testWidgetButtonTitlesAndIcons() {
        let requested: [WidgetDeepLink] = [.engineStart, .lock, .unlock, .windowClose]
        for link in requested {
            XCTAssertFalse(link.title.isEmpty, "\(link.rawValue) 缺少标题")
            XCTAssertFalse(link.systemImage.isEmpty, "\(link.rawValue) 缺少图标")
            XCTAssertFalse(link.systemImage.contains(".") && link.systemImage.isEmpty)
        }
        XCTAssertEqual(WidgetDeepLink.engineStart.title, "远程启动")
        XCTAssertEqual(WidgetDeepLink.lock.title, "锁车")
        XCTAssertEqual(WidgetDeepLink.unlock.title, "解锁")
        XCTAssertEqual(WidgetDeepLink.windowClose.title, "关车窗")
    }

    /// 车名为空时不能导致布局塌陷。
    func testWidgetHandlesEmptySnapshot() {
        let empty = WidgetSnapshot()
        XCTAssertFalse(empty.vehicleName.isEmpty, "空快照也要有占位车名")
        XCTAssertEqual(empty.engineText, "--")
        XCTAssertFalse(empty.engineRunning)
        XCTAssertNil(empty.locked)
        XCTAssertNil(empty.battery)
        XCTAssertNil(empty.range)
    }

    /// 超长车名需要可截断（界面用 lineLimit(1) + truncationMode）。
    func testLongVehicleNameIsSupported() {
        var status = VehicleStatus()
        status.batteryPercent = 70
        let vehicle = GwmVehicle(vin: "LG WEF5A54MH302577",
                                 modelName: "哈弗第三代H6_CC6470AH02A_基础款-黑色内饰_Max超长车型名称")
        let snapshot = WidgetSnapshot(status: status, vehicle: vehicle, updatedAt: Date())
        XCTAssertGreaterThan(snapshot.vehicleName.count, 20)
    }

    func testSnapshotRoundTripThroughStore() {
        var status = VehicleStatus()
        status.doorsLocked = true
        status.batteryPercent = 70
        status.fuelRange = 268
        status.engineState = "0"
        let vehicle = GwmVehicle(vin: "LG WEF5A54MH302577", modelName: "哈弗第三代H6")
        let snapshot = WidgetSnapshot(status: status, vehicle: vehicle, updatedAt: Date())

        WidgetStore.save(snapshot)
        let loaded = WidgetStore.load()
        XCTAssertEqual(loaded.battery, 70)
        XCTAssertEqual(loaded.range, 268)
        XCTAssertEqual(loaded.locked, true)
        XCTAssertEqual(loaded.engineText, "未启动")
    }
}
