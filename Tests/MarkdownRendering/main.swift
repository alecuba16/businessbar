import AppKit
import Foundation
import SwiftUI

let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 10)
watchdog.setEventHandler {
    fputs("FAIL: markdown rendering did not finish within 10 seconds\n", stderr)
    exit(1)
}
watchdog.resume()

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0

func expectText(_ markdown: String, _ expected: String) {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown)
    guard rendered.string == expected else {
        fputs("FAIL: \(markdown.debugDescription) rendered as \(rendered.string.debugDescription), expected \(expected.debugDescription)\n", stderr)
        exit(1)
    }
    checks += 1
}

for literal in [
    "Hello!", "*unfinished", "**unfinished", "_unfinished", "__unfinished",
    "`unfinished", "~unfinished", "~~unfinished", "[label](", "![alt](",
    "snake_case_identifier", "trailing*", "trailing_", "trailing`",
    "trailing~", "trailing[", "trailing!", "🙂 [", "a\\*", ""
] {
    expectText(literal, literal.isEmpty ? "" : literal + "\n")
}

expectText("`code`", "code\n")
expectText("[link](https://example.com)", "link\n")
expectText("First paragraph!\n\nSecond paragraph!", "First paragraph!\n\nSecond paragraph!\n")

let streamedReplies = [
    "Hello! A *partial emphasis*, **bold**, ~~strike~~ and `code`.",
    "A [link](https://example.com) and ![image](https://example.com/a.png).",
    "## Heading\n\nFirst paragraph!\n\n- One\n- Two\n\n```swift\nlet value = 1\n```",
    "snake_case_identifier with trailing punctuation: [!_*~` 🙂"
]
for reply in streamedReplies {
    for end in reply.indices {
        _ = MarkdownAttributedStringLoader.attributedString(for: String(reply[..<end]))
        checks += 1
    }
    _ = MarkdownAttributedStringLoader.attributedString(for: reply)
    checks += 1
}

for length in [1, 2, 8, 32, 128, 512] {
    _ = MarkdownAttributedStringLoader.attributedString(for: String(repeating: "!", count: length))
    checks += 1
}

func findTextView(in view: NSView) -> MarkdownTextView? {
    if let textView = view as? MarkdownTextView { return textView }
    return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
}

struct MarkdownBubbleFixture: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading) {
            MarkdownTextHostingView(markdown: markdown)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

let hostingView = NSHostingView(rootView: MarkdownBubbleFixture(markdown: ""))
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isReleasedWhenClosed = false
window.contentView = hostingView

var heartbeats = 0
let heartbeat = Timer(timeInterval: 0.002, repeats: true) { _ in heartbeats += 1 }
RunLoop.main.add(heartbeat, forMode: .common)

func renderNative(_ markdown: String, expected: String? = nil) {
    hostingView.rootView = MarkdownBubbleFixture(markdown: markdown)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    guard let textView = findTextView(in: hostingView),
          textView.markdownTag == markdown else {
        fputs("FAIL: native text view did not receive its markdown update\n", stderr)
        exit(1)
    }
    if let expected, textView.string != expected {
        fputs("FAIL: native text storage differs from the expected reply\n", stderr)
        exit(1)
    }
    checks += 1
}

let nativeReply = "Hello! [unfinished"
for end in nativeReply.indices {
    renderNative(String(nativeReply[..<end]))
}
renderNative("First paragraph!\n\nSecond paragraph!", expected: "First paragraph!\n\nSecond paragraph!\n")
if let textView = findTextView(in: hostingView) {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13))
    guard textView.frame.width > 0, textView.frame.height >= lineHeight * 3 else {
        fputs("FAIL: chat text view clips its paragraphs at frame \(textView.frame)\n", stderr)
        exit(1)
    }
    checks += 1
    textView.selectAll(nil)
    guard textView.selectedRange() == NSRange(location: 0, length: textView.textStorage?.length ?? 0) else {
        fputs("FAIL: native select-all did not include both paragraphs\n", stderr)
        exit(1)
    }
    checks += 1
}

if let option = CommandLine.arguments.firstIndex(of: "--stream-chunks") {
    guard option + 1 < CommandLine.arguments.count else {
        fputs("FAIL: --stream-chunks requires a recorded stream JSON path\n", stderr)
        exit(1)
    }
    struct RecordedStream: Decodable {
        let chunks: [String]
        let fullText: String
        let terminal: String
    }
    let stream: RecordedStream
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[option + 1]))
        stream = try JSONDecoder().decode(RecordedStream.self, from: data)
    } catch {
        fputs("FAIL: cannot read the recorded stream JSON: \(error)\n", stderr)
        exit(1)
    }
    guard stream.terminal == "finished", !stream.chunks.isEmpty else {
        fputs("FAIL: local-model stream did not finish with text chunks\n", stderr)
        exit(1)
    }
    var reply = ""
    for chunk in stream.chunks {
        reply += chunk
        renderNative(reply)
    }
    guard reply == stream.fullText else {
        fputs("FAIL: streamed deltas differ from the finished reply\n", stderr)
        exit(1)
    }
    checks += 1
    print("PASS: \(stream.chunks.count) real local-model chunks rendered through the native hosting view")
}

heartbeat.invalidate()
window.close()
guard heartbeats > 0 else {
    fputs("FAIL: main run loop did not advance during native rendering\n", stderr)
    exit(1)
}
checks += 1
watchdog.cancel()
print("PASS: \(checks) markdown rendering checks")
