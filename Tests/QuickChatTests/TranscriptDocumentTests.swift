import CryptoKit
import Foundation
import Testing
@testable import QuickChat

@Test func transcriptDocumentAllowsOnlyItsPackagedScriptsAndStyles() throws {
    let html = try TranscriptDocument.bundled.get()
    let policy = try #require(html.split(separator: "\n").first { $0.contains("Content-Security-Policy") })
    let sections = html.components(separatedBy: "<script>").dropFirst()
    #expect(sections.count == 4)
    for section in sections {
        let end = try #require(section.range(of: "</script>"))
        let source = section[..<end.lowerBound]
        let hash = Data(SHA256.hash(data: Data(source.utf8))).base64EncodedString()
        #expect(policy.contains("'sha256-\(hash)'"))
    }
    let cssStart = try #require(html.range(of: "<style>"))
    let cssEnd = try #require(html.range(of: "</style>"))
    let css = html[cssStart.upperBound..<cssEnd.lowerBound]
    let hash = Data(SHA256.hash(data: Data(css.utf8))).base64EncodedString()
    #expect(policy.contains("style-src 'sha256-\(hash)'"))
    #expect(policy.contains("default-src 'none'"))
    #expect(!html.contains("<script src="))
    #expect(!html.contains("<link rel=\"stylesheet\""))
}
