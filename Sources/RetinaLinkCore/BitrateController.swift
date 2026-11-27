public struct BitrateController: Sendable {
    public let linkKind: LinkKind
    public let targetMbps: Double
    public let rangeMbps: ClosedRange<Double>
    public private(set) var bitrateMbps: Double
    private var baselineRTT: Double?

    public init(linkKind: LinkKind, linkSpeedMbps: Int? = nil) {
        self.linkKind = linkKind
        switch linkKind {
        case .thunderbolt where (1...200).contains(linkSpeedMbps ?? 0):
            (targetMbps, rangeMbps) = (65, 25...85)
        case .thunderbolt: (targetMbps, rangeMbps) = (180, 40...250)
        case .wiredEthernet: (targetMbps, rangeMbps) = (100, 40...150)
        case .wifi: (targetMbps, rangeMbps) = (65, 25...100)
        }
        bitrateMbps = targetMbps
    }

    public static func maxInFlightFrames(for linkKind: LinkKind, rttMs: Double) -> Int {
        guard rttMs.isFinite, rttMs >= 0 else { return linkKind == .thunderbolt ? 4 : 5 }
        if rttMs > 25 { return 6 }
        return linkKind == .thunderbolt && rttMs < 10 ? 4 : 5
    }

    public static func shouldDropBeforeEncode(inFlightFrames: Int, maxInFlight: Int = 2) -> Bool {
        inFlightFrames >= max(1, maxInFlight)
    }

    @discardableResult
    public mutating func update(rttMs: Double, congestion: Double, elapsedSeconds: Double) -> Double {
        guard rttMs.isFinite, rttMs >= 0, congestion.isFinite, elapsedSeconds.isFinite,
              elapsedSeconds > 0 else { return bitrateMbps }
        let baseline = min(baselineRTT ?? rttMs, rttMs)
        baselineRTT = baseline
        let queueing = max(0, (rttMs - baseline) / max(8, baseline * 2))
        let pressure = min(1, max(queueing, congestion))
        let desired = pressure > 0.15
            ? rangeMbps.lowerBound + (targetMbps - rangeMbps.lowerBound) * (1 - pressure)
            : (pressure < 0.03 ? rangeMbps.upperBound : targetMbps)
        let delta = desired - bitrateMbps
        let response = min(1, elapsedSeconds * (delta < 0 ? 1.5 : 0.25))
        bitrateMbps = min(rangeMbps.upperBound, max(rangeMbps.lowerBound, bitrateMbps + delta * response))
        return bitrateMbps
    }
}
