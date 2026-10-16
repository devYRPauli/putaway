import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The classifier sees at most this many characters. 1,000 is the size the accuracy test used.
public let textLimit = 1_000

/// Names that may hold credentials. These files are never read or sent anywhere.
/// `.key` is the one exception: Keynote decks share the extension with private keys, so the
/// first 4 bytes are checked on the Mac. Only a zip archive, which is what a deck is, is cleared.
public func isSensitive(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    if name.lowercased().hasSuffix(".key"), isZipArchive(url) { return false }
    // Inline: Regex is not Sendable, so it cannot be a global.
    return name.contains(#/(?i)^\.env|\.(env|pem|key|p8|p12|pfx|ppk|jks|keystore|kdbx|keychain(-db)?|ovpn|1pux)$|^id_(rsa|dsa|ecdsa|ed25519)|recovery[ _-]?(codes?|keys?|kit)|backup[ _-]?codes?|emergency[ _-]?kit|(passwords?|secrets?|credentials?)([._-]|$)|access_?keys?\.csv|rootkey\.csv|seed[ _-]?phrase|mnemonic/#)
}

private func isZipArchive(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
}

/// Text that looks like a credential, whatever the file is named. Checked on the extracted
/// text, which is exactly what would leave the Mac.
public func looksLikeSecret(_ text: String) -> Bool {
    text.contains(#/-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|\b(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}|\bsk-[A-Za-z0-9_-]{20,}|\bsk_live_[A-Za-z0-9]{16,}|\bxox[abp]-[A-Za-z0-9-]{20,}|\bAIza[0-9A-Za-z_-]{35}/#)
}

/// Text read from the start of a file, or nil when the file has no readable text.
public func extractText(_ url: URL) async throws -> String? {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
    let text: String?
    if type.conforms(to: .pdf) {
        text = try await pdfText(url)
    } else if type.conforms(to: .image) {
        text = try await ocr { ocrImage(url) }
    } else if type.conforms(to: .html) {
        text = try htmlText(url)
    } else if let documentType = documentTypes[url.pathExtension.lowercased()] {
        // An explicit type, so a mislabeled file can never reach the HTML importer.
        text = try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil).string
    } else if url.pathExtension.lowercased() == "xlsx" {
        text = try await workbookText(url)
    } else if type.conforms(to: .text) {
        text = try readStart(url, bytes: textLimit * 4)
    } else {
        text = nil
    }
    guard let text, text.contains(where: { $0.isLetter }) else { return nil }
    return String(text.prefix(textLimit))
}

private let documentTypes: [String: NSAttributedString.DocumentType] = [
    "rtf": .rtf, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument,
]

private func readStart(_ url: URL, bytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return String(decoding: try handle.read(upToCount: bytes) ?? Data(), as: UTF8.self)
}

/// The title, then the visible text. Not NSAttributedString: its HTML importer runs WebKit,
/// which loads the page's images from the network and took 63 s on one Wikipedia page.
private func htmlText(_ url: URL) throws -> String {
    let html = try readStart(url, bytes: 512 * 1024)
    let title = html.range(of: "(?is)<title[^>]*>.*?</title>", options: .regularExpression).map { markupText(String(html[$0])) }
    return [title, markupText(html)].compactMap { $0 }.joined(separator: "\n")
}

/// Text of HTML or XML without the parts a reader never sees. Nothing is fetched or run.
private func markupText(_ markup: String) -> String {
    let stripped = markup
        .replacingOccurrences(of: #"(?is)<(head|script|style|nav)\b.*?</\1\s*>|<!--.*?-->"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
    let text = CFXMLCreateStringByUnescapingEntities(nil, stripped as CFString, nil) as String
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The cell text of an Excel workbook, from its shared strings. Foundation cannot read a zip
/// archive, so the system unzip does. It blocks, so it runs off the Swift concurrency pool.
private func workbookText(_ url: URL) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let unzip = Process()
                unzip.executableURL = URL(filePath: "/usr/bin/unzip")
                unzip.arguments = ["-p", url.path, "xl/sharedStrings.xml"]
                let pipe = Pipe()
                unzip.standardOutput = pipe
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                // Stop reading early; a large workbook would otherwise fill the pipe.
                let data = try pipe.fileHandleForReading.read(upToCount: textLimit * 8) ?? Data()
                unzip.terminate()
                unzip.waitUntilExit()
                continuation.resume(returning: markupText(String(decoding: data, as: UTF8.self)))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func pdfText(_ url: URL) async throws -> String? {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
    let pages = (0..<min(2, doc.pageCount)).compactMap { doc.page(at: $0) }
    let text = pages.compactMap(\.string).joined(separator: "\n")
    if text.contains(where: { $0.isLetter }) { return text }
    // A scanned PDF has no text layer; read its first page with OCR instead.
    let image = pages[0].thumbnail(of: CGSize(width: 1700, height: 2200), for: .mediaBox)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return try await ocr { cg }
}

/// The image, at most 4096 px on its long side. Decoding a 48 MP photo at full size costs ~200 MB.
private func ocrImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

// Vision blocks its calling thread. Run it on its own queue so it cannot starve the
// Swift concurrency pool, which deadlocked with 8 OCR calls in flight. The image is decoded
// on the queue too, so only one decoded image is in memory at a time.
private let ocrQueue = DispatchQueue(label: "putaway.ocr")

private func ocr(_ makeImage: @escaping @Sendable () -> CGImage?) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
        ocrQueue.async {
            guard let image = makeImage() else { return continuation.resume(returning: nil) }
            let request = VNRecognizeTextRequest()
            // Classification needs words, not perfect text.
            request.recognitionLevel = .fast
            do {
                try VNImageRequestHandler(cgImage: onWhite(image)).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Transparent pixels read as black, so dark text on a transparent PNG is invisible to OCR.
private func onWhite(_ image: CGImage) -> CGImage {
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
    context.setFillColor(.white)
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage() ?? image
}
