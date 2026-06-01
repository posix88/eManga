import Foundation
import Observation

enum JobStatus {
    case pending
    case processing(progress: Double, message: String)
    case done
    case failed(Error)
}

@Observable
final class ConversionJob: Identifiable {
    let id = UUID()
    let pdfURL: URL
    var status: JobStatus = .pending
    
    init(pdfURL: URL) {
        self.pdfURL = pdfURL
    }

    var filename: String { pdfURL.lastPathComponent }
    var title: String    { pdfURL.deletingPathExtension().lastPathComponent }

    var isComplete: Bool {
        switch status {
        case .done, .failed: return true
        default: return false
        }
    }

    var progressValue: Double {
        switch status {
        case .processing(let p, _): return p
        case .done:                 return 1.0
        default:                    return 0.0
        }
    }

    var statusMessage: String {
        switch status {
        case .pending:
            return String(localized: "Waiting…")
        case .processing(_, let m):
            return m
        case .done:
            return String(localized: "Done ✓")
        case .failed(let err):
            return String(localized: "Failed: \(err.localizedDescription)")
        }
    }
}
