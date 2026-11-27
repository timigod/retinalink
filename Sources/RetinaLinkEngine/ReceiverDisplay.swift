import AppKit
import IOKit.graphics

public struct ReceiverDisplay: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isHiDPI: Bool
    public let isMain: Bool

    @MainActor
    public static func allDisplays() -> [Self] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { ($0.uint32Value, screen.localizedName) }
        })
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return ids.prefix(Int(count)).compactMap { id -> Self? in
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            let native = modes.filter { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }
                .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            guard let mode = native ?? CGDisplayCopyDisplayMode(id) else { return nil }
            let hiDPI = modes.contains {
                $0.isUsableForDesktopGUI() && $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight
                    && $0.width * 2 == mode.pixelWidth && $0.height * 2 == mode.pixelHeight
            }
            return Self(id: id, name: names[id] ?? "Display \(id)", pixelWidth: mode.pixelWidth,
                        pixelHeight: mode.pixelHeight, isHiDPI: hiDPI, isMain: id == CGMainDisplayID())
        }.sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }
    }
}
