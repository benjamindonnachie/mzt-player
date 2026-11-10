import Foundation

struct TapeHeader {
    private static let headerSize = 128
    private static let imageLimit = 1024 * 1024

    let filename: String?
    let attribute: UInt8

    private init?(bytes: Data.SubSequence) {
        guard bytes.count == Self.headerSize, let attribute = bytes.first else { return nil }
        self.attribute = attribute
        // Keep the name field separate from the size field, even without a terminator.
        let name = bytes.dropFirst().prefix(17).prefix { $0 != 0x0d && $0 != 0 }
        let display = name.map { byte in
            (0x20...0x7e).contains(byte)
                ? String(UnicodeScalar(byte))
                : String(format: "\\x%02X", Int(byte))
        }.joined().trimmingCharacters(in: .whitespaces)
        filename = display.isEmpty ? nil : display
    }

    static func readImage(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: imageLimit + 1) ?? Data()
        guard data.count <= imageLimit else {
            throw invalidImage("The tape image exceeds the 1 MiB safety limit.")
        }
        return data
    }

    static func records(in bytes: Data) throws -> [TapeHeader] {
        var records: [TapeHeader] = []
        var offset = bytes.startIndex
        repeat {
            let number = records.count + 1
            guard bytes.endIndex - offset >= headerSize,
                  let header = TapeHeader(bytes: bytes[offset..<(offset + headerSize)]) else {
                throw invalidImage("Tape record \(number) does not contain a complete 128-byte header.")
            }
            let payloadSize = Int(bytes[offset + 0x12]) | (Int(bytes[offset + 0x13]) << 8)
            offset += headerSize
            guard bytes.endIndex - offset >= payloadSize else {
                throw invalidImage("Tape record \(number) has a truncated payload: expected \(payloadSize) bytes, found \(bytes.endIndex - offset).")
            }
            records.append(header)
            offset += payloadSize
        } while offset < bytes.endIndex
        return records
    }

    private static func invalidImage(_ message: String) -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: message])
    }

    var fileType: String {
        switch attribute {
        case 0x01: return "Machine code"
        case 0x02: return "MZ-80 BASIC program"
        case 0x03: return "MZ-80 data file"
        case 0x04: return "MZ-700 data file"
        case 0x05: return "MZ-700 BASIC program"
        default: return "Unknown type"
        }
    }

    var loadingHint: String {
        switch attribute {
        case 0x01: return "Usually load directly from the ROM monitor (L)."
        case 0x02: return "Start a compatible MZ-80 BASIC interpreter first, then use LOAD."
        case 0x05: return "Start a compatible MZ-700 BASIC interpreter first, then use LOAD."
        case 0x03, 0x04: return "Use the BASIC program that reads this data file."
        default: return "The header does not identify which loader to use."
        }
    }

    var typeDescription: String {
        "\(fileType) (\(String(format: "0x%02X", Int(attribute))))"
    }
}
