import RetinaLinkCore
import XCTest

final class HEVCProfileTests: XCTestCase {
    func testProfilePropertiesAndMutualPreference() {
        let all = HEVCProfile.allCases
        XCTAssertEqual(all.map(\.bitDepth), [10, 8, 10, 8])
        XCTAssertEqual(all.map(\.is444), [true, true, false, false])
        XCTAssertEqual(all.map(\.codecLabel), ["HEVC 4:4:4 10-bit", "HEVC 4:4:4", "HEVC 10-bit", "HEVC"])
        XCTAssertEqual(HEVCProfile.negotiate(sender: all, receiver: [.hevc420_8, .hevc444_8]), .hevc444_8)
        XCTAssertEqual(HEVCProfile.negotiate(sender: [.hevc420_10, .hevc420_8], receiver: all), .hevc420_10)
        XCTAssertEqual(HEVCProfile.negotiate(sender: all, receiver: nil), .hevc444_10)
        XCTAssertNil(HEVCProfile.negotiate(sender: [.hevc420_8], receiver: nil))
        XCTAssertNil(HEVCProfile.negotiate(sender: [.hevc420_8], receiver: [.hevc444_10]))
    }
}
