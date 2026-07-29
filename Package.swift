// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YunAudioKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "YunAudioHAL", targets: ["YunAudioHAL"]),
        .executable(name: "yunaudio-cli", targets: ["yunaudio-cli"]),
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

        // The vocabulary two executables share. A URL, a MIDI note, a line of
        // script and a command line are four front ends onto one list of verbs,
        // and one executable target cannot read a type defined in another — so
        // the list lives here rather than being copied into the tool.
        .target(name: "YunAudioControl"),

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

        .executableTarget(
            name: "yunaudio-cli",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRazer", "YunAudioControl",
            ]),

        .testTarget(
            name: "YunAudioTests",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRT", "YunAudioRazer",
                "YunAudioControl",
                // The app is an executable target, and a test target can depend
                // on one since Swift 5.5. It is here so the MIDI message
                // decoding and soft-takeover arithmetic can be tested without a
                // controller plugged in — those are pure functions living
                // beside the CoreMIDI client that feeds them.
                "YunAudioApp",
            ]),
    ]
)
