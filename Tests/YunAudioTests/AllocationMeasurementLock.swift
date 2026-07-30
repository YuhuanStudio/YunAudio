import Foundation

/// Serialises tests that read the process-wide allocation tripwire.
///
/// Swift Testing may run unrelated suites in parallel. The tripwire's counter
/// is deliberately global because the shipping assertion watches every audio
/// thread, so two benchmarks taking before/after readings at once attribute
/// each other's allocations to both operations.
enum AllocationMeasurementLock {
    static let shared = NSLock()
}
