import CoreGraphics
import Foundation
import OSLog

/// Owns a temporary WindowServer mode for exactly one receiver overlay.
struct DisplayScanout {
    let displayID: CGDirectDisplayID
    private let previousMode: CGDisplayMode?
    private let targetMode: CGDisplayMode?
    private let frameDeadline = ContinuousClock.now + .seconds(1)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.retinalink", category: "display")

    var logicalSize: CGSize? {
        targetMode.map { CGSize(width: $0.width, height: $0.height) }
    }

    var scale: CGFloat? { targetMode.map { CGFloat($0.pixelWidth) / CGFloat($0.width) } }

    var waitingForAppKit: Bool { ContinuousClock.now < frameDeadline }

    init(displayID: CGDirectDisplayID, targetWidth: Int, targetHeight: Int) {
        self.displayID = displayID
        let current = CGDisplayCopyDisplayMode(displayID)
        if let current, current.pixelWidth != targetWidth || current.pixelHeight != targetHeight {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
            let target = modes.filter {
                $0.pixelWidth == targetWidth && $0.pixelHeight == targetHeight &&
                $0.isUsableForDesktopGUI() &&
                (($0.width * 2 == targetWidth && $0.height * 2 == targetHeight) ||
                 ($0.width == targetWidth && $0.height == targetHeight))
            }.max { ($0.refreshRate, -$0.width) < ($1.refreshRate, -$1.width) }
            if let target, Self.apply(target, to: displayID) {
                previousMode = current
                targetMode = target
                return
            }
            Self.logger.warning("Could not switch display \(displayID) to \(targetWidth)×\(targetHeight)")
        }
        previousMode = nil
        targetMode = nil
    }

    func restore() {
        guard let previousMode else { return }
        if !Self.apply(previousMode, to: displayID) {
            Self.logger.error("Could not restore the previous mode for display \(displayID)")
        }
    }

    private static func apply(_ mode: CGDisplayMode, to displayID: CGDirectDisplayID) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return false }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success
    }
}
