import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// Validate the final public payload against the key embedded in the app, not
// merely against whichever private key the release runner happens to possess.
guard CommandLine.arguments.count == 6 else {
    fail("Usage: verify-appcast.swift appcast.xml Reclaim.zip public-key.txt version build")
}
let args = CommandLine.arguments
let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[1]))
let items = try document.nodes(forXPath: "/rss/channel/item")
guard items.count == 1, let item = items.first as? XMLElement,
      let enclosure = item.elements(forName: "enclosure").first,
      let signatureString = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
      let signature = Data(base64Encoded: signatureString),
      enclosure.attribute(forName: "url")?.stringValue == "https://github.com/torbensko/reclaim/releases/download/v\(args[4])/Reclaim.zip",
      item.elements(forName: "sparkle:version").first?.stringValue == args[5],
      item.elements(forName: "sparkle:shortVersionString").first?.stringValue == args[4],
      item.elements(forName: "sparkle:minimumSystemVersion").first?.stringValue == "14.0",
      item.elements(forName: "sparkle:channel").isEmpty else {
    fail("Unexpected release feed contents")
}
let publicText = try String(contentsOfFile: args[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let publicData = Data(base64Encoded: publicText) else { fail("Invalid public key") }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
      publicKey.isValidSignature(signature, for: archive) else {
    fail("Update archive signature or size does not match the published app's key")
}
print("Verified the release feed and archive signature against the app's public key.")
