import SwiftUI

struct JobRow: View {
    let job: ConversionJob
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                
                Text(job.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if case .processing(let p, _) = job.status {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
            }
            
            Text(job.statusMessage)
                .font(.caption2)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            
        case .processing:
            Image(systemName: "gear")
                .foregroundStyle(.blue)
                .symbolEffect(.rotate, isActive: true)
            
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: return .red
        case .done:   return .green
        default:      return .secondary
        }
    }
}

#if DEBUG
#Preview("Pending") {
    List {
        JobRow(
            job: ConversionJob(pdfURL: URL(fileURLWithPath: "/demo/One Piece Vol 1.pdf")),
            onRemove: {}
        )
    }
}

#Preview("Processing") {
    let job = ConversionJob(pdfURL: URL(fileURLWithPath: "/demo/Naruto Vol 3.pdf"))
    job.status = .processing(progress: 0.6, message: "Converting page 45 of 75…")
    return List {
        JobRow(job: job, onRemove: {})
    }
}

#Preview("Done") {
    let job = ConversionJob(pdfURL: URL(fileURLWithPath: "/demo/Bleach Vol 7.pdf"))
    job.status = .done
    return List {
        JobRow(job: job, onRemove: {})
    }
}

#Preview("Failed") {
    let job = ConversionJob(pdfURL: URL(fileURLWithPath: "/demo/Berserk Vol 12.pdf"))
    job.status = .failed(
        NSError(domain: "Preview", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "File could not be opened"])
    )
    return List {
        JobRow(job: job, onRemove: {})
    }
}
#endif
