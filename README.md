# RetinaLink

Turn any Mac into a pixel-perfect extended display for another Mac.

An iMac, a MacBook, or a Mac mini or Mac Studio with a 4K, 4.5K, 5K, 6K or
standard 1× monitor becomes a true native-resolution second screen for any
other Mac, over a Thunderbolt or USB-C cable, Ethernet, or Wi-Fi. Text stays
as sharp as it is on the receiver's own desktop.

## What it does

- **True 1:1 native scanout.** The receiver switches its display to the
  panel's exact native pixel raster while streaming, and restores your usual
  mode automatically when you disconnect.
- **Sharp text, smooth motion.** Moving content streams as hardware HEVC
  4:4:4 10-bit. When the screen settles, a bit-exact lossless LZ4 pass
  replaces it, and while you type only the changed rectangles are sent
  losslessly. Static text and typing arrive with 0/255 pixel error, so there
  is no video-compression blur on fonts.
- **Text & UI Size slider.** Native HiDPI scaling from Larger to More Space
  without changing the stream resolution: no black flash, no windows thrown
  around. RetinaLink remembers your preferred size for each receiver.
- **Best link, automatically.** Every route the receiver advertises is ranked
  `Direct Cable` > `Wired LAN` > `Wi-Fi` and hot-swapped live as cables come
  and go. If a direct cable has negotiated USB 2.0 speed (common with charging
  cables), the link tooltip tells you to use a USB 3 or Thunderbolt cable.
- **Apple Silicon and Intel.** Sender and receiver agree on the best hardware
  HEVC profile both Macs support, and the lossless settle works on all of them.
- **Built for daily use.** Multi-display receivers (pick which screen to use),
  a low-latency 120 Hz Retina cursor overlay, no permission prompts on the
  receiver, a single Screen Recording grant on the sender, and a triple-`Esc`
  emergency exit on the receiver.

## Requirements

- macOS 15 or newer on both Macs.
- Xcode or the Swift 6 command-line tools to build.
- Both Macs on the same network, or joined by a Thunderbolt/USB-C cable
  (Thunderbolt Bridge).

## Build and install

```sh
# Build both apps into dist/ (ad hoc signed; no Apple Developer account needed)
scripts/build-and-sign.sh

# Build and install the sender on this Mac
scripts/build-and-sign.sh --install-local

# Install the receiver and keep it running at login…
scripts/install-receiver.sh --local        # …on this Mac (run it on the receiver)
scripts/install-receiver.sh me@studio.local  # …on another Mac over SSH
```

Open **RetinaLink** on the Mac whose screen you want to extend, allow Screen
Recording once, and turn on the switch next to the receiver's name.

Build options:

| Option | Meaning |
| --- | --- |
| `--arch arm64\|x86_64\|universal` | Target architecture (default: this Mac's). `universal` builds both and joins them with `lipo`. |
| `--install-local` | Copy `RetinaLink.app` to `/Applications`. |
| `--install-receiver` | Copy `RetinaLink Receiver.app` to `/Applications`. |
| `--adhoc` | Sign ad hoc even when `SIGN_IDENTITY` is set. |

Environment:

| Variable | Meaning |
| --- | --- |
| `SIGN_IDENTITY` | A codesign identity such as `Developer ID Application: Your Name (TEAMID)`. Unset means ad hoc. A stable identity keeps the Screen Recording grant across rebuilds. |
| `BUNDLE_ID_PREFIX` | Sender bundle ID; the receiver appends `.receiver`. Default `dev.retinalink`. Use the same value for `install-receiver.sh`. |
| `SSH_OPTS` | Extra `ssh` options for `install-receiver.sh`, e.g. `"-p 2222"`. |

`install-receiver.sh` builds the receiver first if `dist/` has none (as a
universal binary for SSH targets), installs it in `/Applications`, and runs it
as a LaunchAgent (`$BUNDLE_ID_PREFIX.receiver`). Its log is
`/tmp/retinalink-receiver.log`.

## Benchmark and verification CLI

```sh
swift test
swift build -c release --product retinalink-bench
.build/release/retinalink-bench verify-virtual-display

# On the receiver Mac
.build/release/retinalink-bench receiver --duration 20 --headless --output native

# On the sender Mac
.build/release/retinalink-bench sender --discover --profile hevc444_10 --duration 5
```

Run a fresh receiver for each measurement. Use `--host <ip>` instead of
`--discover` for a direct connection, `--output bgra` to compare VideoToolbox
output formats, and `--verify-presentation` or `--verify-scanout` (without
`--headless`) to check what actually reaches the screen. The JSON report
separates heartbeat RTT from capture-to-ACK time, reports the negotiated
bitstream profile, chroma format and bit depth from `hvcC`, and measures 1 px
edge contrast and per-channel error against a Display P3 test pattern.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the pipeline, wire protocol,
link ranking and coordinator contracts.

## Attribution

RetinaLink was built end to end by Timi Ajiboye's coding agents:

- **Gemini 4 Neon** (extra-high thinking): architecture, protocol
  specification, audit, review and coordination.
- **Claude Opus 5.5** (high thinking): the macOS SwiftUI menu bar apps, UX
  copy, packaging scripts and documentation.
- **Codex GPT-6.2 Sol** (high thinking): the CoreGraphics, ScreenCaptureKit,
  VideoToolbox and lossless streaming engine, tests and hardware verification.

## License

[MIT](./LICENSE) © 2026 Timi Ajiboye
