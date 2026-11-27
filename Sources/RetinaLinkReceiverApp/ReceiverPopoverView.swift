import AppKit
import CoreGraphics
import RetinaLinkEngine
import SwiftUI

struct ReceiverPopoverView: View {
    @ObservedObject var coordinator: ReceiverCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("RetinaLink Receiver").font(.headline)
                Spacer(minLength: 8)
                badge
            }
            detail
            Divider()
            HStack {
                Toggle("Launch at login", isOn: $coordinator.launchAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") {
                    coordinator.shutdown()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.small)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var badge: some View {
        let (text, tint): (String, Color) = switch coordinator.state {
        case .starting: ("Starting…", Color.secondary)
        case .listening: ("Listening", Color.blue)
        case .streaming: ("Streaming", Color.green)
        case .error: ("Error", Color.red)
        }
        return pill(text, tint: tint)
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var detail: some View {
        switch coordinator.state {
        case .starting:
            Text("Starting…").font(.callout).foregroundStyle(.secondary)
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready for another Mac").font(.callout)
                if coordinator.availableDisplays.count > 1 { displayPicker }
                if !routeSummary.isEmpty {
                    Text(routeSummary).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(coordinator.activeAddresses, id: \.self) { address in
                    Text("\(address.kind.displayName)  \(address.host)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        case .streaming(let senderName, let linkKind, let resolutionLabel):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Connected to \(senderName)").font(.callout).lineLimit(1)
                    pill(linkKind.displayName, tint: Self.tint(for: linkKind))
                }
                Text("Always \(resolutionLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Disconnect Display") { coordinator.dismissOverlay() }
                Text("Press Esc three times anytime to exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.callout).lineLimit(3)
                Spacer(minLength: 4)
                Button("Retry") {
                    coordinator.shutdown()
                    coordinator.start()
                }
                .controlSize(.small)
            }
        }
    }

    /// Only offered on Macs with more than one screen, so single-display receivers stay minimal.
    private var displayPicker: some View {
        Picker("Display", selection: Binding(
            get: { coordinator.selectedDisplayID },
            set: { coordinator.selectDisplay($0) }
        )) {
            ForEach(coordinator.availableDisplays) { display in
                Text("\(display.name) (\(display.pixelWidth)×\(display.pixelHeight))").tag(display.id)
            }
        }
        .controlSize(.small)
        .font(.caption)
        .padding(.vertical, 2)
    }

    private var routeSummary: String {
        Set(coordinator.activeAddresses.map(\.kind)).sorted(by: >).map(\.displayName).joined(separator: " · ")
    }

    private static func tint(for linkKind: LinkKind) -> Color {
        switch linkKind {
        case .thunderbolt: .green
        case .wiredEthernet: .blue
        case .wifi: .teal
        }
    }
}
