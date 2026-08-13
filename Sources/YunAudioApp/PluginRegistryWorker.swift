import Foundation
import YunAudioEngine

struct PluginRegistrySnapshot: Sendable, Equatable {
    let plugins: [AudioUnitPlugin]
    let reachedLimit: Bool
    let timedOut: Bool
}

/// Serialises optional Audio Unit registry inspection behind first/latest admission.
///
/// `AVAudioUnitComponentManager` has no cancellable enumeration API. A vendor
/// registry which stalls therefore keeps this one utility worker, never MainActor
/// or the route teardown queue. A result which crossed the elapsed-time budget is
/// marked unusable rather than replacing the last known-good list.
final class PluginRegistryWorker: @unchecked Sendable {
    static let maximumPlugins = 2_048
    static let defaultTimeout: Duration = .seconds(2)

    struct Request: Sendable {
        let timeout: Duration

        init(timeout: Duration = PluginRegistryWorker.defaultTimeout) {
            self.timeout = timeout
        }
    }

    private let lane: LatestExternalWorkLane<Request, PluginRegistrySnapshot>

    init(
        scan: @escaping @Sendable () -> [AudioUnitPlugin] = AudioUnitPlugins.installed,
        publish: @escaping @MainActor @Sendable (PluginRegistrySnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.plugin-registry", qos: .utility),
            apply: { request in
                let deadline = ExternalIODeadline(timeout: request.timeout)
                guard !deadline.hasExpired else {
                    return PluginRegistrySnapshot(
                        plugins: [], reachedLimit: false, timedOut: true)
                }
                let installed = scan()
                let timedOut = deadline.hasExpired
                return PluginRegistrySnapshot(
                    plugins: timedOut ? [] : Array(installed.prefix(Self.maximumPlugins)),
                    reachedLimit: installed.count > Self.maximumPlugins,
                    timedOut: timedOut)
            },
            publish: publish)
    }

    var statistics: LatestExternalWorkLane<Request, PluginRegistrySnapshot>.Statistics {
        lane.statistics
    }

    @discardableResult
    func submit(_ request: Request = Request()) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
