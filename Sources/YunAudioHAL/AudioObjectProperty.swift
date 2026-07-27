import CoreAudio
import Foundation

// MARK: - Errors

public enum AudioHALError: Error, CustomStringConvertible, Sendable {
    case status(OSStatus, selector: AudioObjectPropertySelector, object: AudioObjectID)
    case missingProperty(selector: AudioObjectPropertySelector, object: AudioObjectID)
    case unexpectedSize(expected: Int, actual: Int, selector: AudioObjectPropertySelector)

    public var description: String {
        switch self {
        case let .status(status, selector, object):
            "CoreAudio error \(fourCharDescription(status)) reading \(fourCharDescription(selector)) on object \(object)"
        case let .missingProperty(selector, object):
            "object \(object) has no property \(fourCharDescription(selector))"
        case let .unexpectedSize(expected, actual, selector):
            "property \(fourCharDescription(selector)) returned \(actual) bytes, expected \(expected)"
        }
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
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
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
                expected: MemoryLayout<Value>.size, actual: Int(size), selector: property.selector)
        }
        return buffer.pointee
    }

    /// Reads a variable-length array of fixed-layout values.
    public func array<Value>(of property: AudioProperty<Value>) throws -> [Value] {
        let byteCount = try dataSize(of: property)
        let count = byteCount / MemoryLayout<Value>.stride
        guard count > 0 else { return [] }

        var address = property.address
        var size = UInt32(byteCount)
        let buffer = UnsafeMutableBufferPointer<Value>.allocate(capacity: count)
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        guard status == noErr else {
            throw AudioHALError.status(status, selector: property.selector, object: self)
        }
        return Array(buffer[0..<(Int(size) / MemoryLayout<Value>.stride)])
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
