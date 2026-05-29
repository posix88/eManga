import SwiftUI

struct ContentView: View {
    private let viewModel: ConversionViewModel
    @State private var inspectorPresented = true

    init(viewModel: ConversionViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.jobs.isEmpty {
                fileList
            }
            dropZone
        }
        .animation(.snappy, value: viewModel.jobs.isEmpty)
        .inspector(isPresented: $inspectorPresented) {
            SettingsPanel(
                settings: viewModel.settings,
                outputURL: viewModel.outputURL,
                onSelectOutputFolder: viewModel.setOutputFolder
            )
            .inspectorColumnWidth(min: 300, ideal: 320, max: 380)
        }
        .toolbar { toolbarItems }
        .frame(minHeight: 480)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if viewModel.jobs.contains(where: { $0.isComplete }) {
            ToolbarItem(placement: .automatic) {
                Button("Clear Done", systemImage: "checkmark.circle") {
                    viewModel.clearCompleted()
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { viewModel.startConversion() } label: {
                Label(
                    viewModel.isConverting ? String(localized: "Converting…") : String(localized: "Convert"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .symbolEffect(.rotate, isActive: viewModel.isConverting)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.jobs.isEmpty || viewModel.outputURL == nil || viewModel.isConverting)
        }
        ToolbarItem(placement: .navigation) {
            Button("Settings", systemImage: "sidebar.right") {
                inspectorPresented.toggle()
            }
        }
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(viewModel.jobs) { job in
                JobRow(job: job) { viewModel.removeJob(job) }
            }
        }
        .listStyle(.inset)
    }

    private var dropZone: some View {
        DropZoneView { urls in viewModel.addPDFs(urls) }
            .frame(maxHeight: viewModel.jobs.isEmpty ? .infinity : 72)
            .padding(8)
    }
}

#if DEBUG
#Preview("With Jobs") {
    ContentView(viewModel: .mock(withJobs: true, outputURL: nil))
}

#Preview("Empty — no output folder") {
    ContentView(viewModel: .mock(withJobs: false, outputURL: nil))
}
#endif

