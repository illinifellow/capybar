/// Text formats the items and menus share: throughput and byte counts.
import Foundation

private let RATE_UNITS = ["B/s", "KB/s", "MB/s", "GB/s"]

/// The longest texts `formatRate` produces in each unit, for sizing a label that must never
/// change width.
let WIDEST_RATE_TEXTS = RATE_UNITS.enumerated().flatMap { index, unit in index == 0 ? ["999 \(unit)"] : ["99.9 \(unit)", "999 \(unit)"] }

/// Formats bytes per second as "12.3 KB/s": one decimal below 100, none from 100 up, never more
/// than three digits (a value that would round to 1000 moves to the next unit).
/// @param bytesPerSecond Throughput; a negative value shows as 0.
/// @returns The formatted rate.
func formatRate(_ bytesPerSecond: Double) -> String {
    var value = max(bytesPerSecond, 0), unitIndex = 0
    while value >= 999.5 && unitIndex < RATE_UNITS.count - 1 { value /= 1000; unitIndex += 1 }
    return value >= 99.95 || unitIndex == 0 ? "\(Int(value.rounded())) \(RATE_UNITS[unitIndex])" : String(format: "%.1f %@", value, RATE_UNITS[unitIndex])
}

/// Reads a C string from a fixed-size buffer.
/// @param characters The buffer, null-terminated within its length. @returns The text before the first null.
func string(fromNullTerminated characters: [CChar]) -> String {
    String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Formats a byte count as "1.2 GB".
/// @param bytes Size. @returns The formatted size.
func formatBytes(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
