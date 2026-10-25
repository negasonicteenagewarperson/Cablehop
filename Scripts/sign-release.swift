// Signs a release's SHA256SUMS.txt so Cablehop's updater can tell it really came from you.
//
//   swift Scripts/sign-release.swift --generate        create the signing key (once) and print its public key
//   swift Scripts/sign-release.swift dist/SHA256SUMS.txt   write dist/SHA256SUMS.txt.sig
//
// The private key lives outside the project, in ~/.cablehop-release-key (readable only by you), or wherever
// CABLEHOP_SIGNING_KEY points. Back it up somewhere safe: without it, future releases can't be installed by
// the in-app updater (people can still download them by hand). Never commit it.
import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["CABLEHOP_SIGNING_KEY"]
    ?? (NSHomeDirectory() + "/.cablehop-release-key")
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

if args.first == "--generate" {
    guard !FileManager.default.fileExists(atPath: keyPath) else { fail("A key already exists at \(keyPath); not overwriting it.") }
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print("Created \(keyPath)")
    print("Public key (put this in Updater.swift): \(key.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

guard let file = args.first else { fail("Usage: swift Scripts/sign-release.swift <SHA256SUMS.txt> | --generate") }
guard let encoded = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
else { fail("No signing key at \(keyPath). Create one with --generate.") }
guard let data = FileManager.default.contents(atPath: file) else { fail("Can't read \(file)") }

let signature = try key.signature(for: data)
try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: file + ".sig"))
print("Signed \(file) → \(file).sig")
