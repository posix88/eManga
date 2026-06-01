import OSLog

extension Logger {
    nonisolated private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.eManga"
    }
    
    /// App lifecycle events (launch, scene transitions).
    nonisolated static var app: Logger {
        Logger(subsystem: subsystem, category: "App")
    }
    
    /// User-driven actions: adding files, starting/cancelling conversions.
    nonisolated static var viewModel: Logger {
        Logger(subsystem: subsystem, category: "ConversionViewModel")
    }

    /// PDF rendering pipeline: page rasterisation, batching, output packaging.
    nonisolated static var converter: Logger {
        Logger(subsystem: subsystem, category: "PDFConverter")
    }
    
    /// CBZ archive assembly.
    nonisolated static var cbzBuilder: Logger {
        Logger(subsystem: subsystem, category: "CBZBuilder")
    }

    /// EPUB package assembly.
    nonisolated static var epubBuilder: Logger {
        Logger(subsystem: subsystem, category: "EPUBBuilder")
    }
}
