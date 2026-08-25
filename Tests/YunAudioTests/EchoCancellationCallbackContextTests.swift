import AudioToolbox
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Echo-cancellation raw callback context", .serialized)
struct EchoCancellationCallbackContextTests {
    private struct DiagnosticsHandle: @unchecked Sendable {
        let raw: OpaquePointer
    }

    private struct RenderInvocation: @unchecked Sendable {
        let context: OpaquePointer
        let buffers: UnsafeMutablePointer<AudioBufferList>
        let frames: UInt32
    }

    private final class BlockingProviderState: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
    }

    private struct ProviderState {
        var calls: UInt32 = 0
        var offered: UInt32 = 0
        var written: UInt32 = 0
        var reported: Int64 = 0
    }

    private static let captureHandler:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafePointer<Float>, UInt32,
            UnsafePointer<AudioTimeStamp>
        ) -> Void = { _, _, _, _ in }

    private static let farEndProvider:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, UInt32
        ) -> Int64 = { rawState, destination, frames in
            let state = rawState.assumingMemoryBound(to: ProviderState.self)
            state.pointee.calls &+= 1
            state.pointee.offered = frames
            let written = min(state.pointee.written, frames)
            for index in 0..<Int(written) {
                destination[index] = Float(index + 1) * 0.25
            }
            return state.pointee.reported
        }

    private static let blockingFarEndProvider:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, UInt32
        ) -> Int64 = { rawState, destination, frames in
            let state = Unmanaged<BlockingProviderState>.fromOpaque(rawState)
                .takeUnretainedValue()
            state.entered.signal()
            state.resume.wait()
            destination.update(repeating: 0.25, count: Int(frames))
            return Int64(frames)
        }

    @Test("the raw render callback clamps reports and clears a bounded tail")
    func rawRenderCallbackIsBounded() throws {
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, 8, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }

        let state = UnsafeMutablePointer<ProviderState>.allocate(capacity: 1)
        state.initialize(to: ProviderState(written: 2, reported: 2))
        defer {
            state.deinitialize(count: 1)
            state.deallocate()
        }
        yun_rt_echo_callback_context_bind(
            context, Self.captureHandler, state, Self.farEndProvider, state)

        var storage: [Float] = [99, -1, -1, -1, -1, 77]
        let status = storage.withUnsafeMutableBufferPointer { samples in
            let buffers = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(buffers.unsafeMutablePointer) }
            buffers[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
                mData: samples.baseAddress! + 1)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return yun_rt_echo_render_callback(
                UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
                buffers.unsafeMutablePointer)
        }

        #expect(status == noErr)
        #expect(state.pointee.calls == 1)
        #expect(state.pointee.offered == 4)
        #expect(storage == [99, 0.25, 0.5, 0, 0, 77])
        #expect(yun_rt_counter_load(counters.farEnd) == 1)
        #expect(yun_rt_counter_load(counters.input) == 0)
    }

    @Test("the 4096-frame ceiling is exact and 4097 fails silent")
    func maximumRenderSliceIsExact() throws {
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, 4_096, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }

        #expect(
            yun_rt_echo_callback_context_create(
                nil, 0, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics) == nil)
        #expect(
            yun_rt_echo_callback_context_create(
                nil, 4_097, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics) == nil)

        let state = UnsafeMutablePointer<ProviderState>.allocate(capacity: 1)
        state.initialize(to: ProviderState())
        defer {
            state.deinitialize(count: 1)
            state.deallocate()
        }
        yun_rt_echo_callback_context_bind(
            context, Self.captureHandler, state, Self.farEndProvider, state)

        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4_098)
        storage.initialize(repeating: 1, count: 4_098)
        storage[0] = 91
        storage[4_097] = 92
        defer {
            storage.deinitialize(count: 4_098)
            storage.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(buffers.unsafeMutablePointer) }
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4_096 * MemoryLayout<Float>.size),
            mData: storage + 1)

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let admitted = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4_096,
            buffers.unsafeMutablePointer)

        #expect(admitted == noErr)
        #expect(state.pointee.calls == 1)
        #expect(state.pointee.offered == 4_096)
        #expect((1...4_096).allSatisfy { storage[$0] == 0 })
        #expect(storage[0] == 91)
        #expect(storage[4_097] == 92)

        for index in 1...4_096 { storage[index] = 1 }
        state.pointee = ProviderState()
        buffers[0].mDataByteSize = UInt32.max
        flags = AudioUnitRenderActionFlags()
        let refused = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4_097,
            buffers.unsafeMutablePointer)

        #expect(refused == kAudioUnitErr_TooManyFramesToProcess)
        #expect(state.pointee.calls == 0)
        #expect((1...4_096).allSatisfy { storage[$0] == 0 })
        #expect(storage[0] == 91)
        #expect(storage[4_097] == 92)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("malformed buffer counts and byte sizes clear only a bounded prefix")
    func malformedRenderLayoutIsBounded() throws {
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, 4, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }

        let state = UnsafeMutablePointer<ProviderState>.allocate(capacity: 1)
        state.initialize(to: ProviderState(written: 4, reported: 4))
        defer {
            state.deinitialize(count: 1)
            state.deallocate()
        }
        yun_rt_echo_callback_context_bind(
            context, Self.captureHandler, state, Self.farEndProvider, state)

        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        storage.initialize(repeating: 1, count: 6)
        storage[0] = 41
        storage[5] = 42
        defer {
            storage.deinitialize(count: 6)
            storage.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(buffers.unsafeMutablePointer) }
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32.max,
            mData: storage + 1)
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = UInt32.max
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()

        let countStatus = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(countStatus == kAudioUnitErr_InvalidParameter)
        #expect((1...4).allSatisfy { storage[$0] == 0 })
        #expect(storage[0] == 41)
        #expect(storage[5] == 42)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))

        for index in 1...4 { storage[index] = 1 }
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = 1
        buffers[0].mDataByteSize = 17
        flags = AudioUnitRenderActionFlags()
        let unalignedStatus = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(unalignedStatus == kAudioUnitErr_InvalidParameter)
        #expect((1...4).allSatisfy { storage[$0] == 0 })
        #expect(storage[0] == 41)
        #expect(storage[5] == 42)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))

        for index in 1...4 { storage[index] = 1 }
        buffers[0].mDataByteSize = UInt32(3 * MemoryLayout<Float>.size)
        flags = AudioUnitRenderActionFlags()
        let undersizedStatus = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(undersizedStatus == kAudioUnitErr_InvalidParameter)
        #expect((1...3).allSatisfy { storage[$0] == 0 })
        #expect(storage[4] == 1)
        #expect(storage[0] == 41)
        #expect(storage[5] == 42)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))

        for index in 1...4 { storage[index] = 1 }
        buffers[0].mNumberChannels = 2
        buffers[0].mDataByteSize = UInt32(4 * MemoryLayout<Float>.size)
        flags = AudioUnitRenderActionFlags()
        let channelStatus = yun_rt_echo_render_callback(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(channelStatus == kAudioUnitErr_InvalidParameter)
        #expect((1...4).allSatisfy { storage[$0] == 0 })
        #expect(storage[0] == 41)
        #expect(storage[5] == 42)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
        #expect(state.pointee.calls == 0)
    }

    @Test("clearing the raw binding makes a late render entry silent")
    func clearedBindingIsSilent() throws {
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, 8, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }

        let state = UnsafeMutablePointer<ProviderState>.allocate(capacity: 1)
        state.initialize(to: ProviderState(written: 4, reported: 4))
        defer {
            state.deinitialize(count: 1)
            state.deallocate()
        }
        yun_rt_echo_callback_context_bind(
            context, Self.captureHandler, state, Self.farEndProvider, state)
        yun_rt_echo_callback_context_clear(context)

        var storage = [Float](repeating: 1, count: 4)
        storage.withUnsafeMutableBufferPointer { samples in
            let buffers = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(buffers.unsafeMutablePointer) }
            buffers[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: samples.baseAddress)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            _ = yun_rt_echo_render_callback(
                UnsafeMutableRawPointer(context), &flags, &timestamp, 0,
                UInt32(samples.count), buffers.unsafeMutablePointer)
        }

        #expect(state.pointee.calls == 0)
        #expect(storage == [0, 0, 0, 0])
        #expect(yun_rt_counter_load(counters.farEnd) == 1)
    }

    @Test("an overlapping render is refused and made completely silent")
    func overlappingRenderIsSilent() throws {
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, 4, nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }

        let state = BlockingProviderState()
        yun_rt_echo_callback_context_bind(
            context, Self.captureHandler,
            Unmanaged.passUnretained(state).toOpaque(),
            Self.blockingFarEndProvider,
            Unmanaged.passUnretained(state).toOpaque())

        let firstStorage = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        firstStorage.initialize(repeating: 1, count: 4)
        defer {
            firstStorage.deinitialize(count: 4)
            firstStorage.deallocate()
        }
        let firstBuffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(firstBuffers.unsafeMutablePointer) }
        firstBuffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
            mData: firstStorage)

        let invocation = RenderInvocation(
            context: context, buffers: firstBuffers.unsafeMutablePointer, frames: 4)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            _ = yun_rt_echo_render_callback(
                UnsafeMutableRawPointer(invocation.context), &flags, &timestamp,
                0, invocation.frames, invocation.buffers)
            finished.signal()
        }
        var firstFinished = false
        defer {
            if !firstFinished {
                state.resume.signal()
                _ = finished.wait(timeout: .now() + TestGate.deadlock)
            }
        }
        try #require(state.entered.wait(timeout: .now() + TestGate.deadlock) == .success)

        var refused: [Float] = [1, 1, 1, 1, 77]
        let refusedStatus = refused.withUnsafeMutableBufferPointer { samples in
            let buffers = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(buffers.unsafeMutablePointer) }
            buffers[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32.max,
                mData: samples.baseAddress)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return yun_rt_echo_render_callback(
                UnsafeMutableRawPointer(context), &flags, &timestamp, 0,
                4, buffers.unsafeMutablePointer)
        }

        state.resume.signal()
        try #require(finished.wait(timeout: .now() + TestGate.deadlock) == .success)
        firstFinished = true

        #expect(refusedStatus == noErr)
        #expect(refused == [0, 0, 0, 0, 77])
        #expect(
            Array(UnsafeBufferPointer(start: firstStorage, count: 4))
                == [0.25, 0.25, 0.25, 0.25])
        #expect(yun_rt_echo_callback_context_overlaps(context) == 1)
        #expect(yun_rt_counter_load(counters.farEnd) == 1)
    }

    @Test("render failure count and status remain one coherent event")
    func renderDiagnosticsAreCoherent() throws {
        let diagnostics = DiagnosticsHandle(
            raw: try #require(yun_rt_echo_render_diagnostics_create()))
        defer { yun_rt_echo_render_diagnostics_free(diagnostics.raw) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for count in 1...100_000 {
                yun_rt_echo_render_diagnostics_record(
                    diagnostics.raw, -OSStatus(count))
            }
            finished.signal()
        }

        var torn = 0
        var complete = 0
        while finished.wait(timeout: .now()) == .timedOut {
            var count: UInt64 = 0
            var status = noErr
            if yun_rt_echo_render_diagnostics_load(
                diagnostics.raw, &count, &status)
            {
                complete += 1
                if count == 0 ? status != noErr : status != -OSStatus(count) {
                    torn += 1
                }
            }
        }
        var finalCount: UInt64 = 0
        var finalStatus = noErr
        #expect(
            yun_rt_echo_render_diagnostics_load(
                diagnostics.raw, &finalCount, &finalStatus))

        print(
            "AEC render diagnostics: \(complete) concurrent snapshots, "
                + "\(torn) torn pairs")
        #expect(torn == 0)
        #expect(finalCount == 100_000)
        #expect(finalStatus == -100_000)
    }

    @Test("the production handlers reach only their two raw rings")
    func productionHandlersUseRawRings() throws {
        let cancelled = try #require(yun_rt_ring_create(16))
        let farEnd = try #require(yun_rt_ring_create(16))
        defer {
            yun_rt_ring_free(farEnd)
            yun_rt_ring_free(cancelled)
        }
        let handles = UnsafeMutablePointer<RealtimeHandles>.allocate(capacity: 1)
        handles.initialize(
            to: RealtimeHandles(cancelledRing: cancelled, farEndRing: farEnd))
        defer {
            handles.deinitialize(count: 1)
            handles.deallocate()
        }

        let captured: [Float] = [0.25, -0.5, 0.75]
        var timestamp = AudioTimeStamp()
        captured.withUnsafeBufferPointer {
            EchoCancellationBridge.captureHandler(
                UnsafeMutableRawPointer(handles), $0.baseAddress!, UInt32($0.count),
                &timestamp)
        }
        var drained = [Float](repeating: 0, count: captured.count)
        let capturedCount = drained.withUnsafeMutableBufferPointer {
            yun_rt_ring_read(cancelled, $0.baseAddress!, UInt32($0.count))
        }

        let reference: [Float] = [.nan, .leastNonzeroMagnitude, -0.75]
        _ = reference.withUnsafeBufferPointer {
            yun_rt_ring_write(farEnd, $0.baseAddress!, UInt32($0.count))
        }
        var safe = [Float](repeating: 99, count: reference.count)
        let referenceCount = safe.withUnsafeMutableBufferPointer {
            EchoCancellationBridge.farEndProvider(
                UnsafeMutableRawPointer(handles), $0.baseAddress!, UInt32($0.count))
        }

        #expect(capturedCount == 3)
        #expect(drained == captured)
        #expect(referenceCount == 3)
        #expect(safe == [0, 0, -0.75])
    }

    #if DEBUG
        @Test(
            "the complete raw route callback stays allocation-free",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("the complete raw route callback stays allocation-free")
    #endif
    func rawRouteCallbackCost() throws {
        let frames = 512
        let iterations = 10_000
        let cancelled = try #require(yun_rt_ring_create(1_024))
        let farEnd = try #require(yun_rt_ring_create(1_024))
        defer {
            yun_rt_ring_free(farEnd)
            yun_rt_ring_free(cancelled)
        }
        let handles = UnsafeMutablePointer<RealtimeHandles>.allocate(capacity: 1)
        handles.initialize(
            to: RealtimeHandles(cancelledRing: cancelled, farEndRing: farEnd))
        defer {
            handles.deinitialize(count: 1)
            handles.deallocate()
        }
        let counters = try makeCounters()
        defer { counters.free() }
        let context = try #require(
            yun_rt_echo_callback_context_create(
                nil, UInt32(frames), nil, nil, counters.truncated, counters.input,
                counters.farEnd, counters.renderDiagnostics))
        defer { yun_rt_echo_callback_context_free(context) }
        yun_rt_echo_callback_context_bind(
            context, EchoCancellationBridge.captureHandler,
            UnsafeMutableRawPointer(handles), EchoCancellationBridge.farEndProvider,
            UnsafeMutableRawPointer(handles))

        let reference = (0..<frames).map {
            $0.isMultiple(of: 127) ? Float.nan : Float($0 % 31) / 31 - 0.5
        }
        var output = [Float](repeating: 0, count: frames)
        var drained = [Float](repeating: 0, count: frames)
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(buffers.unsafeMutablePointer) }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        reference.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                drained.withUnsafeMutableBufferPointer { consumer in
                    buffers[0] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                        mData: destination.baseAddress)
                    var flags = AudioUnitRenderActionFlags()
                    var timestamp = AudioTimeStamp()
                    for _ in 0..<iterations {
                        _ = yun_rt_ring_write(
                            farEnd, source.baseAddress!, UInt32(frames))
                        yun_rt_tripwire_mark_realtime(true)
                        _ = yun_rt_echo_render_callback(
                            UnsafeMutableRawPointer(context), &flags, &timestamp, 0,
                            UInt32(frames), buffers.unsafeMutablePointer)
                        EchoCancellationBridge.captureHandler(
                            UnsafeMutableRawPointer(handles), destination.baseAddress!,
                            UInt32(frames), &timestamp)
                        yun_rt_tripwire_mark_realtime(false)
                        _ = yun_rt_ring_read(
                            cancelled, consumer.baseAddress!, UInt32(frames))
                    }
                }
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        let nanosecondsPerCycle = elapsed / UInt64(iterations)

        print(
            "AEC raw route upper bound \(frames)f: \(nanosecondsPerCycle) ns/cycle, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0)
        #expect(nanosecondsPerCycle < 100_000)
        #expect(yun_rt_counter_load(counters.farEnd) == UInt64(iterations))
        #expect(yun_rt_ring_written(cancelled) == UInt32(frames * iterations))
        #expect(yun_rt_ring_dropped(cancelled) == 0)
        #expect(drained == output)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("structural lint wires Audio Unit entries directly to the raw C context")
    func audioUnitEntriesAreRaw() throws {
        // The callbacks themselves execute numerically throughout this suite;
        // `ci/check-aec-callback-arc.sh` separately inspects their Release
        // object code. This source lint checks only the Audio Unit registration
        // and bridge wiring that neither acceptance boundary can observe.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile:
                root + "Sources/YunAudioEngine/EchoCancellingCapture.swift",
            encoding: .utf8)
        let start = try #require(
            source.range(of: "var inputCallback = AURenderCallbackStruct"))
        let end = try #require(
            source.range(
                of: "// From here every stored property exists",
                range: start.upperBound..<source.endIndex))
        let entries = source[start.lowerBound..<end.lowerBound]

        #expect(entries.contains("inputProc: yun_rt_echo_input_callback"))
        #expect(entries.contains("inputProc: yun_rt_echo_render_callback"))
        #expect(!entries.contains("Unmanaged"))
        #expect(!entries.contains(".owner"))
        #expect(!entries.contains(".capture"))
        #expect(!entries.contains(".farEnd"))

        let bridge = try String(
            contentsOfFile:
                root + "Sources/YunAudioEngine/EchoCancellationBridge.swift",
            encoding: .utf8)
        let bridgeStart = try #require(bridge.range(of: "public func start() -> Bool"))
        let bridgeStop = try #require(
            bridge.range(
                of: "public func stop(timeout:",
                range: bridgeStart.upperBound..<bridge.endIndex))
        let route = bridge[bridgeStart.lowerBound..<bridgeStop.lowerBound]
        #expect(route.contains("capture.startRaw"))
        #expect(!route.contains("capture.start("))
    }

    private func makeCounters() throws -> Counters {
        Counters(
            truncated: try #require(yun_rt_counter_create(0)),
            input: try #require(yun_rt_counter_create(0)),
            farEnd: try #require(yun_rt_counter_create(0)),
            renderDiagnostics: try #require(
                yun_rt_echo_render_diagnostics_create()))
    }

    private struct Counters {
        let truncated: OpaquePointer
        let input: OpaquePointer
        let farEnd: OpaquePointer
        let renderDiagnostics: OpaquePointer

        func free() {
            yun_rt_counter_free(truncated)
            yun_rt_counter_free(input)
            yun_rt_counter_free(farEnd)
            yun_rt_echo_render_diagnostics_free(renderDiagnostics)
        }
    }
}
