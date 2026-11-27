import AppKit
import CoreGraphics
import CVirtualDisplay
import Darwin
import RetinaLinkCore

@MainActor
public final class VirtualDisplayController {
    var onSleep: (() -> Void)?
    private let lifetime = Lifetime()
    public var displayID: CGDirectDisplayID? { lifetime.bridge?.displayID }
    public private(set) var preset: HiDPIPreset?

    private var name: String
    private var sizeInMillimeters: CGSize
    private var maxPixelsWide: Int
    private var maxPixelsHigh: Int
    private let installSignalHandlers: Bool

    public init(name: String = "RetinaLink Display", sizeInMillimeters: CGSize = CGSize(width: 527, height: 296),
                maxPixelsWide: Int = 5760, maxPixelsHigh: Int = 3240, installSignalHandlers: Bool = false) {
        self.name = name
        self.sizeInMillimeters = sizeInMillimeters
        self.maxPixelsWide = maxPixelsWide
        self.maxPixelsHigh = maxPixelsHigh
        self.installSignalHandlers = installSignalHandlers
    }

    func configure(name: String, sizeInMillimeters: CGSize, maxPixelsWide: Int, maxPixelsHigh: Int) {
        self.name = name
        self.sizeInMillimeters = sizeInMillimeters
        self.maxPixelsWide = maxPixelsWide
        self.maxPixelsHigh = maxPixelsHigh
    }

    public func start(preset: HiDPIPreset) throws {
        if displayID != nil {
            try apply(preset: preset)
            return
        }
        guard let bridge = RLVirtualDisplayBridge(
            name: name, maxPixelsWide: UInt(maxPixelsWide), maxPixelsHigh: UInt(maxPixelsHigh),
            sizeInMillimeters: sizeInMillimeters,
            vendorID: 0x524C, productID: 0x454B, serialNum: installSignalHandlers ? 0x00010002 : 0x00010001,
            hiDPI: preset.scaleFactor > 1, modes: [Self.mode(preset)]
        ) else {
            throw RetinaLinkError.operation("CoreGraphics could not create the RetinaLink virtual display")
        }
        lifetime.bridge = bridge
        self.preset = preset
        observeTeardown()
    }

    public func apply(preset: HiDPIPreset) throws {
        guard let bridge = lifetime.bridge, bridge.apply([Self.mode(preset)], hiDPI: preset.scaleFactor > 1) else {
            throw RetinaLinkError.operation("CoreGraphics rejected the requested HiDPI mode")
        }
        self.preset = preset
    }

    public func stop() {
        lifetime.invalidate()
        preset = nil
    }

    private static func mode(_ preset: HiDPIPreset) -> RLVirtualDisplayMode {
        RLVirtualDisplayMode(width: UInt(preset.logicalWidth), height: UInt(preset.logicalHeight), refreshRate: 60)
    }

    private func observeTeardown() {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onSleep?()
                self?.stop()
            }
        }
        lifetime.sleepObserver = (center, observer)
        guard installSignalHandlers else { return }
        lifetime.signals = [SIGTERM, SIGINT].map { number in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stop() }
                Darwin.exit(128 + number)
            }
            source.resume()
            return source
        }
    }

    private final class Lifetime {
        var bridge: RLVirtualDisplayBridge?
        var sleepObserver: (NotificationCenter, any NSObjectProtocol)?
        var signals: [any DispatchSourceSignal] = []

        func invalidate() {
            bridge?.invalidate()
            bridge = nil
            if let (center, observer) = sleepObserver { center.removeObserver(observer) }
            sleepObserver = nil
            for (number, source) in zip([SIGTERM, SIGINT], signals) {
                source.cancel()
                Darwin.signal(number, SIG_DFL)
            }
            signals.removeAll()
        }

        deinit { invalidate() }
    }
}
