import Compression
import CoreVideo
import Foundation
import RetinaLinkCore
import Synchronization

public enum LosslessCodec {
    public static func fullFrame(_ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64,
                                 linkKind: LinkKind, linkSpeedMbps: Int?) -> LosslessFrame? {
        let height = CVPixelBufferGetHeight(surface.pixelBuffer)
        let width = CVPixelBufferGetWidth(surface.pixelBuffer)
        guard height >= 4 else { return nil }
        let bands = (0..<4).map { band in
            PixelRect(x: 0, y: height * band / 4, width: width,
                      height: height * (band + 1) / 4 - height * band / 4)
        }
        let slow = linkKind == .wifi || (linkKind == .thunderbolt && (1...200).contains(linkSpeedMbps ?? 0))
        return compress(surface, frameID: frameID, captureTimeNs: captureTimeNs, baseFrameID: 0,
                        rects: bands, algorithm: .lz4, byteBudget: slow ? 4_500_000 : 12_000_000)
            ?? compress(surface, frameID: frameID, captureTimeNs: captureTimeNs, baseFrameID: 0,
                        rects: bands, algorithm: .lzfse, byteBudget: slow ? 4_500_000 : 8_000_000)
    }

    public static func incremental(_ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64,
                                   baseFrameID: UInt64, dirty: DirtyRects) -> LosslessFrame? {
        guard baseFrameID != 0, dirty.fitsIncrementalBudget else { return nil }
        return compress(surface, frameID: frameID, captureTimeNs: captureTimeNs, baseFrameID: baseFrameID,
                        rects: dirty.rects, algorithm: .lz4, byteBudget: 512_000)
    }

    private static func compress(_ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64,
                                 baseFrameID: UInt64, rects: [PixelRect], algorithm: LosslessAlgorithm,
                                 byteBudget: Int) -> LosslessFrame? {
        let buffer = surface.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let width = UInt16(exactly: CVPixelBufferGetWidth(buffer)),
              let height = UInt16(exactly: CVPixelBufferGetHeight(buffer)),
              rects.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.maxX <= Int(width) && $0.maxY <= Int(height) }),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let source = ReadOnlyPixels(address: UnsafeRawPointer(address), stride: CVPixelBufferGetBytesPerRow(buffer))
        let patches = parallelMap(rects) { rect -> LosslessPatch? in
            let rowBytes = rect.width * 4
            let start = source.address.advanced(by: rect.y * source.stride + rect.x * 4)
            let rawBytes = rowBytes * rect.height
            var compressed = Data(count: min(byteBudget, rawBytes + rawBytes / 255 + 128))
            let size = compressed.withUnsafeMutableBytes { destination in
                let bytePointer = destination.bindMemory(to: UInt8.self).baseAddress!
                if rowBytes == source.stride {
                    return compression_encode_buffer(bytePointer, destination.count,
                        start.assumingMemoryBound(to: UInt8.self), rawBytes, nil, algorithm.native)
                }
                return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: rawBytes) { packed in
                    for row in 0..<rect.height {
                        memcpy(packed.baseAddress! + row * rowBytes, start + row * source.stride, rowBytes)
                    }
                    return compression_encode_buffer(bytePointer, destination.count, packed.baseAddress!,
                                                     rawBytes, nil, algorithm.native)
                }
            }
            guard size > 0 else { return nil }
            compressed.count = size
            return LosslessPatch(x: UInt16(rect.x), y: UInt16(rect.y), width: UInt16(rect.width),
                                 height: UInt16(rect.height), compressedBytes: compressed)
        }
        guard patches.count == rects.count,
              patches.reduce(0, { $0 + $1.compressedBytes.count }) <= byteBudget else { return nil }
        return LosslessFrame(frameID: frameID, captureTimeNs: captureTimeNs, baseFrameID: baseFrameID,
                             width: width, height: height, algorithm: algorithm, patches: patches)
    }
}

// The buffer stays locked and immutable until all concurrent readers finish.
private struct ReadOnlyPixels: @unchecked Sendable {
    let address: UnsafeRawPointer
    let stride: Int
}

extension LosslessAlgorithm {
    var native: compression_algorithm { self == .lz4 ? COMPRESSION_LZ4 : COMPRESSION_LZFSE }
}

func parallelMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], transform: @escaping @Sendable (Input) -> Output?
) -> [Output] {
    let results = Mutex(Array<Output?>(repeating: nil, count: inputs.count))
    DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
        let value = transform(inputs[index])
        results.withLock { $0[index] = value }
    }
    return results.withLock { $0.compactMap { $0 } }
}
