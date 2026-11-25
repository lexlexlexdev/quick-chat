import CryptoKit
import Foundation
import JavaScriptCore
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

@Test func transcriptRendersDisplayMathBesideProse() throws {
    let render = try transcriptMarkdownRenderer()
    let formula = #"h(k,i) = \bigl(h_1(k) + i \cdot h_2(k)\bigr) \bmod m"#
    for source in [
        #"Before \["# + formula + #"\] after."#,
        "Before $$" + formula + "$$ after.",
        "Before \\[\n" + formula + "\n\\] after."
    ] {
        let html = try render(source)
        #expect(html.contains(#"Before <span class="math-display">"#))
        #expect(html.contains(#"display="block""#))
        #expect(html.contains("<msub>"))
        #expect(html.contains("</span> after."))
    }
    #expect(try render(#"\[x^2\] trailing"#).contains("</span> trailing"))
    for source in [#"\[x^2\]"#, "$$x^2$$", "\\[\nx^2\n\\]", "$$\nx^2\n$$"] {
        let html = try render(source)
        #expect(html.hasPrefix(#"<div class="math-display">"#))
        #expect(html.contains(#"display="block""#))
    }
    for source in [#"Text \(x^2\)"#, "Text $x^2$"] {
        let html = try render(source)
        #expect(html.contains("<msup>"))
        #expect(!html.contains(#"display="block""#))
    }
}

@Test func transcriptPreservesCodeCurrencyAndUnfinishedOrInvalidMath() throws {
    let render = try transcriptMarkdownRenderer()
    for source in [
        #"`$$x^2$$` and `\[x^2\]`"#,
        "~~~text\n$$x^2$$\n\\[x^2\\]\n~~~",
        "\\[\n~~~text\nx^2\\]\n~~~",
        #"Escaped \$$x^2$$ and \\[x^2\\]"#,
        "Prices: $10 and $20."
    ] {
        #expect(try !render(source).contains("<math"))
    }
    let partial = #"Before \[x^2"#
    #expect(try render(partial).contains(partial))
    #expect(try !render(partial).contains("<math"))
    #expect(try render(partial + #"\] after"#).contains(#"display="block""#))
    let invalid = try render(#"Before \[\unknown{<img>}\] after"#)
    #expect(invalid.contains(#"\[\unknown{&lt;img&gt;}\]"#))
    #expect(!invalid.contains("<img"))
}

private func transcriptMarkdownRenderer() throws -> (String) throws -> String {
    let context = try #require(JSContext())
    context.evaluateScript("""
        var window = this;
        var document = { getElementById: () => ({ addEventListener() {} }), addEventListener() {} };
        function addEventListener() {}
        """)
    let sections = try TranscriptDocument.bundled.get().components(separatedBy: "<script>").dropFirst()
    for (index, section) in sections.enumerated() {
        let end = try #require(section.range(of: "</script>"))
        context.evaluateScript(String(section[..<end.lowerBound]))
        #expect(context.exception == nil)
        if index == 0 {
            context.evaluateScript("""
                var createMarkdown = markdownit;
                markdownit = (...options) => {
                    var parser = createMarkdown(...options);
                    window.renderMarkdown = text => parser.render(text);
                    return parser;
                };
                """)
        }
    }
    let render = try #require(context.objectForKeyedSubscript("renderMarkdown"))
    return { source in
        let value = try #require(render.call(withArguments: [source]))
        #expect(context.exception == nil)
        return try #require(value.toString())
    }
}
