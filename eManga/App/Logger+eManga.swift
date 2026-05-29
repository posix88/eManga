import OSLog

extension Logger {
    private nonisolated(unsafe) static let subsystem = Bundle.main.bundleIdentifier ?? "com.eManga"

    /// App lifecycle events (launch, scene transitions).
    nonisolated(unsafe) static let app = Logger(subsystem: subsystem, category: "App")

    /// User-driven actions: adding files, starting/cancelling conversions.
    nonisolated(unsafe) static let viewModel = Logger(subsystem: subsystem, category: "ConversionViewModel")

    /// PDF rendering pipeline: page rasterisation, batching, output packaging.
    nonisolated(unsafe) static let converter = Logger(subsystem: subsystem, category: "PDFConverter")

    /// CBZ archive assembly.
    nonisolated(unsafe) static let cbzBuilder = Logger(subsystem: subsystem, category: "CBZBuilder")

    /// EPUB package assembly.
    nonisolated(unsafe) static let epubBuilder = Logger(subsystem: subsystem, category: "EPUBBuilder")
}
