import Foundation

/// Minimal wire codec. Length-delimited fields stay opaque until a known path is read.
enum Proto {
    enum Failure: Error { case malformed }
    static func varint(_ value: UInt64) -> Data {
        var n = value, bytes = Data()
        while n > 127 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
        bytes.append(UInt8(n)); return bytes
    }
    static func int(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func fields(_ data: Data) throws -> [Int: [Data]] {
        let b = [UInt8](data); var index = 0; var result: [Int: [Data]] = [:]
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < b.count else { throw Failure.malformed }
                let byte = b[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw Failure.malformed }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw Failure.malformed
        }
        while index < b.count {
            let tag = try read(); guard tag >> 3 > 0, tag >> 3 <= 536870911 else { throw Failure.malformed }
            let field = Int(tag >> 3); let length: Int
            switch tag & 7 {
            case 0: _ = try read(); continue
            case 1: length = 8
            case 5: length = 4
            case 2:
                let n = try read(); guard n <= UInt64(b.count - index) else { throw Failure.malformed }; length = Int(n)
            default: throw Failure.malformed
            }
            guard length <= b.count - index else { throw Failure.malformed }
            if tag & 7 == 2 { result[field, default: []].append(Data(b[index..<index+length])) }
            index += length
        }
        return result
    }
    static func string(at path: [Int], in data: Data) throws -> String? {
        var current = data
        for field in path { guard let next = try fields(current)[field]?.first else { return nil }; current = next }
        guard let value = String(data: current, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}
