import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case cbz = "CBZ"
    case epub = "EPUB"
    case all = "Both"
    var id: String { rawValue }
}

enum Resolution: String, CaseIterable, Identifiable {
    case light    = "Light"
    case balanced = "Balanced"
    case high     = "High"
    case custom   = "Custom"
    var id: String { rawValue }

    var width: Int {
        switch self {
        case .light:    return 800
        case .balanced: return 1000
        case .high:     return 1300
        case .custom:   return 1000
        }
    }

    var quality: Double {
        switch self {
        case .light:    return 0.45
        case .balanced: return 0.60
        case .high:     return 0.80
        case .custom:   return 0.65
        }
    }

    var label: String {
        switch self {
        case .light:    return String(localized: "Light (800px)")
        case .balanced: return String(localized: "Balanced (1000px)")
        case .high:     return String(localized: "High (1300px)")
        case .custom:   return String(localized: "Custom")
        }
    }
}

enum ReadingDirection: String, CaseIterable, Identifiable {
    case rtl = "rtl"
    case ltr = "ltr"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .rtl: return String(localized: "Right to Left (Manga)")
        case .ltr: return String(localized: "Left to Right (Comics)")
        }
    }
}

@Observable
final class ConversionSettings: Sendable {
    var outputFormat: OutputFormat   = .cbz
    var resolution: Resolution       = .balanced
    var customWidth: Int             = 1200
    var maxFileSizeMB: Int           = 0      // 0 = unlimited
    var author: String               = "Unknown"
    var direction: ReadingDirection  = .rtl

    var effectiveWidth: Int {
        resolution == .custom ? customWidth : resolution.width
    }

    var effectiveQuality: Double {
        resolution.quality
    }
}
