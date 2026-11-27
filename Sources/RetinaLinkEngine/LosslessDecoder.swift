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

    enum Outcome: Sendable {
        case decoded(DecodedVideoFrame)
        case rejected(String)
    }

    public func decode(_ frame: LosslessFrame) throws -> DecodedVideoFrame {
        switch decodeFrame(frame) {
        case .decoded(let decoded): return decoded
        case .rejected(let reason): throw RetinaLinkError.operation(reason)
        }
    }

    func decodeFrame(_ frame: LosslessFrame) -> Outcome {
        let start = DispatchTime.now().uptimeNanoseconds
        guard frame.hasValidBounds, frame.width == width, frame.height == height, frame.frameID != 0 else {
            return .rejected("Invalid lossless frame bounds")
        }
        guard frame.baseFrameID == 0 || frame.baseFrameID == lastFrameID && frame.frameID > lastFrameID else {
            return .rejected("Lossless patch base does not match")
        }
        let rects = frame.patches.map(\.rect)
        guard !rects.indices.contains(where: { index in
            rects.suffix(from: index + 1).contains(where: rects[index].overlaps)
        }) else { return .rejected("Overlapping lossless patches") }
        let area = rects.reduce(0) { $0 + $1.area }
        if frame.baseFrameID == 0 {
            guard area == width * height else { return .rejected("Incomplete full lossless frame") }
        } else {
            guard rects.count <= 8, area <= min(1_800_000, width * height * 15 / 100) else {
                return .rejected("Lossless patch exceeds its pixel budget")
            }
        }
        let algorithm = frame.algorithm.native
        let unpacked = parallelMap(frame.patches) { patch -> Data? in
            let expected = patch.rect.area * 4
            // One spare byte tells us whether decode hit the output limit.
            guard let destination = malloc(expected + 1) else { return nil }
            let written = patch.compressedBytes.withUnsafeBytes { source in
                compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), expected + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, algorithm)
            }
            guard written == expected else {
                free(destination)
                return nil
            }
            return Data(bytesNoCopy: destination, count: expected, deallocator: .free)
        }
        guard unpacked.count == rects.count else { return .rejected("Lossless band decompression failed") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            return .rejected("Could not allocate a lossless display buffer (\(status))")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return .rejected("Lossless display buffer has no base address") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let packedStride = width * 4
        staging.withUnsafeMutableBytes { target in
            let base = target.baseAddress!
            for (rect, bytes) in zip(rects, unpacked) {
                let rowBytes = rect.width * 4
                let start = base + rect.y * packedStride + rect.x * 4
                bytes.withUnsafeBytes { source in
                    if rowBytes == packedStride {
                        memcpy(start, source.baseAddress!, source.count)
                    } else {
                        for row in 0..<rect.height {
                            memcpy(start + row * packedStride, source.baseAddress! + row * rowBytes, rowBytes)
                        }
                    }
                }
            }
            if stride == packedStride {
                memcpy(address, base, target.count)
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
        lastFrameID = frame.frameID
        return .decoded(DecodedVideoFrame(surface: VideoSurface(buffer),
            decodeUs: max(1, UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - start) / 1000))))
    }

    func reset() { lastFrameID = 0 }
}
