# eManga

A native macOS app that converts PDF manga/comic volumes into **CBZ** and/or **EPUB** files, ready for any reader app.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![License MIT](https://img.shields.io/badge/license-MIT-blue)

---

## Features

- **Drag & drop** PDFs onto the drop zone, or use the file browser
- Converts to **CBZ**, **EPUB**, or **both** in one pass
- **Concurrent rendering** — pages are rasterised in parallel across all CPU cores via CoreGraphics
- **Parallel queue** — up to 2 files convert simultaneously; additional files start as slots free up
- **Adaptive size limit** — optionally cap the output file size (e.g. 49 MB); images are recompressed at lower JPEG quality to meet the target without splitting the file
- **Resolution presets** — Light (800 px), Balanced (1000 px), High (1300 px), or a custom width
- **Reading direction** — Right-to-Left (manga) or Left-to-Right (Western comics)
- **EPUB metadata** — author name embedded in the package
- **macOS sandbox** — security-scoped bookmark persistence means the chosen output folder survives app restarts without re-prompting
- Localised in **English** and **Italian**

---

## Requirements

| | |
|---|---|
| macOS | 26.2 (Tahoe) or later |
| Xcode | 26 or later |
| Swift | 6.0 |

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | Building CBZ and EPUB ZIP archives |

---

## Building

```bash
git clone https://github.com/posix88/eManga.git
cd eManga
open eManga.xcodeproj
```

Select the **eManga** scheme, choose **My Mac** as the destination, and hit **Run** (⌘R).

> No additional setup is needed — Swift Package Manager resolves ZIPFoundation automatically on first build.

---

## Usage

1. **Drop PDFs** onto the drop zone (or click *Browse…*)
2. **Choose an output folder** from the toolbar
3. Adjust settings in the **inspector panel** on the right:
   - Output format (CBZ / EPUB / Both)
   - Resolution preset
   - Reading direction
   - Author (for EPUB metadata)
   - Optional size limit
4. Click **Convert** — progress is shown per file; completed and failed jobs are indicated inline

---

## Architecture

```
eManga/
├── App/
│   ├── eMangaApp.swift          # App entry point; restores output folder bookmark
│   └── Logger+eManga.swift      # Typed OSLog categories (app, viewModel, converter, …)
├── Models/
│   ├── ConversionJob.swift      # Per-file job state machine (pending → processing → done/failed)
│   └── ConversionSettings.swift # @Observable settings shared across UI and converter
├── Services/
│   ├── PDFConverter.swift       # AsyncThrowingStream pipeline: concurrent CG render → optional recompress → build
│   ├── CBZBuilder.swift         # Wraps rendered JPEGs into a ZIP archive (.cbz)
│   └── EPUBBuilder.swift        # Builds a valid EPUB 3 package with OPF/NCX/HTML spine
├── ViewModels/
│   └── ConversionViewModel.swift # @MainActor coordinator; manages job queue and sandbox access
└── Views/
    ├── ContentView.swift
    ├── DropZoneView.swift
    ├── JobRow.swift
    └── SettingsPanel.swift
```

**Key design decisions:**

- `PDFConverter` uses `CGPDFDocument` / `CGPDFPage` (not PDFKit) so page rendering has no `@MainActor` restriction and can run freely on background threads via `withThrowingTaskGroup`.
- Jobs are processed with `withTaskGroup(maxConcurrent: 2)` — enough parallelism to overlap the render phase of one file with the archive phase of another, without over-subscribing the CPU.
- JPEG entries in CBZ archives use `.compressionMethod: .none` — JPEG is already compressed; deflate on top adds CPU time with no size benefit.

---

## License

MIT — see [LICENSE](LICENSE).
