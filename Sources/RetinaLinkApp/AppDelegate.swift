import AppKit
import Combine
import RetinaLinkEngine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = SenderCoordinator()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.anotherInstanceIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        let hosting = NSHostingController(rootView: SenderPopoverView(coordinator: coordinator))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        coordinator.$state
            .sink { [weak self] state in
                TerminationSignals.ignoreDefaultHandling()
                self?.updateStatusIcon(for: state)
            }
            .store(in: &subscriptions)

        started = true
        coordinator.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshPermissionStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if started { coordinator.shutdown() }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        coordinator.refreshPermissionStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
    }

    private func updateStatusIcon(for state: SenderConnectionState) {
        let (symbol, label): (String, String) = switch state {
        case .connected(let peerName, _): ("display.2", "RetinaLink: streaming to \(peerName)")
        case .connecting(let peerName): ("display", "RetinaLink: connecting to \(peerName)")
        case .reconnecting(let peerName): ("display", "RetinaLink: reconnecting to \(peerName)")
        case .ready(let peerName): ("display", "RetinaLink: \(peerName) is ready")
        case .searching: ("display", "RetinaLink: searching for a receiver Mac")
        case .permissionRequired: ("exclamationmark.triangle", "RetinaLink: Screen Recording is needed")
        case .error(let message): ("exclamationmark.triangle", "RetinaLink: \(message)")
        }
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != pid }
    }
}
