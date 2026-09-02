import CryptoKit
import Foundation
import Testing

@testable import YunAudioApp

@Suite("Application updates")
struct AppUpdateControllerTests {
    @Test("only writable Applications folders are replaceable in place")
    func installationLocations() {
        let home = URL(fileURLWithPath: "/Users/person", isDirectory: true)

        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(fileURLWithPath: "/Applications/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: false)
                == .applications)
        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(
                    fileURLWithPath: "/Applications/Audio/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: false)
                == .applications)
        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(
                    fileURLWithPath: "/Users/person/Applications/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: false)
                == .userApplications)
        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(fileURLWithPath: "/Volumes/YunAudio/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: true)
                == .readOnlyVolume)
        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(
                    fileURLWithPath:
                        "/private/var/folders/x/AppTranslocation/id/d/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: false)
                == .appTranslocation)
        #expect(
            AppUpdateController.installationLocation(
                bundleURL: URL(fileURLWithPath: "/Users/person/Downloads/YunAudio.app"),
                homeDirectory: home, volumeIsReadOnly: false)
                == .elsewhere)
        #expect(AppUpdateController.InstallationLocation.applications.canReplaceInPlace)
        #expect(AppUpdateController.InstallationLocation.userApplications.canReplaceInPlace)
        #expect(!AppUpdateController.InstallationLocation.readOnlyVolume.canReplaceInPlace)
    }

    @Test("a report carries identity and no device or song detail")
    func issueIdentity() throws {
        let url = try #require(
            AppUpdateController.issueURL(
                version: "0.1.6", build: "7",
                operatingSystem: "Version 27.0 (Build 26A5421a)",
                title: "YunAudio problem: "))
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )

        #expect(components.path == "/YuhuanStudio/YunAudio/issues/new")
        #expect(query["title"] == "YunAudio problem: ")
        let body = try #require(query["body"])
        #expect(body.contains("YunAudio: 0.1.6 (7)"))
        #expect(body.contains("macOS: Version 27.0 (Build 26A5421a)"))
        for privateField in ["device", "route", "song", "microphone"] {
            #expect(!body.localizedCaseInsensitiveContains(privateField))
        }
    }

    @MainActor
    @Test("synthetic evidence starts zero updater owners")
    func syntheticLaunchesDoNotUpdate() {
        for environment in [
            ["YUNAUDIO_RENDER": "out"],
            ["YUNAUDIO_SETTINGS_CHECK": "1"],
            ["YUNAUDIO_SCREENSHOT_NO_AUDIO": "1"],
            ["YUNAUDIO_FLOWCHECK": "1"],
        ] {
            let updater = AppUpdateController()
            updater.start(environment: environment)
            #expect(!updater.isAvailable)
            #expect(!updater.canCheckForUpdates)
        }
    }

    @Test("the app, bundle builder and package agree on the update trust boundary")
    func distributionBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let info = try #require(
            NSDictionary(contentsOfFile: root + "App/Info.plist") as? [String: Any])
        #expect(
            info["SUFeedURL"] as? String
                == "https://raw.githubusercontent.com/YuhuanStudio/YunAudio/main/updates/appcast.xml"
        )
        #expect(
            info["SUPublicEDKey"] as? String
                == "3BBveS7PlOSYZS2iYOmps0u9udcDW/sInL+N16R1SZo=")
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)

        let manifest = try String(
            contentsOfFile: root + "Package.swift", encoding: .utf8)
        #expect(manifest.contains("exact: \"2.9.6\""))
        #expect(manifest.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
        #expect(manifest.contains("@executable_path/../Frameworks"))

        let builder = try String(
            contentsOfFile: root + "App/build-app.sh", encoding: .utf8)
        #expect(builder.contains("Contents/Frameworks/Sparkle.framework"))
        #expect(builder.contains("com.apple.security.cs.disable-library-validation"))
        #expect(builder.contains("codesign --force --deep"))

        let package = try String(
            contentsOfFile: root + "package.sh", encoding: .utf8)
        #expect(package.contains("Contents/Frameworks/Sparkle.framework"))
        #expect(package.contains("codesign --force --deep"))
    }

    @Test("the published feed is signed and its archive carries a complete Ed25519 proof")
    func signedFeed() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "updates/appcast.xml"))
        let text = String(decoding: data, as: UTF8.self)
        let signatureText = try #require(
            text.components(separatedBy: "edSignature: ").dropFirst().first?
                .split(separator: "\n").first.map(String.init))
        let signedLengthText = try #require(
            text.components(separatedBy: "length: ").dropFirst().first?
                .split(separator: "\n").first.map(String.init))
        let signature = try #require(Data(base64Encoded: signatureText))
        let signedLength = try #require(Int(signedLengthText))
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: #require(
                Data(base64Encoded: "3BBveS7PlOSYZS2iYOmps0u9udcDW/sInL+N16R1SZo=")))

        #expect(signature.count == 64)
        #expect(signedLength > 0 && signedLength < data.count)
        #expect(publicKey.isValidSignature(signature, for: data.prefix(signedLength)))
        #expect(text.contains("sparkle:edSignature="))
        #expect(text.contains("length=\"7308621\""))
        #expect(
            text.contains(
                "https://github.com/YuhuanStudio/YunAudio/releases/download/v0.1.5/"))
    }
}
