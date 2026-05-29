import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var dropPulse = false
    @State private var iconBounce = 0

    var body: some View {
        dropShape
            .scaleEffect(dropPulse ? 1.04 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture { isImporting = true }
            .dropDestination(for: URL.self, isEnabled: true) { (urls: [URL], _: DropSession) in
                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                guard !pdfs.isEmpty else { return }
                onDrop(pdfs)
                animateDrop()
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { onDrop(urls) }
            }
    }

    private var dropShape: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [6])
            )
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay {
                Label("Drop PDFs here or click to browse", systemImage: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .symbolEffect(.bounce, value: iconBounce)
            }
    }

    private func animateDrop() {
        iconBounce += 1
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) {
            dropPulse = true
        } completion: {
            withAnimation(.spring(response: 0.3)) {
                dropPulse = false
            }
        }
    }
}

#if DEBUG
#Preview {
    DropZoneView { _ in }
        .frame(width: 420, height: 80)
        .padding()
}
#endif
