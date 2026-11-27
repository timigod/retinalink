import CoreGraphics

struct ScanoutProof: Codable {
    struct Mode: Codable, Equatable {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let windowPixelWidth: Int?
        let windowPixelHeight: Int?

        static func read(windowBacking: CGSize? = nil) -> Self? {
            let id = CGMainDisplayID()
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return Self(displayID: id, width: mode.width, height: mode.height,
                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                        refreshRate: mode.refreshRate, windowPixelWidth: windowBacking.map { Int($0.width) },
                        windowPixelHeight: windowBacking.map { Int($0.height) })
        }
    }

    let before: Mode?
    let during: Mode?
    let after: Mode?
    let passed: Bool

    init(before: Mode?, during: Mode?, after: Mode?) {
        self.before = before
        self.during = during
        self.after = after
        passed = before != nil && before == after && before?.displayID == during?.displayID &&
            during?.width == TestPattern.width / 2 && during?.height == TestPattern.height / 2 &&
            during?.pixelWidth == TestPattern.width && during?.pixelHeight == TestPattern.height &&
            during?.windowPixelWidth == TestPattern.width && during?.windowPixelHeight == TestPattern.height
    }
}
