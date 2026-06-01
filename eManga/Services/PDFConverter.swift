import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OSLog

enum ConversionError: LocalizedError {
    case cannotOpenPDF
    case emptyPDF
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpenPDF: return String(localized: "Cannot open PDF file.")
        case .emptyPDF:      return String(localized: "PDF contains no pages.")
        case .renderFailed:  return String(localized: "Failed to render a page.")
        }
    }
}

/// Events emitted by `PDFConverter.convert`.
enum ConversionEvent: Sendable {
    /// Intermediate progress update.
    case progress(fraction: Double, message: String)
    /// Conversion finished successfully.
    case completed
}

struct PDFConverter {

    /// Converts a PDF to the desired format(s), streaming `ConversionEvent` values.
    /// Iterate with `for try await event in PDFConverter.convert(...)`.
    static func convert(
        pdf url: URL,
        outputDir: URL,
        settings: ConversionSettings
    ) -> AsyncThrowingStream<ConversionEvent, Error> {
        // Capture ALL settings values upfront — ConversionSettings is @Observable but not Sendable
        let renderWidth   = settings.effectiveWidth
        let renderQuality = settings.effectiveQuality
        let maxFileSizeMB = settings.maxFileSizeMB
        let outputFormat  = settings.outputFormat
        let author        = settings.author
        let direction     = settings.direction
        
        let formatRaw = settings.outputFormat.rawValue
        let resolutionRaw = settings.resolution.rawValue
        
        return AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    Logger.converter.info(
                        "convert() — file: \(url.lastPathComponent, privacy: .private(mask: .hash)), format: \(formatRaw, privacy: .public), resolution: \(resolutionRaw, privacy: .public), width: \(renderWidth, privacy: .public)px, quality: \(renderQuality, privacy: .public), maxSizeMB: \(maxFileSizeMB, privacy: .public)"
                    )

                    guard let cgDoc = CGPDFDocument(url as CFURL) else {
                        Logger.converter.error("Cannot open PDF: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                        throw ConversionError.cannotOpenPDF
                    }
                    let pageCount = cgDoc.numberOfPages
                    guard pageCount > 0 else {
                        Logger.converter.error("PDF has no pages: \(url.lastPathComponent, privacy: .private(mask: .hash))")
                        throw ConversionError.emptyPDF
                    }

                    Logger.converter.info("PDF opened — \(pageCount, privacy: .public) page(s)")

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("eManga_\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    // 1. Render each PDF page to JPEG — concurrently across CPU cores
                    continuation.yield(.progress(fraction: 0.0, message: String(localized: "Rendering pages…")))

                    // Pre-allocate destination paths in page order so results stay sorted
                    let imageURLs: [URL] = (0 ..< pageCount).map { i in
                        tempDir.appendingPathComponent(String(format: "page-%04d.jpg", i + 1))
                    }

                    // Divide pages into chunks — one chunk per CPU core; each chunk gets its own CGPDFDocument
                    // CGPDFDocument/CGPDFPage are CoreGraphics types fully concurrent-safe
                    let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, pageCount)
                    let chunkSize   = max(1, (pageCount + concurrency - 1) / concurrency)

                    let renderClock = ContinuousClock()
                    let renderStart = renderClock.now

                    let counter = ProgressCounter()

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for chunkIdx in 0 ..< concurrency {
                            let lo = chunkIdx * chunkSize
                            let hi = min(lo + chunkSize, pageCount)
                            guard lo < pageCount else { break }

                            group.addTask {
                                guard let cgDoc = CGPDFDocument(url as CFURL) else {
                                    throw ConversionError.cannotOpenPDF
                                }
                                for i in lo ..< hi {
                                    // CGPDFDocument pages are 1-indexed
                                    guard let page = cgDoc.page(at: i + 1) else {
                                        Logger.converter.notice("Skipping page \(i + 1, privacy: .public) — CGPDFPage unavailable")
                                        continue
                                    }
                                    let pageStart = renderClock.now
                                    try autoreleasepool {
                                        try PDFConverter.renderPage(page, width: renderWidth, quality: renderQuality, to: imageURLs[i])
                                    }
                                    Logger.converter.debug(
                                        "Rendered page \(i + 1, privacy: .public)/\(pageCount, privacy: .public) in \((renderClock.now - pageStart).formatted(.units(allowed: [.milliseconds])), privacy: .public)"
                                    )
                                    let done = await counter.increment()
                                    if done % 5 == 0 || done == pageCount {
                                        continuation.yield(.progress(
                                            fraction: Double(done) / Double(pageCount) * 0.65,
                                            message:  String(localized: "Rendering page \(done) / \(pageCount)…")
                                        ))
                                    }
                                    await Task.yield()
                                }
                            }
                        }
                        try await group.waitForAll()
                    }

                    // Collect rendered files in page order, skipping any that failed
                    let renderedImages = imageURLs.filter {
                        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                    }

                    Logger.converter.info(
                        "Rendered \(renderedImages.count, privacy: .public) page(s) in \(renderClock.now - renderStart, privacy: .public)"
                    )

                    // 2. If a size limit is set, recompress images at a lower quality to meet it
                    if maxFileSizeMB > 0 {
                        let limitBytes  = maxFileSizeMB * 1_024 * 1_024
                        let actualBytes = renderedImages.reduce(0) { $0 + fileBytes($1) }
                        if actualBytes > limitBytes {
                            // Target 95% of the limit to leave a small margin for archive overhead
                            let ratio            = Double(limitBytes) * 0.95 / Double(actualBytes)
                            let adjustedQuality  = max(0.1, renderQuality * ratio)
                            Logger.converter.notice(
                                "Size limit: \(actualBytes / 1_024 / 1_024, privacy: .public) MB > \(maxFileSizeMB, privacy: .public) MB target; recompressing at quality \(String(format: "%.2f", adjustedQuality), privacy: .public)"
                            )
                            continuation.yield(.progress(fraction: 0.66, message: String(localized: "Recompressing images to meet size limit…")))
                            try await PDFConverter.recompress(renderedImages, quality: adjustedQuality)
                            let newBytes = renderedImages.reduce(0) { $0 + fileBytes($1) }
                            Logger.converter.notice(
                                "After recompression: \(newBytes / 1_024 / 1_024, privacy: .public) MB"
                            )
                        } else {
                            Logger.converter.info(
                                "Size OK: \(actualBytes / 1_024 / 1_024, privacy: .public) MB ≤ \(maxFileSizeMB, privacy: .public) MB"
                            )
                        }
                    }

                    // 3. Build output file(s) from all rendered pages
                    let cleanTitle = sanitize(url.deletingPathExtension().lastPathComponent)

                    continuation.yield(.progress(fraction: 0.65, message: String(localized: "Building \(cleanTitle)…")))
                    Logger.converter.info("Building output — \(renderedImages.count, privacy: .public) page(s)")

                    if outputFormat == .cbz || outputFormat == .all {
                        let out = outputDir.appendingPathComponent("\(cleanTitle).cbz")
                        try await CBZBuilder.build(images: renderedImages, to: out)
                        Logger.converter.notice(
                            "CBZ written: \(out.lastPathComponent, privacy: .private(mask: .hash)) (\(fileSizeKB(out), privacy: .public) KB)"
                        )
                    }

                    if outputFormat == .epub || outputFormat == .all {
                        let out = outputDir.appendingPathComponent("\(cleanTitle).epub")
                        try await EPUBBuilder.build(
                            images:    renderedImages,
                            title:     url.deletingPathExtension().lastPathComponent,
                            author:    author,
                            direction: direction,
                            to:        out
                        )
                        Logger.converter.notice(
                            "EPUB written: \(out.lastPathComponent, privacy: .private(mask: .hash)) (\(fileSizeKB(out), privacy: .public) KB)"
                        )
                    }

                    Logger.converter.notice("convert() complete")
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Page rendering

    /// Renders a single PDF page to a JPEG file.
    /// Uses only CoreGraphics safe to call concurrently.
    private nonisolated static func renderPage(_ page: CGPDFPage, width: Int, quality: Double, to destURL: URL) throws {
        let mediaBox    = page.getBoxRect(.mediaBox)
        let scale       = CGFloat(width) / mediaBox.width
        let pixelWidth  = width
        let pixelHeight = Int(ceil(mediaBox.height * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            Logger.converter.error("CGContext creation failed for page (\(pixelWidth, privacy: .public)×\(pixelHeight, privacy: .public))")
            throw ConversionError.renderFailed
        }

        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Scale to target width and draw — CGPDFPage and CGBitmapContext share bottom-left origin
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)

        guard let cgImage = ctx.makeImage() else {
            Logger.converter.error("ctx.makeImage() returned nil")
            throw ConversionError.renderFailed
        }

        guard let dest = CGImageDestinationCreateWithURL(
            destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            Logger.converter.error("CGImageDestinationCreateWithURL failed")
            throw ConversionError.renderFailed
        }

        CGImageDestinationAddImage(dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            Logger.converter.error("CGImageDestinationFinalize failed")
            throw ConversionError.renderFailed
        }
    }

    // MARK: - Helpers

    /// Recompresses all JPEG images in-place at the given quality level.
    /// Used to meet a target file size after the initial render.
    private nonisolated static func recompress(_ urls: [URL], quality: Double) async throws {
        for url in urls {
            try autoreleasepool {
                let cfURL = url as CFURL
                guard
                    let source = CGImageSourceCreateWithURL(cfURL, nil),
                    let image  = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let dest   = CGImageDestinationCreateWithURL(cfURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw ConversionError.renderFailed }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ConversionError.renderFailed }
            }
            await Task.yield()
        }
    }

    /// Returns file size in bytes using FileManager (reliable in sandboxed temp directories).
    private nonisolated static func fileBytes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
    }

    /// Returns file size in KB for logging.
    private nonisolated static func fileSizeKB(_ url: URL) -> Int { fileBytes(url) / 1_024 }

    private nonisolated static func sanitize(_ name: String) -> String {
        name.replacing(" ", with: "_")
            .replacing(/[\/\\?%*:|"<>]/, with: "_")
    }
}

// MARK: - Helpers

/// Thread-safe counter for tracking concurrent render progress.
private actor ProgressCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}
