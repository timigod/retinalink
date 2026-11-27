import Foundation

// Owns TCP framing and stream state on one executor. Codec sessions use their
// own queues, so none of the three stages waits for the main run loop.
enum MediaQueue {
    private static let identity = QueueIdentity()
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "RetinaLink.media", qos: .userInteractive)
        queue.setSpecific(key: identity.key, value: 1)
        return queue
    }()

    private final class QueueIdentity: @unchecked Sendable {
        let key = DispatchSpecificKey<UInt8>()
    }

    static func sync<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: identity.key) != nil { return action() }
        return queue.sync(execute: action)
    }
}

@propertyWrapper
final class MediaValue<Value: Sendable> {
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { MediaQueue.sync { value } }
        set { MediaQueue.sync { value = newValue } }
    }
}
