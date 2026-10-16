import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// The classifier sees at most this many characters. 1,000 is the size the accuracy test used.
public let textLimit = 1_000

/// Names that may hold credentials. These files are never read or sent anywhere.
public func isSensitive(_ url: URL) -> Bool {
    url.lastPathComponent.contains(/(?i)^\.env|\.(pem|key|p12|pfx|kdbx|keychain|ovpn)$|^id_(rsa|dsa|ecdsa|ed25519)|recovery|backup.?codes|passwords?|secrets?|credentials?/)
}

/// Text read from the start of a file, or nil when the file has no readable text.
public func extractText(_ url: URL) async throws -> String? {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
    let text: String?
    if type.conforms(to: .pdf) {
        text = try await pdfText(url)
    } else if type.conforms(to: .image) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        text = try await ocr(image)
    } else if type.conforms(to: .rtf) || type.conforms(to: .html) || ["docx", "doc", "odt"].contains(url.pathExtension.lowercased()) {
        text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
    } else if type.conforms(to: .text) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        text = String(decoding: try handle.read(upToCount: textLimit * 4) ?? Data(), as: UTF8.self)
    } else {
        text = nil
    }
    guard let text, text.contains(where: { $0.isLetter }) else { return nil }
    return String(text.prefix(textLimit))
}

private func pdfText(_ url: URL) async throws -> String? {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
    let pages = (0..<min(2, doc.pageCount)).compactMap { doc.page(at: $0) }
    let text = pages.compactMap(\.string).joined(separator: "\n")
    if text.contains(where: { $0.isLetter }) { return text }
    // A scanned PDF has no text layer; read its first page with OCR instead.
    let image = pages[0].thumbnail(of: CGSize(width: 1700, height: 2200), for: .mediaBox)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return try await ocr(cg)
}

// Vision blocks its calling thread. Run it on its own queue so it cannot starve the
// Swift concurrency pool, which deadlocked with 8 OCR calls in flight.
private let ocrQueue = DispatchQueue(label: "putaway.ocr")

private func ocr(_ image: CGImage) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        ocrQueue.async {
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
