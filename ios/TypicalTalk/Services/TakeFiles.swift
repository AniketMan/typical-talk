import Foundation

/// Where takes live on disk.
///
/// Application Support, not the temporary directory: the system may clear
/// temporary files at any time, and a take that has been recorded but not yet
/// uploaded must survive that.
enum TakeFiles {
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func fileName(for takeID: UUID) -> String {
        "\(takeID.uuidString.lowercased()).mov"
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// Takes a freshly recorded file into the takes folder. Moves rather than
    /// copies, because a take can be tens of megabytes.
    static func adopt(_ source: URL, as takeID: UUID) -> String? {
        let name = fileName(for: takeID)
        let destination = url(for: name)
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            do { try manager.copyItem(at: source, to: destination) } catch { return nil }
        }
        return name
    }

    /// Moves a finished download into place. Called from the URLSession
    /// delegate, which must finish with the temporary file before it returns.
    static func install(download location: URL, as takeID: UUID) -> String? {
        let name = fileName(for: takeID)
        let destination = url(for: name)
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: location, to: destination)
            // Other people's takes can be fetched again, so they stay out of
            // the device backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = destination
            try? target.setResourceValues(values)
            return name
        } catch {
            return nil
        }
    }

    static func remove(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Everything, for sign out and account deletion.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func size(of fileName: String) -> Int {
        (try? url(for: fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
