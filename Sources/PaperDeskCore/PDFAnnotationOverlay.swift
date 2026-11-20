import AppKit
import PDFKit

/// Tracks only annotations created by this reader session, preserving imported PDF annotations.
@MainActor
public final class PDFAnnotationOverlay {
    private weak var document: PDFDocument?
    private var applied: [PDFAnnotation] = []
    private var snapshot: [ReadingNote]?

    public init() { }

    public func apply(_ notes: [ReadingNote], to document: PDFDocument?) {
        guard self.document !== document || snapshot != notes else { return }
        for annotation in applied { annotation.page?.removeAnnotation(annotation) }
        applied = []; self.document = document; snapshot = notes
        guard let document else { return }
        for note in notes {
            guard let page = document.page(at: note.page) else { continue }
            for rect in note.rects {
                let annotation = PDFAnnotation(bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                    forType: .highlight, withProperties: nil)
                annotation.color = NSColor(calibratedRed: 1, green: 0.83, blue: 0.22, alpha: 0.45)
                annotation.contents = note.body.isEmpty ? note.quote : note.body
                annotation.userName = "PaperDesk"
                annotation.setValue(note.id, forAnnotationKey: PDFAnnotationKey(rawValue: "PaperDeskID"))
                page.addAnnotation(annotation)
                applied.append(annotation)
            }
        }
    }
}
