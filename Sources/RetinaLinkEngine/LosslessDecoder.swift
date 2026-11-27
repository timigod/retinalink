import Compression
import CoreGraphics
import CoreVideo
import Foundation
import RetinaLinkCore

// Confined to the receiver's lossless queue. Only completed snapshots leave it.
public final class LosslessDecoder {
    private let width: Int
    private let height: Int
    private let colors: StreamColorSpace
    private let pool: CVPixelBufferPool
    private var staging: Data
    private var lastFrameID: UInt64 = 0
    private var initialCoverage: UInt32?
    private var transferBytes = 0
    private let grid: [PixelRect]

    public convenience init(width: Int, height: Int, colorSpace: StreamColorSpace) throws {
        guard let pool = Self.makePool(width: width, height: height) else {
            throw RetinaLinkError.operation("Could not create lossless display buffer pool")
        }
        self.init(width: width, height: height, colorSpace: colorSpace, pool: pool)
    }

    static func make(width: Int, height: Int, colorSpace: StreamColorSpace) -> LosslessDecoder? {
        guard let pool = makePool(width: width, height: height) else { return nil }
        return Self(width: width, height: height, colorSpace: colorSpace, pool: pool)
    }

    private init(width: Int, height: Int, colorSpace: StreamColorSpace, pool: CVPixelBufferPool) {
        self.width = width
        self.height = height
        colors = colorSpace
        self.pool = pool
        staging = Data(count: width * height * 4)
        grid = LosslessTileGrid.rectangles(width: width, height: height)
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        guard (1...8192).contains(width), (1...8192).contains(height) else { return nil }
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pool)
        return status == kCVReturnSuccess ? pool : nil
    }

    package enum Outcome: Sendable {
        case applied(decodeUs: UInt32, frame: DecodedVideoFrame?)
        case rejected(String)
    }

    private struct StagingDestination: @unchecked Sendable {
        let address: UnsafeMutableRawPointer
        let stride: Int
    }

    package func decodeFrame(_ frame: LosslessFrame) -> Outcome {
        let start = DispatchTime.now().uptimeNanoseconds
        guard frame.hasValidBounds, frame.payloadBytes + WireFrame.headerSize <= LosslessFrame.maxChunkBytes,
              frame.width == width, frame.height == height else {
            reset()
            return .rejected("Invalid lossless frame bounds")
        }
        guard frame.frameID > lastFrameID, frame.resetsStaging || frame.baseFrameID == lastFrameID else {
            reset()
            return .rejected("Lossless patch base does not match")
        }
        let bytesInTransfer = (frame.resetsStaging ? 0 : transferBytes) + frame.payloadBytes + WireFrame.headerSize
        guard bytesInTransfer <= LosslessFrame.maxSettleBytes else {
            reset()
            return .rejected("Lossless settle exceeds its transfer budget")
        }
        var coverage = frame.resetsStaging ? UInt32(0) : initialCoverage
        if let previous = coverage {
            var written = previous
            for patch in frame.patches {
                guard let tile = grid.firstIndex(of: patch.rect), written & (1 << tile) == 0 else {
                    reset()
                    return .rejected("Initial lossless settle must write each grid tile once")
                }
                written |= 1 << tile
            }
            if frame.present && written != UInt32.max {
                reset()
                return .rejected("Incomplete full lossless frame")
            }
            coverage = frame.present ? nil : written
        }
        let packedStride = width * 4
        let decompressed = staging.withUnsafeMutableBytes { bytes in
            let target = StagingDestination(address: bytes.baseAddress!, stride: packedStride)
            let applied: [Bool] = parallelMap(frame.patches) { patch in
                guard Self.apply(patch, to: target) else { return nil }
                return true
            }
            return applied.count == frame.patches.count
        }
        guard decompressed else {
            reset()
            return .rejected("Lossless tile decompression failed")
        }
        lastFrameID = frame.frameID
        initialCoverage = coverage
        transferBytes = frame.present ? 0 : bytesInTransfer
        guard frame.present else { return .applied(decodeUs: Self.elapsed(since: start), frame: nil) }
        guard let presented = displayFrame(start: start) else {
            reset()
            return .rejected("Could not allocate a lossless display buffer")
        }
        return .applied(decodeUs: presented.decodeUs, frame: presented)
    }

    // A chunk's wire-validated patches are disjoint. Decode each packed tile
    // into scratch storage, then scatter its rows into staging in parallel.
    private static func apply(_ patch: LosslessPatch, to target: StagingDestination) -> Bool {
        let rect = patch.rect
        let rowBytes = rect.width * 4
        let expected = rowBytes * rect.height
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: expected + 1) { scratch in
            let written = patch.compressedBytes.withUnsafeBytes { source in
                compression_decode_buffer(scratch.baseAddress!, scratch.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, patch.algorithm.native)
            }
            guard written == expected else { return false }
            let start = target.address + rect.y * target.stride + rect.x * 4
            for row in 0..<rect.height {
                memcpy(start + row * target.stride, scratch.baseAddress! + row * rowBytes, rowBytes)
            }
            return true
        }
    }

    private func displayFrame(start: UInt64) -> DecodedVideoFrame? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let packedStride = width * 4
        staging.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!
            if stride == packedStride {
                memcpy(address, base, bytes.count)
            } else {
                for row in 0..<height { memcpy(address + row * stride, base + row * packedStride, packedStride) }
            }
        }
        colors.tag(buffer)
        let colorName = switch colors {
        case .displayP3: CGColorSpace.displayP3
        case .sRGB: CGColorSpace.sRGB
        case .rec709: CGColorSpace.itur_709
        }
        if let colorSpace = CGColorSpace(name: colorName) {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        }
        return DecodedVideoFrame(surface: VideoSurface(buffer), decodeUs: Self.elapsed(since: start))
    }

    private static func elapsed(since start: UInt64) -> UInt32 {
        max(1, UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - start) / 1000))
    }

    func reset() {
        lastFrameID = 0
        initialCoverage = nil
        transferBytes = 0
    }
}
