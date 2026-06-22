import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import eManga

struct eMangaTests {

    @MainActor
    @Test func sizeLimitModeDefaultsToFast() {
        let settings = ConversionSettings()
        #expect(settings.sizeLimitMode == .fast)
    }

    @MainActor
    @Test func converterUsesCropBoxAspectRatio() async throws {
        let workDir = try temporaryDirectory()
        let pdfURL = workDir.appendingPathComponent("cropped.pdf")
        let outputDir = workDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try makePDF(
            at: pdfURL,
            mediaBox: CGRect(x: 0, y: 0, width: 400, height: 400),
            cropBox: CGRect(x: 50, y: 100, width: 300, height: 150)
        )

        let settings = ConversionSettings()
        settings.outputFormat = .cbz
        settings.resolution = .custom
        settings.customWidth = 320

        try await drain(PDFConverter.convert(pdf: pdfURL, outputDir: outputDir, settings: settings))

        let cbzURL = outputDir.appendingPathComponent("cropped.cbz")
        let jpegData = try storedZipEntryData(in: cbzURL, pathSuffix: ".jpg")
        let dimensions = try imageDimensions(from: jpegData)

        #expect(dimensions.width == 320)
        #expect(abs(dimensions.height - 160) <= 1)
    }

    @MainActor
    @Test func converterCanEmitGrayscaleJPEG() async throws {
        let workDir = try temporaryDirectory()
        let pdfURL = workDir.appendingPathComponent("gray.pdf")
        let outputDir = workDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try makePDF(
            at: pdfURL,
            mediaBox: CGRect(x: 0, y: 0, width: 200, height: 300),
            cropBox: nil
        )

        let settings = ConversionSettings()
        settings.outputFormat = .cbz
        settings.resolution = .custom
        settings.customWidth = 200
        settings.imageEncoding = .grayscaleJPEG

        try await drain(PDFConverter.convert(pdf: pdfURL, outputDir: outputDir, settings: settings))

        let cbzURL = outputDir.appendingPathComponent("gray.cbz")
        let jpegData = try storedZipEntryData(in: cbzURL, pathSuffix: ".jpg")
        guard
            let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TestFailure.imageDecodeFailed
        }

        #expect(image.colorSpace?.model == .monochrome)
    }

    @Test func epubStoresCompressedImagesWithoutDeflate() async throws {
        let workDir = try temporaryDirectory()
        let imageURL = workDir.appendingPathComponent("page.jpg")
        let epubURL = workDir.appendingPathComponent("book.epub")
        try makeJPEG(at: imageURL, width: 80, height: 120)

        try await EPUBBuilder.build(
            images: [imageURL],
            title: "Book",
            author: "Author",
            language: "en",
            direction: .ltr,
            to: epubURL
        )

        let entries = try zipEntries(in: epubURL)
        #expect(entries.first { $0.name == "mimetype" }?.compressionMethod == 0)
        #expect(entries.first { $0.name.hasSuffix(".jpg") }?.compressionMethod == 0)
    }

    @Test func epubDeclaresComicMetadataAndLanguage() async throws {
        let workDir = try temporaryDirectory()
        let imageURL = workDir.appendingPathComponent("page.jpg")
        let epubURL = workDir.appendingPathComponent("book.epub")
        try makeJPEG(at: imageURL, width: 80, height: 120)

        try await EPUBBuilder.build(
            images: [imageURL],
            title: "Book",
            author: "Author",
            language: "en",
            direction: .ltr,
            to: epubURL
        )

        let opf = try epubEntryText(in: epubURL, path: "OEBPS/content.opf")
        #expect(opf.contains("<dc:language>en</dc:language>"))
        #expect(opf.contains("<dc:type>comic</dc:type>"))
        #expect(opf.contains("<dc:subject>Comics &amp; Graphic Novels</dc:subject>"))
        #expect(opf.contains("schema:genre"))
    }
}

private func drain(_ stream: AsyncThrowingStream<ConversionEvent, Error>) async throws {
    for try await _ in stream {}
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("eMangaTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePDF(at url: URL, mediaBox: CGRect, cropBox: CGRect?) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw TestFailure.cannotCreatePDF
    }
    var box = mediaBox
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw TestFailure.cannotCreatePDF
    }

    var pageInfo: [String: Any] = [
        kCGPDFContextMediaBox as String: pdfBoxData(mediaBox)
    ]
    if let cropBox {
        pageInfo[kCGPDFContextCropBox as String] = pdfBoxData(cropBox)
    }

    context.beginPDFPage(pageInfo as CFDictionary)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(mediaBox)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(cropBox ?? mediaBox)
    context.endPDFPage()
    context.closePDF()
}

private func pdfBoxData(_ rect: CGRect) -> Data {
    var rect = rect
    return Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
}

private func makeJPEG(at url: URL, width: Int, height: Int) throws {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw TestFailure.imageEncodeFailed
    }

    context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.86, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 10, y: 10, width: width - 20, height: height - 20))

    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
        throw TestFailure.imageEncodeFailed
    }

    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.75
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure.imageEncodeFailed
    }
}

private func imageDimensions(from data: Data) throws -> (width: Int, height: Int) {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
        throw TestFailure.imageDecodeFailed
    }
    return (width, height)
}

private func epubEntryText(in archiveURL: URL, path: String) throws -> String {
    let archive = try Archive(url: archiveURL, accessMode: .read)
    guard let entry = archive[path] else {
        throw TestFailure.zipEntryMissing
    }

    var data = Data()
    _ = try archive.extract(entry, skipCRC32: true) { chunk in
        data.append(chunk)
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw TestFailure.imageDecodeFailed
    }
    return text
}

private func storedZipEntryData(in archiveURL: URL, pathSuffix: String) throws -> Data {
    let archiveData = try Data(contentsOf: archiveURL)
    let entries = try zipEntries(in: archiveURL)
    guard let entry = entries.first(where: { $0.name.hasSuffix(pathSuffix) }) else {
        throw TestFailure.zipEntryMissing
    }
    guard entry.compressionMethod == 0 else {
        throw TestFailure.zipEntryCompressed
    }

    let localOffset = entry.localHeaderOffset
    let nameLength = Int(uint16(archiveData, localOffset + 26))
    let extraLength = Int(uint16(archiveData, localOffset + 28))
    let dataStart = localOffset + 30 + nameLength + extraLength
    let dataEnd = dataStart + entry.compressedSize
    guard dataStart <= dataEnd, dataEnd <= archiveData.count else {
        throw TestFailure.zipEntryMissing
    }
    return Data(archiveData[dataStart ..< dataEnd])
}

private func zipEntries(in archiveURL: URL) throws -> [ZipEntry] {
    let data = try Data(contentsOf: archiveURL)
    var entries: [ZipEntry] = []
    var offset = 0

    while offset + 46 <= data.count {
        if uint32(data, offset) != 0x0201_4B50 {
            offset += 1
            continue
        }

        let compressionMethod = uint16(data, offset + 10)
        let compressedSize = Int(uint32(data, offset + 20))
        let nameLength = Int(uint16(data, offset + 28))
        let extraLength = Int(uint16(data, offset + 30))
        let commentLength = Int(uint16(data, offset + 32))
        let localHeaderOffset = Int(uint32(data, offset + 42))
        let nameStart = offset + 46
        let nameEnd = nameStart + nameLength
        guard nameEnd <= data.count else { throw TestFailure.zipEntryMissing }

        let name = String(decoding: data[nameStart ..< nameEnd], as: UTF8.self)
        entries.append(ZipEntry(
            name: name,
            compressionMethod: compressionMethod,
            compressedSize: compressedSize,
            localHeaderOffset: localHeaderOffset
        ))

        offset = nameEnd + extraLength + commentLength
    }

    return entries
}

private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let localHeaderOffset: Int
}

private enum TestFailure: Error {
    case cannotCreatePDF
    case imageEncodeFailed
    case imageDecodeFailed
    case zipEntryMissing
    case zipEntryCompressed
}
