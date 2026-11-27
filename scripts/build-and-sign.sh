#!/usr/bin/env bash
# Builds, packages and signs dist/RetinaLink.app (the sender, on the Mac whose screen you extend)
# and dist/RetinaLink Receiver.app (on the Mac that shows the extended display).
#
# Usage: scripts/build-and-sign.sh [--adhoc] [--arch arm64|x86_64|universal] [--install-local] [--install-receiver]
#   --adhoc             sign ad hoc even when SIGN_IDENTITY is set
#   --arch <arch>       arm64, x86_64 or universal (default: this Mac's architecture)
#   --install-local     copy dist/RetinaLink.app to /Applications
#   --install-receiver  copy dist/RetinaLink Receiver.app to /Applications
# Environment:
#   SIGN_IDENTITY     codesign identity, e.g. "Developer ID Application: Name (TEAMID)" (default: ad hoc)
#   BUNDLE_ID_PREFIX  sender bundle ID; the receiver appends .receiver (default: dev.retinalink)
#   VERSION, BUILD_NUMBER
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

ADHOC=0
INSTALL_LOCAL=0
INSTALL_RECEIVER=0
ARCH="$(uname -m)"
while (( $# )); do
  case "$1" in
    --adhoc) ADHOC=1 ;;
    --install-local) INSTALL_LOCAL=1 ;;
    --install-receiver) INSTALL_RECEIVER=1 ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "--arch needs a value" >&2; usage >&2; exit 64; }
      ARCH="$2"; shift ;;
    --arch=*) ARCH="${1#--arch=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

case "$ARCH" in
  arm64|x86_64) ARCHS=("$ARCH") ;;
  universal) ARCHS=(arm64 x86_64) ;;
  *) echo "Unsupported --arch: $ARCH (use arm64, x86_64 or universal)" >&2; exit 64 ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
  echo "build-and-sign.sh must run on macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-dev.retinalink}"
[[ -z "$SIGN_IDENTITY" ]] && ADHOC=1
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"

PRODUCTS=(RetinaLinkApp RetinaLinkReceiverApp)
BIN="$WORK/bin"
mkdir -p "$BIN"
for arch in "${ARCHS[@]}"; do
  echo "==> Building release $arch products"
  for product in "${PRODUCTS[@]}"; do
    swift build -c release --arch "$arch" --product "$product"
  done
done
for product in "${PRODUCTS[@]}"; do
  slices=()
  for arch in "${ARCHS[@]}"; do
    slices+=("$(swift build -c release --arch "$arch" --show-bin-path)/$product")
  done
  if (( ${#slices[@]} > 1 )); then
    echo "==> Joining ${ARCHS[*]} into a universal $product"
    lipo -create "${slices[@]}" -output "$BIN/$product"
  else
    cp "${slices[0]}" "$BIN/$product"
  fi
  lipo -info "$BIN/$product"
done

echo "==> Drawing app icons"
cat > "$WORK/make-icons.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Motif { case sender, receiver }

struct IconError: Error, CustomStringConvertible { let description: String }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// A monitor in a 1024-point canvas: stand, dark bezel, luminous P3-style screen and a hairline rim.
func drawDisplay(_ ctx: CGContext, _ frame: CGRect, dim: CGFloat = 1) {
    let neck = CGRect(x: frame.midX - frame.width * 0.07, y: frame.minY - frame.height * 0.17,
                      width: frame.width * 0.14, height: frame.height * 0.2)
    let foot = CGRect(x: frame.midX - frame.width * 0.2, y: neck.minY - frame.height * 0.045,
                      width: frame.width * 0.4, height: frame.height * 0.06)
    fillGradient(ctx, CGPath(rect: neck, transform: nil), [rgb(0.80, 0.82, 0.86, dim), rgb(0.52, 0.55, 0.60, dim)],
                 from: CGPoint(x: neck.midX, y: neck.maxY), to: CGPoint(x: neck.midX, y: neck.minY))
    ctx.addPath(rounded(foot, foot.height / 2))
    ctx.setFillColor(rgb(0.70, 0.72, 0.77, dim))
    ctx.fillPath()

    let bezel = rounded(frame, frame.width * 0.045)
    ctx.addPath(bezel)
    ctx.setFillColor(rgb(0.05, 0.06, 0.08))
    ctx.fillPath()
    let inset = frame.width * 0.04
    let screen = frame.insetBy(dx: inset, dy: inset)
    fillGradient(ctx, rounded(screen, frame.width * 0.015),
                 [rgb(0.38 * dim, 0.70 * dim, 1.0 * dim), rgb(0.43 * dim, 0.33 * dim, 0.96 * dim)],
                 from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY))
    // Diagonal glass reflection across the screen.
    ctx.saveGState()
    ctx.addPath(rounded(screen, frame.width * 0.015))
    ctx.clip()
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: screen.minX, y: screen.maxY))
    sheen.addLine(to: CGPoint(x: screen.minX + screen.width * 0.55, y: screen.maxY))
    sheen.addLine(to: CGPoint(x: screen.minX + screen.width * 0.25, y: screen.minY))
    sheen.addLine(to: CGPoint(x: screen.minX, y: screen.minY))
    sheen.closeSubpath()
    ctx.addPath(sheen)
    ctx.setFillColor(rgb(1, 1, 1, 0.10 * dim))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(bezel)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.30 * dim))
    ctx.setLineWidth(frame.width * 0.01)
    ctx.strokePath()
}

func drawIcon(_ ctx: CGContext, _ motif: Motif, scale: CGFloat) {
    // macOS icon grid: 824-point tile with a continuous-feeling corner inside a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = rounded(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: rgb(0, 0, 0, 0.4))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0.09, 0.10, 0.12))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, tilePath, [rgb(0.25, 0.27, 0.32), rgb(0.06, 0.07, 0.09)],
                 from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Dark glass: a soft sheen on the upper half and a hairline rim.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    fillGradient(ctx, CGPath(ellipseIn: CGRect(x: -80, y: 540, width: 1184, height: 660), transform: nil),
                 [rgb(1, 1, 1, 0.16), rgb(1, 1, 1, 0)], from: CGPoint(x: 512, y: 1200), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    ctx.addPath(rounded(tile.insetBy(dx: 3, dy: 3), 182))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.14))
    ctx.setLineWidth(5)
    ctx.strokePath()

    switch motif {
    case .sender:
        drawDisplay(ctx, CGRect(x: 420, y: 480, width: 400, height: 236), dim: 0.62)
        drawDisplay(ctx, CGRect(x: 204, y: 352, width: 460, height: 272))
    case .receiver:
        let frame = CGRect(x: 232, y: 392, width: 560, height: 330)
        drawDisplay(ctx, frame)
        // Down arrow landing on the screen (shaft and head filled separately so they never cancel out).
        let midX = frame.midX
        ctx.setFillColor(rgb(1, 1, 1, 0.95))
        ctx.fill(CGRect(x: midX - 22, y: frame.midY - 10, width: 44, height: 120))
        ctx.move(to: CGPoint(x: midX - 86, y: frame.midY + 6))
        ctx.addLine(to: CGPoint(x: midX + 86, y: frame.midY + 6))
        ctx.addLine(to: CGPoint(x: midX, y: frame.midY - 92))
        ctx.closePath()
        ctx.fillPath()
    }
}

func render(_ motif: Motif, pixels: Int, to url: URL) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(description: "Could not create a \(pixels)px bitmap")
    }
    let scale = CGFloat(pixels) / 1024
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, motif, scale: scale)
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(description: "Could not encode \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError(description: "Could not write \(url.path)") }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let entries: [(String, Int)] = [16, 32, 128, 256, 512].flatMap { size in
    [("icon_\(size)x\(size).png", size), ("icon_\(size)x\(size)@2x.png", size * 2)]
}
do {
    for (motif, name) in [(Motif.sender, "Sender"), (Motif.receiver, "Receiver")] {
        let iconset = output.appendingPathComponent("\(name).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for (file, pixels) in entries { try render(motif, pixels: pixels, to: iconset.appendingPathComponent(file)) }
    }
} catch {
    FileHandle.standardError.write(Data("make-icons: \(error)\n".utf8))
    exit(1)
}
SWIFT
swift "$WORK/make-icons.swift" "$WORK"
iconutil -c icns "$WORK/Sender.iconset" -o "$WORK/Sender.icns"
iconutil -c icns "$WORK/Receiver.iconset" -o "$WORK/Receiver.icns"

# assemble <bundle name> <executable> <bundle id> <icns> <extra plist XML>
assemble() {
  local name="$1" executable="$2" bundle_id="$3" icon="$4" extra="$5"
  local app="$DIST/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$executable" "$app/Contents/MacOS/$executable"
  cp "$icon" "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_retinalink._tcp</string>
  </array>
$extra
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >/dev/null
}

echo "==> Assembling bundles in dist/"
mkdir -p "$DIST"
assemble "RetinaLink" "RetinaLinkApp" "$BUNDLE_ID_PREFIX" "$WORK/Sender.icns" \
'  <key>NSScreenCaptureUsageDescription</key><string>RetinaLink captures the virtual display it creates so it can stream it to another Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>RetinaLink discovers receiver Macs on your local network and streams your extended display.</string>'
assemble "RetinaLink Receiver" "RetinaLinkReceiverApp" "$BUNDLE_ID_PREFIX.receiver" "$WORK/Receiver.icns" \
'  <key>NSLocalNetworkUsageDescription</key><string>RetinaLink Receiver advertises this Mac on your local network so another Mac can extend its display here.</string>'

sign() {
  local app="$1"
  if (( ADHOC )); then
    codesign --force --deep --options runtime --timestamp=none --sign - "$app"
  else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
  fi
  codesign --verify --deep --strict --verbose=2 "$app"
}

echo "==> Signing$( (( ADHOC )) && echo " (ad hoc)" || echo " with $SIGN_IDENTITY")"
sign "$DIST/RetinaLink.app"
sign "$DIST/RetinaLink Receiver.app"

# install_app <bundle name> <executable>
install_app() {
  local name="$1" executable="$2" target="/Applications/$1.app"
  echo "==> Installing $target"
  rm -rf "$target"
  ditto "$DIST/$name.app" "$target"
  codesign --verify --deep --strict "$target"
  if pgrep -f "$target/Contents/MacOS/$executable" >/dev/null; then
    echo "$name is running the previous build: choose Quit in its menu, then open it again."
  fi
}

(( INSTALL_LOCAL )) && install_app "RetinaLink" "RetinaLinkApp"
if (( INSTALL_RECEIVER )); then
  install_app "RetinaLink Receiver" "RetinaLinkReceiverApp"
  echo "To keep it running at login, run scripts/install-receiver.sh --local on this Mac."
fi

echo "==> Done"
echo "  $DIST/RetinaLink.app"
echo "  $DIST/RetinaLink Receiver.app"
