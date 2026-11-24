import AppKit
import CryptoKit
import Foundation

enum PopupSurface {
    private static let light = 0xF8F9FB
    private static let dark = 0x202124

    static let color = NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                       green: Double((rgb >> 8) & 0xFF) / 255,
                       blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }

    static let stylesheet = """
    :root { --canvas: \(String(format: "#%06x", light)); }
    @media (prefers-color-scheme: dark) { :root { --canvas: \(String(format: "#%06x", dark)); } }
    """
}

struct TranscriptDocument {
    enum AssetError: Error { case invalidInlineAsset }

    static let bundled = Result { try makeHTML() }

    static func makeHTML() throws -> String {
        let assets = Bundle.module.resourceURL!.appendingPathComponent("TranscriptAssets", isDirectory: true)
        let styles = try PopupSurface.stylesheet + "\n"
            + read(assets.appendingPathComponent("transcript.css"), tag: "style")
        let scripts = try ["markdown-it.min.js", "highlight.min.js", "katex.min.js", "transcript.js"].map {
            try read(assets.appendingPathComponent($0), tag: "script")
        }
        let policies = "default-src 'none'; script-src \(scripts.map(hash).joined(separator: " ")); "
            + "style-src \(hash(styles)); base-uri 'none'; form-action 'none'"
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policies)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Transcript</title>
        <style>\(styles)</style>
        </head>
        <body>
        <main id="transcript" class="transcript"></main>
        \(scripts.map { "<script>\($0)</script>" }.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func read(_ file: URL, tag: String) throws -> String {
        // HTML normalizes line endings before checking CSP hashes.
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard text.range(of: "</\(tag)", options: .caseInsensitive) == nil else {
            throw AssetError.invalidInlineAsset
        }
        return text
    }

    private static func hash(_ text: String) -> String {
        "'sha256-\(Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString())'"
    }
}
