import Foundation

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case cbz = "CBZ"
    case epub = "EPUB"
    case all = "Both"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cbz:
            return String(localized: "CBZ")
        case .epub:
            return String(localized: "EPUB")
        case .all:
            return String(localized: "Both")
        }
    }
}

enum Resolution: String, CaseIterable, Identifiable, Sendable {
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

enum ReadingDirection: String, CaseIterable, Identifiable, Sendable {
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

enum ImageEncoding: String, CaseIterable, Identifiable, Sendable {
    case colorJPEG = "Color JPEG"
    case grayscaleJPEG = "Grayscale JPEG"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colorJPEG:
            return String(localized: "Color JPEG")
        case .grayscaleJPEG:
            return String(localized: "Grayscale JPEG")
        }
    }
}

enum PublicationLanguage: String, CaseIterable, Identifiable, Sendable {
    case japanese = "ja"
    case english = "en"
    case italian = "it"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }
    var code: String { rawValue }

    var label: String {
        switch self {
        case .japanese:
            return String(localized: "Japanese")
        case .english:
            return String(localized: "English")
        case .italian:
            return String(localized: "Italian")
        case .french:
            return String(localized: "French")
        case .german:
            return String(localized: "German")
        case .spanish:
            return String(localized: "Spanish")
        case .portuguese:
            return String(localized: "Portuguese")
        case .korean:
            return String(localized: "Korean")
        case .simplifiedChinese:
            return String(localized: "Chinese (Simplified)")
        case .traditionalChinese:
            return String(localized: "Chinese (Traditional)")
        }
    }
}

enum SizeLimitMode: String, CaseIterable, Identifiable, Sendable {
    case fast = "Fast"
    case precise = "Precise"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast:
            return String(localized: "Fast")
        case .precise:
            return String(localized: "Precise")
        }
    }

    var explanation: String {
        switch self {
        case .fast:
            return String(localized: "Fast estimates the final size and keeps conversion quick. The output may be slightly above or below the limit.")
        case .precise:
            return String(localized: "Precise measures temporary packages and may take extra passes to get closer to the limit.")
        }
    }
}

@Observable
final class ConversionSettings: Sendable {
    var outputFormat: OutputFormat   = .cbz
    var resolution: Resolution       = .balanced
    var customWidth: Int             = 1200
    var maxFileSizeMB: Int           = 0      // 0 = unlimited
    var sizeLimitMode: SizeLimitMode = .fast
    var imageEncoding: ImageEncoding = .colorJPEG
    var author: String               = "Unknown"
    var language: PublicationLanguage = .japanese
    var direction: ReadingDirection  = .rtl

    var effectiveWidth: Int {
        max(320, resolution == .custom ? customWidth : resolution.width)
    }

    var effectiveQuality: Double {
        min(max(resolution.quality, 0.10), 0.92)
    }
}
