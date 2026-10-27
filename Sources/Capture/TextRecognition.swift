import AppKit
import Vision

/// One thing Vision found in a capture: a text line or a barcode payload.
///
/// `confidence` is Vision's own 0…1 confidence for the observation, kept so the
/// result window can order or annotate entries without re-running the request.
struct RecognizedItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case barcode
    }

    let kind: Kind
    let text: String
    let confidence: Float
}

/// Vision wrappers for OCR and barcode/QR detection.
///
/// Pure and synchronous: give it an image, get an ordered array. No errors are
/// surfaced — Vision failures (unsupported language pack, malformed image) and
/// genuinely empty images both degrade to `[]`, because the caller only needs
/// to know whether there is something worth showing.
///
/// Ordering is intentional: barcodes come first, then text lines in reading
/// order (top-to-bottom, left-to-right). When someone screenshots a link they
/// almost always want the URL, not the surrounding caption.
/// Runtime knobs for OCR, fed by 设置 → OCR.
///
/// `nonisolated(unsafe)` is the same single-threaded UI contract as
/// `AnnotationDefaults`: settings writes on the main actor, Vision reads while
/// a capture is running.
enum TextRecognitionRuntime {
    nonisolated(unsafe) static var languages = TextRecognition.recognitionLanguages
    nonisolated(unsafe) static var detectsBarcodes = true
}

enum TextRecognition {
    /// The languages the text request asks for. Chinese first so a mixed
    /// screenshot is segmented with the CJK model, then English.
    static let recognitionLanguages = ["zh-Hans", "en-US"]

    /// 设置 → OCR → 语言. Only the three combinations that actually improve
    /// Vision's segmentation are offered.
    static func languages(for choice: String) -> [String] {
        switch choice {
        case "zh": ["zh-Hans"]
        case "en": ["en-US"]
        default: recognitionLanguages
        }
    }

    /// Common 1D/2D symbologies plus the retail ones. QR and Code128 are what
    /// links and screenshots actually contain; the rest cost nothing extra.
    static let barcodeSymbologies: [VNBarcodeSymbology] = [
        .qr,
        .aztec,
        .pdf417,
        .dataMatrix,
        .code128,
        .code39,
        .code39Checksum,
        .code93,
        .ean13,
        .ean8,
        .upce,
        .itf14,
        .codabar,
        .gs1DataBar,
        .gs1DataBarExpanded,
        .gs1DataBarLimited,
        .microQR,
        .microPDF417
    ]

    /// Recognise text and barcodes in one image. Barcodes come first.
    static func recognize(in image: NSImage) -> [RecognizedItem] {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return []
        }
        return recognize(in: cgImage)
    }

    /// Pixel-level entry point. Useful for callers that already hold a
    /// `CGImage` (the capture path) and for the self test.
    static func recognize(in cgImage: CGImage) -> [RecognizedItem] {
        guard cgImage.width > 0, cgImage.height > 0 else { return [] }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var items: [RecognizedItem] = []

        // Barcodes first — both the request order here and the final array.
        if let barcodes = recognizeBarcodes(with: handler) {
            items.append(contentsOf: barcodes)
        }
        if let texts = recognizeText(with: handler) {
            items.append(contentsOf: texts)
        }
        return items
    }

    // MARK: - Requests

    private static func recognizeBarcodes(
        with handler: VNImageRequestHandler
    ) -> [RecognizedItem]? {
        guard TextRecognitionRuntime.detectsBarcodes else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = barcodeSymbologies

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = (request.results ?? []).sorted(by: readingOrder)
        return observations.compactMap { observation in
            guard let payload = observation.payloadStringValue?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !payload.isEmpty else { return nil }
            return RecognizedItem(
                kind: .barcode,
                text: payload,
                confidence: observation.confidence
            )
        }
    }

    private static func recognizeText(
        with handler: VNImageRequestHandler
    ) -> [RecognizedItem]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = TextRecognitionRuntime.languages

        do {
            try handler.perform([request])
        } catch {
            // A language pack can be unavailable on a stripped-down system.
            // Fall back to English rather than losing text recognition.
            request.recognitionLanguages = ["en-US"]
            do {
                try handler.perform([request])
            } catch {
                return []
            }
        }

        let observations = (request.results ?? []).sorted(by: readingOrder)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedItem(
                kind: .text,
                text: text,
                confidence: candidate.confidence
            )
        }
    }

    /// Vision normalised boxes are bottom-left origin. Top-to-bottom first,
    /// then left-to-right; a 2 % vertical tolerance keeps words on the same
    /// visual line grouped by their x position instead of by tiny baseline
    /// differences.
    private static func readingOrder<T: VNDetectedObjectObservation>(_ lhs: T, _ rhs: T) -> Bool {
        let a = lhs.boundingBox
        let b = rhs.boundingBox
        if abs(a.maxY - b.maxY) > 0.02 {
            return a.maxY > b.maxY
        }
        return a.minX < b.minX
    }
}
