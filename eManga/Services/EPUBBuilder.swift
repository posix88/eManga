import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation
import OSLog

struct EPUBBuilder {

    nonisolated static func build(
        images:    [URL],
        title:     String,
        author:    String,
        direction: ReadingDirection,
        to destination: URL
    ) async throws {
        Logger.epubBuilder.info(
            "Building EPUB — \(images.count, privacy: .public) image(s), direction: \(direction.rawValue, privacy: .public) → \(destination.lastPathComponent, privacy: .private(mask: .hash))"
        )
        let clock = ContinuousClock()
        let start = clock.now

        let fm      = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let metaInf  = tempDir.appendingPathComponent("META-INF")
        let oebps    = tempDir.appendingPathComponent("OEBPS")
        let imgDir   = oebps.appendingPathComponent("images")
        let xhtmlDir = oebps.appendingPathComponent("xhtml")

        for dir in [metaInf, imgDir, xhtmlDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Logger.epubBuilder.debug("Temp directory structure created at \(tempDir.lastPathComponent, privacy: .public)")

        // mimetype — must be plain ASCII, no trailing newline
        try Data("application/epub+zip".utf8).write(to: tempDir.appendingPathComponent("mimetype"))

        // META-INF/container.xml
        try containerXML.write(to: metaInf.appendingPathComponent("container.xml"),
                                atomically: true, encoding: .utf8)

        // Build pages
        var manifestLines: [String] = []
        var spineLines: [String] = []
        manifestLines.reserveCapacity(images.count)
        spineLines.reserveCapacity(images.count)
        
        for (i, imgURL) in images.enumerated() {
            let pageNum = i + 1
            let imgName = String(format: "page_%04d.jpg", pageNum)
            let destImg = imgDir.appendingPathComponent(imgName)
            try fm.copyItem(at: imgURL, to: destImg)

            let (w, h) = imageDimensions(at: destImg)
            Logger.epubBuilder.debug("Page \(pageNum, privacy: .public): \(w, privacy: .public)×\(h, privacy: .public)px")
            let coverAttr = pageNum == 1 ? " properties=\"cover-image\"" : ""

            manifestLines.append("    <item id=\"img_\(pageNum)\" href=\"images/\(imgName)\" media-type=\"image/jpeg\"\(coverAttr)/>\n")
            manifestLines.append("    <item id=\"page_\(pageNum)\" href=\"xhtml/page_\(pageNum).xhtml\" media-type=\"application/xhtml+xml\"/>\n")
            spineLines.append("    <itemref idref=\"page_\(pageNum)\"/>\n")

            try pageXHTML(pageNum: pageNum, imgName: imgName, width: w, height: h)
                .write(to: xhtmlDir.appendingPathComponent("page_\(pageNum).xhtml"),
                       atomically: true, encoding: .utf8)
            
            await Task.yield()
        }

        let manifestItems = manifestLines.joined(separator: "\n")
        let spineItems = spineLines.joined(separator: "\n")
        
        
        // nav.xhtml & content.opf
        try navXHTML.write(to: oebps.appendingPathComponent("nav.xhtml"),
                           atomically: true, encoding: .utf8)
        try contentOPF(title: title, author: author,
                       direction: direction.rawValue,
                       manifest: manifestItems, spine: spineItems)
            .write(to: oebps.appendingPathComponent("content.opf"),
                   atomically: true, encoding: .utf8)

        // ZIP — mimetype must be first and stored uncompressed (EPUB spec)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let archive = try Archive(url: destination, accessMode: .create, pathEncoding: nil)
        try archive.addEntry(with: "mimetype",
                             fileURL: tempDir.appendingPathComponent("mimetype"),
                             compressionMethod: .none)
        try await addDirectoryContents(of: tempDir, into: archive, relativeTo: tempDir, excluding: "mimetype")

        let elapsed = clock.now - start
        let sizeKB  = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 / 1024 } ?? 0
        Logger.epubBuilder.notice(
            "EPUB built in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public) — \(sizeKB, privacy: .public) KB"
        )
    }

    // MARK: - Helpers

    private static func addDirectoryContents(
        of dir: URL, into archive: Archive, relativeTo base: URL, excluding: String?
    ) async throws {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            if let ex = excluding, item.lastPathComponent == ex { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try await addDirectoryContents(of: item, into: archive, relativeTo: base, excluding: nil)
            } else {
                let rel = String(item.path.dropFirst(base.path.count + 1))
                try archive.addEntry(with: rel, fileURL: item)
            }
            
            await Task.yield()
        }
    }

    private nonisolated static func imageDimensions(at url: URL) -> (Int, Int) {
        guard
            let src   = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w     = props[kCGImagePropertyPixelWidth]  as? Int,
            let h     = props[kCGImagePropertyPixelHeight] as? Int
        else { return (1000, 1414) }
        return (w, h)
    }

    private nonisolated static func xmlEscape(_ s: String) -> String {
        s.replacing("&",  with: "&amp;")
         .replacing("<",  with: "&lt;")
         .replacing(">",  with: "&gt;")
         .replacing("\"", with: "&quot;")
    }

    // MARK: - Templates

    private nonisolated static var containerXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private nonisolated static var navXHTML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>TOC</title></head>
          <body>
            <nav epub:type="toc" id="toc">
              <ol><li><a href="xhtml/page_1.xhtml">Start Reading</a></li></ol>
            </nav>
          </body>
        </html>
        """
    }

    private nonisolated static func pageXHTML(pageNum: Int, imgName: String, width: Int, height: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head>
            <title>Page \(pageNum)</title>
            <meta charset="utf-8"/>
            <meta name="viewport" content="width=\(width), height=\(height)"/>
            <style>@page{margin:0}body{margin:0;padding:0;background:#000;text-align:center}img{width:100vw;height:100vh;object-fit:contain}</style>
          </head>
          <body><img src="../images/\(imgName)" alt="Page \(pageNum)"/></body>
        </html>
        """
    }

    private nonisolated static func contentOPF(
        title: String, author: String,
        direction: String, manifest: String, spine: String
    ) -> String {
        let uuid = "emanga-\(UUID().uuidString)"
        let date = Date.now.formatted(.iso8601)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" version="3.0"
                 prefix="rendition: http://www.idpf.org/vocab/rendition/#">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:\(uuid)</dc:identifier>
            <dc:title>\(xmlEscape(title))</dc:title>
            <dc:creator>\(xmlEscape(author))</dc:creator>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">\(date)</meta>
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:spread">none</meta>
            <meta property="rendition:orientation">auto</meta>
            <meta name="cover" content="img_1"/>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)  </manifest>
          <spine page-progression-direction="\(direction)">
            <itemref idref="nav" linear="no"/>
        \(spine)  </spine>
        </package>
        """
    }
}
