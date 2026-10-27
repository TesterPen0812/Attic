import QuartzCore

/// CGEventTimestamp is nanoseconds, not raw mach ticks. NSEvent.timestamp and
/// CACurrentMediaTime are seconds on the mach-absolute uptime clock.
enum LabClock {
    static func eventTimestamp(seconds: Double = CACurrentMediaTime()) -> UInt64 { UInt64(seconds * 1e9) }
    static func seconds(eventTimestamp: UInt64) -> Double { Double(eventTimestamp) / 1e9 }
}
func labNow() -> Double { CACurrentMediaTime() }
