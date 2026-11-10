import Foundation

struct TapeHeader {
    let filename: String?
    let attribute: UInt8

    init?(bytes: Data) {
        guard bytes.count >= 128, let attribute = bytes.first else { return nil }
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

    static func read(from url: URL) throws -> TapeHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 128), let header = TapeHeader(bytes: bytes) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The tape image does not contain a complete 128-byte header."
            ])
        }
        return header
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
