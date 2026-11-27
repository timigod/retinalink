public struct HiDPIPreset: Codable, Hashable, Identifiable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let label: String
    public let isNativeDefault: Bool
    public let scaleFactor: Int

    public init(logicalWidth: Int, logicalHeight: Int, label: String, isNativeDefault: Bool, scaleFactor: Int = 2) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.label = label
        self.isNativeDefault = isNativeDefault
        self.scaleFactor = scaleFactor
    }

    private enum CodingKeys: String, CodingKey {
        case logicalWidth, logicalHeight, label, isNativeDefault, scaleFactor
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(logicalWidth: try values.decode(Int.self, forKey: .logicalWidth),
                  logicalHeight: try values.decode(Int.self, forKey: .logicalHeight),
                  label: try values.decode(String.self, forKey: .label),
                  isNativeDefault: try values.decode(Bool.self, forKey: .isNativeDefault),
                  scaleFactor: try values.decodeIfPresent(Int.self, forKey: .scaleFactor) ?? 2)
    }

    public var pixelWidth: Int { logicalWidth * scaleFactor }
    public var pixelHeight: Int { logicalHeight * scaleFactor }
    public var id: String { "\(logicalWidth)x\(logicalHeight)" }

    public static func backingCap(forPanelWidth width: Int, height: Int) -> (width: Int, height: Int) {
        (min(7680, max(5760, width * 5 / 4)), min(4320, max(3240, height * 5 / 4)))
    }

    public static func ladder(forPanelWidth width: Int, height: Int, isHiDPI: Bool = true) -> [Self] {
        guard (1...Int(UInt16.max)).contains(width), (1...Int(UInt16.max)).contains(height) else { return [] }
        guard isHiDPI else {
            return [Self(logicalWidth: width, logicalHeight: height, label: "Default", isNativeDefault: true, scaleFactor: 1)]
        }
        let cap = backingCap(forPanelWidth: width, height: height)
        let upper = width == 5120 && height == 2880 ? 2520
            : min(2880, cap.width * 2240 / width, cap.height * 2240 / height)
        let steps = [(1600, "Larger"), (1920, "Large"), (2048, "Medium"),
                     (2240, "Default"), ((2240 + upper) / 2, "Compact"), (upper, "More Space")]
        var result: [Self] = []
        for (index, step) in steps.enumerated() {
            let (reference, label) = step
            let native = index == 3
            if index > 3 && reference <= 2240 { continue }
            // The exact native mode can have an odd logical dimension.
            let logicalWidth = native ? width / 2 : min(cap.width / 4 * 2, ((width * reference + 4480) / 8960) * 2)
            let logicalHeight = native ? height / 2 : min(cap.height / 4 * 2, ((height * reference + 4480) / 8960) * 2)
            guard logicalWidth > 0, logicalHeight > 0 else { continue }
            let preset = Self(logicalWidth: logicalWidth, logicalHeight: logicalHeight, label: label, isNativeDefault: native)
            if native { result.removeAll { $0.id == preset.id } }
            if !result.contains(where: { $0.id == preset.id }) { result.append(preset) }
        }
        return result
    }
}
