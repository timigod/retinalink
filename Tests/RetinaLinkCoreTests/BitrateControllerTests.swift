import RetinaLinkCore
import XCTest

final class BitrateControllerTests: XCTestCase {
    func testSlowDirectCableUsesMeasured100MbpsLink() {
        var cable = BitrateController(linkKind: .thunderbolt, linkSpeedMbps: 100)
        XCTAssertEqual(cable.targetMbps, 65)
        XCTAssertEqual(cable.rangeMbps, 25...85)
        XCTAssertEqual(cable.update(rttMs: 1, congestion: 0, elapsedSeconds: 10), 85)
        XCTAssertEqual(cable.update(rttMs: 50, congestion: 1, elapsedSeconds: 10), 25)
        XCTAssertEqual(BitrateController(linkKind: .thunderbolt, linkSpeedMbps: 1000).rangeMbps, 40...250)
        XCTAssertEqual(BitrateController(linkKind: .thunderbolt).targetMbps, 180)
    }

    func testPipelineWindowByLinkAndRTT() {
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .thunderbolt, rttMs: 9.9), 4)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .thunderbolt, rttMs: 10), 5)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .wiredEthernet, rttMs: 10), 5)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .wifi, rttMs: 25), 5)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .wifi, rttMs: 25.1), 6)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .thunderbolt, rttMs: .nan), 4)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .wiredEthernet, rttMs: .infinity), 5)
        XCTAssertEqual(BitrateController.maxInFlightFrames(for: .wifi, rttMs: -1), 5)
    }

    func testBackpressureUsesTheSelectedWindow() {
        XCTAssertFalse(BitrateController.shouldDropBeforeEncode(inFlightFrames: 4, maxInFlight: 5))
        XCTAssertTrue(BitrateController.shouldDropBeforeEncode(inFlightFrames: 5, maxInFlight: 5))
        XCTAssertFalse(BitrateController.shouldDropBeforeEncode(inFlightFrames: 5, maxInFlight: 6))
        XCTAssertTrue(BitrateController.shouldDropBeforeEncode(inFlightFrames: 6, maxInFlight: 6))
        XCTAssertFalse(BitrateController.shouldDropBeforeEncode(inFlightFrames: 0, maxInFlight: 0))
    }

    func testBackpressureDropsAtTwoBeforeEncoding() {
        XCTAssertFalse(BitrateController.shouldDropBeforeEncode(inFlightFrames: 0))
        XCTAssertFalse(BitrateController.shouldDropBeforeEncode(inFlightFrames: 1))
        XCTAssertTrue(BitrateController.shouldDropBeforeEncode(inFlightFrames: 2))
        XCTAssertTrue(BitrateController.shouldDropBeforeEncode(inFlightFrames: 3))
    }

    func testTierTargetsAndBounds() {
        let tiers: [(LinkKind, Double, ClosedRange<Double>)] = [
            (.thunderbolt, 180, 40...250), (.wiredEthernet, 100, 40...150), (.wifi, 65, 25...100),
        ]
        for (kind, target, bounds) in tiers {
            var controller = BitrateController(linkKind: kind)
            XCTAssertEqual(controller.targetMbps, target)
            XCTAssertEqual(controller.rangeMbps, bounds)
            XCTAssertEqual(controller.bitrateMbps, target)
            for _ in 0..<100 { controller.update(rttMs: 50, congestion: 1, elapsedSeconds: 0.1) }
            XCTAssertEqual(controller.bitrateMbps, bounds.lowerBound, accuracy: 0.01)
            for _ in 0..<2000 { controller.update(rttMs: 1, congestion: 0, elapsedSeconds: 0.1) }
            XCTAssertEqual(controller.bitrateMbps, bounds.upperBound, accuracy: 0.01)
        }
    }

    func testCongestionSmoothlyDecreasesAndRecovers() {
        var wifi = BitrateController(linkKind: .wifi)
        let pressured = wifi.update(rttMs: 2, congestion: 0.8, elapsedSeconds: 0.1)
        XCTAssertLessThan(pressured, 65)
        XCTAssertGreaterThan(pressured, 25)
        let delayed = wifi.update(rttMs: 35, congestion: 0, elapsedSeconds: 0.1)
        XCTAssertLessThan(delayed, pressured)
        let recovered = wifi.update(rttMs: 2, congestion: 0, elapsedSeconds: 0.1)
        XCTAssertGreaterThan(recovered, delayed)
        XCTAssertLessThan(recovered, 65)
    }

    func testInvalidMeasurementLeavesStateUnchanged() {
        var controller = BitrateController(linkKind: .wiredEthernet)
        XCTAssertEqual(controller.update(rttMs: .nan, congestion: 0, elapsedSeconds: 1), 100)
        XCTAssertEqual(controller.update(rttMs: 10, congestion: .infinity, elapsedSeconds: 1), 100)
        XCTAssertEqual(controller.update(rttMs: 10, congestion: 0, elapsedSeconds: -1), 100)
    }
}
