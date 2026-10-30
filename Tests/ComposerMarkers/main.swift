import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(message)")
    }
}

func pump() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
}

func descendant<T: NSView>(_ root: NSView, of type: T.Type) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let match = descendant(child, of: type) { return match }
    }
    return nil
}

func rows(in view: ComposerNSTextView) -> [NSRect] {
    let manager = view.layoutManager!
    let container = view.textContainer!
    manager.ensureLayout(for: container)
    var result: [NSRect] = []
    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
        rect, _, _, _, _ in result.append(rect)
    }
    if manager.extraLineFragmentTextContainer === container {
        result.append(manager.extraLineFragmentRect)
    }
    return result
}

func verifyMarkers(_ view: ComposerNSTextView, _ label: String, expected: Int? = nil) {
    let text = view.string
    let selection = view.selectedRange()
    view.layout()
    let fragments = rows(in: view)
    let wanted = text.isEmpty ? 0 : max(0, fragments.count - 1)
    if let expected { expect(wanted == expected, "\(label): native row count \(wanted), expected \(expected)") }
    let markers = view.markerLayers
    expect(markers.count == wanted, "\(label): expected \(wanted) arrows, got \(markers.count)")
    expect(markers.allSatisfy { ($0.string as? String) == "↩" }, "\(label): only return arrows, got \(markers.map { $0.string ?? "nil" })")
    expect(markers.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= view.textContainerOrigin.x + 0.01 }, "\(label): arrows stay in left gutter")
    for (marker, fragment) in zip(markers, fragments.dropFirst()) {
        expect(abs(marker.frame.minY - (view.textContainerOrigin.y + fragment.minY)) < 0.1, "\(label): arrow follows row y")
        expect(abs(marker.frame.height - fragment.height) < 0.1, "\(label): arrow follows row height")
        expect(abs(marker.frame.width - 12) < 0.1, "\(label): existing 12pt marker width")
        expect(marker.superlayer === view.layer, "\(label): marker attached to text view")
    }
    expect(view.string == text, "\(label): layout preserves text")
    expect(view.selectedRange() == selection, "\(label): layout preserves caret/selection")
    let drawRect = NSRect(x: 0, y: 0, width: min(view.bounds.width, 640), height: min(view.bounds.height, 160))
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: drawRect) {
        view.cacheDisplay(in: drawRect, to: bitmap)
        expect(view.string == text && view.selectedRange() == selection, "\(label): drawing preserves text and selection")
        expect(view.markerLayers.map(\.frame) == markers.map(\.frame), "\(label): draw and layout marker positions agree")
    } else {
        expect(false, "\(label): native bitmap drawing context exists")
    }
    let baseline = view.layer?.sublayers?.count ?? 0
    let previous = view.markerLayers
    for _ in 0..<6 { view.layout() }
    expect(view.markerLayers.count == wanted, "\(label): repeated layout has no duplicate markers")
    expect((view.layer?.sublayers?.count ?? 0) == baseline, "\(label): repeated layout does not leak sublayers")
    let currentIDs = Set(view.markerLayers.map(ObjectIdentifier.init))
    expect(previous.allSatisfy { currentIDs.contains(ObjectIdentifier($0)) || $0.superlayer == nil }, "\(label): replaced layers detached")
    expect(view.string == text && view.selectedRange() == selection, "\(label): repeated layout preserves text and selection")
}

final class Storage {
    var text = "one\ntwo"
    var focus = 0
    var sends = 0
    var heights: [CGFloat] = []
}
let storage = Storage()
func composer() -> ComposerTextView {
    ComposerTextView(
        text: Binding(get: { storage.text }, set: { storage.text = $0 }),
        focusRequest: Binding(get: { storage.focus }, set: { storage.focus = $0 }),
        onReturn: { storage.sends += 1 },
        onPaste: { _ in fatalError("Fixture must not paste") },
        onContentHeight: { storage.heights.append($0) }
    )
}
let host = NSHostingView(rootView: composer())
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = host
host.layoutSubtreeIfNeeded()
pump()
guard let view = descendant(host, of: ComposerNSTextView.self),
      let scroll = descendant(host, of: ComposerScrollView.self) else {
    print("FAIL actual ComposerTextView did not create native composer")
    exit(1)
}
view.wantsLayer = true
verifyMarkers(view, "hard break", expected: 1)
if CommandLine.arguments.contains("--red-only") {
    print("Composer markers: \(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

let cases: [(String, String, Int?)] = [
    ("empty", "", 0),
    ("plain", "plain text", 0),
    ("hard break", "one\ntwo", 1),
    ("trailing newline", "one\n", 1),
    ("single newline", "\n", 1),
    ("blank consecutive lines", "one\n\n\ntwo", 3),
    ("blank trailing lines", "one\n\n", 2),
    ("CRLF", "one\r\ntwo\r\n", 2),
    ("literal pilcrow", "¶ user text\n¶ stays", 1),
    ("soft wrap", String(repeating: "word ", count: 35), nil),
    ("mixed", String(repeating: "word ", count: 20) + "\n\n" + String(repeating: "tail ", count: 20) + "\n", nil),
    ("unicode", "👨‍👩‍👧‍👦 café\n日本語\n", 2)
]

for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearanceName)
    for width: CGFloat in [120, 280, 640] {
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 72)
        scroll.tile()
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: 1200))
        for (name, text, count) in cases {
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: min(2, (text as NSString).length)))
            let label = "\(appearanceName.rawValue)/\(Int(width))/\(name)"
            // Exact short-line counts apply only where their text fits without a soft wrap.
            verifyMarkers(view, label, expected: width >= 280 ? count : nil)
            if name == "soft wrap" { expect(view.markerLayers.count > 0, "\(label): wrapping exercised") }
        }
    }
}

scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 64)
scroll.tile()
view.setFrameSize(NSSize(width: scroll.contentSize.width, height: 1200))
view.string = (0..<40).map { "row \($0)" }.joined(separator: "\n")
view.setSelectedRange(NSRange(location: 0, length: 0))
verifyMarkers(view, "before scrolling", expected: 39)
let originalFrames = view.markerLayers.map(\.frame)
scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
scroll.reflectScrolledClipView(scroll.contentView)
verifyMarkers(view, "after scrolling", expected: 39)
expect(scroll.contentView.bounds.origin.y > 0, "scrolling fixture actually scrolled")
expect(view.markerLayers.map(\.frame) == originalFrames, "scrolling preserves document-relative marker positions")

view.string = String(repeating: "resize word ", count: 30)
view.layout()
let narrowCount = view.markerLayers.count
view.setFrameSize(NSSize(width: 640, height: 1200))
verifyMarkers(view, "resize to wide")
expect(view.markerLayers.count < narrowCount, "wider text view reduces wrapped rows")
view.setFrameSize(NSSize(width: 120, height: 1200))
verifyMarkers(view, "resize back narrow")
expect(view.markerLayers.count > narrowCount, "narrower text view increases wrapped rows")

storage.text = "external\nupdate\n"
host.rootView = composer()
host.layoutSubtreeIfNeeded()
pump()
expect(view.string == storage.text, "Binding update reaches native text")
verifyMarkers(view, "Binding update", expected: 2)
storage.text = String(repeating: "row\n", count: 12)
host.rootView = composer()
host.layoutSubtreeIfNeeded()
pump()
verifyMarkers(view, "overflowing Binding update", expected: 12)
let caretRowBottom = view.textContainerOrigin.y + (rows(in: view).last?.maxY ?? 0)
expect(view.frame.height + 0.1 >= caretRowBottom, "Binding update: document height \(view.frame.height) includes trailing caret row bottom \(caretRowBottom)")
expect(view.markerLayers.allSatisfy { $0.frame.maxY <= view.bounds.maxY + 0.1 }, "overflowing Binding update: all arrows fit document bounds")
print("Trailing caret allocation: document height \(view.frame.height), final row bottom \(caretRowBottom), last arrow bottom \(view.markerLayers.last?.frame.maxY ?? -1)")
expect(!storage.heights.isEmpty && storage.heights.allSatisfy { $0 > 0 }, "host reports positive content height")

func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
}
for code: UInt16 in [36, 76] {
    view.string = "send"
    view.setSelectedRange(NSRange(location: 4, length: 0))
    let before = storage.sends
    view.keyDown(with: key(code))
    expect(storage.sends == before + 1, "key \(code): Return sends once")
    expect(view.string == "send", "key \(code): sending inserts no newline")
    expect(view.selectedRange() == NSRange(location: 4, length: 0), "key \(code): sending preserves caret")
    for modifiers: NSEvent.ModifierFlags in [.shift, .option] {
        view.string = "line"
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let sends = storage.sends
        view.keyDown(with: key(code, modifiers: modifiers))
        expect(view.string == "line\n", "key \(code)/\(modifiers.rawValue): modifier inserts newline")
        expect(storage.text == view.string, "key \(code)/\(modifiers.rawValue): edit updates Binding")
        expect(storage.sends == sends, "key \(code)/\(modifiers.rawValue): newline does not send")
        verifyMarkers(view, "modified Return \(code)/\(modifiers.rawValue)", expected: 1)
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-dir"), flag + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    window.setContentSize(NSSize(width: 280, height: 100))
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        storage.text = "First input line\n" + String(repeating: "wrapped text ", count: 9) + "\n\nLast line\n"
        host.rootView = composer()
        host.layoutSubtreeIfNeeded()
        pump()
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        verifyMarkers(view, "snapshot \(name)")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            expect(false, "snapshot \(name): bitmap allocated")
            continue
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
            let marker = NSColor.systemGray.withAlphaComponent(0.55).usingColorSpace(.sRGB)!
            func luminance(_ channels: [CGFloat]) -> CGFloat {
                let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
            }
            let backdrop = [background.redComponent, background.greenComponent, background.blueComponent]
            let foreground = [marker.redComponent, marker.greenComponent, marker.blueComponent]
            let composite = zip(foreground, backdrop).map { $0 * marker.alphaComponent + $1 * (1 - marker.alphaComponent) }
            let a = luminance(composite)
            let b = luminance(backdrop)
            let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            print("Existing marker contrast on native text background (\(name)): \(String(format: "%.2f", Double(ratio))):1, unchanged decoration, not an AA claim")
        }
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let destination = directory.appendingPathComponent("composer-\(name).png")
            try data.write(to: destination)
            print("Native snapshot: \(destination.path)")
        } else {
            expect(false, "snapshot \(name): PNG encoded")
        }
    }
}

window.close()
print("Composer markers: \(checks) checks, \(failures) failures, 72 appearance/width/content combinations")
exit(failures == 0 ? 0 : 1)
