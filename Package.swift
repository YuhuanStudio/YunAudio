// swift-tools-version: 6.2
import PackageDescription

// Why every user-interface target below disables dynamic actor isolation.
//
// macOS 27.0 (26A5388g) ships a `libswift_Concurrency` whose
// `swift_task_isCurrentExecutorWithFlags` falls over on its slow path: it
// dereferences the executor identity as an object and that identity is a small
// integer — `0x1e`, `0x200`, `-1`, different garbage each time. One report names
// the failure outright as a pointer authentication failure, and its registers
// hold `CFMainExecutor`'s type metadata beside `DispatchMainExecutor`'s witness
// table, which is two main-executor implementations being mixed.
//
// Those checks are not ours to want. The compiler inserts them where a
// main-actor-isolated closure is handed to a `@preconcurrency` conformance —
// which is every SwiftUI container, in every view. Twelve hypotheses were tested
// and killed before this one, including the toolchain: Swift 6.3.3 crashes
// identically. The measurements are in the commit that made the change.
//
// Turning them off is safe *here* specifically because this package is in Swift
// 6 language mode, so the isolation these checks re-verify at runtime has
// already been proven at compile time. What they add is a second, dynamic
// opinion for conformances the compiler had to trust — and on this system that
// second opinion is fatal.
//
// It is a mitigation, not a cure. With the flag the application survived ten
// minutes and thirty-eight seconds where every build before it died inside one,
// and then crashed inside SwiftUI's own `NSViewResponder.platformCurrentEvent`,
// which calls `MainActor.assumeIsolated` in Apple's compiled code on every
// mouse-move hit test. Nothing in this repository can reach that.
//
// **Remove this the moment a macOS build fixes the runtime.** The check for
// whether it has is five minutes:
//
//     YUNAUDIO_FLOWCHECK=1 YUNAUDIO_FLOWCHECK_ONLY="the song is ours to play" \
//         ./build/YunAudio.app/Contents/MacOS/YunAudioApp
//
let noDynamicActorIsolation: [SwiftSetting] = [
    .unsafeFlags(["-disable-dynamic-actor-isolation"])
]

let package = Package(
    name: "YunAudioKit",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
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

        // The Objective-C exception barrier. Separate from `YunAudioRT`
        // deliberately: that one is the realtime shim and has no
        // Foundation in it, and this one is nothing but Foundation.
        .target(name: "YunAudioObjC"),

        .target(
            name: "YunAudioHAL", dependencies: ["YunAudioRT"],
            // Device profiles ship as documents rather than compiled tables, so
            // supporting somebody else's microphone is a text file rather than
            // a release.
            resources: [.copy("Resources/Devices")]),

        .target(
            name: "YunAudioEngine",
            dependencies: ["YunAudioHAL", "YunAudioRT"],
            // The learned pitch head. `.copy` rather than `.process`: an
            // `.mlpackage` is a directory Core ML opens by path, and processing
            // would flatten it into the bundle root as loose files.
            resources: [.copy("Resources/PitchHead.mlpackage")],
            swiftSettings: [
                // Accelerate's current CBLAS declarations remove the macOS
                // 13.3 deprecation from the strided realtime copy while
                // retaining the 32-bit interface this bounded frame count uses.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]),

        .target(name: "YunDesign", swiftSettings: noDynamicActorIsolation),

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
                "YunAudioControl", "YunAudioMedia", "YunAudioOBS", "YunAudioObjC",
                // For JavaScriptCore's execution time limit, which is declared
                // in YunAudioRT.h because JavaScriptCore does not export it to
                // Swift. See the note there.
                "YunAudioRT",
            ],
            resources: [.process("Resources")],
            swiftSettings: noDynamicActorIsolation),

        .executableTarget(
            name: "yunaudio-cli",
            dependencies: [
                "YunAudioHAL", "YunAudioEngine", "YunAudioRazer", "YunAudioControl",
                "YunAudioOBS",
            ]),

        // An MCP server, so an agent can drive the application. Stateless: it
        // forwards over the control socket and holds nothing, which is what
        // lets an MCP client start and stop it whenever it likes.
        // Training data for the learned pitch estimator. Not shipped — it
        // exists so the features a model is trained on come out of the same
        // code that will serve it.
        .executableTarget(
            name: "yunaudio-pitchdata", dependencies: ["YunAudioEngine"]),

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
            ],
            resources: [.copy("Resources/SpeechFixture.wav")]),
    ]
)
