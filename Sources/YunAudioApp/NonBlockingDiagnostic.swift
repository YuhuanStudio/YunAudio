import Foundation

/// Keeps a back-pressured stderr pipe off MainActor and audio-owner queues.
///
/// A GUI launch normally has no useful stderr reader. Test harnesses sometimes
/// attach a pipe, and a full pipe turns `FileHandle.write` into an unbounded
/// synchronous wait. Diagnostics are best-effort and process-local, so one
/// utility lane is the appropriate containment boundary.
enum NonBlockingDiagnostic {
    private static let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.diagnostics", qos: .utility)

    static func write(_ message: String) {
        let data = Data(message.utf8)
        queue.async { FileHandle.standardError.write(data) }
    }
}
