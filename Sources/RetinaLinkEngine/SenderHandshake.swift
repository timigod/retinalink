import Foundation
import RetinaLinkCore

public enum SenderHandshake {
    public static func open(candidate: EndpointCandidate)
        async throws -> (TransportSession, ReceiverHello) {
        let session = TransportSession(candidate: candidate)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = Task.isCancelled
                MediaQueue.sync {
                    guard !alreadyCancelled, !session.isClosed else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let pending = PendingHandshake()
                    session.onMessage = { [weak session] message in
                        guard let session, case .receiverHello(let hello) = message else { return }
                        session.onMessage = nil
                        session.onClose = nil
                        pending.waitingForHello = false
                        continuation.resume(returning: (session, hello))
                    }
                    session.onClose = { reason in
                        pending.waitingForHello = false
                        continuation.resume(throwing: RetinaLinkError.operation(reason))
                    }
                    MediaQueue.queue.asyncAfter(deadline: .now() + .seconds(4)) { [weak session] in
                        guard let session, pending.waitingForHello else { return }
                        session.close(reason: "No receiver hello")
                    }
                    session.start()
                }
            }
        } onCancel: {
            session.close(reason: "Connection cancelled")
        }
    }
    // Its callbacks all run on the media queue.
    private final class PendingHandshake: @unchecked Sendable {
        var waitingForHello = true
    }
}
