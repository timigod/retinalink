import Foundation
import RetinaLinkCore
import XCTest

final class WireProtocolTests: XCTestCase {
    private var messages: [WireMessage] {
        [
            .receiverHello(.init(name: "Studio Display Mac", panelPixelWidth: 4480, panelPixelHeight: 2520, cursorPort: 58420, ingressKind: .wiredEthernet)),
            .senderConfig(.init(name: "Laptop Mac", width: 4480, height: 2520, profile: .hevc444_10,
                                colorSpace: .displayP3, linkKind: .thunderbolt, cursorMode: .overlay)),
            .videoFrame(.init(frameID: 0x1234, captureTimeNs: 0x123456789abcdef0, isKeyframe: true,
                               width: 4480, height: 2520, hvcC: Data([1, 4, 3, 10]),
                               nalUnits: Data([0, 0, 0, 2, 0x26, 1]))),
            .frameAck(.init(frameID: 0x1234, captureTimeNs: 0x123456789abcdef0, decodeUs: 3456, receivedBytes: 110)),
            .cursorImage(.init(cursorHash: 77, width: 96, height: 96, hotSpotX: 5.5, hotSpotY: 12.25,
                               scale: 2, pngBytes: Data([137, 80, 78, 71]))),
            .cursorPosition(.init(sequence: UInt32.max, cursorHash: 77, normX: 0.25, normY: 0.75, visible: false)),
            .heartbeat(.init(timestampNs: 0x123456789abcdef0, isReply: true)),
            .requestKeyframe,
            .disconnect(.init(reason: "Done")),
            .losslessFrame(.init(frameID: 4, captureTimeNs: 42, baseFrameID: 3, width: 4480, height: 2520,
                                 algorithm: .lz4, patches: [.init(x: 16, y: 32, width: 64, height: 20,
                                                                 compressedBytes: Data([1, 2, 3]))])),
        ]
    }

    func testRoundTripEveryType() throws {
        var reader = FrameBufferReader()
        for (message, type) in zip(messages, MessageType.allCases) {
            let frame = try message.frame(sequence: 0xf1234567)
            XCTAssertEqual(frame.type, type)
            let decoded = try XCTUnwrap(reader.append(frame.encoded()).first)
            XCTAssertEqual(decoded.sequence, 0xf1234567)
            XCTAssertEqual(try WireMessage(frame: decoded), message)
        }
        XCTAssertEqual(messages.count, MessageType.allCases.count)
    }

    func testBigEndianHeaderAndHeartbeatBytes() throws {
        let frame = WireFrame(type: .videoFrame, flags: 0xf2, sequence: 0x01020304, payload: Data([9, 8, 7]))
        XCTAssertEqual(Array(try frame.encoded()), [
            0x52, 0x4c, 0x4e, 0x4b, 3, 0xf2, 0, 0, 0, 0, 0, 3, 1, 2, 3, 4, 9, 8, 7,
        ])
        XCTAssertEqual(Array(Heartbeat(timestampNs: 0x0102030405060708, isReply: true).encoded()),
                       [1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try messages[3].frame().payload.count, 24)
        XCTAssertEqual(try messages[7].frame().payload.count, 0)
        XCTAssertEqual(Array(try messages[2].frame().payload.prefix(28)), [
            0, 0, 0, 0, 0, 0, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
            0, 0, 0, 3, 0x11, 0x80, 0x09, 0xd8, 0, 0, 0, 4,
        ])
    }

    func testEveryByteFragmentedAndFramesCoalesced() throws {
        let frames = try messages.enumerated().map { try $0.element.frame(sequence: UInt32($0.offset)) }
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        var fragmented = FrameBufferReader()
        var reconstructed: [WireFrame] = []
        for byte in bytes { reconstructed.append(contentsOf: try fragmented.append(Data([byte]))) }
        XCTAssertEqual(reconstructed, frames)
        var combined = FrameBufferReader()
        XCTAssertEqual(try combined.append(bytes), frames)
    }

    func testLargePacketAndRetainedPayloadAcrossBufferCompaction() throws {
        let frame = WireFrame(type: .videoFrame, payload: Data(repeating: 0xed, count: 80_000))
        let second = try messages[0].frame()
        let bytes = try frame.encoded() + second.encoded()
        var reader = FrameBufferReader()
        let first = try reader.append(Data(bytes.dropLast(5)))
        XCTAssertEqual(try reader.append(Data(bytes.suffix(5))), [second])
        XCTAssertEqual(first, [frame])
    }

    func testLengthMagicTypeAndPayloadValidation() throws {
        for (index, value, expected) in [(0, UInt8(7), WireError.invalidMagic),
                                         (4, 0xff, .unknownMessage), (8, 3, .oversizedPayload)] {
            var bytes = try WireFrame(type: .requestKeyframe).encoded()
            bytes[index] = value
            var reader = FrameBufferReader()
            XCTAssertThrowsError(try reader.append(bytes)) { XCTAssertEqual($0 as? WireError, expected) }
        }
        XCTAssertThrowsError(try WireMessage(frame: WireFrame(type: .requestKeyframe, payload: Data([0]))))
        XCTAssertThrowsError(try FrameAck(decoding: Data(count: 23)))
        XCTAssertThrowsError(try VideoFrame(decoding: Data(count: 27)))
        XCTAssertThrowsError(try CursorImage(decoding: Data(count: 24)))
        XCTAssertThrowsError(try Heartbeat(decoding: Data(count: 17)))
    }

    func testLosslessFrameRejectsMalformedFields() throws {
        let payload = try XCTUnwrap(messages.last).frame().payload
        for (offset, value): (Int, UInt8) in [(24, 0), (28, 2), (29, 0), (29, 65), (30, 255), (38, 255)] {
            var corrupt = payload
            corrupt[offset] = value
            if offset == 24 { corrupt[25] = 0 }
            XCTAssertThrowsError(try WireMessage(frame: WireFrame(type: .losslessFrame, payload: corrupt)))
        }
        for corrupt in [Data(payload.dropLast()), payload + Data([0])] {
            XCTAssertThrowsError(try WireMessage(frame: WireFrame(type: .losslessFrame, payload: corrupt)))
        }
        let empty = LosslessPatch(x: 0, y: 0, width: 1, height: 1, compressedBytes: Data())
        let frame = LosslessFrame(frameID: 1, captureTimeNs: 2, baseFrameID: 0, width: 16, height: 16,
                                  algorithm: .lzfse, patches: [empty])
        XCTAssertThrowsError(try WireMessage.losslessFrame(frame).frame())
    }

    func testReceiverCapabilitiesAreOptionalForLegacyPeers() throws {
        let old = Data(#"{"name":"Display","panelPixelWidth":4480,"panelPixelHeight":2520}"#.utf8)
        let hello = try JSONDecoder().decode(ReceiverHello.self, from: old)
        XCTAssertNil(hello.supportsLossless)
        XCTAssertNil(hello.supportedProfiles)
        XCTAssertNil(hello.panelIsHiDPI)
        let updated = ReceiverHello(name: "Display", panelPixelWidth: 4480, panelPixelHeight: 2520, cursorPort: 58420,
                                    supportsLossless: true, supportedProfiles: HEVCProfile.allCases,
                                    physicalWidthMm: 522, physicalHeightMm: 294, panelIsHiDPI: true)
        XCTAssertEqual(try WireMessage(frame: WireMessage.receiverHello(updated).frame()), .receiverHello(updated))
    }

    func testUDPExact24BytesAndVisibilitySignBit() throws {
        let visible = CursorPosition(sequence: UInt32.max, cursorHash: 0x0102030405060708,
                                     normX: 0.5, normY: 1, visible: true)
        let full = visible.encoded()
        XCTAssertEqual(Array(full), [
            0x52, 0x4c, 0x43, 0x50, 255, 255, 255, 255, 1, 2, 3, 4, 5, 6, 7, 8,
            0x3f, 0, 0, 0, 0x3f, 0x80, 0, 0,
        ])
        XCTAssertEqual(try CursorPosition(decoding: full), visible)
        let hidden = CursorPosition(sequence: 3, cursorHash: 5, normX: -0.0, normY: 2, visible: false)
        XCTAssertEqual(hidden.encoded()[16], 0x80)
        XCTAssertEqual(try CursorPosition(decoding: hidden.encoded()), hidden)
        XCTAssertEqual(hidden.normX, 0)
        XCTAssertEqual(hidden.normY, 1)
    }

    func testUDPRejectsWrongSizesMagicAndNonNormalizedFloats() throws {
        let packet = CursorPosition(sequence: 0, cursorHash: 0, normX: 0.5, normY: 0.5, visible: true)
        XCTAssertThrowsError(try CursorPosition(decoding: packet.encoded() + Data(count: 4)))
        var invalid = packet.encoded()
        invalid[0] = 0
        XCTAssertThrowsError(try CursorPosition(decoding: invalid)) { XCTAssertEqual($0 as? WireError, .invalidMagic) }
        invalid = packet.encoded()
        invalid[20] = 0x7f
        invalid[21] = 0x80
        XCTAssertThrowsError(try CursorPosition(decoding: invalid)) { XCTAssertEqual($0 as? WireError, .malformedPayload) }
    }
}
