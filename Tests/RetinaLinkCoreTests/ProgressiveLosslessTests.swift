import CoreVideo
import Foundation
import RetinaLinkCore
@testable import RetinaLinkEngine
import XCTest

final class ProgressiveLosslessTests: XCTestCase {
    func testProgressiveMixedCompressionAndCachedTilesSurviveMotion() throws {
        let source = try surface()
        let width = CVPixelBufferGetWidth(source.pixelBuffer), height = CVPixelBufferGetHeight(source.pixelBuffer)
        let grid = LosslessTileGrid.rectangles(width: width, height: height)
        let initial = try XCTUnwrap(LosslessCodec.settle(source, firstFrameID: 2, captureTimeNs: 1))
        XCTAssertGreaterThan(initial.chunks.count, 1)
        XCTAssertEqual(initial.chunks.flatMap(\.patches).map(\.rect), grid)
        XCTAssertEqual(Set(initial.chunks.flatMap(\.patches).map(\.algorithm)), [.lz4, .lzfse])
        XCTAssertTrue(initial.chunks.allSatisfy { $0.payloadBytes + WireFrame.headerSize <= LosslessFrame.maxChunkBytes })
        let decoder = try LosslessDecoder(width: width, height: height, colorSpace: .displayP3)
        let first = try apply(initial, to: decoder)
        XCTAssertEqual(bytes(first.surface), bytes(source))

        // Motion frames have their own decoder. A new exact frame can use the
        // existing staging base after arbitrary intervening video frame IDs.
        let changed = try surface(changed: true)
        let cached = try XCTUnwrap(LosslessCodec.settle(changed, firstFrameID: 100, captureTimeNs: 2,
            baseFrameID: try XCTUnwrap(initial.chunks.last?.frameID), previousHashes: initial.hashes))
        XCTAssertEqual(cached.unchangedTiles, 31)
        XCTAssertEqual(cached.chunks.flatMap(\.patches).map(\.rect), [grid[0]])
        XCTAssertFalse(try XCTUnwrap(cached.chunks.first).resetsStaging)
        let second = try apply(cached, to: decoder)
        XCTAssertEqual(bytes(second.surface), bytes(changed))
        XCTAssertEqual(bytes(first.surface), bytes(source))

        let unchanged = try XCTUnwrap(LosslessCodec.settle(changed, firstFrameID: 200, captureTimeNs: 3,
            baseFrameID: try XCTUnwrap(cached.chunks.last?.frameID), previousHashes: cached.hashes))
        XCTAssertEqual(unchanged.unchangedTiles, 32)
        XCTAssertLessThan(try XCTUnwrap(unchanged.chunks.first?.payloadBytes), 100)
        XCTAssertEqual(bytes(try apply(unchanged, to: decoder).surface), bytes(changed))
    }

    func testRejectsIncompleteOrDuplicateInitialCoverageAndWrongBase() throws {
        let source = try surface()
        let initial = try XCTUnwrap(LosslessCodec.settle(source, firstFrameID: 2, captureTimeNs: 1))
        let chunk = try XCTUnwrap(initial.chunks.first)
        let decoder = try LosslessDecoder(width: Int(chunk.width), height: Int(chunk.height), colorSpace: .displayP3)
        func frame(_ id: UInt64, base: UInt64, present: Bool, patches: [LosslessPatch]) -> LosslessFrame {
            LosslessFrame(frameID: id, captureTimeNs: 1, baseFrameID: base, width: chunk.width, height: chunk.height,
                          present: present, resetsStaging: base == 0, patches: patches)
        }
        func rejects(_ frame: LosslessFrame, line: UInt = #line) {
            guard case .rejected = decoder.decodeFrame(frame) else { return XCTFail("Accepted invalid chunk", line: line) }
        }
        rejects(frame(2, base: 0, present: true, patches: chunk.patches))
        guard case .applied(_, nil) = decoder.decodeFrame(chunk) else { return XCTFail("Rejected valid intermediate chunk") }
        rejects(frame(3, base: 2, present: false, patches: chunk.patches))
        rejects(frame(4, base: 3, present: true, patches: chunk.patches))
    }

    private func apply(_ settle: LosslessCodec.Settle, to decoder: LosslessDecoder) throws -> DecodedVideoFrame {
        var final: DecodedVideoFrame?
        for chunk in settle.chunks {
            let message = try WireMessage(frame: WireMessage.losslessFrame(chunk).frame())
            guard case .losslessFrame(let decoded) = message else { throw WireError.malformedPayload }
            switch decoder.decodeFrame(decoded) {
            case .applied(let time, let frame):
                XCTAssertGreaterThan(time, 0)
                XCTAssertEqual(frame != nil, chunk.present)
                final = frame
            case .rejected(let reason): XCTFail(reason)
            }
        }
        return try XCTUnwrap(final)
    }

    private func surface(changed: Bool = false) throws -> VideoSurface {
        let width = 4096, height = 2048
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var rng: UInt32 = 1
        for row in 0..<height {
            let line = address + row * stride
            memset(line, changed && row < 512 ? 8 : 7, 2048)
            for column in 2048..<(width * 4) {
                rng = 1_664_525 &* rng &+ 1_013_904_223
                line[column] = 127 + UInt8(rng >> 30)
            }
        }
        return VideoSurface(pixelBuffer)
    }

    private func bytes(_ surface: VideoSurface) -> Data {
        let buffer = surface.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var output = Data(capacity: width * height * 4)
        for row in 0..<height { output.append(base + row * stride, count: width * 4) }
        return output
    }
}
