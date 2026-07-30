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

        .target(
            name: "YunAudioEngine",
            dependencies: ["YunAudioHAL", "YunAudioRT"],
            swiftSettings: [
                // Accelerate's current CBLAS declarations remove the macOS
                // 13.3 deprecation from the strided realtime copy while
                // retaining the 32-bit interface this bounded frame count uses.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]),

        .target(name: "YunDesign"),

        .target(name: "YunAudioRazer"),

        // The command vocabulary and the socket that carries it. A URL, a MIDI
        // note, a line of script, a command line and an MCP tool are five front
        // ends onto one list of verbs — and SwiftPM will not let one file
        // belong to two targets, so the list lives here rather than being
        // copied into each tool. A copy of a grammar is the thing this type
        // exists to prevent.
        .target(name: "YunAudioControl"),

        // Values shared by player adapters without pulling AppKit, networking
        // or audio into the boundary that accepts untrusted page metadata.
        .target(name: "YunAudioMedia"),

        // A client of somebody else's control protocol, which is why it is not
        // in `YunAudioControl`: that module is the vocabulary this application
        // answers to and has to keep answering to, and obs-websocket is a
        // vocabulary the OBS project can change under us. It depends on
        // `YunAudioControl` only for `JSONValue` — a second JSON type in one
        // process is the kind of duplication this package layout exists to
        // prevent.
        .target(name: "YunAudioOBS", dependencies: ["YunAudioControl"]),

        .executableTarget(
            name: "YunAudioApp",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunDesign", "YunAudioRazer",
                "YunAudioControl", "YunAudioMedia", "YunAudioOBS",
                // For JavaScriptCore's execution time limit, which is declared
                // in YunAudioRT.h because JavaScriptCore does not export it to
                // Swift. See the note there.
                "YunAudioRT",
            ],
            resources: [.process("Resources")]),

        .executableTarget(
            name: "yunaudio-cli",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRazer", "YunAudioControl",
                "YunAudioOBS",
            ]),

        // An MCP server, so an agent can drive the application. Stateless: it
        // forwards over the control socket and holds nothing, which is what
        // lets an MCP client start and stop it whenever it likes.
        .executableTarget(name: "yunaudio-mcp", dependencies: ["YunAudioControl"]),

        .testTarget(
            name: "YunAudioTests",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRT", "YunAudioRazer",
                "YunAudioControl", "YunAudioMedia", "YunAudioOBS", "yunaudio-mcp",
                // The app is an executable target, and a test target can depend
                // on one since Swift 5.5. It is here so the MIDI message
                // decoding and soft-takeover arithmetic can be tested without a
                // controller plugged in — those are pure functions living
                // beside the CoreMIDI client that feeds them.
                "YunAudioApp",
            ]),
    ]
)
