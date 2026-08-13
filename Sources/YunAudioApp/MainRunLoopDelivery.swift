import CoreFoundation
import Foundation
import YunDesign

/// Delivers MainActor work through the main run loop's common modes.
///
/// AppKit's deferred-termination handshake runs a nested run loop. That loop
/// services common-mode sources but does not necessarily drain a Swift
/// MainActor task, so a `Task { @MainActor }` completion can wait forever while
/// AppKit is waiting for that very completion. The run-loop block is also safe
/// for ordinary operation; `onTheMainThread` records the executor proof without
/// invoking the damaged dynamic executor check described in YunDesign.
enum MainRunLoopDelivery {
    static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            onTheMainThread { body() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
