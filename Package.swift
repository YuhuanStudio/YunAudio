// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YunAudioKit",
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

        .target(name: "YunAudioHAL", dependencies: ["YunAudioRT"]),

        .target(name: "YunAudioEngine", dependencies: ["YunAudioHAL", "YunAudioRT"]),

        .target(name: "YunDesign"),

        .target(name: "YunAudioRazer"),

        .executableTarget(
            name: "YunAudioApp",
            dependencies: ["YunAudioHAL", "YunAudioEngine", "YunDesign"]),

        .executableTarget(name: "yunaudio-cli", dependencies: ["YunAudioHAL", "YunAudioEngine", "YunAudioRazer"]),

    ]
)
