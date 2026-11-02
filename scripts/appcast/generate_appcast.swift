// Generates the Sparkle 2 appcast.xml for BusinessBar from GitHub Release DMGs.
//
// swift generate_appcast.swift <output.xml> <appcast-url> <ed25519-seed-b64> <dmg|version|build> [dmg|version|build...]
//   dmg     local file path or download URL of a release DMG
//   version marketing version, e.g. 1.6.2
//   build   CFBundleVersion of that release, e.g. 17 (must grow per release)

import CryptoKit
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

func rfc1123(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZ"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}

guard CommandLine.arguments.count >= 5 else {
    fail("usage: generate_appcast.swift <output.xml> <appcast-url> <seed-b64> <dmg|version|build> [dmg|version|build...]")
}

let output = CommandLine.arguments[1]
let appcastURL = CommandLine.arguments[2].trimmingCharacters(in: .whitespaces)
let seedB64 = CommandLine.arguments[3].trimmingCharacters(in: .whitespaces)

guard let seedData = Data(base64Encoded: seedB64), seedData.count == 32 else {
    fail("seed must be base64 of 32 bytes")
}
let privateKey: Curve25519.Signing.PrivateKey
do {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
} catch {
    fail("bad seed: \(error)")
}

struct Item {
    let url: String
    let version: String
    let build: Int
    let length: Int
    let signature: String
}

var items: [Item] = []

for arg in CommandLine.arguments[4...] {
    let parts = arg.split(separator: "|", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { fail("argument '\(arg)' must be dmg|version|build") }
    let path = parts[0]
    let version = parts[1]
    guard let build = Int(parts[2]) else { fail("build must be an integer in '\(arg)'") }

    let data: Data
    do {
        if path.hasPrefix("http") {
            guard let url = URL(string: path) else { fail("bad url \(path)") }
            data = try Data(contentsOf: url)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
    } catch {
        fail("load \(path): \(error)")
    }

    let signature = try! privateKey.signature(for: data).base64EncodedString()
    items.append(Item(url: path, version: version, build: build, length: data.count, signature: signature))
}

guard !items.isEmpty else { fail("no items") }

let sorted = items.sorted { $0.build > $1.build }

var xml = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
<title>BusinessBar</title>
<link>\(esc(appcastURL))</link>
<description>BusinessBar release feed</description>
<language>en</language>

"""

for item in sorted {
    xml += """
<item>
<title>BusinessBar \(esc(item.version))</title>
<description>BusinessBar \(esc(item.version))</description>
<pubDate>\(rfc1123(Date()))</pubDate>
<sparkle:version>\(item.build)</sparkle:version>
<sparkle:shortVersionString>\(esc(item.version))</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<enclosure
url="\(esc(item.url))"
sparkle:edSignature="\(item.signature)"
length="\(item.length)"
type="application/x-apple-diskimage"
/>
</item>

"""
}

xml += """
</channel>
</rss>
"""

do {
    try xml.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
    print("wrote \(output) with \(sorted.count) item(s)")
} catch {
    fail("write \(output): \(error)")
}