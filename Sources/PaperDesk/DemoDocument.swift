import AppKit
import PDFKit
import PaperDeskCore

enum DemoDocument {
    static func make() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PaperDesk-Demo-v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "PaperDesk — 阅读示例.pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let metadata = [kCGPDFContextTitle as String: "Reading with evidence", kCGPDFContextAuthor as String: "PaperDesk"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, metadata) else { throw PaperDeskError.message("无法生成示例文献。") }
        let teal = NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.40, alpha: 1)
        let ink = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1)
        let muted = NSColor(calibratedWhite: 0.43, alpha: 1)
        let pages: [(String, String, [(String, String)])] = [
            ("Reading with\nevidence", "A practical guide to a thoughtful research workflow", [
                ("ABSTRACT", "A useful research tool keeps ideas close to their sources. This demonstration document introduces an evidence-first reading workflow: explore the paper, select a passage, record an observation, and return to the source whenever a claim needs checking. It is an original product demo, not a published research study."),
                ("01   Start with the question", "Before reading, write down what you want to understand. A precise question helps separate the paper's central argument from background details. Read the abstract, inspect the figures, and identify the evidence that would change your understanding."),
                ("02   Keep context attached", "A highlight is most useful when it carries a reason. Add a short note explaining why the passage matters, what assumption it makes, or which question it answers. Store the page and position together with the quotation so the observation can always be checked.")
            ]),
            ("From highlights\nto understanding", "Small annotations, durable knowledge", [
                ("03   Annotate with intent", "Select a sentence and save a highlight. Describe the idea in your own words, then add one question that remains open. This small act of interpretation makes a note more valuable than a copied paragraph. In PaperDesk, highlights remain connected to their original PDF coordinates."),
                ("04   Ask grounded questions", "An AI reading assistant should distinguish evidence from interpretation. Ask it to explain a passage, translate an unfamiliar term, or compare two claims. A useful answer points back to the passages it used. If the provided context is incomplete, the answer should make that limitation explicit."),
                ("05   Check the source", "A citation is a path back to the document, not a guarantee that an answer is correct. Open the cited passage and inspect its context. Check whether the source supports the exact claim, whether important qualifications were omitted, and whether a figure or table tells a different story.")
            ]),
            ("Make room\nfor your own ideas", "A reading checklist you can actually use", [
                ("06   Build a reading habit", "Return to your notes after finishing a paper. Write a short synthesis: the research question, the main contribution, the evidence, and the limitations. Separate the author's conclusions from your own hypotheses. Keep unresolved questions visible for the next reading session."),
                ("TRY IT IN PAPERDESK", "1. Select a sentence in this document.\n2. Click the highlight button or press Command-Shift-H.\n3. Add a note in the right-hand panel.\n4. Search for a word using Command-F.\n5. Click a saved note to return to its source.\n6. Configure your model service to try translation and questions."),
                ("ABOUT THIS DOCUMENT", "This three-page sample was created for PaperDesk. All text is original demonstration content. Your library, reading progress, notes, and conversations are stored locally. AI requests send relevant text to the model service you configure, only when you ask a question.")
            ])
        ]
        func draw(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, font: NSFont, color: NSColor, line: CGFloat = 5) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = line
            (text as NSString).draw(in: CGRect(x: x, y: 792 - top - height, width: width, height: height), withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ])
        }
        for (index, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw("PAPERDESK   /   FIELD NOTES", x: 60, top: 44, width: 400, height: 18, font: .systemFont(ofSize: 9, weight: .semibold), color: teal)
            context.setStrokeColor(teal.withAlphaComponent(0.35).cgColor)
            context.move(to: CGPoint(x: 60, y: 714)); context.addLine(to: CGPoint(x: 552, y: 714)); context.strokePath()
            draw(page.0, x: 60, top: 100, width: 500, height: 100, font: .systemFont(ofSize: 38, weight: .semibold), color: ink, line: 1)
            draw(page.1, x: 62, top: 211, width: 490, height: 30, font: .systemFont(ofSize: 12), color: muted)
            var top: CGFloat = 278
            for (heading, body) in page.2 {
                draw(heading, x: 62, top: top, width: 488, height: 20, font: .systemFont(ofSize: 10, weight: .bold), color: teal)
                draw(body, x: 62, top: top + 29, width: 488, height: 112, font: .systemFont(ofSize: 11.5), color: ink, line: 5)
                top += 145
            }
            draw("PAPERDESK DEMO     •     ORIGINAL SAMPLE DOCUMENT", x: 62, top: 752, width: 440, height: 16, font: .systemFont(ofSize: 8), color: muted)
            draw(String(format: "%02d", index + 1), x: 522, top: 750, width: 30, height: 20, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: teal)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        let children: [[String: Any]] = pages.enumerated().map { index, entry in
            [kCGPDFOutlineTitle as String: entry.0.replacingOccurrences(of: "\n", with: " "),
             kCGPDFOutlineDestination as String: index + 1]
        }
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        context.closePDF()
        return url
    }
}
