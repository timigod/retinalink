import CoreGraphics
import RetinaLinkCore
import XCTest

final class DirtyRectsTests: XCTestCase {
    func testLanczosMappingRoundsPadsAndClampsInOutputPixels() {
        let input = CGRect(x: 3558, y: 2028, width: 160, height: 84)
        XCTAssertEqual(CaptureDirtyRects.lanczos([input], sourceWidth: 3840, sourceHeight: 2160,
                                               outputWidth: 4480, outputHeight: 2520),
                       [CGRect(x: 4147, y: 2362, width: 195, height: 106)])
        XCTAssertEqual(CaptureDirtyRects.lanczos([CGRect(x: 0, y: 1, width: 4, height: 3)],
                                               sourceWidth: 5120, sourceHeight: 2880, outputWidth: 4480, outputHeight: 2520),
                       [CGRect(x: 0, y: 0, width: 8, height: 8)])
        XCTAssertEqual(CaptureDirtyRects.lanczos([input], sourceWidth: 4480, sourceHeight: 2520,
                                                outputWidth: 4480, outputHeight: 2520), [input])
    }

    func testNativeCaptureKeepsTopLeftOutputPixels() {
        let dirty = CGRect(x: 4198, y: 2388, width: 160, height: 84)
        XCTAssertEqual(CaptureDirtyRects.normalize([dirty], contentRect: CGRect(x: 0, y: 0, width: 2240, height: 1260),
                                                   contentScale: 1, scaleFactor: 2, width: 4480, height: 2520), [dirty])
    }

    func testScaledCaptureCoversResamplingOutsideReportedRect() throws {
        let dirty = CGRect(x: 4151, y: 2366, width: 186.6666717529297, height: 98)
        let actualChange = CGRect(x: 4148, y: 2363, width: 192, height: 104)
        let rects = CaptureDirtyRects.normalize([dirty], contentRect: CGRect(x: 0, y: 0, width: 2240, height: 1260),
                                               contentScale: 1.166666626930237, scaleFactor: 2, width: 4480, height: 2520)
        let patch = try XCTUnwrap(rects.first)
        XCTAssertEqual(patch, CGRect(x: 4147, y: 2362, width: 195, height: 106))
        XCTAssertTrue(patch.contains(actualChange))
    }

    func testAmbiguousCaptureGeometryFallsBack() {
        let dirty = CGRect(x: 4151, y: 2366, width: 187, height: 98)
        let unexplainedContent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(CaptureDirtyRects.normalize([dirty], contentRect: unexplainedContent,
                                                 contentScale: 1.1667, scaleFactor: 2, width: 4480, height: 2520).isEmpty)
        let offsetContent = CGRect(x: 16, y: 20, width: 2240, height: 1260)
        XCTAssertTrue(CaptureDirtyRects.normalize([dirty], contentRect: offsetContent,
                                                 contentScale: 1.1667, scaleFactor: 2, width: 4480, height: 2520).isEmpty)
    }

    func testClampsAlignsAndMergesNearbyPixels() {
        let input = [CGRect(x: -5, y: -3, width: 18, height: 15),
                     CGRect(x: 30, y: 0, width: 22, height: 12),
                     CGRect(x: 199, y: 99, width: 10, height: 10),
                     CGRect(x: 300, y: 400, width: 50, height: 50)]
        let result = DirtyRects(input, width: 200, height: 100)
        XCTAssertEqual(result.rects, [
            PixelRect(x: 0, y: 0, width: 52, height: 12),
            PixelRect(x: 196, y: 99, width: 4, height: 1),
        ])
        XCTAssertEqual(result.pixelCount, 628)
        XCTAssertEqual(result.areaRatio, 0.0314)
        XCTAssertEqual(result, DirtyRects(input.reversed(), width: 200, height: 100))
    }

    func testReducesToEightDisjointRects() {
        let input = (0..<12).map { CGRect(x: $0 * 100, y: 30, width: 16, height: 40) }
        let result = DirtyRects(input, width: 1200, height: 300)
        XCTAssertEqual(result.rects.count, 8)
        XCTAssertTrue(result.rects.enumerated().allSatisfy { index, rect in
            !result.rects.suffix(from: index + 1).contains(where: rect.overlaps)
        })
        XCTAssertTrue(result.fitsIncrementalBudget)
    }

    func testIncrementalAreaAndAbsolutePixelLimits() {
        let crop = [CGRect(x: 12, y: 1960, width: 1024, height: 256)]
        XCTAssertTrue(DirtyRects(crop, width: 4480, height: 2520).fitsIncrementalBudget)
        XCTAssertFalse(DirtyRects([], width: 4480, height: 2520).fitsIncrementalBudget)
        XCTAssertFalse(DirtyRects([CGRect(x: 0, y: 0, width: 4480, height: 600)],
                                  width: 4480, height: 2520).fitsIncrementalBudget)
        XCTAssertFalse(DirtyRects([CGRect(x: 0, y: 0, width: 2000, height: 1000)],
                                  width: 7680, height: 4320).fitsIncrementalBudget)
    }
}
