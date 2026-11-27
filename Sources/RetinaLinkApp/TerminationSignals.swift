import AppKit
import Darwin

/// Routes SIGINT and SIGTERM through `NSApp.terminate` so `applicationWillTerminate` always runs.
@MainActor
final class TerminationSignals {
    private static let numbers = [SIGINT, SIGTERM]
    private let sources: [any DispatchSourceSignal]

    static func install() -> TerminationSignals { TerminationSignals() }

    /// The engine restores default signal handling when its virtual display goes away; take it back.
    static func ignoreDefaultHandling() {
        for number in numbers { Darwin.signal(number, SIG_IGN) }
    }

    private init() {
        Self.ignoreDefaultHandling()
        sources = Self.numbers.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            return source
        }
    }
}
