import AppKit
import Foundation

let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 10)
watchdog.setEventHandler {
    fputs("FAIL: markdown rendering did not finish within 10 seconds\n", stderr)
    exit(1)
}
watchdog.resume()

_ = NSApplication.shared
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

watchdog.cancel()
print("PASS: \(checks) markdown rendering checks")
