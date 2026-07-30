import AudioToolbox
import Testing

@testable import YunAudioEngine

@Suite("Echo-cancellation unit setup", .serialized)
struct EchoCancellationUnitSetupTests {
    @Test("every failed required property stops before initialisation")
    func propertyFailuresAreFatal() {
        let steps: [EchoCancellationUnitSetupStep] = [
            .enableInput,
            .enableOutput,
            .setCurrentDevice,
            .setCaptureFormat,
            .setRenderFormat,
            .setMaximumFrames,
            .disableAutomaticGain,
            .setInputCallback,
            .setRenderCallback,
        ]

        for (index, expectedStep) in steps.enumerated() {
            let harness = SetupHarness()
            harness.failedSetCall = index + 1

            let result = runSetup(harness: harness)

            #expect(result?.step == expectedStep)
            #expect(result?.status == -50)
            #expect(harness.setCalls == index + 1)
            #expect(harness.initialiseCalls == 0)
        }
    }

    @Test("a failed device read stops before format setup and initialisation")
    func deviceReadFailureIsFatal() {
        let harness = SetupHarness()
        harness.getStatus = -66_748

        let result = runSetup(harness: harness)

        #expect(result?.step == .readCurrentDevice)
        #expect(result?.status == -66_748)
        #expect(result?.expectedDeviceID == 41)
        #expect(harness.setCalls == 3)
        #expect(harness.getCalls == 1)
        #expect(harness.initialiseCalls == 0)
    }

    @Test("a unit that kept another device cannot be reported as dedicated")
    func deviceReadbackMustMatch() {
        let harness = SetupHarness()
        harness.actualDeviceID = 42

        let result = runSetup(harness: harness, boundDeviceID: 41)

        #expect(result?.step == .readCurrentDevice)
        #expect(result?.status == noErr)
        #expect(result?.expectedDeviceID == 41)
        #expect(result?.actualDeviceID == 42)
        #expect(harness.setCalls == 3)
        #expect(harness.getCalls == 1)
        #expect(harness.initialiseCalls == 0)
    }

    @Test("initialisation runs exactly once only after every contract holds")
    func completeSetupInitialisesOnce() {
        let harness = SetupHarness()

        let result = runSetup(harness: harness)

        #expect(result == nil)
        #expect(harness.setCalls == 9)
        #expect(harness.getCalls == 1)
        #expect(harness.initialiseCalls == 1)
    }

    @Test("an initialisation error is attributed to the final setup step")
    func initialisationFailureIsReported() {
        let harness = SetupHarness()
        harness.initialiseStatus = -10_863

        let result = runSetup(harness: harness)

        #expect(result?.step == .initialise)
        #expect(result?.status == -10_863)
        #expect(harness.setCalls == 9)
        #expect(harness.getCalls == 1)
        #expect(harness.initialiseCalls == 1)
    }

    @Test("the standalone path deliberately skips dedicated-device binding")
    func standalonePathSkipsDeviceReadback() {
        let harness = SetupHarness()

        let result = runSetup(harness: harness, boundDeviceID: nil)

        #expect(result == nil)
        #expect(harness.setCalls == 8)
        #expect(harness.getCalls == 0)
        #expect(harness.initialiseCalls == 1)
    }

    @Test("an invalid maximum slice cannot trap or reach initialisation")
    func invalidMaximumFramesFailsClosed() {
        let harness = SetupHarness()

        let result = runSetup(harness: harness, maximumFrames: -1)

        #expect(result?.step == .setMaximumFrames)
        #expect(result?.status == -50)
        #expect(harness.setCalls == 5)
        #expect(harness.initialiseCalls == 0)
    }

    private func runSetup(
        harness: SetupHarness,
        boundDeviceID: AudioObjectID? = 41,
        maximumFrames: Int = 512
    ) -> EchoCancellationUnitSetupFailure? {
        var inputCallback = emptyCallback()
        var renderCallback = emptyCallback()
        return EchoCancellingCapture.setupVoiceProcessingUnit(
            boundDeviceID: boundDeviceID,
            sampleRate: 48_000,
            maximumFrames: maximumFrames,
            inputCallback: &inputCallback,
            renderCallback: &renderCallback,
            operations: harness.operations)
    }

    private func emptyCallback() -> AURenderCallbackStruct {
        AURenderCallbackStruct(
            inputProc: { _, _, _, _, _, _ in noErr },
            inputProcRefCon: nil)
    }
}

private final class SetupHarness {
    var failedSetCall: Int?
    var setCalls = 0
    var getCalls = 0
    var initialiseCalls = 0
    var getStatus: OSStatus = noErr
    var initialiseStatus: OSStatus = noErr
    var actualDeviceID = AudioObjectID(41)

    var operations: EchoCancellationUnitSetupOperations {
        EchoCancellationUnitSetupOperations(
            setProperty: { [self] _, _, _, _, _ in
                setCalls += 1
                return setCalls == failedSetCall ? -50 : noErr
            },
            getProperty: { [self] _, _, _, data, _ in
                getCalls += 1
                if getStatus == noErr {
                    data.assumingMemoryBound(to: AudioObjectID.self).pointee =
                        actualDeviceID
                }
                return getStatus
            },
            initialise: { [self] in
                initialiseCalls += 1
                return initialiseStatus
            })
    }
}
