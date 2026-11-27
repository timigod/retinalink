import RetinaLinkCore
import XCTest

final class HiDPIPresetTests: XCTestCase {
    func testExact45KLadderAndLabels() {
        let presets = HiDPIPreset.ladder(forPanelWidth: 4480, height: 2520)
        XCTAssertEqual(presets.map(\.id), ["1600x900", "1920x1080", "2048x1152", "2240x1260", "2560x1440", "2880x1620"])
        XCTAssertEqual(presets.map(\.label), ["Larger", "Large", "Medium", "Default", "Compact", "More Space"])
        XCTAssertEqual(presets.map(\.isNativeDefault), [false, false, false, true, false, false])
        XCTAssertEqual(presets.map(\.pixelWidth), [3200, 3840, 4096, 4480, 5120, 5760])
        XCTAssertEqual(presets.map(\.pixelHeight), [1800, 2160, 2304, 2520, 2880, 3240])
    }

    func test5KNativeBackingAndOrderedSteps() {
        let presets = HiDPIPreset.ladder(forPanelWidth: 5120, height: 2880)
        XCTAssertEqual(presets[3].label, "Default")
        XCTAssertTrue(presets[3].isNativeDefault)
        XCTAssertEqual(presets[3].pixelWidth, 5120)
        XCTAssertEqual(presets[3].pixelHeight, 2880)
        XCTAssertEqual(presets.last?.pixelWidth, 5760)
        XCTAssertEqual(presets.last?.pixelHeight, 3240)
        XCTAssertEqual(presets.map(\.logicalWidth), presets.map(\.logicalWidth).sorted())
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
    }

    func testUltrawideAndPortraitPreserveRatioWithinRounding() {
        for (width, height) in [(3440, 1440), (1080, 1920), (1922, 1082)] {
            let presets = HiDPIPreset.ladder(forPanelWidth: width, height: height)
            XCTAssertEqual(presets.count, 6)
            for preset in presets {
                XCTAssertEqual(preset.pixelWidth % 2, 0)
                XCTAssertEqual(preset.pixelHeight % 2, 0)
                let idealHeight = Double(preset.logicalWidth) * Double(height) / Double(width)
                XCTAssertLessThanOrEqual(abs(Double(preset.logicalHeight) - idealHeight), 1 + Double(height) / Double(width))
            }
        }
    }

    func testLargerAndBuiltInPanelsPreserveExactNativePixels() throws {
        for (width, height) in [(6016, 3384), (3024, 1964), (3456, 2234), (3840, 2160)] {
            let ladder = HiDPIPreset.ladder(forPanelWidth: width, height: height)
            let native = try XCTUnwrap(ladder.first(where: \.isNativeDefault))
            let cap = HiDPIPreset.backingCap(forPanelWidth: width, height: height)
            XCTAssertEqual(ladder.count, 6)
            XCTAssertEqual(native.pixelWidth, width)
            XCTAssertEqual(native.pixelHeight, height)
            XCTAssertTrue(ladder.allSatisfy { $0.pixelWidth <= cap.width && $0.pixelHeight <= cap.height })
        }
    }

    func testNative1xPanels() throws {
        for (width, height) in [(1920, 1080), (2560, 1440)] {
            let modes = HiDPIPreset.ladder(forPanelWidth: width, height: height, isHiDPI: false)
            let native = try XCTUnwrap(modes.first(where: \.isNativeDefault))
            XCTAssertEqual(native.scaleFactor, 1)
            XCTAssertEqual(native.pixelWidth, width)
            XCTAssertEqual(native.pixelHeight, height)
            XCTAssertEqual(native.label, "Default")
        }
    }

    func testInvalidDimensionsHaveNoModes() {
        XCTAssertTrue(HiDPIPreset.ladder(forPanelWidth: 0, height: 2520).isEmpty)
        XCTAssertTrue(HiDPIPreset.ladder(forPanelWidth: 4480, height: -1).isEmpty)
        XCTAssertTrue(HiDPIPreset.ladder(forPanelWidth: Int.max, height: 2520).isEmpty)
    }
}
