import Foundation

@main
struct ResourceChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: ResourceChecks <app path> <SwiftPM binary directory>")
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let binaryDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let installed = ChatResourceLocation.indexURL(resourceRoot: app.appending(path: "Contents/Resources"), bundleRoot: app)
        let development = ChatResourceLocation.indexURL(resourceRoot: nil, bundleRoot: binaryDirectory)
        for url in [installed, development] {
            guard let url else { fatalError("Chat resource bundle is missing") }
            let root = url.deletingLastPathComponent()
            for file in ["index.html", "markup.js", "chat.js", "vendor/katex.min.js", "vendor/markdown-it.min.js"] {
                guard FileManager.default.fileExists(atPath: root.appending(path: file).path) else {
                    fatalError("Missing offline chat resource: \(file)")
                }
            }
        }
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        guard ChatResourceLocation.indexURL(resourceRoot: missing, bundleRoot: missing) == nil else {
            fatalError("Unexpected fallback to a developer directory")
        }
        print("PASS  App and SwiftPM chat resources resolve without an absolute build-path fallback")
    }
}
