import AppKit
import Darwin

/// Routes SIGINT and SIGTERM (launchctl bootout) through `NSApp.terminate` so `applicationWillTerminate` always runs.
@MainActor
final class TerminationSignals {
    private let sources: [any DispatchSourceSignal]

    static func install() -> TerminationSignals { TerminationSignals() }

    private init() {
        sources = [SIGINT, SIGTERM].map { number in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            return source
        }
    }
}
