/// The ICMP echo exchange the ping item makes: building a request, recognising its reply among
/// everything an ICMP datagram socket receives, and the receive timeout for the remaining wait.
import Darwin

private let ECHO_REQUEST_TYPE: UInt8 = 8
private let ECHO_REPLY_TYPE: UInt8 = 0
private let ICMP_HEADER_LENGTH = 8
private let IPV4_SOURCE_OFFSET = 12
private let PAYLOAD_BYTE: UInt8 = 0x63

/// Computes the internet checksum of an ICMP message (RFC 1071).
/// @param bytes The message with its checksum field zeroed. @returns The checksum.
func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[index]) << 8 | (index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0)
    }
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

/// Builds an echo request: type 8, code 0, checksum, identifier, sequence, then the payload.
/// @param identifier Identifies this program's pings. @param sequence Identifies this ping.
/// @param payloadLength Payload bytes after the header.
/// @returns The message, checksum filled in.
func makeEchoRequest(identifier: UInt16, sequence: UInt16, payloadLength: Int) -> [UInt8] {
    var packet: [UInt8] = [ECHO_REQUEST_TYPE, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        + [UInt8](repeating: PAYLOAD_BYTE, count: payloadLength)
    let checksum = icmpChecksum(packet)
    packet[2] = UInt8(checksum >> 8)
    packet[3] = UInt8(checksum & 0xFF)
    return packet
}

/// Whether a datagram read from an ICMP socket is the reply to one particular echo request. The
/// socket also receives replies meant for other programs pinging at the same time, so the
/// source, type, identifier and sequence must all match.
/// @param datagram What `recv` returned: the IPv4 header, then the ICMP message.
/// @param source The pinged host as four bytes. @param identifier The request's identifier. @param sequence The request's sequence.
/// @returns True only for that request's echo reply.
func isEchoReply(_ datagram: ArraySlice<UInt8>, from source: [UInt8], identifier: UInt16, sequence: UInt16) -> Bool {
    let bytes = Array(datagram)
    guard let first = bytes.first else { return false }
    let headerLength = Int(first & 0x0F) * 4
    guard bytes.count >= headerLength + ICMP_HEADER_LENGTH, headerLength >= IPV4_SOURCE_OFFSET + 4 else { return false }
    let icmp = headerLength
    return Array(bytes[IPV4_SOURCE_OFFSET..<IPV4_SOURCE_OFFSET + 4]) == source
        && bytes[icmp] == ECHO_REPLY_TYPE
        && UInt16(bytes[icmp + 4]) << 8 | UInt16(bytes[icmp + 5]) == identifier
        && UInt16(bytes[icmp + 6]) << 8 | UInt16(bytes[icmp + 7]) == sequence
}

/// Converts a wait in seconds to a socket timeout, keeping the fraction (0.5 s is 0 s and
/// 500000 µs, not 0 s, which would mean no timeout at all).
/// @param seconds The wait, above 0. @returns The timeval.
func socketTimeout(seconds: Double) -> timeval {
    let microseconds = Int((seconds * 1_000_000).rounded())
    return timeval(tv_sec: microseconds / 1_000_000, tv_usec: Int32(microseconds % 1_000_000))
}
