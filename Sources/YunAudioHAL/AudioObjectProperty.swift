import CoreAudio
import Foundation

// MARK: - Errors

public enum AudioHALError: Error, CustomStringConvertible, Sendable {
    case status(OSStatus, selector: AudioObjectPropertySelector, object: AudioObjectID)
    case missingProperty(selector: AudioObjectPropertySelector, object: AudioObjectID)
    case unexpectedSize(expected: Int, actual: Int, selector: AudioObjectPropertySelector)
    case misalignedArraySize(
        actual: Int, elementStride: Int, selector: AudioObjectPropertySelector)
    case propertyTooLarge(
        limit: Int, actual: Int, selector: AudioObjectPropertySelector)
    case tooManyElements(
        limit: Int, actual: Int, selector: AudioObjectPropertySelector)

    public var description: String {
        switch self {
        case let .status(status, selector, object):
            "CoreAudio error \(fourCharDescription(status)) reading \(fourCharDescription(selector)) on object \(object)"
        case let .missingProperty(selector, object):
            "object \(object) has no property \(fourCharDescription(selector))"
        case let .unexpectedSize(expected, actual, selector):
            "property \(fourCharDescription(selector)) returned \(actual) bytes, expected \(expected)"
        case let .misalignedArraySize(actual, stride, selector):
            "property \(fourCharDescription(selector)) returned \(actual) bytes for \(stride)-byte elements"
        case let .propertyTooLarge(limit, actual, selector):
            "property \(fourCharDescription(selector)) requested \(actual) bytes, above the \(limit)-byte limit"
        case let .tooManyElements(limit, actual, selector):
            "property \(fourCharDescription(selector)) returned \(actual) elements, above the \(limit)-element limit"
        }
    }
}

/// Bounds and validates the two variable-size answers around a HAL array read.
///
/// Device and process lists are untrusted cross-process data. A corrupt size
/// must not become an arbitrary allocation, and a shortened byte count must
/// not be rounded down into a persuasive partial list.
enum HALArrayReadPolicy {
    static let maximumBytes = 1 << 20
    static let maximumAttempts = 3

    static func elementCount<Value>(
        byteCount: Int, for _: Value.Type,
        selector: AudioObjectPropertySelector,
        capacity: Int? = nil
    ) throws -> Int {
        let stride = MemoryLayout<Value>.stride
        guard byteCount <= maximumBytes else {
            throw AudioHALError.propertyTooLarge(
                limit: maximumBytes, actual: byteCount, selector: selector)
        }
        if let capacity, byteCount > capacity {
            throw AudioHALError.unexpectedSize(
                expected: capacity, actual: byteCount, selector: selector)
        }
        guard stride > 0, byteCount >= 0, byteCount.isMultiple(of: stride) else {
            throw AudioHALError.misalignedArraySize(
                actual: byteCount, elementStride: stride, selector: selector)
        }
        return byteCount / stride
    }
}

/// Property-specific ceilings applied before callers perform one HAL query per
/// returned object. The byte ceiling prevents a giant allocation; these stop a
/// still-valid one-megabyte list from becoming hundreds of thousands of
/// synchronous messages to `coreaudiod`.
enum HALSemanticArrayPolicy {
    static let maximumDevices = 4_096
    static let maximumProcesses = 16_384
    static let maximumTaps = 4_096
    static let maximumStreamsPerDevice = 256
    static let maximumFormatsPerObject = 4_096
    static let maximumOwnedObjects = 4_096
    static let maximumProcessDevices = 256

    static func validate(
        count: Int, maximum: Int, selector: AudioObjectPropertySelector
    ) throws {
        guard count >= 0, maximum >= 0, count <= maximum else {
            throw AudioHALError.tooManyElements(
                limit: max(0, maximum), actual: count, selector: selector)
        }
    }
}

/// Validates the trailing-array layout of `AudioBufferList` before any buffer
/// entry is dereferenced.
///
/// Unlike an ordinary HAL array this structure declares its own element count
/// in the first word. Both the outer byte count and the inner count come from
/// another process; trusting either one can turn a device census into an
/// unbounded allocation or an out-of-bounds walk.
enum HALAudioBufferListPolicy {
    static let headerBytes =
        MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride

    static func bufferCount(
        byteCount: Int,
        declaredCount: UInt32,
        selector: AudioObjectPropertySelector
    ) throws -> Int {
        _ = try HALArrayReadPolicy.elementCount(
            byteCount: byteCount, for: UInt8.self, selector: selector)
        guard byteCount >= headerBytes else {
            throw AudioHALError.unexpectedSize(
                expected: headerBytes, actual: byteCount, selector: selector)
        }
        let count = Int(declaredCount)
        let (payloadBytes, overflowed) = count.multipliedReportingOverflow(
            by: MemoryLayout<AudioBuffer>.stride)
        let (requiredBytes, additionOverflowed) = headerBytes.addingReportingOverflow(
            payloadBytes)
        guard !overflowed, !additionOverflowed, requiredBytes <= byteCount else {
            throw AudioHALError.unexpectedSize(
                expected: overflowed || additionOverflowed ? Int.max : requiredBytes,
                actual: byteCount, selector: selector)
        }
        return count
    }
}

/// Renders a four-char code as `'abcd'` when printable, else as a signed
/// integer. CoreAudio selectors and error codes are both four-char codes, and
/// reading them as decimal makes every log message useless.
public func fourCharDescription(_ value: some BinaryInteger) -> String {
    let raw = UInt32(truncatingIfNeeded: Int64(value))
    let bytes = [
        UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
        UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF),
    ]
    if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
    return String(Int32(bitPattern: raw))
}

// MARK: - Property addressing

/// A typed CoreAudio property address.
///
/// The phantom `Value` keeps the selector and the type it yields together, so
/// a caller cannot ask for `kAudioDevicePropertyNominalSampleRate` as a `UInt32`
/// and silently read four bytes of a `Float64`.
public struct AudioProperty<Value>: Sendable {
    public var selector: AudioObjectPropertySelector
    public var scope: AudioObjectPropertyScope
    public var element: AudioObjectPropertyElement

    public init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// The same property read through a different scope.
    public func scoped(to scope: AudioObjectPropertyScope) -> Self {
        var copy = self
        copy.scope = scope
        return copy
    }
}

// MARK: - Reading and writing

extension AudioObjectID {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public func has(_ property: AudioProperty<some Any>) -> Bool {
        var address = property.address
        return AudioObjectHasProperty(self, &address)
    }

    public func isSettable(_ property: AudioProperty<some Any>) -> Bool {
        var address = property.address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    /// Byte size the property will return right now. Variable-length properties
    /// (device lists, stream configurations, format lists) must be sized before
    /// every read — the answer changes as hardware comes and goes.
    public func dataSize(of property: AudioProperty<some Any>) throws -> Int {
        var address = property.address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioHALError.status(status, selector: property.selector, object: self)
        }
        return Int(size)
    }

    /// Reads a fixed-layout value.
    public func value<Value>(of property: AudioProperty<Value>) throws -> Value {
        var address = property.address
        var size = UInt32(MemoryLayout<Value>.size)
        let buffer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            throw AudioHALError.status(status, selector: property.selector, object: self)
        }
        guard size == UInt32(MemoryLayout<Value>.size) else {
            throw AudioHALError.unexpectedSize(
                expected: MemoryLayout<Value>.size, actual: Int(size),
                selector: property.selector)
        }
        return buffer.pointee
    }

    /// Reads a variable-length array of fixed-layout values.
    public func array<Value>(of property: AudioProperty<Value>) throws -> [Value] {
        for attempt in 0..<HALArrayReadPolicy.maximumAttempts {
            let byteCount = try dataSize(of: property)
            let count = try HALArrayReadPolicy.elementCount(
                byteCount: byteCount, for: Value.self, selector: property.selector)
            guard count > 0 else { return [] }

            var address = property.address
            var size = UInt32(byteCount)
            let buffer = UnsafeMutableBufferPointer<Value>.allocate(capacity: count)
            defer { buffer.deallocate() }

            let status = AudioObjectGetPropertyData(
                self, &address, 0, nil, &size, buffer.baseAddress!)
            if status == kAudioHardwareBadPropertySizeError,
                attempt + 1 < HALArrayReadPolicy.maximumAttempts
            {
                continue
            }
            guard status == noErr else {
                throw AudioHALError.status(
                    status, selector: property.selector, object: self)
            }
            let returnedCount = try HALArrayReadPolicy.elementCount(
                byteCount: Int(size), for: Value.self, selector: property.selector,
                capacity: byteCount)
            return Array(buffer[0..<returnedCount])
        }
        preconditionFailure("the bounded HAL array retry loop did not return")
    }

    /// Reads an array and rejects a semantically impossible object count before
    /// a caller turns every entry into another synchronous HAL operation.
    public func array<Value>(
        of property: AudioProperty<Value>, maximumCount: Int
    ) throws -> [Value] {
        let values = try array(of: property)
        try HALSemanticArrayPolicy.validate(
            count: values.count, maximum: maximumCount, selector: property.selector)
        return values
    }

    /// Reads a `CFString` property.
    ///
    /// CoreAudio hands these back at +1 — the headers say "the caller is
    /// responsible for releasing the returned CFObject" — so the reference is
    /// taken through `Unmanaged` rather than relying on implicit bridging.
    public func string(of property: AudioProperty<CFString>) throws -> String {
        var address = property.address
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        var unmanaged: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw AudioHALError.status(status, selector: property.selector, object: self)
        }
        guard let unmanaged else {
            throw AudioHALError.missingProperty(selector: property.selector, object: self)
        }
        return unmanaged.takeRetainedValue() as String
    }

    /// Reads a property, returning nil instead of throwing when the object
    /// simply does not implement it. Optional hardware traits — clock domain,
    /// transport type, workgroups — are absent often enough that treating
    /// absence as an error would bury real failures.
    public func optionalValue<Value>(of property: AudioProperty<Value>) -> Value? {
        guard has(property) else { return nil }
        return try? value(of: property)
    }

    public func optionalString(of property: AudioProperty<CFString>) -> String? {
        guard has(property) else { return nil }
        return try? string(of: property)
    }

    public func setValue<Value>(_ newValue: Value, for property: AudioProperty<Value>) throws {
        var address = property.address
        let status = withUnsafePointer(to: newValue) { pointer in
            AudioObjectSetPropertyData(
                self, &address, 0, nil, UInt32(MemoryLayout<Value>.size),
                UnsafeRawPointer(pointer))
        }
        guard status == noErr else {
            throw AudioHALError.status(status, selector: property.selector, object: self)
        }
    }
}
