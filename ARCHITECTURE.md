# RetinaLink Architecture Specification

Native macOS display bridge that turns any Mac into a pixel-perfect extended display for another Mac. The sender creates a HiDPI virtual display, captures it at the receiver panel's exact native pixel size, and streams it over the best available link (direct Thunderbolt/USB-C cable, wired LAN or Wi-Fi). Motion travels as hardware HEVC; settled content and typing are corrected to bit-exact lossless pixels. This bypasses AirPlay's `3840×2160` 4:2:0 ceiling and its compression blur on text.

## 1. Supported Hardware

- **Sender**: any Mac on macOS 15+ (Apple Silicon or Intel) that can create a `CGVirtualDisplay` and encode HEVC in hardware.
- **Receiver**: any Mac on macOS 15+ with any panel: Retina 4K / 4.5K / 5K / 6K, a HiDPI external monitor, or a standard 1× monitor. Multi-display receivers choose which screen shows the stream.
- **Codec**: sender and receiver negotiate the best of four hardware HEVC profiles both support (see §3.6). Apple Silicon typically lands on HEVC Main 4:4:4 10-bit; older Intel Macs fall back to a 4:2:0 profile, and the lossless settle restores exact pixels either way.
- **Signing**: `scripts/build-and-sign.sh` signs ad hoc by default. Set `SIGN_IDENTITY` to a Developer ID identity so the sender's Screen Recording grant survives rebuilds.
- **Bundle IDs** (from `BUNDLE_ID_PREFIX`, default `dev.retinalink`):
  - Sender: `$BUNDLE_ID_PREFIX` (`RetinaLink.app`)
  - Receiver: `$BUNDLE_ID_PREFIX.receiver` (`RetinaLink Receiver.app`), also the receiver LaunchAgent label

## 2. Package Layout (Swift Package, macOS 15.0+, Swift 6)

```text
Package.swift
Sources/
  CVirtualDisplay/           # Obj-C shim for CGVirtualDisplayDescriptor/Mode/Settings/Display
  RetinaLinkCore/            # Pure Swift deterministic logic, wire protocol, preset math, link ranker, bitrate controller
  RetinaLinkEngine/          # Virtual display, ScreenCaptureKit, VideoToolbox HEVC, lossless settle, Network/Bonjour, cursor, renderer, scanout, coordinators
  RetinaLinkBench/           # CLI harness for live sender/receiver steady-state verification
  RetinaLinkApp/             # Sender menu bar app (LSUIElement, SwiftUI/AppKit)
  RetinaLinkReceiverApp/     # Receiver menu bar app (LSUIElement, SwiftUI/AppKit)
Tests/
  RetinaLinkCoreTests/       # Unit tests for deterministic core modules
scripts/
  build-and-sign.sh          # Release .app packaging (arm64 / x86_64 / universal), ad hoc or Developer ID signing, verification
  install-receiver.sh        # Install RetinaLink Receiver.app + LaunchAgent locally (--local) or over SSH
```

## 3. Core Data & Pipeline Architecture

### 3.1 Display Pipeline (Sender -> Receiver)

```text
CGVirtualDisplay (hiDPI=1, dynamic logical size, stable vendor/product/serial)
  -> ScreenCaptureKit SCStream (locked to receiver native pixels, e.g. 4480x2520 or 3840x2160, 60fps, Display P3, 32BGRA)
  -> Backpressure gate (drop before encode at the RTT-aware limit of 4–6 unacknowledged frames)
  -> VideoToolbox VTCompressionSession (negotiated HW HEVC profile, RealTime=true, LowLatencyRateControl=true, AllowFrameReordering=false)
  -> Lossless settle: dirty-rect diff against the last exact frame -> LZ4 tiles (message 0x0A) once motion stops or while typing
  -> Network.framework TCP (noDelay=true) over highest-ranked route (Direct Cable > Wired LAN > Wi-Fi)
  -> VideoToolbox VTDecompressionSession (IOSurface + Metal compatible) + lossless tile patching onto the presented surface
  -> DisplayScanout switches the chosen ReceiverDisplay to its native raster at 1x or 2x
  -> Fullscreen borderless receiver window (direct Display P3 IOSurface on CALayer, AV sample-buffer / Metal alternatives)
  + Parallel 120Hz UDP cursor channel (NSEvent.mouseLocation + NSCursor.currentSystem hash cache -> CALayer cursor overlay)
```

The media queue handles framing, frame delivery, and ACKs. VideoToolbox encode and
decode each have their own queue. AppKit receives the latest decoded frame for
presentation and publishes sender statistics on a timer.

The pipeline opens four slots for Thunderbolt below 10 ms RTT, five slots
through 25 ms, and six above 25 ms. RTT samples are smoothed per session.

### 3.2 Dynamic HiDPI Sizing (`HiDPIPreset`)

The receiver reports its exact physical panel pixel dimensions `(panelPixelWidth, panelPixelHeight)` and whether the panel is HiDPI in `ReceiverHello`.
`HiDPIPreset.ladder(forPanelWidth:height:isHiDPI:)` generates an ordered list of even-dimension presets matched to that aspect ratio. Each preset carries a `scaleFactor`: `2` for HiDPI panels and `1` for standard 1× monitors, where the native preset maps one logical point to one panel pixel.

For a `4480 × 2520` (4.5K 16:9) HiDPI panel:
1. `1600 × 900` — "Larger" (`3200×1800` backing)
2. `1920 × 1080` — "Large" (`3840×2160` backing)
3. `2048 × 1152` — "Medium" (`4096×2304` backing)
4. `2240 × 1260` — "Default" (`4480×2520` backing, `isNativeDefault = true`)
5. `2560 × 1440` — "Compact" (`5120×2880` backing, GPU-downscaled by SCStream to `4480×2520`)
6. `2880 × 1620` — "More Space" (`5760×3240` backing, GPU-downscaled by SCStream to `4480×2520`)

The sender remembers the chosen preset per receiver and restores it on the next connection.

Changing preset updates `CGVirtualDisplay.applySettings(...)` in place while `SCStream` output dimensions remain locked to `panelPixelWidth × panelPixelHeight`: **no encoder/decoder restart, no black flash, no window scatter**.

### 3.3 Wire Protocol (`WireProtocol.swift`)

TCP frame envelope (16-byte big-endian header):
- `0..3`: `magic = 0x524C4E4B` (`"RLNK"`)
- `4`: `messageType: UInt8`
- `5`: `flags: UInt8`
- `6..7`: `reserved: UInt16`
- `8..11`: `payloadLength: UInt32` (max 32 MiB)
- `12..15`: `sequence: UInt32`

Message types:
- `0x01 receiverHello` (UTF-8 JSON `ReceiverHello`)
- `0x02 senderConfig` (UTF-8 JSON `SenderConfig`)
- `0x03 videoFrame` (Binary: `frameID: UInt64`, `captureTimeNs: UInt64`, `frameFlags: UInt32` [bit 0 = keyframe, bit 1 = hasHvcC], `width: UInt16`, `height: UInt16`, `hvcCLength: UInt32`, `hvcC bytes`, `HVCC length-prefixed NALU payload`)
- `0x04 frameAck` (Binary 24B: `frameID: UInt64`, `captureTimeNs: UInt64`, `decodeUs: UInt32`, `receivedBytes: UInt32`)
- `0x05 cursorImage` (Binary: `cursorHash: UInt64`, `width: UInt16`, `height: UInt16`, `hotSpotX: Float32`, `hotSpotY: Float32`, `scale: Float32`, `pngBytes`)
- `0x06 cursorPosition` (Binary 24B, UDP preferred / TCP fallback: `magic: UInt32 (0x524C4350 "RLCP")`, `seq: UInt32`, `cursorHash: UInt64`, `normX: Float32`, `normY: Float32`. The sign bit of `normX` is set for hidden and clear for visible, leaving the magnitude as the nonnegative X coordinate)
- `0x07 heartbeat` (Binary 16B: `timestampNs: UInt64`, `isReply: UInt8`, `pad: 7B`)
- `0x08 requestKeyframe` (empty)
- `0x09 disconnect` (UTF-8 JSON `DisconnectReason`)
- `0x0A losslessFrame` (Binary: `frameID: UInt64`, `captureTimeNs: UInt64`, `baseFrameID: UInt64` [`0` = full-frame settle; non-zero = incremental dirty-rect patch on top of `baseFrameID`], `width: UInt16`, `height: UInt16`, `algorithm: UInt8` [`0` = LZ4, `1` = LZFSE], `patchCount: UInt8` [`1..64`], then `patchCount` patches of `x: UInt16`, `y: UInt16`, `width: UInt16`, `height: UInt16`, `length: UInt32`, `compressedBytes` holding the exact BGRA pixels of that rectangle). Patches must lie inside `width × height` and be non-empty. The receiver applies them onto the presented surface, so static content is bit-exact (0/255 error) regardless of the HEVC profile.
  - **Full-frame settle** (`baseFrameID = 0`): sent once motion stops. The frame is split into 4 horizontal bands that are compressed in parallel (and decompressed in parallel on the receiver). LZ4 is tried first within a 12 MB budget (4.5 MB on Wi-Fi or a USB 2.0-speed direct cable); if it does not fit, LZFSE is tried within 8 MB (4.5 MB on slow links). If neither fits, the frame stays HEVC.
  - **Incremental dirty-rect patch** (`baseFrameID` = the last lossless frame): sent while typing, LZ4 only, when the dirty rectangles cover at most 15% of the frame (and at most 1.8 MP) and compress into 512 KB (512,000 bytes).

### 3.4 Multi-Interface Discovery & Wired/Wireless Auto-Switch (`EndpointRanker.swift`, `LinkDiscovery.swift`)

- Receiver listens on all interfaces (`NWListener`, TCP port `58420` with ephemeral fallback) and advertises `_retinalink._tcp` via Bonjour.
- Receiver embeds all active non-loopback local IPv4 addresses + link tags into the Bonjour TXT record (`addrs=tb:...,eth:...,wifi:...;port=...;w=4480;h=2520;name=...`) AND refreshes the TXT record whenever `NWPathMonitor` detects interface changes (e.g., Thunderbolt cable plugged/unplugged).
- Sender browses `_retinalink._tcp` (`includePeerToPeer = true`) and monitors local paths with `NWPathMonitor`.
- Sender probes all advertised candidates in parallel (TCP connect + single `heartbeat` RTT) and selects strictly by:
  1. `LinkKind.thunderbolt`, shown as "Direct Cable" (priority 3, target 180 Mbps, range 40–250 Mbps; target 65 Mbps, range 25–85 Mbps when the direct cable's link speed is ≤ 200 Mbps, i.e. USB 2.0). Covers Thunderbolt Bridge and direct USB-C networking.
  2. `LinkKind.wiredEthernet`, shown as "Wired LAN" (priority 2, target 100 Mbps, range 40–150 Mbps)
  3. `LinkKind.wifi`, shown as "Wi-Fi" (priority 1, target 65 Mbps, range 25–100 Mbps)
  4. Lowest measured RTT within the same tier.
- **Link-speed detection**: the sender reads the negotiated speed of the active interface and publishes it as `StreamStats.linkSpeedMbps`. A direct cable at USB 2.0 speed (≤ 200 Mbps, typical of charging cables) is flagged in the sender's link tooltip with a hint to use a USB 3 or Thunderbolt cable.
- **Hot-swap upgrade/failover**: If a higher-priority link (e.g. Thunderbolt) becomes reachable while connected, sender opens the new session in the background, sends `senderConfig` + keyframe, and swaps transports cleanly without tearing down `CGVirtualDisplay`. If the active link drops (e.g. cable unplugged), sender retains `CGVirtualDisplay` for a 5-second reconnect grace window and reconnects automatically over Ethernet/Wi-Fi.

### 3.5 Codec Negotiation

`ReceiverHello` lists the HEVC profiles the receiver can decode in hardware; the sender intersects that with what it can encode and picks the best of four, in order: 4:4:4 10-bit, 4:4:4 8-bit, 4:2:0 10-bit, 4:2:0 8-bit. The chosen profile travels in `SenderConfig.profile`, both ends validate the `hvcC` against it, and `StreamStats.codecLabel` names it in the sender's footer. Whatever the motion profile, the lossless settle (`0x0A`) makes static content bit-exact, and the footer reads `Lossless` once `StreamStats.isLosslessSettled` is true.

### 3.6 Receiver Displays & Native Scanout (`ReceiverDisplay`, `DisplayScanout`)

- `ReceiverCoordinator.availableDisplays` lists every connected screen as a `ReceiverDisplay` (ID, name, native pixel size, HiDPI or 1×, main or not). The receiver advertises the selected display's panel, and the receiver popover shows a display picker only when there is more than one.
- While streaming, `DisplayScanout` switches the selected display to a mode whose pixel raster equals its native panel (2× for HiDPI panels, 1× for standard monitors), so every streamed pixel lands on exactly one physical pixel. The previous mode is restored on disconnect, socket loss, triple-`Esc` and quit.

### 3.7 Coordinator Contracts for UI Apps (`RetinaLinkEngine`)

Both UI apps bind exclusively to these `@MainActor` `ObservableObject` coordinators:

```swift
public enum LinkKind: String, Codable, Sendable, Equatable, Comparable {
    case wifi
    case wiredEthernet
    case thunderbolt
    public var displayName: String { ... } // "Wi-Fi", "Wired LAN", "Direct Cable"
}

public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let panelPixelWidth: Int
    public let panelPixelHeight: Int
    public let panelIsHiDPI: Bool
    public let candidates: [EndpointCandidate]
    public let bestKnownLink: LinkKind
}

public enum SenderConnectionState: Equatable, Sendable {
    case searching
    case ready(peerName: String)
    case connecting(peerName: String)
    case connected(peerName: String, linkKind: LinkKind)
    case reconnecting(peerName: String)
    case permissionRequired
    case error(String)
}

public struct StreamStats: Equatable, Sendable {
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var logicalWidth: Int = 0
    public var logicalHeight: Int = 0
    public var fps: Double = 0
    public var rttMs: Double = 0
    public var encodeMs: Double = 0
    public var decodeMs: Double = 0
    public var bitrateMbps: Double = 0
    public var linkKind: LinkKind = .wifi
    public var codecLabel: String = "HEVC 4:4:4"
    public var isLosslessSettled: Bool = false
    public var linkSpeedMbps: Int?
}

public struct HiDPIPreset: Codable, Hashable, Identifiable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let label: String
    public let isNativeDefault: Bool
    public let scaleFactor: Int        // 2 on HiDPI panels, 1 on standard monitors
    public var pixelWidth: Int { get }  // logicalWidth * scaleFactor
    public var pixelHeight: Int { get }
    public static func ladder(forPanelWidth: Int, height: Int, isHiDPI: Bool = true) -> [HiDPIPreset]
}

@MainActor
public final class SenderCoordinator: ObservableObject {
    @Published public private(set) var state: SenderConnectionState
    @Published public private(set) var peers: [DiscoveredPeer]
    @Published public private(set) var selectedPeerID: String?
    @Published public private(set) var presets: [HiDPIPreset]
    @Published public private(set) var selectedPresetIndex: Int
    @Published public private(set) var stats: StreamStats
    @Published public var autoConnect: Bool
    @Published public var launchAtLogin: Bool
    @Published public private(set) var hasScreenRecordingPermission: Bool

    public init()
    public func start()
    public func connect(to peerID: String? = nil)
    public func disconnect()
    public func selectPreset(at index: Int)
    public func refreshPermissionStatus()
    public func requestScreenRecordingPermission()
    public func openScreenRecordingSettings()
    public func shutdown()
}

public struct ReceiverDisplay: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isHiDPI: Bool
    public let isMain: Bool
}

public enum ReceiverConnectionState: Equatable, Sendable {
    case starting
    case listening(hostName: String, linkSummary: String)
    case streaming(senderName: String, linkKind: LinkKind, resolutionLabel: String)
    case error(String)
}

@MainActor
public final class ReceiverCoordinator: ObservableObject {
    @Published public private(set) var state: ReceiverConnectionState
    @Published public var launchAtLogin: Bool
    @Published public private(set) var activeAddresses: [EndpointCandidate]
    @Published public private(set) var availableDisplays: [ReceiverDisplay]
    @Published public private(set) var selectedDisplayID: CGDirectDisplayID

    public init()
    public func start()
    public func selectDisplay(_ displayID: CGDirectDisplayID)
    public func dismissOverlay()
    public func shutdown()
}
```

## 4. Reliability & Safety Guarantees

1. **Zero ghost virtual displays**: `VirtualDisplayController` destroys `CGVirtualDisplay` immediately on user Disconnect, `applicationWillTerminate`, `SIGTERM`/`SIGINT`, and `NSWorkspace.willSleepNotification`.
2. **Receiver safety**:
   - Auto-presents borderless fullscreen window only after receiving a valid `SenderConfig` on the TCP connection and decoding its first keyframe. The protocol uses plain TCP and UDP on trusted local networks.
   - Auto-dismisses immediately on `disconnect`, socket EOF, or 3-second heartbeat timeout.
   - Triple-press `Esc` on the receiver's keyboard ALWAYS dismisses the overlay locally and restores the display mode.
   - Prevents receiver display sleep only while actively streaming; releases IOPMAssertion immediately on disconnect.
3. **Zero TCC prompts for Receiver; minimal TCC for Sender**:
   - Receiver requires **zero** TCC permissions (no Screen Recording, no Accessibility).
   - Sender requires **only Screen Recording** (once, tied to its signed bundle ID; sign with a stable `SIGN_IDENTITY` so the grant survives rebuilds); cursor tracking uses `NSEvent.mouseLocation` + `NSCursor.currentSystem` without Accessibility permission.
4. **Zero-traffic idle**: When no screen pixels change, ScreenCaptureKit stops emitting frames -> encoder and network drop to 0 fps / ~0% CPU.
