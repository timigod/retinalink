import Compression
import CoreVideo
import CryptoKit
import Foundation
import RetinaLinkCore
import Synchronization

public enum LosslessCodec {
    public struct Settle: Sendable {
        public let chunks: [LosslessFrame]
        public let unchangedTiles: Int
        let hashes: [UInt64?]
    }

    public static func settle(_ surface: VideoSurface, firstFrameID: UInt64, captureTimeNs: UInt64,
                             baseFrameID: UInt64 = 0, previousHashes: [UInt64?] = []) -> Settle? {
        withLockedPixels(surface) { source in
            let grid = LosslessTileGrid.rectangles(width: source.width, height: source.height)
            guard grid.count == 32, baseFrameID == 0 || previousHashes.count == grid.count else { return nil }
            let cached = baseFrameID != 0
            let tiles = parallelMap(Array(grid.enumerated()).map { Tile(index: $0.offset, rect: $0.element) }) { tile -> PreparedTile? in
                source.withPacked(tile.rect) { pixels in
                    let hash = Self.hash(pixels)
                    if cached && hash == previousHashes[tile.index] {
                        return PreparedTile(hash: hash, patch: nil)
                    }
                    guard let patch = compress(pixels, rect: tile.rect, adaptive: true) else { return nil }
                    return PreparedTile(hash: hash, patch: patch)
                }
            }
            guard tiles.count == grid.count else { return nil }
            var patches = tiles.compactMap(\.patch)
            let unchanged = grid.count - patches.count
            if patches.isEmpty {
                // A known-exact staging image only needs a new presentation.
                let pixel = PixelRect(x: 0, y: 0, width: 1, height: 1)
                guard let patch = source.withPacked(pixel, { compress($0, rect: pixel, adaptive: false) }) else { return nil }
                patches = [patch]
            }
            var groups = [[LosslessPatch]]()
            var group = [LosslessPatch]()
            var bytes = LosslessFrame.headerBytes
            let limit = LosslessFrame.maxChunkBytes - WireFrame.headerSize
            for patch in patches {
                guard patch.payloadBytes + LosslessFrame.headerBytes <= limit else { return nil }
                if bytes + patch.payloadBytes > limit {
                    groups.append(group)
                    group = []
                    bytes = LosslessFrame.headerBytes
                }
                group.append(patch)
                bytes += patch.payloadBytes
            }
            groups.append(group)
            var base = baseFrameID
            let chunks = groups.enumerated().map { index, patches in
                let id = firstFrameID + UInt64(index)
                let frame = LosslessFrame(frameID: id, captureTimeNs: captureTimeNs, baseFrameID: base,
                    width: UInt16(source.width), height: UInt16(source.height), present: index == groups.count - 1,
                    resetsStaging: base == 0, patches: patches)
                base = id
                return frame
            }
            guard chunks.reduce(0, { $0 + $1.payloadBytes + WireFrame.headerSize }) <= LosslessFrame.maxSettleBytes else { return nil }
            return Settle(chunks: chunks, unchangedTiles: unchanged, hashes: tiles.map { $0.hash })
        }
    }

    public static func incremental(_ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64,
                                   baseFrameID: UInt64, dirty: DirtyRects) -> LosslessFrame? {
        guard baseFrameID != 0, dirty.fitsIncrementalBudget else { return nil }
        return withLockedPixels(surface) { source in
            guard dirty.rects.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.maxX <= source.width && $0.maxY <= source.height })
            else { return nil }
            let patches = parallelMap(dirty.rects) { rect in
                source.withPacked(rect) { compress($0, rect: rect, adaptive: false, limit: 512_000) }
            }
            guard patches.count == dirty.rects.count,
                  patches.reduce(0, { $0 + $1.compressedBytes.count }) <= 512_000 else { return nil }
            return LosslessFrame(frameID: frameID, captureTimeNs: captureTimeNs, baseFrameID: baseFrameID,
                                 width: UInt16(source.width), height: UInt16(source.height), present: true,
                                 resetsStaging: false, patches: patches)
        }
    }

    private static func withLockedPixels<T>(_ surface: VideoSurface, _ body: (ReadOnlyPixels) -> T?) -> T? {
        let buffer = surface.pixelBuffer
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard (1...Int(UInt16.max)).contains(width), (1...Int(UInt16.max)).contains(height),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return body(ReadOnlyPixels(address: UnsafeRawPointer(address), stride: CVPixelBufferGetBytesPerRow(buffer),
                                   width: width, height: height))
    }

    private static func hash(_ raw: UnsafeRawBufferPointer) -> UInt64 {
        // CryptoKit uses the CPU SHA instructions on Apple Silicon. Hash the
        // entire packed tile, including alpha, with no stride padding.
        var digest = SHA256()
        digest.update(bufferPointer: raw)
        return digest.finalize().withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    private static func compress(_ raw: UnsafeRawBufferPointer, rect: PixelRect, adaptive: Bool,
                                 limit: Int = LosslessFrame.maxChunkBytes) -> LosslessPatch? {
        func encode(_ algorithm: LosslessAlgorithm) -> Data? {
            var compressed = Data(count: min(limit, raw.count + raw.count / 255 + 128))
            let size = compressed.withUnsafeMutableBytes { destination in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, algorithm.native)
            }
            guard size > 0 else { return nil }
            compressed.count = size
            return compressed
        }
        let lz4 = encode(.lz4)
        let lzfse = adaptive && (lz4?.count ?? Int.max) > 120_000 ? encode(.lzfse) : nil
        let useLZFSE = (lzfse?.count ?? Int.max) < (lz4?.count ?? Int.max)
        guard let bytes = useLZFSE ? lzfse : lz4 else { return nil }
        return LosslessPatch(x: UInt16(rect.x), y: UInt16(rect.y), width: UInt16(rect.width),
                             height: UInt16(rect.height), algorithm: useLZFSE ? .lzfse : .lz4, compressedBytes: bytes)
    }

    private struct Tile: Sendable {
        let index: Int
        let rect: PixelRect
    }

    private struct PreparedTile: Sendable {
        let hash: UInt64
        let patch: LosslessPatch?
    }
}

// The buffer stays locked and immutable until all concurrent readers finish.
private struct ReadOnlyPixels: @unchecked Sendable {
    let address: UnsafeRawPointer
    let stride: Int
    let width: Int
    let height: Int

    func withPacked<T>(_ rect: PixelRect, _ body: (UnsafeRawBufferPointer) -> T) -> T {
        let rowBytes = rect.width * 4
        let start = address + rect.y * stride + rect.x * 4
        return withUnsafeTemporaryAllocation(byteCount: rowBytes * rect.height, alignment: 16) { packed in
            for row in 0..<rect.height {
                memcpy(packed.baseAddress! + row * rowBytes, start + row * stride, rowBytes)
            }
            return body(UnsafeRawBufferPointer(packed))
        }
    }
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
