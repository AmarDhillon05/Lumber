// Which build is this? CI stamps CFBundleVersion with the run number and
// LumberCommit with the short commit (see project.yml), so a phone's build can
// be matched to its CI run. Local builds show "dev".

import Foundation

enum BuildInfo {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var version: String { info("CFBundleShortVersionString").isEmpty ? "1.0.0" : info("CFBundleShortVersionString") }

    /// The CI run number, "" for a local build.
    static var build: String {
        let b = info("CFBundleVersion")
        return b == "0" ? "" : b
    }

    static var commit: String { info("LumberCommit") }
    static var configuration: String { info("LumberConfiguration") }

    /// "v1.0.0 #42" / "v1.0.0 dev"
    static var shortLabel: String { "v\(version) \(build.isEmpty ? "dev" : "#\(build)")" }

    /// "Lumber (native) 1.0.0 · build 42 · abc1234 · Release"
    static var label: String {
        ["Lumber (native) \(version)", build.isEmpty ? "local build" : "build \(build)", commit, configuration]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
