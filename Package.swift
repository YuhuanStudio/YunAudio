// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YunAudioKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "YunAudioHAL", targets: ["YunAudioHAL"]),
        .executable(name: "yunaudio-cli", targets: ["yunaudio-cli"]),
        .executable(name: "yunaudio-mcp", targets: ["yunaudio-mcp"]),
        .executable(name: "YunAudioApp", targets: ["YunAudioApp"]),
    ],
    targets: [
        // C shim. The os_workgroup / AudioWorkInterval APIs are annotated
        // __SWIFT_UNAVAILABLE_MSG("Swift is not supported for use with audio
        // realtime threads"), so every call into them lives here.
        .target(name: "YunAudioRT"),

        .target(
            name: "YunAudioHAL", dependencies: ["YunAudioRT"],
            // Device profiles ship as documents rather than compiled tables, so
            // supporting somebody else's microphone is a text file rather than
            // a release.
            resources: [.copy("Resources/Devices")]),

        .target(name: "YunAudioEngine", dependencies: ["YunAudioHAL", "YunAudioRT"]),

        .target(name: "YunDesign"),

        .target(name: "YunAudioRazer"),

        // The command vocabulary and the socket that carries it. A module of
        // its own because the MCP server is a separate process and needs the
        // same definitions, and SwiftPM will not let one file belong to two
        // targets — the alternative was a second copy of the grammar.
        .target(name: "YunAudioControl", dependencies: ["YunDesign"]),

        .executableTarget(
            name: "YunAudioApp",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunDesign", "YunAudioRazer",
                "YunAudioControl",
                // For JavaScriptCore's execution time limit, which is declared
                // in YunAudioRT.h because JavaScriptCore does not export it to
                // Swift. See the note there.
                "YunAudioRT",
            ],
            resources: [.process("Resources")]),

        .executableTarget(name: "yunaudio-cli", dependencies: ["YunAudioHAL", "YunAudioEngine", "YunAudioRazer"]),

        // An MCP server, so an agent can drive the application. Stateless: it
        // forwards over the control socket and holds nothing, which is what
        // lets an MCP client start and stop it whenever it likes.
        .executableTarget(name: "yunaudio-mcp", dependencies: ["YunAudioControl"]),

        .testTarget(
            name: "YunAudioTests",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRT", "YunAudioRazer",
                "YunAudioControl", "yunaudio-mcp",
                // The app is an executable target, and a test target can depend
                // on one since Swift 5.5. It is here so the MIDI message
                // decoding and soft-takeover arithmetic can be tested without a
                // controller plugged in — those are pure functions living
                // beside the CoreMIDI client that feeds them.
                "YunAudioApp",
            ]),
    ]
)
