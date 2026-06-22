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
    private nonisolated static let renderPermitPool = RenderPermitPool(
        limit: max(1, ProcessInfo.processInfo.activeProcessorCount)
    )

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
        let sizeLimitMode = settings.sizeLimitMode
        let imageEncoding = settings.imageEncoding
        let outputFormat  = settings.outputFormat
        let author        = settings.author
        let language      = settings.language.code
        let direction     = settings.direction
        
        let formatRaw = settings.outputFormat.rawValue
        let resolutionRaw = settings.resolution.rawValue
        
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    Logger.converter.info(
                        "convert() — file: \(url.lastPathComponent, privacy: .private(mask: .hash)), format: \(formatRaw, privacy: .public), resolution: \(resolutionRaw, privacy: .public), width: \(renderWidth, privacy: .public)px, quality: \(renderQuality, privacy: .public), maxSizeMB: \(maxFileSizeMB, privacy: .public)"
                    )

                    try Task.checkCancellation()
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

                    // 1. Render each PDF page to JPEG.
                    continuation.yield(.progress(fraction: 0.0, message: String(localized: "Rendering pages…")))
                    let renderClock = ContinuousClock()
                    let renderStart = renderClock.now
                    var renderedImages = try await renderDocument(
                        pdf: url,
                        sampleDocument: cgDoc,
                        pageCount: pageCount,
                        width: renderWidth,
                        quality: renderQuality,
                        imageEncoding: imageEncoding,
                        tempDir: tempDir,
                        progressStart: 0.0,
                        progressSpan: 0.60,
                        continuation: continuation
                    )

                    Logger.converter.info(
                        "Rendered \(renderedImages.count, privacy: .public) page(s) in \(renderClock.now - renderStart, privacy: .public)"
                    )

                    guard !renderedImages.isEmpty else {
                        throw ConversionError.renderFailed
                    }

                    // 2. If a size limit is set, optimize images before packaging.
                    if maxFileSizeMB > 0 {
                        let limitBytes  = maxFileSizeMB * 1_024 * 1_024
                        let estimatedBytes = estimatedPackagedBytes(
                            imageBytes: totalBytes(renderedImages),
                            imageCount: renderedImages.count,
                            outputFormat: outputFormat
                        )
                        if estimatedBytes > limitBytes {
                            Logger.converter.notice(
                                "Size limit: estimated \(estimatedBytes / 1_024 / 1_024, privacy: .public) MB > \(maxFileSizeMB, privacy: .public) MB target; optimizing images in \(sizeLimitMode.rawValue, privacy: .public) mode"
                            )
                            continuation.yield(.progress(fraction: 0.62, message: String(localized: "Optimizing images to meet size limit…")))
                            switch sizeLimitMode {
                            case .fast:
                                renderedImages = try await recompressFastForSizeLimit(
                                    renderedImages,
                                    limitBytes: limitBytes,
                                    baseQuality: renderQuality,
                                    outputFormat: outputFormat,
                                    tempDir: tempDir
                                )
                            case .precise:
                                renderedImages = try await recompressPreciselyForSizeLimit(
                                    renderedImages,
                                    pdf: url,
                                    sampleDocument: cgDoc,
                                    pageCount: pageCount,
                                    currentWidth: renderWidth,
                                    imageEncoding: imageEncoding,
                                    limitBytes: limitBytes,
                                    baseQuality: renderQuality,
                                    title: url.deletingPathExtension().lastPathComponent,
                                    author: author,
                                    language: language,
                                    direction: direction,
                                    outputFormat: outputFormat,
                                    tempDir: tempDir,
                                    continuation: continuation
                                )
                            }

                            let newBytes = estimatedPackagedBytes(
                                imageBytes: totalBytes(renderedImages),
                                imageCount: renderedImages.count,
                                outputFormat: outputFormat
                            )
                            Logger.converter.notice(
                                "After optimization: estimated \(newBytes / 1_024 / 1_024, privacy: .public) MB"
                            )
                        } else {
                            Logger.converter.info(
                                "Size OK: estimated \(estimatedBytes / 1_024 / 1_024, privacy: .public) MB ≤ \(maxFileSizeMB, privacy: .public) MB"
                            )
                        }
                    }

                    // 3. Build output file(s) from all rendered pages
                    let cleanTitle = sanitize(url.deletingPathExtension().lastPathComponent)

                    continuation.yield(.progress(fraction: 0.78, message: String(localized: "Building \(cleanTitle)…")))
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
                            language:  language,
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
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Page rendering

    private nonisolated static func renderDocument(
        pdf url: URL,
        sampleDocument: CGPDFDocument,
        pageCount: Int,
        width: Int,
        quality: Double,
        imageEncoding: ImageEncoding,
        tempDir: URL,
        progressStart: Double,
        progressSpan: Double,
        continuation: AsyncThrowingStream<ConversionEvent, Error>.Continuation
    ) async throws -> [URL] {
        try Task.checkCancellation()

        let renderDir = tempDir.appendingPathComponent("render-\(width)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)

        let imageURLs: [URL] = (0 ..< pageCount).map { i in
            renderDir.appendingPathComponent(String(format: "page-%04d.jpg", i + 1))
        }

        let concurrency = renderConcurrency(
            for: sampleDocument,
            pageCount: pageCount,
            targetWidth: width
        )
        let chunkSize = max(1, (pageCount + concurrency - 1) / concurrency)
        let renderClock = ContinuousClock()
        let counter = ProgressCounter()

        Logger.converter.info(
            "Rendering with \(concurrency, privacy: .public) local worker(s), width \(width, privacy: .public)px, image mode \(imageEncoding.rawValue, privacy: .public)"
        )

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
                        try Task.checkCancellation()

                        guard let page = cgDoc.page(at: i + 1) else {
                            Logger.converter.notice("Skipping page \(i + 1, privacy: .public) — CGPDFPage unavailable")
                            continue
                        }

                        await renderPermitPool.acquire()
                        defer { Task { await renderPermitPool.release() } }
                        try Task.checkCancellation()

                        let pageStart = renderClock.now
                        try autoreleasepool {
                            try PDFConverter.renderPage(
                                page,
                                width: width,
                                quality: quality,
                                imageEncoding: imageEncoding,
                                to: imageURLs[i]
                            )
                        }
                        Logger.converter.debug(
                            "Rendered page \(i + 1, privacy: .public)/\(pageCount, privacy: .public) in \((renderClock.now - pageStart).formatted(.units(allowed: [.milliseconds])), privacy: .public)"
                        )

                        let done = await counter.increment()
                        if done % 5 == 0 || done == pageCount {
                            continuation.yield(.progress(
                                fraction: progressStart + Double(done) / Double(pageCount) * progressSpan,
                                message:  String(localized: "Rendering page \(done) / \(pageCount)…")
                            ))
                        }
                        await Task.yield()
                    }
                }
            }
            try await group.waitForAll()
        }

        return imageURLs.filter {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Renders a single PDF page to a JPEG file.
    /// Uses CoreGraphics only, so it is safe to call away from the main actor.
    private nonisolated static func renderPage(
        _ page: CGPDFPage,
        width: Int,
        quality: Double,
        imageEncoding: ImageEncoding,
        to destURL: URL
    ) throws {
        let box = preferredPDFBox(for: page)
        let pageSize = orientedPageSize(for: page, box: box)
        guard pageSize.width > 0, pageSize.height > 0 else {
            throw ConversionError.renderFailed
        }

        let scale       = CGFloat(width) / pageSize.width
        let pixelWidth  = width
        let pixelHeight = max(1, Int(ceil(pageSize.height * scale)))

        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        switch imageEncoding {
        case .colorJPEG:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        case .grayscaleJPEG:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        }

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            Logger.converter.error("CGContext creation failed for page (\(pixelWidth, privacy: .public)×\(pixelHeight, privacy: .public))")
            throw ConversionError.renderFailed
        }

        let targetRect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        switch imageEncoding {
        case .colorJPEG:
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        case .grayscaleJPEG:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        }
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.concatenate(page.getDrawingTransform(box, rect: targetRect, rotate: 0, preserveAspectRatio: true))
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

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedJPEGQuality(quality),
            kCGImagePropertyJFIFDictionary: [
                kCGImagePropertyJFIFIsProgressive: true
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage,
            properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            Logger.converter.error("CGImageDestinationFinalize failed")
            throw ConversionError.renderFailed
        }
    }

    // MARK: - Helpers

    private nonisolated static func renderConcurrency(
        for document: CGPDFDocument,
        pageCount: Int,
        targetWidth: Int
    ) -> Int {
        let cpuLimit = max(1, min(ProcessInfo.processInfo.activeProcessorCount, pageCount))
        let pagesToSample = max(1, min(pageCount, 8))
        let maxPixels = (1 ... pagesToSample).compactMap { pageIndex -> Int? in
            guard let page = document.page(at: pageIndex) else { return nil }
            let pageSize = orientedPageSize(for: page, box: preferredPDFBox(for: page))
            guard pageSize.width > 0, pageSize.height > 0 else { return nil }
            let scale = CGFloat(targetWidth) / pageSize.width
            return targetWidth * max(1, Int(ceil(pageSize.height * scale)))
        }.max() ?? targetWidth * targetWidth

        let bytesPerPage = maxPixels * 4
        let memoryBudget = 384 * 1_024 * 1_024
        let memoryLimit = max(1, memoryBudget / max(bytesPerPage, 1))
        return max(1, min(cpuLimit, memoryLimit))
    }

    private nonisolated static func preferredPDFBox(for page: CGPDFPage) -> CGPDFBox {
        let cropBox = page.getBoxRect(.cropBox).standardized
        return cropBox.width > 0 && cropBox.height > 0 ? .cropBox : .mediaBox
    }

    private nonisolated static func orientedPageSize(for page: CGPDFPage, box: CGPDFBox) -> CGSize {
        let rect = page.getBoxRect(box).standardized
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: rect.height, height: rect.width)
        }
        return rect.size
    }

    private nonisolated static func clampedJPEGQuality(_ quality: Double) -> Double {
        min(max(quality, 0.08), 0.92)
    }

    private nonisolated static func recompressFastForSizeLimit(
        _ sourceURLs: [URL],
        limitBytes: Int,
        baseQuality: Double,
        outputFormat: OutputFormat,
        tempDir: URL
    ) async throws -> [URL] {
        let targetImageBytes = targetImageBytes(forLimitBytes: limitBytes, imageCount: sourceURLs.count, outputFormat: outputFormat)
        let originalBytes = totalBytes(sourceURLs)
        guard originalBytes > targetImageBytes else { return sourceURLs }

        var quality = fastQualityEstimate(
            baseQuality: baseQuality,
            currentBytes: originalBytes,
            targetBytes: targetImageBytes
        )
        var outputURLs = sourceURLs

        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            let candidateDir = tempDir.appendingPathComponent("quality-fast-\(attempt)-\(UUID().uuidString)")
            outputURLs = try await recompress(sourceURLs, quality: quality, to: candidateDir)
            let candidateBytes = totalBytes(outputURLs)
            if candidateBytes <= targetImageBytes || quality <= 0.13 {
                Logger.converter.notice(
                    "Fast size limit selected JPEG quality \(String(format: "%.2f", quality), privacy: .public)"
                )
                return outputURLs
            }

            let ratio = Double(targetImageBytes) / Double(max(candidateBytes, 1))
            quality = max(0.12, quality * pow(ratio, 0.75) * 0.96)
        }

        Logger.converter.notice(
            "Fast size limit settled at estimated \(estimatedPackagedBytes(imageBytes: totalBytes(outputURLs), imageCount: outputURLs.count, outputFormat: outputFormat) / 1_024 / 1_024, privacy: .public) MB"
        )
        return outputURLs
    }

    private nonisolated static func recompressPreciselyForSizeLimit(
        _ sourceURLs: [URL],
        pdf url: URL,
        sampleDocument: CGPDFDocument,
        pageCount: Int,
        currentWidth: Int,
        imageEncoding: ImageEncoding,
        limitBytes: Int,
        baseQuality: Double,
        title: String,
        author: String,
        language: String,
        direction: ReadingDirection,
        outputFormat: OutputFormat,
        tempDir: URL,
        continuation: AsyncThrowingStream<ConversionEvent, Error>.Continuation
    ) async throws -> [URL] {
        var workingURLs = sourceURLs
        var actualBytes = try await packagedSizeBytes(
            images: workingURLs,
            title: title,
            author: author,
            language: language,
            direction: direction,
            outputFormat: outputFormat,
            tempDir: tempDir
        )
        let scaledWidth = scaledWidthForSizeLimit(
            currentWidth: currentWidth,
            actualBytes: actualBytes,
            limitBytes: limitBytes
        )
        if scaledWidth < Int(Double(currentWidth) * 0.92) {
            Logger.converter.notice(
                "Rerendering at \(scaledWidth, privacy: .public)px before lowering JPEG quality"
            )
            workingURLs = try await renderDocument(
                pdf: url,
                sampleDocument: sampleDocument,
                pageCount: pageCount,
                width: scaledWidth,
                quality: baseQuality,
                imageEncoding: imageEncoding,
                tempDir: tempDir,
                progressStart: 0.62,
                progressSpan: 0.12,
                continuation: continuation
            )
            actualBytes = try await packagedSizeBytes(
                images: workingURLs,
                title: title,
                author: author,
                language: language,
                direction: direction,
                outputFormat: outputFormat,
                tempDir: tempDir
            )
        }

        guard actualBytes > limitBytes else { return workingURLs }

        let lowerBound = 0.12
        var low = lowerBound
        var high = clampedJPEGQuality(baseQuality)
        var bestQuality: Double?

        for _ in 0 ..< 7 {
            try Task.checkCancellation()
            let candidateQuality = (low + high) / 2
            let candidateDir = tempDir.appendingPathComponent("quality-\(UUID().uuidString)")
            let candidateURLs = try await recompress(workingURLs, quality: candidateQuality, to: candidateDir)
            let candidateBytes = try await packagedSizeBytes(
                images: candidateURLs,
                title: title,
                author: author,
                language: language,
                direction: direction,
                outputFormat: outputFormat,
                tempDir: tempDir
            )
            try? FileManager.default.removeItem(at: candidateDir)

            if candidateBytes <= limitBytes {
                bestQuality = candidateQuality
                low = candidateQuality
            } else {
                high = candidateQuality
            }
        }

        let finalQuality = bestQuality ?? lowerBound
        if bestQuality == nil {
            Logger.converter.warning(
                "Could not meet size limit at minimum JPEG quality; using quality \(String(format: "%.2f", finalQuality), privacy: .public)"
            )
        } else {
            Logger.converter.notice(
                "Selected JPEG quality \(String(format: "%.2f", finalQuality), privacy: .public) for size limit"
            )
        }

        let finalDir = tempDir.appendingPathComponent("quality-final-\(UUID().uuidString)")
        return try await recompress(workingURLs, quality: finalQuality, to: finalDir)
    }

    private nonisolated static func scaledWidthForSizeLimit(
        currentWidth: Int,
        actualBytes: Int,
        limitBytes: Int
    ) -> Int {
        guard actualBytes > limitBytes, limitBytes > 0 else { return currentWidth }
        let scale = sqrt(Double(limitBytes) * 0.96 / Double(actualBytes))
        return max(600, Int(Double(currentWidth) * scale))
    }

    private nonisolated static func fastQualityEstimate(
        baseQuality: Double,
        currentBytes: Int,
        targetBytes: Int
    ) -> Double {
        let ratio = Double(targetBytes) / Double(max(currentBytes, 1))
        return max(0.12, min(clampedJPEGQuality(baseQuality), baseQuality * pow(ratio, 0.85) * 0.98))
    }

    /// Recompresses JPEG images into a destination directory without mutating the source images.
    private nonisolated static func recompress(_ urls: [URL], quality: Double, to destinationDir: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        var outputURLs: [URL] = []
        outputURLs.reserveCapacity(urls.count)

        for url in urls {
            let outputURL = destinationDir.appendingPathComponent(url.lastPathComponent)
            try autoreleasepool {
                let cfURL = url as CFURL
                guard
                    let source = CGImageSourceCreateWithURL(cfURL, nil),
                    let image  = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let dest   = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw ConversionError.renderFailed }

                let properties: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: clampedJPEGQuality(quality),
                    kCGImagePropertyJFIFDictionary: [
                        kCGImagePropertyJFIFIsProgressive: true
                    ]
                ]
                CGImageDestinationAddImage(dest, image, properties as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ConversionError.renderFailed }
            }
            outputURLs.append(outputURL)
            await Task.yield()
        }
        return outputURLs
    }

    private nonisolated static func packagedSizeBytes(
        images: [URL],
        title: String,
        author: String,
        language: String,
        direction: ReadingDirection,
        outputFormat: OutputFormat,
        tempDir: URL
    ) async throws -> Int {
        let sizeDir = tempDir.appendingPathComponent("size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sizeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sizeDir) }

        var sizes: [Int] = []
        if outputFormat == .cbz || outputFormat == .all {
            let out = sizeDir.appendingPathComponent("size.cbz")
            try await CBZBuilder.build(images: images, to: out)
            sizes.append(fileBytes(out))
        }
        if outputFormat == .epub || outputFormat == .all {
            let out = sizeDir.appendingPathComponent("size.epub")
            try await EPUBBuilder.build(
                images: images,
                title: title,
                author: author,
                language: language,
                direction: direction,
                to: out
            )
            sizes.append(fileBytes(out))
        }
        return sizes.max() ?? images.reduce(.zero) { $0 + fileBytes($1) }
    }

    private nonisolated static func estimatedPackagedBytes(
        imageBytes: Int,
        imageCount: Int,
        outputFormat: OutputFormat
    ) -> Int {
        imageBytes + estimatedArchiveOverhead(imageCount: imageCount, outputFormat: outputFormat)
    }

    private nonisolated static func targetImageBytes(
        forLimitBytes limitBytes: Int,
        imageCount: Int,
        outputFormat: OutputFormat
    ) -> Int {
        let availableBytes = max(1, limitBytes - estimatedArchiveOverhead(imageCount: imageCount, outputFormat: outputFormat))
        return max(1, Int(Double(availableBytes) * 0.965))
    }

    private nonisolated static func estimatedArchiveOverhead(
        imageCount: Int,
        outputFormat: OutputFormat
    ) -> Int {
        let cbzOverhead = 4_096 + imageCount * 196
        let epubOverhead = 80_000 + imageCount * 2_600
        switch outputFormat {
        case .cbz:
            return cbzOverhead
        case .epub:
            return epubOverhead
        case .all:
            return max(cbzOverhead, epubOverhead)
        }
    }

    /// Returns file size in bytes using FileManager (reliable in sandboxed temp directories).
    private nonisolated static func fileBytes(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? .zero
    }

    private nonisolated static func totalBytes(_ urls: [URL]) -> Int {
        urls.reduce(.zero) { $0 + fileBytes($1) }
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

private actor RenderPermitPool {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
