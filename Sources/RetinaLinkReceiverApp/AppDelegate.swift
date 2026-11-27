import AppKit
import Combine
import RetinaLinkEngine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = ReceiverCoordinator()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.anotherInstanceIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        let hosting = NSHostingController(rootView: ReceiverPopoverView(coordinator: coordinator))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        coordinator.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.updateStatusIcon(for: state) }
            .store(in: &subscriptions)

        started = true
        coordinator.start()
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
    }

    private func updateStatusIcon(for state: ReceiverConnectionState) {
        let (symbol, label): (String, String) = switch state {
        case .starting: ("display.and.arrow.down", "RetinaLink Receiver: starting")
        case .listening: ("display.and.arrow.down", "RetinaLink Receiver: ready for another Mac")
        case .streaming(let senderName, _, _): ("display.2", "RetinaLink Receiver: showing \(senderName)")
        case .error(let message): ("exclamationmark.triangle", "RetinaLink Receiver: \(message)")
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
