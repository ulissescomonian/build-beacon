import AppKit
@testable import BuildBeaconUI
import XCTest

final class BuildBeaconBrandTests: XCTestCase {
    func testBrandUsesAvailableNativeBeaconSymbolInsteadOfAntenna() {
        XCTAssertEqual(BuildBeaconBrand.symbolName, "light.beacon.max.fill")
        XCTAssertFalse(BuildBeaconBrand.symbolName.contains("antenna"))
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: BuildBeaconBrand.symbolName,
                accessibilityDescription: nil
            )
        )
    }
}
