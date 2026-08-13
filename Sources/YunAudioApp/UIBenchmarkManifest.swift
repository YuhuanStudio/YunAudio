import Darwin
import Foundation

/// The immutable contract shared by every process in one UI evidence group.
enum UIBenchmarkContract {
    static let schemaVersion = 1
    static let fixtureRevision = "mainactor-four-scenario-v1"
    static let thresholdRevision =
        "p50-0.5-p99-2-max-8-containment-100-cadence-1-coverage-99-v1"
    static let cadenceNanoseconds: UInt64 = 1_000_000
    static let minimumSampleCoverage = 0.99
    static let maximumManifestBytes = 64 * 1024
    static let requiredScenarios: [UIResourceBenchmarkScenario] = [
        .appOpen, .panelClosed, .section69, .ktvStage,
    ]
}

/// Revision identity which must be identical across all four fresh processes.
struct UIBenchmarkRevisionIdentity: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runGroupID: String
    let gitHEAD: String
    let dirtyDigest: String
    let sourceTreeSHA256: String
    let binarySHA256: String
    let toolchainSHA256: String
    let operatingSystemBuild: String
    let fixtureRevision: String
    let thresholdRevision: String

    var isCanonical: Bool {
        schemaVersion == UIBenchmarkContract.schemaVersion
            && !runGroupID.isEmpty
            && runGroupID.count <= 128
            && Self.isHexRevision(gitHEAD, lengths: [40, 64])
            && Self.isHexRevision(dirtyDigest, lengths: [64])
            && Self.isHexRevision(sourceTreeSHA256, lengths: [64])
            && Self.isHexRevision(binarySHA256, lengths: [64])
            && Self.isHexRevision(toolchainSHA256, lengths: [64])
            && !operatingSystemBuild.isEmpty
            && operatingSystemBuild.count <= 128
            && fixtureRevision == UIBenchmarkContract.fixtureRevision
            && thresholdRevision == UIBenchmarkContract.thresholdRevision
    }

    static func resolve(environment: [String: String]) -> Self? {
        func required(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }

        guard
            let runGroupID = required("YUNAUDIO_UI_BENCHMARK_RUN_GROUP"),
            let gitHEAD = required("YUNAUDIO_UI_BENCHMARK_GIT_HEAD"),
            let dirtyDigest = required("YUNAUDIO_UI_BENCHMARK_DIRTY_DIGEST"),
            let sourceTreeSHA256 = required("YUNAUDIO_UI_BENCHMARK_SOURCE_SHA256"),
            let binarySHA256 = required("YUNAUDIO_UI_BENCHMARK_BINARY_SHA256"),
            let toolchainSHA256 = required("YUNAUDIO_UI_BENCHMARK_TOOLCHAIN_SHA256"),
            let operatingSystemBuild = required("YUNAUDIO_UI_BENCHMARK_OS_BUILD"),
            required("YUNAUDIO_UI_BENCHMARK_FIXTURE_REVISION")
                == UIBenchmarkContract.fixtureRevision,
            required("YUNAUDIO_UI_BENCHMARK_THRESHOLD_REVISION")
                == UIBenchmarkContract.thresholdRevision
        else { return nil }

        let identity = Self(
            schemaVersion: UIBenchmarkContract.schemaVersion,
            runGroupID: runGroupID,
            gitHEAD: gitHEAD,
            dirtyDigest: dirtyDigest,
            sourceTreeSHA256: sourceTreeSHA256,
            binarySHA256: binarySHA256,
            toolchainSHA256: toolchainSHA256,
            operatingSystemBuild: operatingSystemBuild,
            fixtureRevision: UIBenchmarkContract.fixtureRevision,
            thresholdRevision: UIBenchmarkContract.thresholdRevision)
        return identity.isCanonical ? identity : nil
    }

    private static func isHexRevision(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.count)
            && value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }
    }
}

/// CPU, wall, memory and view invalidation evidence for one measured phase.
struct UIBenchmarkResourcePhase: Codable, Equatable, Sendable {
    let name: String
    let processorSeconds: Double
    let wallSeconds: Double
    let footprintBytes: UInt64
    let bodyEvaluations: [String: Int]
}

/// One fresh process's complete, machine-readable evidence.
struct UIBenchmarkScenarioManifest: Codable, Equatable, Sendable {
    let identity: UIBenchmarkRevisionIdentity
    let scenario: UIResourceBenchmarkScenario
    let processIdentifier: Int32
    let style: String
    let variant: String
    let requestedSeconds: Double
    let mainActor: MainActorScenarioEvidence
    let resources: [UIBenchmarkResourcePhase]
    let passed: Bool
}

/// The accepted four-scenario group. Its identity is the revision it proves.
struct UIBenchmarkAggregateManifest: Codable, Equatable, Sendable {
    let identity: UIBenchmarkRevisionIdentity
    let scenarios: [UIBenchmarkScenarioManifest]
}

enum UIBenchmarkManifestValidationError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

/// Refuses partial, mixed-revision or numerically failed UI evidence.
enum UIBenchmarkManifestAggregator {
    static func validate(
        _ manifests: [UIBenchmarkScenarioManifest]
    ) -> Result<UIBenchmarkAggregateManifest, UIBenchmarkManifestValidationError> {
        let required = UIBenchmarkContract.requiredScenarios
        guard manifests.count == required.count else {
            return .failure(.invalid("expected exactly four scenario manifests"))
        }
        guard let first = manifests.first else {
            return .failure(.invalid("the scenario group is empty"))
        }
        guard first.identity.isCanonical else {
            return .failure(.invalid("the revision identity is not canonical"))
        }
        guard manifests.allSatisfy({ $0.identity == first.identity }) else {
            return .failure(.invalid("scenario manifests belong to different revisions"))
        }
        guard Set(manifests.map(\.processIdentifier)).count == required.count else {
            return .failure(.invalid("every scenario must run in a fresh process"))
        }
        guard manifests.allSatisfy({ $0.processIdentifier > 0 }) else {
            return .failure(.invalid("a scenario has an invalid process identifier"))
        }
        guard Set(manifests.map(\.scenario)) == Set(required) else {
            return .failure(
                .invalid("the four required scenarios are not present exactly once"))
        }
        guard manifests.allSatisfy({ $0.style == first.style }) else {
            return .failure(.invalid("scenario styles differ"))
        }
        guard first.style == "flat" || first.style == "glass" else {
            return .failure(.invalid("the resolved drawing style is invalid"))
        }
        guard manifests.allSatisfy({ $0.variant == first.variant }) else {
            return .failure(.invalid("scenario drawing variants differ"))
        }
        guard first.variant == "full" else {
            return .failure(.invalid("named scenarios must use production drawing"))
        }
        guard manifests.allSatisfy({ $0.requestedSeconds == first.requestedSeconds }) else {
            return .failure(.invalid("scenario measurement durations differ"))
        }
        guard first.requestedSeconds.isFinite, (4...60).contains(first.requestedSeconds) else {
            return .failure(.invalid("the scenario measurement duration is invalid"))
        }
        guard manifests.allSatisfy(\.passed) else {
            return .failure(.invalid("at least one scenario reported failure"))
        }
        guard manifests.allSatisfy({ UIResourceBenchmarkBudget.admitsMainActor($0.mainActor) })
        else {
            return .failure(.invalid("at least one scenario failed the MainActor distribution"))
        }
        guard
            manifests.allSatisfy({ manifest in
                let expectedPasses: Int
                let plannedSeconds: Double
                switch manifest.scenario {
                case .appOpen, .panelClosed, .windowMovement:
                    expectedPasses = 1
                    plannedSeconds = manifest.requestedSeconds
                case .section69, .ktvStage:
                    expectedPasses = 5
                    let staticSeconds =
                        manifest.scenario == .section69
                        ? max(10, manifest.requestedSeconds) : 4
                    plannedSeconds = staticSeconds + manifest.requestedSeconds * 4
                case .standard:
                    return false
                }
                let minimumExpectedSamples = Int(
                    floor(
                        plannedSeconds
                            * 1_000_000_000
                            / Double(UIBenchmarkContract.cadenceNanoseconds)
                            * UIBenchmarkContract.minimumSampleCoverage))
                return manifest.mainActor.passCount == expectedPasses
                    && manifest.mainActor.expectedSamples >= minimumExpectedSamples
            })
        else {
            return .failure(.invalid("a scenario does not cover every required 1 ms pass"))
        }
        guard
            manifests.allSatisfy({
                $0.mainActor.delivery.maximumSeconds
                    <= UIResourceBenchmarkBudget.maximumMainRunLoopDeliveryLatency
            })
        else {
            return .failure(.invalid("at least one scenario failed the containment watchdog"))
        }
        guard
            manifests.allSatisfy({ !$0.resources.isEmpty })
                && manifests.flatMap(\.resources).allSatisfy({
                    $0.processorSeconds.isFinite && $0.processorSeconds >= 0
                        && $0.wallSeconds.isFinite && $0.wallSeconds > 0
                        && $0.footprintBytes > 0
                        && $0.bodyEvaluations.values.allSatisfy { $0 >= 0 }
                })
        else {
            return .failure(.invalid("a resource phase contains an invalid number"))
        }

        let ordered = required.compactMap { scenario in
            manifests.first { $0.scenario == scenario }
        }
        return .success(
            UIBenchmarkAggregateManifest(identity: first.identity, scenarios: ordered))
    }
}

/// Atomic, size-bounded persistence for one benchmark run group.
enum UIBenchmarkManifestStore {
    enum Outcome: Equatable {
        case recorded
        case aggregated(URL)
    }

    static func write(
        _ manifest: UIBenchmarkScenarioManifest, to directory: URL
    ) throws -> Outcome {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= UIBenchmarkContract.maximumManifestBytes else {
            throw UIBenchmarkManifestValidationError.invalid("scenario manifest is too large")
        }
        let basename = manifest.scenario.rawValue
        let claimURL = directory.appendingPathComponent(basename + ".claim")
        let claimDescriptor = open(claimURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard claimDescriptor >= 0 else {
            throw UIBenchmarkManifestValidationError.invalid(
                "a scenario manifest was already recorded in this run group")
        }
        close(claimDescriptor)
        let scenarioURL = directory.appendingPathComponent(basename + ".json")
        try data.write(
            to: scenarioURL, options: .atomic)

        let urls = UIBenchmarkContract.requiredScenarios.map {
            directory.appendingPathComponent($0.rawValue + ".json")
        }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return .recorded
        }
        let manifests = try urls.map(readScenario)
        let aggregate = try UIBenchmarkManifestAggregator.validate(manifests).get()
        let aggregateData = try encoder.encode(aggregate)
        guard aggregateData.count <= UIBenchmarkContract.maximumManifestBytes else {
            throw UIBenchmarkManifestValidationError.invalid("aggregate manifest is too large")
        }
        let aggregateURL = directory.appendingPathComponent("aggregate.json")
        try aggregateData.write(to: aggregateURL, options: .atomic)
        return .aggregated(aggregateURL)
    }

    private static func readScenario(_ url: URL) throws -> UIBenchmarkScenarioManifest {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard bytes <= UIBenchmarkContract.maximumManifestBytes else {
            throw UIBenchmarkManifestValidationError.invalid("scenario manifest is too large")
        }
        return try JSONDecoder().decode(
            UIBenchmarkScenarioManifest.self, from: Data(contentsOf: url))
    }
}
