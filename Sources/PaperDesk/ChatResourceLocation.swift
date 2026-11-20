import Foundation

enum ChatResourceLocation {
    static func indexURL(resourceRoot: URL? = Bundle.main.resourceURL,
                         bundleRoot: URL = Bundle.main.bundleURL) -> URL? {
        // Resolve relative to the installed app or SwiftPM executable. Bundle.module
        // embeds the developer's absolute build directory as a fallback string.
        for root in [resourceRoot, bundleRoot].compactMap({ $0 }) {
            let location = root.appending(path: "PaperDesk_PaperDesk.bundle")
            if let bundle = Bundle(url: location),
               let index = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Chat") {
                return index
            }
        }
        return nil
    }
}
