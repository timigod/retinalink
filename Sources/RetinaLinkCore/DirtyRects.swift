import CoreGraphics
import Foundation

public struct PixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { width * height }

    public func overlaps(_ other: Self) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    fileprivate func union(_ other: Self) -> Self {
        let left = min(x, other.x)
        let top = min(y, other.y)
        return Self(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }
}

public struct DirtyRects: Equatable, Sendable {
    public let rects: [PixelRect]
    public let pixelCount: Int
    public let areaRatio: Double

    public var fitsIncrementalBudget: Bool { !rects.isEmpty && pixelCount <= 1_800_000 && areaRatio <= 0.15 }

    public init(_ dirtyRects: [CGRect], width: Int, height: Int) {
        let bounds = CGRect(x: 0, y: 0, width: max(0, width), height: max(0, height))
        var result = dirtyRects.compactMap { rect -> PixelRect? in
            let clipped = rect.intersection(bounds)
            guard !clipped.isEmpty, !clipped.isNull, !clipped.isInfinite else { return nil }
            let x = Int(floor(clipped.minX)) / 4 * 4
            let y = Int(floor(clipped.minY))
            let right = min(width, (Int(ceil(clipped.maxX)) + 3) / 4 * 4)
            return PixelRect(x: x, y: y, width: right - x, height: Int(ceil(clipped.maxY)) - y)
        }
        result.sort { ($0.y, $0.x, $0.height, $0.width) < ($1.y, $1.x, $1.height, $1.width) }
        while result.count > 1 {
            var best: (first: Int, second: Int, growth: Int)?
            for first in result.indices {
                let left = result[first]
                for second in (first + 1)..<result.count {
                    let right = result[second]
                    let nearby = max(left.x, right.x) - min(left.maxX, right.maxX) <= 32
                        && max(left.y, right.y) - min(left.maxY, right.maxY) <= 32
                    guard result.count > 8 || nearby else { continue }
                    let growth = left.union(right).area - left.area - right.area
                    if best == nil || growth < best!.growth { best = (first, second, growth) }
                }
            }
            guard let best else { break }
            result[best.first] = result[best.first].union(result.remove(at: best.second))
        }
        rects = result
        pixelCount = result.reduce(0) { $0 + $1.area }
        areaRatio = width > 0 && height > 0 ? Double(pixelCount) / (Double(width) * Double(height)) : 0
    }
}

/// ScreenCaptureKit display capture with `.best` reports dirty rectangles in
/// top-left output pixels. Scaled captures can change pixels just outside them.
package enum CaptureDirtyRects {
    package static func normalize(_ rects: [CGRect], contentRect: CGRect, contentScale: CGFloat,
                                  scaleFactor: CGFloat, width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0, contentScale.isFinite, contentScale > 0,
              scaleFactor.isFinite, scaleFactor > 0, contentRect.origin == .zero,
              abs(contentRect.width * scaleFactor - CGFloat(width)) <= 1,
              abs(contentRect.height * scaleFactor - CGFloat(height)) <= 1,
              rects.allSatisfy({ !$0.isNull && !$0.isEmpty && !$0.isInfinite &&
                  $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite }) else { return [] }

        // A 3840×2160 source upscaled to 4480×2520 changed up to three pixels
        // beyond the reported rect. Round the source-pixel margin up in output
        // pixels to cover the resampling footprint and fractional boundaries.
        let margin = abs(contentScale - 1) < 0.0001 ? 0 : ceil(3 * max(1, contentScale))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return rects.map { $0.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds) }
            .filter { !$0.isNull && !$0.isEmpty }
    }
}
