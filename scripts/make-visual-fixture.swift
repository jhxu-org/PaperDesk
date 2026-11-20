// Original synthetic fixture; no user paper is sent during local visual checks.
import AppKit
import PDFKit

let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/visual-fixture.pdf")
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let context = CGContext(url as CFURL, mediaBox: &box, nil)!
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 14, _ width: CGFloat = 490) {
    (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 80),
        withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
}
for index in 0..<2 {
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text("PAPERDESK / ORIGINAL VISUAL FIXTURE", 54, 675, 22)
    if index == 0 {
        text("A local test of illustrated paper reading", 54, 570, 20)
        text("This synthetic document verifies that a discussion can show a figure from another page. The diagram and values are invented for software testing, not research results.", 54, 440)
        text("The evaluation illustration is on physical PDF page 2. Use it to verify image previews, zoom, PDF navigation and caption highlighting.", 54, 320)
    } else {
        text("Illustrative results", 54, 580, 20)
        context.setStrokeColor(NSColor.gray.cgColor); context.setLineWidth(1)
        context.move(to: CGPoint(x: 95, y: 280)); context.addLine(to: CGPoint(x: 95, y: 540))
        context.move(to: CGPoint(x: 95, y: 280)); context.addLine(to: CGPoint(x: 520, y: 280)); context.strokePath()
        for (bar, value) in [40, 70, 90].enumerated() {
            let x = CGFloat(145 + bar * 120)
            context.setFillColor(NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.49, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: 280, width: 65, height: CGFloat(value) * 2.5))
            text("\(value)", x + 12, 280 + CGFloat(value) * 2.5, 15, 50)
            text(["A", "B", "C"][bar], x + 20, 192, 14, 50)
        }
        text("Figure 1: Synthetic comparison of A, B and C.", 54, 128, 14)
        text("All values are illustrative. C has the tallest bar (90). No scientific claim is made.", 54, 68, 12)
    }
    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
}
context.closePDF()
print(url.path)
