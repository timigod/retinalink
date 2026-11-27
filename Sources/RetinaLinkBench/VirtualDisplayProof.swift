import CoreGraphics
import RetinaLinkCore
import RetinaLinkEngine

@MainActor
enum VirtualDisplayProof {
    static func run() async throws {
        let before = try onlineDisplays()
        print("Online display IDs before: \(before)")
        let ladder = HiDPIPreset.ladder(forPanelWidth: 4480, height: 2520)
        let display = VirtualDisplayController(installSignalHandlers: true)
        defer { display.stop() }
        try display.start(preset: ladder[3])
        guard let id = display.displayID, !before.contains(id) else {
            throw RetinaLinkError.operation("Virtual display ID must be new")
        }
        for index in [3, 1, 4] {
            let preset = ladder[index]
            if index != 3 { try display.apply(preset: preset) }
            try await wait {
                guard display.displayID == id, CGDisplayIsOnline(id) != 0,
                      let mode = CGDisplayCopyDisplayMode(id) else { return false }
                return mode.width == preset.logicalWidth && mode.height == preset.logicalHeight
                    && mode.pixelWidth == preset.pixelWidth && mode.pixelHeight == preset.pixelHeight
            } failure: {
                let actual = CGDisplayCopyDisplayMode(id).map {
                    "\($0.width)×\($0.height) logical, \($0.pixelWidth)×\($0.pixelHeight) pixels"
                } ?? "no active mode"
                return "Display \(id) expected \(preset.logicalWidth)×\(preset.logicalHeight) @ 2×, observed \(actual)"
            }
            print("Display \(id): \(preset.logicalWidth)×\(preset.logicalHeight) @ 2× = \(preset.pixelWidth)×\(preset.pixelHeight)")
        }
        display.stop()
        try await wait {
            try onlineDisplays() == before
        } failure: {
            "Teardown did not restore online display IDs: \((try? onlineDisplays()) ?? [])"
        }
        print("Online display IDs after: \(try onlineDisplays())")
        print("PASS: displayID \(id) preserved across both mode changes; zero ghost displays")
    }

    private static func onlineDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var status = CGGetOnlineDisplayList(0, nil, &count)
        guard status == .success else { throw RetinaLinkError.operation("Cannot enumerate online displays: \(status)") }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        status = CGGetOnlineDisplayList(count, &displays, &count)
        guard status == .success else { throw RetinaLinkError.operation("Cannot read online display IDs: \(status)") }
        return displays.prefix(Int(count)).sorted()
    }

    private static func wait(_ check: () throws -> Bool, failure: () -> String) async throws {
        for _ in 0..<40 {
            if try check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RetinaLinkError.operation(failure())
    }
}
