import AppKit
import RetinaLinkEngine
import SwiftUI

struct SenderPopoverView: View {
    @ObservedObject var coordinator: SenderCoordinator
    @State private var chosenPeerID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !coordinator.hasScreenRecordingPermission { permissionBanner }
            if let errorMessage { errorBanner(errorMessage) }
            if let ladder = sizeLadder {
                displaySize(presets: ladder.presets, selected: ladder.selected, live: ladder.live)
            }
            footer
        }
        .padding(14)
        .frame(width: 288)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                peerName
                linkPill
            }
            Spacer(minLength: 8)
            Toggle("Stream to \(displayName)", isOn: Binding(
                get: { isActive },
                set: { on in
                    if on { coordinator.connect(to: targetPeer?.id) } else { coordinator.disconnect() }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!coordinator.hasScreenRecordingPermission || (!isActive && coordinator.peers.isEmpty))
        }
    }

    @ViewBuilder
    private var peerName: some View {
        if coordinator.peers.count > 1 {
            Menu {
                ForEach(coordinator.peers) { peer in
                    Button {
                        chosenPeerID = peer.id
                        if isActive { coordinator.connect(to: peer.id) }
                    } label: {
                        if peer.id == targetPeer?.id { Label(peer.name, systemImage: "checkmark") } else { Text(peer.name) }
                    }
                }
            } label: {
                Text(displayName).font(.headline)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
        } else {
            Text(displayName).font(.headline).lineLimit(1)
        }
    }

    private var linkPill: some View {
        let (text, tint) = linkStatus
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .help(linkHelp ?? "")
    }

    // MARK: Banners

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Screen Recording so RetinaLink can extend your screen to another Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Screen Capture") {
                coordinator.requestScreenRecordingPermission()
                coordinator.openScreenRecordingSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).lineLimit(2)
            Spacer(minLength: 4)
            Button("Retry", action: retry).controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Display Size

    private func displaySize(presets: [HiDPIPreset], selected: Int, live: Bool) -> some View {
        let active = presets[selected]
        let native = presets.first(where: \.isNativeDefault)
        let panelWidth = native?.pixelWidth ?? targetPeer?.panelPixelWidth ?? 0
        let isHiDPI = native.map { $0.scaleFactor > 1 } ?? targetPeer?.panelIsHiDPI ?? true
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Text & UI Size").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Self.resolutionBadge(panelWidth: panelWidth, isHiDPI: isHiDPI) + (active.isNativeDefault ? " · 1:1" : ""))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(active.isNativeDefault ? Color.accentColor : Color.secondary)
                        .help("The stream always sends every pixel of the display. Size only changes how big things look.")
                }
                Text(Self.looksLike(active))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if presets.count > 1 {
                HStack(spacing: 8) {
                    Text("Larger")
                    Slider(
                        value: Binding(
                            get: { Double(selected) },
                            set: { value in coordinator.selectPreset(at: Int(value.rounded())) }
                        ),
                        in: 0...Double(presets.count - 1),
                        step: 1
                    )
                    .accessibilityLabel("Text & UI Size")
                    .accessibilityValue("\(active.label), \(Self.looksLike(active))")
                    Text("More Space")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets.indices, id: \.self) { index in
                    PresetPill(preset: presets[index], isSelected: index == selected) {
                        coordinator.selectPreset(at: index)
                    }
                }
            }
        }
        .disabled(!live)
        .opacity(live ? 1 : 0.55)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let telemetry {
                Text(telemetry)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Auto-connect", isOn: $coordinator.autoConnect)
                Toggle("Launch at login", isOn: $coordinator.launchAtLogin)
                Spacer(minLength: 4)
                Button("Quit") {
                    coordinator.shutdown()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
        }
    }

    // MARK: Derived state

    private var isActive: Bool {
        switch coordinator.state {
        case .connected, .connecting, .reconnecting: true
        default: false
        }
    }

    private var targetPeer: DiscoveredPeer? {
        let id = coordinator.selectedPeerID ?? chosenPeerID
        return coordinator.peers.first { $0.id == id } ?? coordinator.peers.first
    }

    private var displayName: String {
        if let targetPeer { return targetPeer.name }
        switch coordinator.state {
        case .ready(let peerName), .connecting(let peerName), .connected(let peerName, _),
             .reconnecting(let peerName):
            return peerName
        case .searching, .permissionRequired, .error:
            return "RetinaLink"
        }
    }

    private var linkStatus: (String, Color) {
        switch coordinator.state {
        case .searching: ("Searching…", Color.secondary)
        case .connecting: ("Connecting…", Color.orange)
        case .reconnecting: ("Reconnecting…", Color.orange)
        case .connected(_, let linkKind): (linkKind.displayName, Self.tint(for: linkKind))
        case .ready, .permissionRequired, .error:
            (targetPeer?.bestKnownLink.displayName ?? "Searching…", Color.secondary)
        }
    }

    /// The pill stays short; the measured link speed and any cable hint live in its tooltip.
    private var linkHelp: String? {
        guard case .connected(_, let linkKind) = coordinator.state else { return nil }
        if linkKind == .thunderbolt, let speed = coordinator.stats.linkSpeedMbps, speed > 0 {
            if speed <= 200 {
                return "Direct Cable (\(speed) Mbps USB 2.0) — use a USB 3 or Thunderbolt cable for full bandwidth."
            }
            return "Direct Cable (\(speed >= 1000 ? "\(speed / 1000) Gbps" : "\(speed) Mbps"))"
        }
        return linkKind.displayName
    }

    private var errorMessage: String? {
        if case .error(let message) = coordinator.state { message } else { nil }
    }

    /// The live ladder while streaming; otherwise a disabled preview of the ready peer's ladder.
    private var sizeLadder: (presets: [HiDPIPreset], selected: Int, live: Bool)? {
        if !coordinator.presets.isEmpty,
           coordinator.presets.indices.contains(coordinator.selectedPresetIndex) {
            return (coordinator.presets, coordinator.selectedPresetIndex, true)
        }
        guard let targetPeer else { return nil }
        let ladder = HiDPIPreset.ladder(
            forPanelWidth: targetPeer.panelPixelWidth,
            height: targetPeer.panelPixelHeight,
            isHiDPI: targetPeer.panelIsHiDPI
        )
        guard let native = ladder.firstIndex(where: \.isNativeDefault) else { return nil }
        return (ladder, native, false)
    }

    private var telemetry: String? {
        guard case .connected = coordinator.state else { return nil }
        let stats = coordinator.stats
        let rtt = "\(Int(stats.rttMs.rounded())) ms"
        if stats.isLosslessSettled {
            return "\(stats.pixelWidth)×\(stats.pixelHeight) · Lossless · \(rtt)"
        }
        return "\(stats.pixelWidth)×\(stats.pixelHeight) · \(stats.codecLabel) · "
            + "\(Int(stats.fps.rounded())) fps · \(rtt)"
    }

    private func retry() {
        if coordinator.peers.isEmpty {
            coordinator.shutdown()
            coordinator.start()
        } else {
            coordinator.connect(to: targetPeer?.id)
        }
    }

    private static func looksLike(_ preset: HiDPIPreset) -> String {
        "Looks like \(preset.logicalWidth) × \(preset.logicalHeight) · "
            + (preset.isNativeDefault ? "Native 1:1" : "Scaled")
    }

    /// The stream resolution never changes with size, so name it from the panel alone.
    private static func resolutionBadge(panelWidth: Int, isHiDPI: Bool) -> String {
        switch panelWidth {
        case 6000...: "Always 6K"
        case 5000...: "Always 5K"
        case 4400...: "Always 4.5K"
        case 3800...: "Always 4K"
        case 2500... where isHiDPI: "Always Retina"
        default: "Always Native"
        }
    }

    private static func tint(for linkKind: LinkKind) -> Color {
        switch linkKind {
        case .thunderbolt: .green
        case .wiredEthernet: .blue
        case .wifi: .teal
        }
    }
}

private struct PresetPill: View {
    let preset: HiDPIPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(preset.label).lineLimit(1).minimumScaleFactor(0.75)
                if preset.isNativeDefault {
                    Circle().frame(width: 4, height: 4).opacity(0.7)
                }
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Looks like \(preset.logicalWidth) × \(preset.logicalHeight) · Always full panel resolution"
            + (preset.isNativeDefault ? " · Sharpest 1:1" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
