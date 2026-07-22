import AppKit
@testable import BuildBeacon
import XCTest

@MainActor
final class BuildBeaconApplicationDelegateTests: XCTestCase {
    func testReopenWithoutVisibleWindowsOpensDashboardAndSuppressesDefaultHandling() {
        let delegate = BuildBeaconApplicationDelegate()
        var reopenCalls = 0
        delegate.install {
            reopenCalls += 1
        }

        let shouldUseDefaultHandling = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        XCTAssertEqual(reopenCalls, 1)
        XCTAssertFalse(shouldUseDefaultHandling)
    }

    func testReopenWithVisibleWindowsFocusesDashboardAndSuppressesDefaultHandling() {
        let delegate = BuildBeaconApplicationDelegate()
        var reopenCalls = 0
        delegate.install {
            reopenCalls += 1
        }

        let shouldUseDefaultHandling = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: true
        )

        XCTAssertEqual(reopenCalls, 1)
        XCTAssertFalse(shouldUseDefaultHandling)
    }

    func testReopenBeforeInstallationIsDeliveredOnceWhenHandlerBecomesAvailable() {
        let delegate = BuildBeaconApplicationDelegate()

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))

        var reopenCalls = 0
        delegate.install {
            reopenCalls += 1
        }

        XCTAssertEqual(reopenCalls, 1)
    }
}
