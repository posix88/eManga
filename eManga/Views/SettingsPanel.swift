import SwiftUI
import Observation
import UniformTypeIdentifiers

struct SettingsPanel: View {
    @Bindable var settings: ConversionSettings
    let outputURL: URL?
    let onSelectOutputFolder: (URL) -> Void

    @State private var isPickingFolder = false

    var body: some View {
        Form {
            Section("Output Folder") {
                HStack {
                    Group {
                        if let url = outputURL {
                            Text(url.abbreviatingWithTildeInPath)
                        } else {
                            Text("Not selected")
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(outputURL == nil ? .secondary : .primary)
                    .font(.caption)
                    Spacer()
                    Button("Choose…") { isPickingFolder = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    onSelectOutputFolder(url)
                }
            }

            Section("Output") {
                Picker("Format", selection: $settings.outputFormat) {
                    ForEach(OutputFormat.allCases) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Quality") {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(Resolution.allCases) { res in
                        Text(res.label).tag(res)
                    }
                }
                if settings.resolution == .custom {
                    LabeledContent("Width (px)") {
                        TextField("px", value: $settings.customWidth, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                }
            }

            Section("Metadata") {
                Picker("Direction", selection: $settings.direction) {
                    ForEach(ReadingDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                LabeledContent("Author") {
                    TextField("", text: $settings.author)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Size Limit") {
                Toggle("Limit output size", isOn: Binding(
                    get: { settings.maxFileSizeMB > 0 },
                    set: { settings.maxFileSizeMB = $0 ? 49 : 0 }
                ))
                if settings.maxFileSizeMB > 0 {
                    LabeledContent("Max size (MB)") {
                        TextField("MB", value: $settings.maxFileSizeMB, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

#if DEBUG
#Preview("Default settings") {
    struct PreviewWrapper: View {
        @State var settings = ConversionSettings()
        var body: some View {
            SettingsPanel(settings: settings, outputURL: nil, onSelectOutputFolder: {_ in })
        }
    }
    return PreviewWrapper()
        .frame(width: 300)
}
#endif
