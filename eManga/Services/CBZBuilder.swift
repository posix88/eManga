import Foundation
import ZIPFoundation
import OSLog

struct CBZBuilder {
    static func build(images: [URL], to destination: URL) throws {
        Logger.cbzBuilder.info(
            "Building CBZ — \(images.count, privacy: .public) image(s) → \(destination.lastPathComponent, privacy: .private(mask: .hash))"
        )
        let clock = ContinuousClock()
        let start = clock.now

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            Logger.cbzBuilder.debug("Removing existing file at destination")
            try fm.removeItem(at: destination)
        }

        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)
        for (idx, imageURL) in images.enumerated() {
            let entryName = String(format: "page-%04d.jpg", idx + 1)
            // Store JPEGs without re-compression — they are already compressed and deflate yields no benefit
            try archive.addEntry(with: entryName, fileURL: imageURL, compressionMethod: .none)
        }

        let elapsed = clock.now - start
        let sizeKB  = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 / 1024 } ?? 0
        Logger.cbzBuilder.notice(
            "CBZ built in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public) — \(sizeKB, privacy: .public) KB"
        )
    }
}

enum ArchiveError: LocalizedError {
    case cannotCreate
    var errorDescription: String? { String(localized: "Cannot create archive file.") }
}
