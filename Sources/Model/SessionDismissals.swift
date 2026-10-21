import Foundation
import Darwin

/// App-owned fingerprints, separate from hook state and conversation history.
enum SessionDismissals {
    static func load(at path: String) throws -> [String: String] {
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    static func save(_ versions: [String: String], at path: String) throws {
        let fm = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(versions)
        let temporary = path + "." + UUID().uuidString + ".tmp"
        guard fm.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(atPath: temporary) }
        guard rename(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
